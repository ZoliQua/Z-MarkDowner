import AppKit
import UniformTypeIdentifiers
import MarkDownerCore

/// Compares two versions of a text side by side or inline at word level, and turns the result into
/// review marks (a new Markdown document) or tracked changes (a Word file).
final class DiffWindowController: NSWindowController, NSWindowDelegate {

    enum Layout: Int { case sideBySide = 0, inline = 1 }

    let oldTitle: String
    let newTitle: String
    private let oldSource: String
    private let newSource: String

    /// The on-screen comparison.
    var result: DiffResult? { shownResult?.value }
    private var shownResult: (options: DiffOptions, value: DiffResult)?
    private var sourceCache: (options: DiffOptions, value: DiffResult)?

    var layout: Layout = .sideBySide {
        didSet {
            layoutControl.selectedSegment = layout.rawValue
            applyLayout()
        }
    }
    var ignoreWhitespace = false { didSet { whitespaceBox.state = ignoreWhitespace ? .on : .off } }
    var ignoreCase = false { didSet { caseBox.state = ignoreCase ? .on : .off } }
    /// Compares the prose text of the parsed Markdown instead of the source.
    var ignoreFormatting = false { didSet { formattingBox.state = ignoreFormatting ? .on : .off } }

    /// Off for LaTeX sources: CriticMarkup must not enter LaTeX.
    var allowsReviewMarks = true { didSet { reviewButton.isEnabled = allowsReviewMarks } }
    /// Resolves relative images when exporting to Word.
    var baseURL: URL?

    private(set) var oldTextView: NSTextView!
    private(set) var newTextView: NSTextView!
    private(set) var inlineTextView: NSTextView!
    private let oldScroll = NSScrollView()
    private let newScroll = NSScrollView()
    private let inlineScroll = NSScrollView()
    private let sideBySide = NSStackView()
    private let headers = NSStackView()

    private let layoutControl = NSSegmentedControl()
    private let whitespaceBox = NSButton(checkboxWithTitle: L("diff.ignoreWhitespace", "Ignore whitespace"), target: nil, action: nil)
    private let caseBox = NSButton(checkboxWithTitle: L("diff.ignoreCase", "Ignore case"), target: nil, action: nil)
    private let formattingBox = NSButton(checkboxWithTitle: L("diff.ignoreFormatting", "Ignore formatting"), target: nil, action: nil)
    private let statsLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let reviewButton = NSButton()

    private var rendering = DiffRendering()
    /// Index of the selected change in the current layout.
    private(set) var currentChange: Int?
    private var generation = 0
    private var syncing = false
    private var alignedWidth: CGFloat = 0
    private var alignWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    /// Open comparison windows (kept alive until closed).
    private(set) static var openControllers: [DiffWindowController] = []

    private static let defaults = UserDefaults.standard
    private enum Key {
        static let layout = "diffLayout"
        static let ignoreWhitespace = "diffIgnoreWhitespace"
        static let ignoreCase = "diffIgnoreCase"
        static let ignoreFormatting = "diffIgnoreFormatting"
    }

    init(oldTitle: String, old: String, newTitle: String, new: String) {
        self.oldTitle = oldTitle
        self.newTitle = newTitle
        oldSource = old
        newSource = new
        let window = DiffWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 400)
        window.title = LF("diff.windowTitle", "Compare: %@ ↔ %@", oldTitle, newTitle)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.onCommandArrow = { [weak self] step in
            if step > 0 { self?.selectNextChange() } else { self?.selectPreviousChange() }
        }
        buildUI()
        layout = Layout(rawValue: Self.defaults.integer(forKey: Key.layout)) ?? .sideBySide
        ignoreWhitespace = Self.defaults.bool(forKey: Key.ignoreWhitespace)
        ignoreCase = Self.defaults.bool(forKey: Key.ignoreCase)
        ignoreFormatting = Self.defaults.bool(forKey: Key.ignoreFormatting)
        syncControls()
        applyLayout()
        window.setFrameAutosaveName("ZMarkDownerDiffWindow")
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Opens a comparison window and starts the diff.
    @discardableResult
    static func show(oldTitle: String, old: String, newTitle: String, new: String,
                     allowsReviewMarks: Bool = true, baseURL: URL? = nil) -> DiffWindowController {
        let controller = DiffWindowController(oldTitle: oldTitle, old: old, newTitle: newTitle, new: new)
        controller.allowsReviewMarks = allowsReviewMarks
        controller.baseURL = baseURL
        openControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        Task { await controller.recompute() }
        return controller
    }

    /// Text of a file for comparison: LaTeX and plain sources as they are, everything else through the importers.
    static func text(ofFileAt url: URL) async throws -> String {
        let ext = url.pathExtension.lowercased()
        if SourceFormat(fileExtension: ext) == .latex {
            return DocumentImporter.decodeText(try Data(contentsOf: url))
        }
        // The AppKit readers (RTF, DOC, ODT, HTML) need the main thread; the others can run in the background.
        let background = Set(["pdf", "docx"]).union(DocumentImporter.markdownExtensions).union(DocumentImporter.plainTextExtensions)
        if background.contains(ext) {
            return try await Task.detached(priority: .userInitiated) { try DocumentImporter.markdown(fromFileAt: url) }.value
        }
        return try DocumentImporter.markdown(fromFileAt: url)
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        layoutControl.segmentStyle = .rounded
        layoutControl.trackingMode = .selectOne
        layoutControl.segmentCount = 2
        layoutControl.setLabel(L("diff.sideBySide", "Side by Side"), forSegment: 0)
        layoutControl.setLabel(L("diff.inline", "Inline"), forSegment: 1)
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged(_:))
        for box in [whitespaceBox, caseBox, formattingBox] {
            box.target = self
            box.action = #selector(optionChanged(_:))
        }
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.lineBreakMode = .byTruncatingTail
        statsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let topBar = bar([layoutControl, whitespaceBox, caseBox, formattingBox, NSView(), progress, statsLabel])

        for (scroll, label) in [(oldScroll, oldTitle), (newScroll, newTitle)] {
            let header = NSTextField(labelWithString: label)
            header.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            header.textColor = .secondaryLabelColor
            header.lineBreakMode = .byTruncatingMiddle
            header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let holder = NSStackView(views: [header])
            holder.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
            headers.addArrangedSubview(holder)
            let textView = Self.makeTextView(in: scroll)
            if scroll === oldScroll { oldTextView = textView } else { newTextView = textView }
            sideBySide.addArrangedSubview(scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                    object: scroll.contentView, queue: .main) { [weak self] _ in
                self?.syncScroll(from: scroll)
            })
        }
        inlineTextView = Self.makeTextView(in: inlineScroll)
        headers.orientation = .horizontal
        headers.distribution = .fillEqually
        headers.spacing = 1
        sideBySide.orientation = .horizontal
        sideBySide.distribution = .fillEqually
        sideBySide.spacing = 1
        oldScroll.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                                object: oldScroll, queue: .main) { [weak self] _ in
            self?.scheduleAlignment()
        })

        let previous = iconButton("chevron.up", L("diff.previousChange", "Previous Change") + " (⌘↑)", #selector(previousChange(_:)))
        let next = iconButton("chevron.down", L("diff.nextChange", "Next Change") + " (⌘↓)", #selector(nextChange(_:)))
        positionLabel.textColor = .secondaryLabelColor
        positionLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        reviewButton.title = L("diff.openReviewMarks", "Open as Review Marks")
        reviewButton.bezelStyle = .rounded
        reviewButton.target = self
        reviewButton.action = #selector(openReviewMarks(_:))
        let word = NSButton(title: L("diff.exportWord", "Export as Word with Tracked Changes…"), target: self, action: #selector(exportWordChanges(_:)))
        let copy = NSButton(title: L("diff.copySummary", "Copy Summary"), target: self, action: #selector(copySummary(_:)))
        let bottomBar = bar([previous, next, positionLabel, NSView(), copy, reviewButton, word])

        let column = NSStackView(views: [topBar, separator(), headers, sideBySide, inlineScroll, separator(), bottomBar])
        column.orientation = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for view in column.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        for view in [sideBySide, inlineScroll] {
            view.setContentHuggingPriority(.defaultLow, for: .vertical)
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        }
    }

    private func bar(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        return stack
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .rounded
        button.toolTip = tip
        return button
    }

    private static func makeTextView(in scroll: NSScrollView) -> NSTextView {
        let storage = NSTextStorage()
        let layout = DiffLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500), textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return textView
    }

    /// Property observers do not run during init.
    private func syncControls() {
        layoutControl.selectedSegment = layout.rawValue
        whitespaceBox.state = ignoreWhitespace ? .on : .off
        caseBox.state = ignoreCase ? .on : .off
        formattingBox.state = ignoreFormatting ? .on : .off
    }

    private func applyLayout() {
        let side = layout == .sideBySide
        sideBySide.isHidden = !side
        headers.isHidden = !side
        inlineScroll.isHidden = side
        currentChange = nil
        updatePosition()
        updateStats()
        if side {
            window?.layoutIfNeeded()
            alignRows()
        }
    }

    // MARK: - Diff

    /// Runs the diff in the background and shows the result.
    func recompute() async {
        generation += 1
        let current = generation
        let old = oldSource, new = newSource, formatting = ignoreFormatting
        let options = DiffOptions(ignoreWhitespace: ignoreWhitespace, ignoreCase: ignoreCase)
        progress.startAnimation(nil)
        statsLabel.stringValue = L("diff.comparing", "Comparing…")
        let (result, rendering) = await Task.detached(priority: .userInitiated) { () -> (DiffResult, DiffRendering) in
            let a = formatting ? TextStatistics.proseText(of: old) : old
            let b = formatting ? TextStatistics.proseText(of: new) : new
            let result = TextDiff.compare(a, b, options: options)
            return (result, DiffRendering(result: result))
        }.value
        guard current == generation else { return }
        progress.stopAnimation(nil)
        self.shownResult = (options, result)
        self.rendering = rendering
        oldTextView.textStorage?.setAttributedString(rendering.old)
        newTextView.textStorage?.setAttributedString(rendering.new)
        inlineTextView.textStorage?.setAttributedString(rendering.inline)
        alignedWidth = 0
        applyLayout()
        updateStats()
    }

    private func updateStats() {
        guard let result else { statsLabel.stringValue = ""; return }
        if rendering.inlineChanges.isEmpty {
            statsLabel.stringValue = L("diff.noDifferences", "No differences")
        } else {
            statsLabel.stringValue = LF("diff.stats", "%d words inserted · %d words deleted · %d changes",
                                        result.insertedWords, result.deletedWords, changeCount)
        }
    }

    /// Source-level diff (whitespace and case options only) for the outputs, so review marks and Word
    /// changes keep the Markdown even when the window compares the prose ("ignore formatting").
    /// Computed in the background when first needed and reused while the options stay the same.
    private func sourceResult() async -> DiffResult {
        let options = DiffOptions(ignoreWhitespace: ignoreWhitespace, ignoreCase: ignoreCase)
        if !ignoreFormatting, let shown = shownResult, shown.options == options { return shown.value }
        if let cached = sourceCache, cached.options == options { return cached.value }
        let old = oldSource, new = newSource
        let value = await Task.detached(priority: .userInitiated) { TextDiff.compare(old, new, options: options) }.value
        sourceCache = (options, value)
        return value
    }

    private func reviewMarkdown() async -> String {
        TextDiff.criticMarkup(await sourceResult().segments)
    }

    // MARK: - Side by side alignment

    private func syncScroll(from source: NSScrollView) {
        guard !syncing, layout == .sideBySide else { return }
        let target = source === oldScroll ? newScroll : oldScroll
        syncing = true
        let y = source.contentView.bounds.origin.y
        target.contentView.scroll(to: NSPoint(x: target.contentView.bounds.origin.x, y: y))
        target.reflectScrolledClipView(target.contentView)
        syncing = false
    }

    private func scheduleAlignment() {
        alignWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.alignRows() }
        alignWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Pads the shorter side of each row (when lines wrap differently) so both sides stay line-aligned.
    private func alignRows() {
        guard layout == .sideBySide, !rendering.rowRanges.isEmpty,
              let oldStorage = oldTextView.textStorage, let newStorage = newTextView.textStorage else { return }
        let width = oldScroll.frame.width
        guard width > 0, abs(width - alignedWidth) > 0.5 || alignedWidth == 0 else { return }
        alignedWidth = width
        let views: [NSTextView] = [oldTextView, newTextView]
        let storages = [oldStorage, newStorage]
        for storage in storages {
            storage.beginEditing()
            storage.addAttribute(.paragraphStyle, value: DiffRendering.paragraph, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        var heights: [[CGFloat]] = []
        for (side, view) in views.enumerated() {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            heights.append(rendering.rowRanges.map { ranges in
                let glyphs = layout.glyphRange(forCharacterRange: side == 0 ? ranges.old : ranges.new, actualCharacterRange: nil)
                var height: CGFloat = 0
                layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in height += rect.height }
                return height
            })
        }
        var styles: [Int: NSParagraphStyle] = [:]
        for side in 0..<2 {
            let storage = storages[side]
            storage.beginEditing()
            for (row, ranges) in rendering.rowRanges.enumerated() {
                let missing = (heights[1 - side][row] - heights[side][row]).rounded()
                guard missing >= 1 else { continue }
                let key = Int(missing)
                let style = styles[key] ?? {
                    let s = DiffRendering.paragraph.mutableCopy() as! NSMutableParagraphStyle
                    s.paragraphSpacing = missing
                    return s
                }()
                styles[key] = style
                storage.addAttribute(.paragraphStyle, value: style, range: side == 0 ? ranges.old : ranges.new)
            }
            storage.endEditing()
        }
        syncScroll(from: newScroll)
    }

    // MARK: - Change navigation

    private var changeCount: Int {
        layout == .sideBySide ? rendering.sideChanges.count : rendering.inlineChanges.count
    }

    func selectNextChange() { moveChange(1) }
    func selectPreviousChange() { moveChange(-1) }

    private func moveChange(_ step: Int) {
        let count = changeCount
        guard count > 0 else { NSSound.beep(); return }
        if let currentChange {
            self.currentChange = (currentChange + step + count) % count
        } else {
            currentChange = step > 0 ? 0 : count - 1
        }
        revealCurrentChange()
        updatePosition()
    }

    /// Scrolls to the current change. Inline it is selected; side by side only flashed, so that the
    /// selection does not hide the word highlights.
    private func revealCurrentChange() {
        guard let index = currentChange else { return }
        func visible(_ range: NSRange) -> NSRange {
            range.length > 1 ? NSRange(location: range.location, length: range.length - 1) : range
        }
        if layout == .sideBySide {
            let change = rendering.sideChanges[index]
            for (view, range) in [(oldTextView!, change.old), (newTextView!, change.new)] {
                view.setSelectedRange(NSRange(location: range.location, length: 0))
                view.scrollRangeToVisible(range)
            }
            if visible(change.new).length > 0 { newTextView.showFindIndicator(for: visible(change.new)) }
        } else {
            let range = visible(rendering.inlineChanges[index])
            window?.makeFirstResponder(inlineTextView)
            inlineTextView.setSelectedRange(range)
            inlineTextView.scrollRangeToVisible(range)
            if range.length > 0 { inlineTextView.showFindIndicator(for: range) }
        }
    }

    private func updatePosition() {
        let count = changeCount
        positionLabel.stringValue = count == 0 ? "" : "\(currentChange.map { String($0 + 1) } ?? "–") / \(count)"
    }

    // MARK: - Outputs

    /// A new untitled Markdown document with the new text and `{--old--}{++new++}` marks.
    @discardableResult
    func openAsReviewMarks() async -> MarkdownDocument {
        let text = await reviewMarkdown()
        let doc = MarkdownDocument()
        doc.text = text
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        doc.updateChangeCount(.changeDone)
        return doc
    }

    /// Writes a Word file in which the changes are tracked (deletions and insertions).
    func exportWord(to url: URL) async throws {
        let title = (newTitle as NSString).deletingPathExtension
        let markdown = await reviewMarkdown()
        try DocxExporter.data(markdown: markdown, options: Settings.shared.exportOptions(title: title, baseURL: baseURL))
            .write(to: url, options: .atomic)
    }

    /// Plain-text summary of the comparison.
    func summary() -> String {
        var lines = [LF("diff.windowTitle", "Compare: %@ ↔ %@", oldTitle, newTitle)]
        if let result {
            lines.append(LF("diff.summaryInserted", "Words inserted: %d", result.insertedWords))
            lines.append(LF("diff.summaryDeleted", "Words deleted: %d", result.deletedWords))
            lines.append(LF("diff.summaryChanges", "Changes: %d", changeCount))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Actions

    @objc private func layoutChanged(_ sender: NSSegmentedControl) {
        layout = Layout(rawValue: sender.selectedSegment) ?? .sideBySide
        Self.defaults.set(layout.rawValue, forKey: Key.layout)
    }

    @objc private func optionChanged(_ sender: NSButton) {
        ignoreWhitespace = whitespaceBox.state == .on
        ignoreCase = caseBox.state == .on
        ignoreFormatting = formattingBox.state == .on
        Self.defaults.set(ignoreWhitespace, forKey: Key.ignoreWhitespace)
        Self.defaults.set(ignoreCase, forKey: Key.ignoreCase)
        Self.defaults.set(ignoreFormatting, forKey: Key.ignoreFormatting)
        Task { await recompute() }
    }

    @objc private func previousChange(_ sender: Any?) { selectPreviousChange() }
    @objc private func nextChange(_ sender: Any?) { selectNextChange() }

    @objc private func openReviewMarks(_ sender: Any?) {
        guard allowsReviewMarks else { return }
        Task { await openAsReviewMarks() }
    }

    @objc private func exportWordChanges(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(filenameExtension: "docx")!]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = (newTitle as NSString).deletingPathExtension + ".docx"
        panel.directoryURL = baseURL
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    try await self.exportWord(to: url)
                } catch {
                    let alert = NSAlert(error: error)
                    alert.messageText = L("export.failed", "Export failed")
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    @objc private func copySummary(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary(), forType: .string)
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        generation += 1
        alignWork?.cancel()
        Self.openControllers.removeAll { $0 === self }
    }
}

/// Handles ⌘↓ / ⌘↑ (next / previous change) before the text views see them.
private final class DiffWindow: NSWindow {
    var onCommandArrow: ((Int) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command, let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value {
            if key == UInt32(NSDownArrowFunctionKey) { onCommandArrow?(1); return true }
            if key == UInt32(NSUpArrowFunctionKey) { onCommandArrow?(-1); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension NSAttributedString.Key {
    /// Background color of the whole line (changed or padding rows of the side-by-side view).
    static let diffLineBackground = NSAttributedString.Key("ZMDDiffLineBackground")
}

/// Draws `diffLineBackground` across the full width of each line.
private final class DiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let width = textContainers.first?.textView?.bounds.width {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            storage.enumerateAttribute(.diffLineBackground, in: characters) { value, range, _ in
                guard let color = value as? NSColor else { return }
                color.setFill()
                let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                    NSRect(x: 0, y: rect.minY + origin.y, width: width, height: rect.height).fill(using: .sourceOver)
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// Attributed texts and change positions for both layouts (built off the main thread).
struct DiffRendering {
    var old = NSAttributedString()
    var new = NSAttributedString()
    var inline = NSAttributedString()
    /// Character ranges of each row (including its line break) in the old and new side texts.
    var rowRanges: [(old: NSRange, new: NSRange)] = []
    /// Consecutive changed rows.
    var sideChanges: [(old: NSRange, new: NSRange)] = []
    /// Consecutive deletions and insertions of the inline text.
    var inlineChanges: [NSRange] = []

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return style
    }()
    private static let base: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph,
    ]
    private static let deletedWord = NSColor.systemRed.withAlphaComponent(0.28)
    private static let insertedWord = NSColor.systemGreen.withAlphaComponent(0.28)
    private static let deletedLine = NSColor.systemRed.withAlphaComponent(0.08)
    private static let insertedLine = NSColor.systemGreen.withAlphaComponent(0.08)
    private static let paddingLine = NSColor.gray.withAlphaComponent(0.12)

    init() {}

    init(result: DiffResult) {
        let old = NSMutableAttributedString(), new = NSMutableAttributedString()
        var groupStart: (old: Int, new: Int)?
        func closeGroup() {
            if let start = groupStart {
                sideChanges.append((NSRange(location: start.old, length: old.length - start.old),
                                    NSRange(location: start.new, length: new.length - start.new)))
            }
            groupStart = nil
        }
        for row in result.rows {
            let changed = row.old == nil || row.new == nil
                || row.old!.contains { $0.kind != .equal } || row.new!.contains { $0.kind != .equal }
            if !changed { closeGroup() }
            let oldStart = old.length, newStart = new.length
            if changed, groupStart == nil { groupStart = (oldStart, newStart) }
            Self.appendLine(row.old, to: old, changed: changed, lineColor: Self.deletedLine)
            Self.appendLine(row.new, to: new, changed: changed, lineColor: Self.insertedLine)
            rowRanges.append((NSRange(location: oldStart, length: old.length - oldStart),
                              NSRange(location: newStart, length: new.length - newStart)))
        }
        closeGroup()

        let inline = NSMutableAttributedString()
        var changeStart: Int?
        for segment in result.segments {
            if segment.kind == .equal, let start = changeStart {
                inlineChanges.append(NSRange(location: start, length: inline.length - start))
                changeStart = nil
            } else if segment.kind != .equal, changeStart == nil {
                changeStart = inline.length
            }
            inline.append(NSAttributedString(string: segment.text, attributes: Self.attributes(segment.kind, inline: true)))
        }
        if let start = changeStart { inlineChanges.append(NSRange(location: start, length: inline.length - start)) }

        self.old = old
        self.new = new
        self.inline = inline
    }

    private static func appendLine(_ segments: [DiffSegment]?, to text: NSMutableAttributedString, changed: Bool, lineColor: NSColor) {
        let start = text.length
        for segment in segments ?? [] {
            text.append(NSAttributedString(string: segment.text, attributes: attributes(segment.kind, inline: false)))
        }
        text.append(NSAttributedString(string: "\n", attributes: base))
        let line = NSRange(location: start, length: text.length - start)
        if segments == nil {
            text.addAttribute(.diffLineBackground, value: paddingLine, range: line)
        } else if changed {
            text.addAttribute(.diffLineBackground, value: lineColor, range: line)
        }
    }

    private static func attributes(_ kind: DiffKind, inline: Bool) -> [NSAttributedString.Key: Any] {
        var attributes = base
        switch kind {
        case .equal:
            break
        case .delete:
            attributes[.backgroundColor] = deletedWord
            if inline {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = NSColor.systemRed
                attributes[.foregroundColor] = NSColor.systemRed
            }
        case .insert:
            attributes[.backgroundColor] = insertedWord
            if inline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = NSColor.systemGreen
            }
        }
        return attributes
    }
}
