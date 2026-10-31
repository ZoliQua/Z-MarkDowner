import AppKit
import MarkDownerCore

/// Sidebar tab listing the review comments imported from a PDF, with the actions on them: select the
/// passage, apply the suggestion, mark done or rejected, reopen, reply, and the bulk commands.
final class ReviewPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    weak var controller: ReviewController? { didSet { reload() } }

    private let headerLabel = NSTextField(labelWithString: "")
    private let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let authorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let applyAllButton = NSButton()
    private let marksButton = NSButton()
    private let exportButton = NSButton()
    private let aiAllButton = NSButton()
    private let aiStatusLabel = NSTextField(labelWithString: "")
    private let aiCancelButton = NSButton()
    private let aiStatusRow = NSStackView()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton()
    private var actionButtons: [(button: NSButton, action: Action)] = []
    private let topStack = NSStackView()
    private let actionBar = NSStackView()

    private var rows: [ReviewComment] = []
    private var heights: [String: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0
    private lazy var sizingCell = ReviewCommentCell()

    /// Number of comments the table shows with the current filters.
    var displayedCount: Int { rows.count }

    /// Width of the comment column (rows wrap at it).
    var columnWidth: CGFloat { table.tableColumns.first?.width ?? 0 }

    private enum Action: Int, CaseIterable {
        case select, apply, done, reject, reopen, reply, suggestAI
    }

    /// Whether the AI commands (Suggest Edit, Suggest Edits for All) are shown.
    var showsAIControls: Bool { AISuggester.isEnabled }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        headerLabel.font = .systemFont(ofSize: 11)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        filterPopup.addItems(withTitles: [L("review.filter.open", "Open"), L("review.filter.all", "All")])
        filterPopup.controlSize = .small
        filterPopup.font = .systemFont(ofSize: 11)
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        filterPopup.toolTip = L("review.filter.tip", "Show open comments or all comments")
        authorPopup.controlSize = .small
        authorPopup.font = .systemFont(ofSize: 11)
        authorPopup.target = self
        authorPopup.action = #selector(filterChanged)
        authorPopup.toolTip = L("review.filter.authorTip", "Show the comments of one reviewer")
        authorPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(applyAllButton, L("review.applyAll", "Apply All Suggestions"), "wand.and.stars", #selector(applyAllClicked))
        applyAllButton.title = L("review.applyAll", "Apply All Suggestions")
        applyAllButton.imagePosition = .imageLeading
        applyAllButton.lineBreakMode = .byTruncatingTail
        applyAllButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(marksButton, L("review.insertMarks", "Insert as Review Marks"), "text.bubble", #selector(marksClicked))
        configure(exportButton, L("review.exportResponse", "Export Response to Reviewers…"), "square.and.arrow.up", #selector(exportClicked))
        configure(aiAllButton, L("review.aiAll", "Suggest Edits for All (AI)"), "sparkles", #selector(aiAllClicked))
        aiStatusLabel.font = .systemFont(ofSize: 11)
        aiStatusLabel.textColor = .secondaryLabelColor
        aiStatusLabel.lineBreakMode = .byTruncatingTail
        aiStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        aiCancelButton.bezelStyle = .inline
        aiCancelButton.controlSize = .small
        aiCancelButton.title = L("button.cancel", "Cancel")
        aiCancelButton.target = self
        aiCancelButton.action = #selector(aiCancelClicked)
        aiStatusRow.setViews([aiStatusLabel, aiCancelButton], in: .leading)
        aiStatusRow.spacing = 6

        let filters = NSStackView(views: [filterPopup, authorPopup])
        filters.spacing = 6
        let bulk = NSStackView(views: [applyAllButton, NSView(), aiAllButton, marksButton, exportButton])
        bulk.spacing = 4
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = 5
        topStack.addArrangedSubview(headerLabel)
        topStack.addArrangedSubview(filters)
        topStack.addArrangedSubview(bulk)
        topStack.addArrangedSubview(aiStatusRow)
        bulk.widthAnchor.constraint(equalTo: topStack.widthAnchor).isActive = true
        aiStatusRow.widthAnchor.constraint(lessThanOrEqualTo: topStack.widthAnchor).isActive = true
        headerLabel.widthAnchor.constraint(lessThanOrEqualTo: topStack.widthAnchor).isActive = true
        filters.widthAnchor.constraint(lessThanOrEqualTo: topStack.widthAnchor).isActive = true

        let column = NSTableColumn(identifier: .init("comment"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        table.allowsEmptySelection = true
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let titles: [(Action, String, String)] = [
            (.apply, L("review.action.apply", "Apply Suggestion"), "wand.and.rays"),
            (.done, L("review.action.done", "Mark Done"), "checkmark.circle"),
            (.reject, L("review.action.reject", "Reject"), "xmark.circle"),
            (.reopen, L("review.action.reopen", "Reopen"), "arrow.uturn.backward.circle"),
            (.reply, L("review.action.reply", "Reply…"), "arrowshape.turn.up.left"),
            (.suggestAI, L("review.action.suggestAI", "Suggest Edit (AI)"), "sparkles"),
        ]
        for (action, title, symbol) in titles {
            let button = NSButton()
            configure(button, title, symbol, #selector(actionClicked(_:)))
            button.tag = action.rawValue
            actionButtons.append((button, action))
            actionBar.addArrangedSubview(button)
        }
        actionBar.spacing = 2
        actionBar.distribution = .fillEqually

        emptyLabel.stringValue = L("review.empty", "No review comments. Import the comments of a reviewed PDF to work through them here.")
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        importButton.title = L("review.importButton", "Import from PDF…")
        importButton.bezelStyle = .rounded
        importButton.target = self
        importButton.action = #selector(importClicked)

        for view in [topStack, scroll, actionBar, emptyLabel, importButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            topStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            topStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -4),
            actionBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            actionBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            importButton.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 12),
            importButton.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
        reload()
    }

    /// The single column always spans the visible width, so rows wrap at the sidebar's width.
    override func layout() {
        super.layout()
        guard scroll.contentSize.width > 0 else { return }
        if abs(table.frame.width - scroll.contentSize.width) > 0.5 { table.frame.size.width = scroll.contentSize.width }
        table.sizeLastColumnToFit()
    }

    private func configure(_ button: NSButton, _ title: String, _ symbol: String, _ action: Selector) {
        button.bezelStyle = .accessoryBarAction
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = action
    }

    // MARK: Content

    /// Rebuilds the list from the controller, keeping the selected comment.
    func reload() {
        let session = controller?.session
        let hasSession = session != nil
        for view in [topStack, scroll, actionBar] as [NSView] { view.isHidden = !hasSession }
        emptyLabel.isHidden = hasSession
        importButton.isHidden = hasSession
        let selectedID = selectedComment?.id

        let authors = Array(NSOrderedSet(array: (session?.comments ?? []).map(\.author).filter { !$0.isEmpty })) as? [String] ?? []
        let chosenAuthor = authorPopup.indexOfSelectedItem > 0 ? authorPopup.titleOfSelectedItem : nil
        authorPopup.removeAllItems()
        authorPopup.addItem(withTitle: L("review.filter.allReviewers", "All Reviewers"))
        authorPopup.addItems(withTitles: authors)
        if let chosenAuthor, authors.contains(chosenAuthor) { authorPopup.selectItem(withTitle: chosenAuthor) }
        authorPopup.isHidden = authors.count < 2
        let author = authorPopup.indexOfSelectedItem > 0 ? authorPopup.titleOfSelectedItem : nil

        let openOnly = filterPopup.indexOfSelectedItem == 0
        rows = (session?.comments ?? []).filter { comment in
            (!openOnly || comment.status == .open) && (author == nil || comment.author == author)
        }
        if let controller, hasSession {
            var parts = [LF("review.count.open", "%d open", controller.count(.open))]
            let applied = controller.count(.applied), done = controller.count(.done), rejected = controller.count(.rejected)
            if applied > 0 { parts.append(LF("review.count.applied", "%d applied", applied)) }
            if done > 0 { parts.append(LF("review.count.done", "%d done", done)) }
            if rejected > 0 { parts.append(LF("review.count.rejected", "%d rejected", rejected)) }
            headerLabel.stringValue = parts.joined(separator: " · ")
            headerLabel.toolTip = session.map { LF("review.header.tip", "Comments from %@", URL(fileURLWithPath: $0.pdfPath).lastPathComponent) }
            applyAllButton.isEnabled = !controller.applicableIDs.isEmpty
            marksButton.isHidden = !controller.canInsertMarks
        }
        let ai = showsAIControls
        aiAllButton.isHidden = !ai
        aiAllButton.isEnabled = !(controller?.aiCandidateIDs.isEmpty ?? true)
        let status = controller?.aiStatus ?? ""
        aiStatusLabel.stringValue = status
        aiStatusLabel.toolTip = status
        aiCancelButton.isHidden = !(controller?.isSuggesting ?? false)
        aiStatusRow.isHidden = !ai || (status.isEmpty && aiCancelButton.isHidden)
        for (button, action) in actionButtons where action == .suggestAI { button.isHidden = !ai }
        heights = [:]
        table.reloadData()
        if let selectedID, let row = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateActionButtons()
    }

    /// Called when the tab is shown: anchors are brought up to date with edits made meanwhile.
    func becameVisible() {
        controller?.refresh()
    }

    private var selectedComment: ReviewComment? {
        let row = table.selectedRow
        return row >= 0 && row < rows.count ? rows[row] : nil
    }

    /// The comment a context-menu command or button acts on: the clicked row, else the selected one.
    private var targetComment: ReviewComment? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return row >= 0 && row < rows.count ? rows[row] : nil
    }

    private func isEnabled(_ action: Action, for comment: ReviewComment?) -> Bool {
        guard let comment else { return false }
        let anchored = controller?.anchors[comment.id] != nil
        switch action {
        case .select: return anchored
        case .apply: return comment.status == .open && comment.suggestion != nil && anchored
        case .done: return comment.status != .done
        case .reject: return comment.status != .rejected
        case .reopen: return comment.status != .open
        case .reply: return true
        case .suggestAI: return controller?.canSuggestWithAI(comment) ?? false
        }
    }

    private func updateActionButtons() {
        let comment = selectedComment
        for (button, action) in actionButtons { button.isEnabled = isEnabled(action, for: comment) }
    }

    // MARK: Actions

    @objc private func filterChanged() { reload() }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        controller?.highlight(rows[table.clickedRow].id)
    }

    @objc private func rowDoubleClicked() {
        guard table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        controller?.select(rows[table.clickedRow].id)
    }

    @objc private func actionClicked(_ sender: NSButton) {
        guard let action = Action(rawValue: sender.tag) else { return }
        perform(action, on: selectedComment)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = Action(rawValue: sender.tag), let id = sender.representedObject as? String else { return }
        perform(action, on: controller?.comment(id))
    }

    private func perform(_ action: Action, on comment: ReviewComment?) {
        guard let controller, let comment, isEnabled(action, for: comment) else { return }
        switch action {
        case .select: controller.select(comment.id)
        case .apply:
            do {
                try controller.apply(comment.id)
            } catch {
                controller.windowController?.showMessage(error.localizedDescription)
                NSSound.beep()
            }
        case .done: controller.setStatus(comment.id, .done)
        case .reject: controller.setStatus(comment.id, .rejected)
        case .reopen: controller.setStatus(comment.id, .open)
        case .reply: askReply(for: comment)
        case .suggestAI: controller.startSuggesting(comment.id)
        }
    }

    @objc private func aiAllClicked() {
        controller?.startSuggesting(nil)
    }

    @objc private func aiCancelClicked() {
        controller?.cancelAI()
    }

    @objc private func settingsChanged() {
        reload()
    }

    private func askReply(for comment: ReviewComment) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("review.reply.title", "Reply to the Reviewer")
        let quote = comment.comment.isEmpty ? comment.quotedText : comment.comment
        alert.informativeText = String(quote.prefix(300))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
        text.string = comment.reply
        text.isRichText = false
        text.font = .systemFont(ofSize: 13)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: L("review.reply.save", "Save Reply"))
        alert.addButton(withTitle: L("button.cancel", "Cancel"))
        alert.window.initialFirstResponder = text
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.controller?.setReply(comment.id, text.string)
        }
    }

    @objc private func applyAllClicked() {
        guard let controller, let window else { return }
        let count = controller.applicableIDs.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = LF("review.applyAll.title", "Apply %d suggestions?", count)
        alert.informativeText = L("review.applyAll.text", "Each change is checked against the source first; suggestions whose text has changed are skipped and stay open. The changes can be undone in each document.")
        alert.addButton(withTitle: L("review.applyAll.button", "Apply All"))
        alert.addButton(withTitle: L("button.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let result = controller.applyAll()
            controller.windowController?.showMessage(result.failed == 0
                ? LF("review.applyAll.done", "%d suggestions applied", result.applied)
                : LF("review.applyAll.partly", "%d suggestions applied, %d skipped (the text has changed)", result.applied, result.failed))
        }
    }

    @objc private func marksClicked() {
        controller?.insertMarks()
    }

    @objc private func exportClicked() {
        controller?.windowController?.exportResponseLetter(nil)
    }

    @objc private func importClicked() {
        controller?.windowController?.importReviewComments(nil)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        let comment = rows[row]
        let items: [(Action, String)] = [
            (.select, L("review.action.select", "Select in Source")),
            (.apply, L("review.action.apply", "Apply Suggestion")),
            (.done, L("review.action.done", "Mark Done")),
            (.reject, L("review.action.reject", "Reject")),
            (.reopen, L("review.action.reopen", "Reopen")),
            (.reply, L("review.action.reply", "Reply…")),
        ]
            + (showsAIControls ? [(.suggestAI, L("review.action.suggestAI", "Suggest Edit (AI)"))] : [])
        for (action, title) in items {
            let item = NSMenuItem(title: title, action: isEnabled(action, for: comment) ? #selector(menuAction(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.tag = action.rawValue
            item.representedObject = comment.id
            menu.addItem(item)
            if action == .select || action == .reopen || (action == .reply && showsAIControls) { menu.addItem(.separator()) }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ReviewCommentCell.identifier, owner: self) as? ReviewCommentCell ?? ReviewCommentCell()
        configure(cell, row: row, width: tableColumn?.width ?? tableView.bounds.width)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
        let comment = rows[row]
        if let height = heights[comment.id] { return height }
        configure(sizingCell, row: row, width: width)
        let height = max(36, sizingCell.fittingHeight())
        heights[comment.id] = height
        return height
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionButtons()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        let width = table.tableColumns.first?.width ?? 0
        guard abs(width - measuredWidth) > 0.5 else { return }
        measuredWidth = width
        heights = [:]
        let selection = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selection, byExtendingSelection: false)
    }

    private func configure(_ cell: ReviewCommentCell, row: Int, width: CGFloat) {
        let comment = rows[row]
        let anchored = controller?.anchors[comment.id] != nil
        var file: String?
        if let url = controller?.anchorFiles[comment.id], let main = controller?.mainURL,
           url.standardizedFileURL.path != main.standardizedFileURL.path {
            file = url.lastPathComponent
        }
        cell.configure(comment, anchored: anchored, file: file, width: width)
    }
}

/// One review comment: author and page, the quoted words, the comment, the suggested change and its status.
final class ReviewCommentCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ReviewCommentCell")

    private let statusIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let quoteLabel = NSTextField(wrappingLabelWithString: "")
    private let commentLabel = NSTextField(wrappingLabelWithString: "")
    private let replyLabel = NSTextField(wrappingLabelWithString: "")
    private let pill = PillView()
    private let aiBadge = PillView()
    private let warningLabel = NSTextField(labelWithString: "")
    private let pillRow = NSStackView()
    private let stack = NSStackView()
    private let titleRow = NSStackView()
    private var textWidth: CGFloat = 200
    private static let insets = NSEdgeInsets(top: 5, left: 4, bottom: 6, right: 4)
    private static let spacing: CGFloat = 3

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        statusIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (label, lines) in [(quoteLabel, 2), (commentLabel, 3), (replyLabel, 2)] {
            label.maximumNumberOfLines = lines
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = true
            label.isSelectable = false
        }
        quoteLabel.font = NSFontManager.shared.convert(.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)
        commentLabel.font = .systemFont(ofSize: 12)
        replyLabel.font = .systemFont(ofSize: 11)
        warningLabel.font = .systemFont(ofSize: 10)
        warningLabel.textColor = .systemOrange
        aiBadge.text = L("review.aiBadge", "AI")
        aiBadge.color = .systemPurple
        aiBadge.toolTip = L("review.aiBadge.tip", "Suggested by AI")

        let title = titleRow
        title.addArrangedSubview(statusIcon)
        title.addArrangedSubview(titleLabel)
        title.spacing = 4
        pillRow.spacing = 4
        pillRow.addArrangedSubview(pill)
        pillRow.addArrangedSubview(aiBadge)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.spacing
        stack.edgeInsets = Self.insets
        for view in [title, quoteLabel, commentLabel, pillRow, replyLabel, warningLabel] as [NSView] {
            stack.addArrangedSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -(Self.insets.left + Self.insets.right)),
        ])
        for label in [quoteLabel, commentLabel, replyLabel, warningLabel] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(Self.insets.left + Self.insets.right)).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ comment: ReviewComment, anchored: Bool, file: String?, width: CGFloat) {
        let open = comment.status == .open
        var title = [comment.author.isEmpty ? L("review.anonymous", "Reviewer") : comment.author,
                     LF("review.page", "p. %d", comment.page + 1)]
        if let file { title.append(file) }
        titleLabel.stringValue = title.joined(separator: " · ")
        titleLabel.textColor = open ? .labelColor : .secondaryLabelColor

        let (symbol, color): (String, NSColor) = {
            switch comment.status {
            case .open: return ("circle", .tertiaryLabelColor)
            case .applied: return ("checkmark.circle.fill", .systemGreen)
            case .done: return ("checkmark.circle", .systemBlue)
            case .rejected: return ("xmark.circle", .systemRed)
            }
        }()
        let status = ReviewSession.statusName(comment.status)
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status)
        statusIcon.contentTintColor = color
        statusIcon.toolTip = status

        let quote = Self.singleLine(comment.quotedText).trimmingCharacters(in: .whitespaces)
        quoteLabel.stringValue = quote.isEmpty ? "" : "“\(quote)”"
        quoteLabel.isHidden = quote.isEmpty
        quoteLabel.textColor = .secondaryLabelColor
        let text = comment.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        commentLabel.stringValue = text
        commentLabel.isHidden = text.isEmpty
        commentLabel.textColor = open ? .labelColor : .secondaryLabelColor
        let reply = comment.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        replyLabel.stringValue = "↩ " + reply
        replyLabel.isHidden = reply.isEmpty
        replyLabel.textColor = .secondaryLabelColor

        if let suggestion = comment.suggestion {
            pill.text = Self.pillText(suggestion)
            pill.color = comment.suggestionIsAI ? .systemPurple : .controlAccentColor
            pill.toolTip = Self.pillTip(suggestion)
            pillRow.isHidden = false
            aiBadge.isHidden = !comment.suggestionIsAI
        } else {
            pillRow.isHidden = true
        }
        warningLabel.stringValue = "⚠︎ " + L("review.unanchored", "Not found in the source")
        warningLabel.isHidden = anchored || !open

        textWidth = max(40, width - Self.insets.left - Self.insets.right)
        for label in [quoteLabel, commentLabel, replyLabel] { label.preferredMaxLayoutWidth = textWidth }
        pill.maxWidth = textWidth - 30
    }

    /// The row height for the current content at the width given to `configure`, measured line by line
    /// (wrapped labels limited to their number of lines).
    func fittingHeight() -> CGFloat {
        var parts: [CGFloat] = [titleRow.fittingSize.height]
        for label in [quoteLabel, commentLabel, replyLabel] where !label.isHidden {
            guard let cell = label.cell, let font = label.font else { continue }
            let full = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            parts.append(min(full, lineHeight * CGFloat(label.maximumNumberOfLines) + 2))
        }
        if !pillRow.isHidden { parts.append(pillRow.fittingSize.height) }
        if !warningLabel.isHidden { parts.append(warningLabel.fittingSize.height) }
        let gaps = Self.spacing * CGFloat(max(0, parts.count - 1))
        return ceil(parts.reduce(0, +) + gaps + Self.insets.top + Self.insets.bottom)
    }

    /// The suggestion in a few characters: `→ new`, `+ text`, `delete`.
    static func pillText(_ suggestion: Suggestion) -> String {
        switch suggestion {
        case .replace(_, let with): return "→ " + Self.singleLine(with)
        case .insertAfter(_, let text), .insertBefore(_, let text):
            return "+ " + Self.singleLine(text).trimmingCharacters(in: .whitespaces)
        case .delete: return L("review.pill.delete", "delete")
        }
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    private static func pillTip(_ suggestion: Suggestion) -> String {
        switch suggestion {
        case .replace(let target, let with): return LF("review.pill.replaceTip", "Replace “%@” with “%@”", target, with)
        case .insertAfter(let target, let text): return LF("review.pill.insertAfterTip", "Insert “%@” after “%@”", text, target)
        case .insertBefore(let target, let text): return LF("review.pill.insertBeforeTip", "Insert “%@” before “%@”", text, target)
        case .delete(let target): return LF("review.pill.deleteTip", "Delete “%@”", target)
        }
    }
}

/// A short text on a rounded, tinted background.
final class PillView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var widthLimit: NSLayoutConstraint!

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var color: NSColor = .controlAccentColor {
        didSet { label.textColor = color; needsDisplay = true }
    }

    var maxWidth: CGFloat {
        get { widthLimit.constant }
        set { widthLimit.constant = max(20, newValue) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        widthLimit = widthAnchor.constraint(lessThanOrEqualToConstant: 200)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            widthLimit,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 4
        layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
    }
}
