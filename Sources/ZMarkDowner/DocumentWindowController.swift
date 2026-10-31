import AppKit
import PDFKit
import UniformTypeIdentifiers
import MarkDownerCore

enum ViewMode: Int {
    case editor = 0, split = 1, preview = 2
}

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate,
                                      NSToolbarDelegate, NSSplitViewDelegate, NSMenuItemValidation {

    private let mainSplit = NSSplitView()
    private let contentSplit = NSSplitView()
    let sidebar = SidebarView(frame: .zero)
    let editorScroll = NSScrollView()
    private(set) var editor: EditorTextView!
    let preview = PreviewView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(labelWithString: "")
    private let goalBar = NSProgressIndicator()
    private var modeControl: NSSegmentedControl?
    private(set) var statsPopover: NSPopover?
    /// Statistics of the whole document (updated shortly after each edit).
    private(set) var statistics = TextStatistics()
    private var lastWordCount: Int?
    /// Result of the last citation / cross-reference processing (preview).
    private(set) var lastProcessing: ProcessingResult?

    private let highlighter = MarkdownHighlighter()
    private var previewWork: DispatchWorkItem?
    private var messageWork: DispatchWorkItem?
    private var pendingEdit: (range: NSRange, replacement: String, replaced: String)?
    private var lineStarts: [Int] = [0]
    private var syncSource: (side: Int, time: TimeInterval) = (0, 0)   // 1 = editor, 2 = preview
    private var observers: [NSObjectProtocol] = []

    private(set) var mode: ViewMode = .split

    /// Comments imported from a reviewer's PDF (Comments tab of the sidebar).
    let review = ReviewController()

    /// Set at init; NSDocument.addWindowController assigns `document` afterwards
    /// (assigning it ourselves beforehand makes addWindowController skip registration).
    private weak var ownerDocument: MarkdownDocument?

    var markdownDocument: MarkdownDocument? { (document as? MarkdownDocument) ?? ownerDocument }

    /// LaTeX sources: Markdown-only features (live formatting, formatting commands, rendered preview) are off.
    var isLatex: Bool { markdownDocument?.sourceFormat == .latex }

    init(document: MarkdownDocument) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 600, height: 380)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titlebarSeparatorStyle = .line
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        super.init(window: window)
        ownerDocument = document
        review.windowController = self
        window.delegate = self
        buildUI()
        buildToolbar()
        applySettings()
        loadDocumentText()
        let initialMode: ViewMode = document.sourceFormat == .latex ? .editor
            : document.importedFrom != nil ? .split : Settings.shared.defaultViewMode
        setMode(initialMode, remember: false)
        setSidebarVisible(Settings.shared.showSidebar, remember: false)
        window.setFrameAutosaveName("ZMarkDownerDocumentWindow")
        if window.frame.origin == .zero { window.center() }

        observers.append(NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        })
        observers.append(NotificationCenter.default.addObserver(forName: WritingGoals.dailyGoalReached, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.window?.isKeyWindow == true else { return }
            self.showMessage(L("stats.dailyGoalReached", "🎉 Daily writing goal reached!"))
            self.updateGoalDisplay()
        })
        editorScroll.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                object: editorScroll.contentView, queue: .main) { [weak self] _ in
            self?.editorDidScroll()
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        // Editor (TextKit 1 stack for predictable attribute handling)
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600), textContainer: container)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.insertionPointColor = .controlAccentColor
        editor.delegate = self
        editor.citationCandidates = { [weak self] in self?.citationCandidates() ?? [] }
        editor.setAccessibilityLabel(L("editor.accessibility", "Markdown editor"))

        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = .textBackgroundColor
        editorScroll.borderType = .noBorder

        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.delegate = self
        contentSplit.addArrangedSubview(editorScroll)
        contentSplit.addArrangedSubview(preview)

        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.delegate = self
        mainSplit.addArrangedSubview(sidebar)
        mainSplit.addArrangedSubview(contentSplit)
        mainSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        mainSplit.translatesAutoresizingMaskIntoConstraints = false

        sidebar.onSelectHeading = { [weak self] line in self?.reveal(line: line) }
        sidebar.searchView.onOpenMatch = { [weak self] url, range in self?.openSearchResult(url, range) }
        sidebar.reviewView.controller = review
        review.onChange = { [weak self] in self?.sidebar.reviewView.reload() }
        preview.onScroll = { [weak self] line in self?.previewDidScroll(line) }

        // Status bar
        let statusBar = NSVisualEffectView()
        statusBar.material = .titlebar
        statusBar.blendingMode = .withinWindow
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        for label in [statusLabel, positionLabel, messageLabel, warningLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            statusBar.addSubview(label)
        }
        messageLabel.alignment = .right
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        warningLabel.textColor = .systemOrange
        warningLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showStatistics(_:))))
        statusLabel.toolTip = L("stats.tooltip", "Click for document statistics and writing goals")
        goalBar.style = .bar
        goalBar.controlSize = .small
        goalBar.isIndeterminate = false
        goalBar.minValue = 0
        goalBar.maxValue = 1
        goalBar.isHidden = true
        goalBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(goalBar)
        statusBar.addSubview(separator)

        content.addSubview(mainSplit)
        content.addSubview(statusBar)
        NSLayoutConstraint.activate([
            mainSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainSplit.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            separator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            goalBar.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
            goalBar.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            goalBar.widthAnchor.constraint(equalToConstant: 70),
            positionLabel.leadingAnchor.constraint(equalTo: goalBar.trailingAnchor, constant: 12),
            positionLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            warningLabel.leadingAnchor.constraint(equalTo: positionLabel.trailingAnchor, constant: 16),
            warningLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: warningLabel.trailingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            messageLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
    }

    private var appliedPreviewKey = ""
    private var appliedProcessingKey = ""
    private var appliedFontKey = ""

    private func applySettings() {
        let settings = Settings.shared
        let live = settings.liveFormatting && !isLatex
        let fontKey = "\(settings.editorFontName)|\(settings.editorFontSize)|\(live)"
        if fontKey != appliedFontKey {
            appliedFontKey = fontKey
            highlighter.format = isLatex ? .latex : .markdown
            highlighter.liveFormatting = live
            highlighter.updateFonts()
            editor.liveFormatting = live
            rehighlight()
        }
        editor.readableWidth = settings.readableWidth
        editor.isContinuousSpellCheckingEnabled = settings.spellCheck
        if editor.focusMode != settings.focusMode { editor.focusMode = settings.focusMode }
        if editor.typewriterMode != settings.typewriterMode { editor.typewriterMode = settings.typewriterMode }
        editor.typingAttributes = highlighter.baseAttributes
        // Reload the preview page only when its appearance settings changed
        let previewKey = "\(settings.previewTheme.rawValue)|\(settings.customCSS.hashValue)|\(settings.renderMath)|\(settings.renderDiagrams)"
        if previewKey != appliedPreviewKey {
            appliedPreviewKey = previewKey
            preview.reloadShell()
        }
        let processingKey = "\(settings.citationStyle.rawValue)|\(settings.defaultBibliographyPath)|\(settings.numberSections)"
        if processingKey != appliedProcessingKey {
            let first = appliedProcessingKey.isEmpty
            appliedProcessingKey = processingKey
            if !first { schedulePreview() }
        }
        updateGoalDisplay()
    }

    // MARK: - Document text

    private func loadDocumentText() {
        let text = markdownDocument?.text ?? ""
        editor.string = text
        preview.baseDirectory = markdownDocument?.baseDirectory
        rehighlight()
        lastWordCount = nil
        documentStructureChanged()
        updateStatus()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        markdownDocument?.undoManager?.removeAllActions()
        sidebar.currentFile = markdownDocument?.fileURL
        sidebar.documentFolderChanged(markdownDocument?.baseDirectory)
        review.loadSidecar()
    }

    /// Called when the document re-reads its file (e.g. Revert).
    func documentTextDidChangeExternally() {
        guard editor != nil, let doc = markdownDocument, editor.string != doc.text else { return }
        loadDocumentText()
    }

    /// Called after the document was saved to a (possibly new) location.
    func documentLocationChanged() {
        preview.baseDirectory = markdownDocument?.baseDirectory
        sidebar.currentFile = markdownDocument?.fileURL
        sidebar.documentFolderChanged(markdownDocument?.baseDirectory)
        sidebar.reloadFiles()
        review.mainLocationChanged()
    }

    func commitEditing() {
        guard editor != nil else { return }
        markdownDocument?.text = editor.string
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let replaced = (textView.string as NSString).substring(with: affectedCharRange)
        pendingEdit = (affectedCharRange, replacementString ?? "", replaced)
        return true
    }

    func textDidChange(_ notification: Notification) {
        markdownDocument?.text = editor.string
        if let storage = editor.textStorage {
            if let edit = pendingEdit {
                highlighter.highlight(storage, editedRange: edit.range, replacement: edit.replacement, replaced: edit.replaced)
            } else {
                highlighter.highlight(storage)
            }
            editor.typingAttributes = highlighter.baseAttributes
            if editor.focusMode || editor.liveFormatting { editor.updateFocusDimming() }
        }
        pendingEdit = nil
        refreshLineStarts()
        schedulePreview()
        updateStatus()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updatePosition()
    }

    /// Removes spelling / grammar marks inside code, URLs and math.
    func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
                  options: [NSSpellChecker.OptionKey: Any] = [:], results: [NSTextCheckingResult],
                  orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        let excluded = highlighter.noSpellRanges
        guard !excluded.isEmpty else { return results }
        return results.filter { result in
            guard result.resultType == .spelling || result.resultType == .grammar else { return true }
            return !excluded.contains { NSIntersectionRange($0, result.range).length > 0 }
        }
    }

    private func rehighlight() {
        guard let storage = editor.textStorage else { return }
        highlighter.highlight(storage)
        editor.typingAttributes = highlighter.baseAttributes
        if editor.focusMode || editor.liveFormatting { editor.updateFocusDimming() }
    }

    private func schedulePreview() {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.documentStructureChanged()
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func refreshLineStarts() {
        let text = editor.string as NSString
        var starts = [0]
        var location = 0
        while location < text.length {
            let r = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
            guard r.location != NSNotFound else { break }
            starts.append(NSMaxRange(r))
            location = NSMaxRange(r)
        }
        lineStarts = starts
    }

    var processingOptions: ProcessingOptions {
        var options = Settings.shared.processingOptions
        options.baseURL = markdownDocument?.baseDirectory
        return options
    }

    /// Parses the text once and updates the outline, statistics and (when visible) the preview.
    private func documentStructureChanged() {
        refreshLineStarts()
        if isLatex {
            latexStructureChanged()
            return
        }
        let doc = MDDocument(markdown: editor.string)
        sidebar.setHeadings(doc.outline.map { SidebarView.Heading(level: $0.level, text: $0.text, line: $0.line) })
        sidebar.highlightHeading(forLine: lineNumber(at: editor.selectedRange().location))
        if mode != .editor {
            preview.baseDirectory = markdownDocument?.baseDirectory
            let result = DocumentProcessor.process(doc, options: processingOptions)
            lastProcessing = result
            preview.update(document: result.document)
            updateWarnings(result)
        }
        statistics = TextStatistics(document: doc)
        if let last = lastWordCount, statistics.words > last {
            WritingGoals.shared.record(statistics.words - last)
        }
        lastWordCount = statistics.words
        updateStatus()
        updateGoalDisplay()
        statsController?.refresh()
    }

    private static let latexSection = try! NSRegularExpression(
        pattern: #"^[ \t]*\\(section|subsection|subsubsection)\*?\{([^}\n]*)\}"#, options: [.anchorsMatchLines])

    /// LaTeX: outline from `\section` / `\subsection` / `\subsubsection`, the preview shows the plain
    /// source, statistics count the text; no Markdown processing.
    private func latexStructureChanged() {
        let text = editor.string
        let levels = ["section": 1, "subsection": 2, "subsubsection": 3]
        let headings = Self.latexSection.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map { m in
            SidebarView.Heading(level: levels[(text as NSString).substring(with: m.range(at: 1))] ?? 1,
                                text: (text as NSString).substring(with: m.range(at: 2)),
                                line: lineNumber(at: m.range.location))
        }
        sidebar.setHeadings(headings)
        sidebar.highlightHeading(forLine: lineNumber(at: editor.selectedRange().location))
        let doc = MDDocument(blocks: [.codeBlock(language: "latex", code: text)])
        if mode != .editor {
            preview.baseDirectory = markdownDocument?.baseDirectory
            lastProcessing = nil
            preview.update(document: doc)
            warningLabel.stringValue = ""
        }
        statistics = TextStatistics(markdown: text)
        if let last = lastWordCount, statistics.words > last {
            WritingGoals.shared.record(statistics.words - last)
        }
        lastWordCount = statistics.words
        updateStatus()
        updateGoalDisplay()
        statsController?.refresh()
    }

    /// Unresolved citations and cross-references (only meaningful when a bibliography is in use).
    private func updateWarnings(_ result: ProcessingResult) {
        let relevant = result.unresolved.filter { key in
            !result.entries.isEmpty || ["fig:", "tbl:", "eq:", "sec:"].contains { key.hasPrefix($0) }
        }
        var parts: [String] = []
        if !relevant.isEmpty {
            let unique = Array(NSOrderedSet(array: relevant)) as? [String] ?? relevant
            parts.append(LF("warning.unresolved", "⚠︎ Unresolved: %@", unique.prefix(4).joined(separator: ", ") + (unique.count > 4 ? "…" : "")))
        }
        if let problem = result.warnings.first { parts.append("⚠︎ " + problem) }
        warningLabel.stringValue = parts.joined(separator: "  ")
        warningLabel.toolTip = (relevant + result.warnings).joined(separator: "\n")
    }

    private func lineNumber(at index: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func updateStatus() {
        let minutes = max(1, Int(statistics.readingMinutes.rounded()))
        var text = LF("status.words", "%d words · %d characters", statistics.words, statistics.characters)
        if statistics.words > 0 { text += " · " + LF("status.readingTime", "%d min read", minutes) }
        if let goal = documentGoal, goal > 0 {
            text = LF("status.goal", "%d / %d words", statistics.words, goal) + " · " + LF("status.readingTime", "%d min read", minutes)
        }
        statusLabel.stringValue = text
        updatePosition()
    }

    // MARK: - Statistics and goals

    /// Word goal of this document: front matter `goal:` / `word-goal:`, or one set in the statistics panel.
    var documentGoal: Int? {
        get {
            let fm = isLatex ? [:] : MarkdownParser.frontMatter(of: editor.string)
            if let value = fm["goal"] ?? fm["word-goal"] ?? fm["wordgoal"], let n = Int(value.filter(\.isNumber)) { return n }
            return markdownDocument?.fileURL.flatMap { WritingGoals.shared.goal(for: $0) }
        }
        set {
            if let url = markdownDocument?.fileURL { WritingGoals.shared.setGoal(newValue, for: url) }
            updateStatus()
            updateGoalDisplay()
        }
    }

    private func updateGoalDisplay() {
        guard editor != nil else { return }
        if let goal = documentGoal, goal > 0 {
            goalBar.isHidden = false
            goalBar.doubleValue = min(1, Double(statistics.words) / Double(goal))
            goalBar.toolTip = LF("stats.goalProgress", "%d%% of the goal", Int(goalBar.doubleValue * 100))
        } else if Settings.shared.dailyWordGoal > 0 {
            goalBar.isHidden = false
            goalBar.doubleValue = min(1, Double(WritingGoals.shared.wordsToday) / Double(Settings.shared.dailyWordGoal))
            goalBar.toolTip = LF("stats.dailyProgress", "Today: %d of %d words", WritingGoals.shared.wordsToday, Settings.shared.dailyWordGoal)
        } else {
            goalBar.isHidden = true
        }
    }

    private weak var statsController: StatisticsViewController?

    @objc func showStatistics(_ sender: Any?) {
        if let popover = statsPopover, popover.isShown { popover.close(); return }
        let controller = StatisticsViewController(windowController: self)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        statsPopover = popover
        statsController = controller
        popover.show(relativeTo: statusLabel.bounds, of: statusLabel, preferredEdge: .maxY)
    }

    /// Statistics of the current selection (nil when nothing is selected).
    var selectionStatistics: TextStatistics? {
        let sel = editor.selectedRange()
        guard sel.length > 0 else { return nil }
        return TextStatistics(markdown: (editor.string as NSString).substring(with: sel))
    }

    private func updatePosition() {
        let sel = editor.selectedRange()
        let line = lineNumber(at: sel.location)
        let column = sel.location - (line < lineStarts.count ? lineStarts[line] : 0) + 1
        var text = LF("status.position", "Ln %d, Col %d", line + 1, column)
        if sel.length > 0 { text += " · " + LF("status.selected", "%d selected", sel.length) }
        positionLabel.stringValue = text
        sidebar.highlightHeading(forLine: line)
    }

    func showMessage(_ message: String) {
        messageLabel.stringValue = message
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.messageLabel.stringValue = "" }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    // MARK: - Scroll synchronisation

    /// Source line at the top of the editor (fractional), or -1 when scrolled to the end.
    func editorTopLine() -> Double {
        guard let lm = editor.layoutManager, let tc = editor.textContainer else { return 0 }
        let clip = editorScroll.contentView
        if clip.bounds.maxY >= editor.frame.height - 2, clip.bounds.minY > 0 { return -1 }
        let y = clip.bounds.minY - editor.textContainerOrigin.y
        guard lm.numberOfGlyphs > 0 else { return 0 }
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: tc)
        let charIndex = lm.characterIndexForGlyph(at: glyph)
        let line = lineNumber(at: charIndex)
        let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let fraction = rect.height > 0 ? max(0, min(1, (y - rect.minY) / rect.height)) : 0
        return Double(line) + Double(fraction)
    }

    private func editorDidScroll() {
        guard Settings.shared.syncScroll, mode == .split else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if syncSource.side == 2 && now - syncSource.time < 0.25 { return }
        syncSource = (1, now)
        preview.scroll(toLine: editorTopLine())
    }

    private func previewDidScroll(_ line: Double) {
        guard Settings.shared.syncScroll, mode == .split else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if syncSource.side == 1 && now - syncSource.time < 0.25 { return }
        syncSource = (2, now)
        scrollEditor(toLine: line)
    }

    func scrollEditor(toLine line: Double) {
        guard let lm = editor.layoutManager else { return }
        let clip = editorScroll.contentView
        if line < 0 {
            clip.scroll(to: NSPoint(x: 0, y: max(0, editor.frame.height - clip.bounds.height)))
        } else {
            let index = Int(line)
            guard index < lineStarts.count, lm.numberOfGlyphs > 0 else { return }
            let charIndex = min(lineStarts[index], max(0, (editor.string as NSString).length - 1))
            let glyph = lm.glyphIndexForCharacter(at: charIndex)
            let rect = lm.lineFragmentRect(forGlyphAt: min(glyph, lm.numberOfGlyphs - 1), effectiveRange: nil)
            let y = rect.minY + rect.height * CGFloat(line - Double(index))
            clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
        }
        editorScroll.reflectScrolledClipView(clip)
    }

    /// Jumps to a source line in the editor and the preview (outline navigation).
    func reveal(line: Int) {
        let index = max(0, min(line, lineStarts.count - 1))
        let location = lineStarts[index]
        syncSource = (1, ProcessInfo.processInfo.systemUptime)
        if mode != .preview {
            window?.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: location, length: 0))
            scrollEditor(toLine: Double(index))
        }
        if mode != .editor { preview.scroll(toLine: Double(index)) }
    }

    // MARK: - View modes

    func setMode(_ newMode: ViewMode, remember: Bool = true) {
        mode = newMode
        if remember { Settings.shared.defaultViewMode = newMode }
        editorScroll.isHidden = newMode == .preview
        preview.isHidden = newMode == .editor
        contentSplit.adjustSubviews()
        if newMode == .split {
            contentSplit.setPosition(contentSplit.bounds.width / 2, ofDividerAt: 0)
        }
        if newMode != .editor {
            documentStructureChanged()
            if newMode == .split { preview.scroll(toLine: editorTopLine()) }
        } else {
            warningLabel.stringValue = ""
        }
        modeControl?.selectedSegment = newMode.rawValue
        window?.makeFirstResponder(newMode == .preview ? preview : editor)
        window?.toolbar?.validateVisibleItems()
    }

    @objc func showEditorOnly(_ sender: Any?) { setMode(.editor) }
    @objc func showSplit(_ sender: Any?) { setMode(.split) }
    @objc func showPreviewOnly(_ sender: Any?) { setMode(.preview) }
    @objc func toggleEditPreview(_ sender: Any?) { setMode(mode == .preview ? .editor : .preview) }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setMode(ViewMode(rawValue: sender.selectedSegment) ?? .split)
    }

    func setSidebarVisible(_ visible: Bool, remember: Bool = true) {
        if remember { Settings.shared.showSidebar = visible }
        sidebar.isHidden = !visible
        mainSplit.adjustSubviews()
        if visible { mainSplit.setPosition(240, ofDividerAt: 0) }
    }

    var isSidebarVisible: Bool { !sidebar.isHidden }

    @objc func toggleDocumentSidebar(_ sender: Any?) { setSidebarVisible(sidebar.isHidden) }
    @objc func showOutline(_ sender: Any?) { setSidebarVisible(true); sidebar.selectedTab = 0 }
    @objc func showFiles(_ sender: Any?) { setSidebarVisible(true); sidebar.selectedTab = 1 }
    @objc func toggleSyncScroll(_ sender: Any?) { Settings.shared.syncScroll.toggle() }
    @objc func toggleFocusMode(_ sender: Any?) { Settings.shared.focusMode.toggle() }
    @objc func toggleTypewriterMode(_ sender: Any?) { Settings.shared.typewriterMode.toggle() }
    @objc func toggleLiveFormatting(_ sender: Any?) { Settings.shared.liveFormatting.toggle() }
    @objc func toggleNumberSections(_ sender: Any?) { Settings.shared.numberSections.toggle() }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === mainSplit ? max(proposedMinimumPosition, 160) : max(proposedMinimumPosition, 240)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === mainSplit ? min(proposedMaximumPosition, 420) : min(proposedMaximumPosition, splitView.bounds.width - 240)
    }

    func windowDidResize(_ notification: Notification) {
        if mode == .split, !editorScroll.isHidden, !preview.isHidden {
            let w = contentSplit.bounds.width
            let current = editorScroll.frame.width
            if current < 240 || current > w - 240 { contentSplit.setPosition(w / 2, ofDividerAt: 0) }
        }
        editor.updateInsets()
    }

    // MARK: - Editor font size

    @objc func increaseFontSize(_ sender: Any?) { Settings.shared.editorFontSize += 1 }
    @objc func decreaseFontSize(_ sender: Any?) { Settings.shared.editorFontSize -= 1 }
    @objc func resetFontSize(_ sender: Any?) { Settings.shared.editorFontSize = 14 }

    // MARK: - Formatting forwarding

    /// Formatting commands are implemented by the editor; route them there even if
    /// another view (e.g. the preview) has focus. Disabled in preview-only mode.
    static let formattingSelectors: Set<Selector> = [
        #selector(EditorTextView.formatBold(_:)), #selector(EditorTextView.formatItalic(_:)),
        #selector(EditorTextView.formatStrikethrough(_:)), #selector(EditorTextView.formatInlineCode(_:)),
        #selector(EditorTextView.insertLink(_:)), #selector(EditorTextView.insertImage(_:)),
        #selector(EditorTextView.formatHeading1(_:)), #selector(EditorTextView.formatHeading2(_:)),
        #selector(EditorTextView.formatHeading3(_:)), #selector(EditorTextView.formatHeading4(_:)),
        #selector(EditorTextView.formatHeading5(_:)), #selector(EditorTextView.formatHeading6(_:)),
        #selector(EditorTextView.formatParagraph(_:)), #selector(EditorTextView.formatBulletList(_:)),
        #selector(EditorTextView.formatNumberedList(_:)), #selector(EditorTextView.formatTaskList(_:)),
        #selector(EditorTextView.formatQuote(_:)), #selector(EditorTextView.insertCodeBlock(_:)),
        #selector(EditorTextView.insertTable(_:)), #selector(EditorTextView.insertHorizontalRule(_:)),
        #selector(EditorTextView.pasteAsMarkdown(_:)), #selector(EditorTextView.insertFootnote(_:)),
        #selector(EditorTextView.insertInlineMath(_:)), #selector(EditorTextView.insertMathBlock(_:)),
        #selector(EditorTextView.insertDiagram(_:)), #selector(EditorTextView.formatTable(_:)),
        #selector(EditorTextView.tableInsertRow(_:)), #selector(EditorTextView.tableInsertColumn(_:)),
        #selector(EditorTextView.tableDeleteRow(_:)), #selector(EditorTextView.tableDeleteColumn(_:)),
        #selector(EditorTextView.tableAlignLeft(_:)), #selector(EditorTextView.tableAlignCenter(_:)),
        #selector(EditorTextView.tableAlignRight(_:)),
        #selector(EditorTextView.insertComment(_:)), #selector(EditorTextView.markAsInsertion(_:)),
        #selector(EditorTextView.markAsDeletion(_:)), #selector(EditorTextView.selectNextChange(_:)),
        #selector(EditorTextView.selectPreviousChange(_:)), #selector(EditorTextView.acceptChange(_:)),
        #selector(EditorTextView.rejectChange(_:)), #selector(EditorTextView.acceptAllChanges(_:)),
        #selector(EditorTextView.rejectAllChanges(_:)), #selector(EditorTextView.removeAllComments(_:)),
        #selector(EditorTextView.insertTableOfContents(_:)), #selector(EditorTextView.insertReferenceList(_:)),
        #selector(EditorTextView.insertFigure(_:)), #selector(EditorTextView.insertTableCaption(_:)),
        #selector(EditorTextView.insertCrossReference(_:)),
    ]

    /// Commands that only read the text keep working in preview mode.
    static let readOnlySelectors: Set<Selector> = [#selector(EditorTextView.copyAsRichText(_:))]

    override func responds(to aSelector: Selector!) -> Bool {
        if let aSelector, Self.formattingSelectors.contains(aSelector) {
            return mode != .preview && !isLatex
        }
        if let aSelector, Self.readOnlySelectors.contains(aSelector) { return true }
        return super.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let aSelector, Self.formattingSelectors.contains(aSelector), mode != .preview, !isLatex {
            if window?.firstResponder !== editor { window?.makeFirstResponder(editor) }
            return editor
        }
        if let aSelector, Self.readOnlySelectors.contains(aSelector) { return editor }
        return super.forwardingTarget(for: aSelector)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showEditorOnly(_:)): menuItem.state = mode == .editor ? .on : .off
        case #selector(showSplit(_:)): menuItem.state = mode == .split ? .on : .off
        case #selector(showPreviewOnly(_:)): menuItem.state = mode == .preview ? .on : .off
        case #selector(toggleDocumentSidebar(_:)):
            menuItem.title = isSidebarVisible ? L("menu.hideSidebar", "Hide Sidebar") : L("menu.showSidebar", "Show Sidebar")
        case #selector(toggleSyncScroll(_:)): menuItem.state = Settings.shared.syncScroll ? .on : .off
        case #selector(toggleFocusMode(_:)):
            menuItem.state = Settings.shared.focusMode ? .on : .off
            return mode != .preview
        case #selector(toggleTypewriterMode(_:)):
            menuItem.state = Settings.shared.typewriterMode ? .on : .off
            return mode != .preview
        case #selector(toggleLiveFormatting(_:)):
            menuItem.state = Settings.shared.liveFormatting && !isLatex ? .on : .off
            return mode != .preview && !isLatex
        case #selector(exportPDF(_:)), #selector(exportDOCX(_:)), #selector(exportHTML(_:)), #selector(exportEPUB(_:)),
             #selector(EditorTextView.copyAsRichText(_:)):
            return !isLatex
        case #selector(exportResponseLetter(_:)):
            return review.session != nil
        case #selector(showComments(_:)):
            menuItem.state = isSidebarVisible && sidebar.selectedTab == SidebarView.commentsTab ? .on : .off
        case #selector(toggleNumberSections(_:)):
            menuItem.state = Settings.shared.numberSections ? .on : .off
        default: break
        }
        return true
    }

    // MARK: - Export

    private var exportBaseName: String {
        markdownDocument?.displayName.map { ($0 as NSString).deletingPathExtension } ?? L("document.untitled", "Document")
    }

    func exportOptions() -> ExportOptions {
        Settings.shared.exportOptions(title: exportBaseName, baseURL: markdownDocument?.baseDirectory)
    }

    @objc func exportPDF(_ sender: Any?) {
        runExport(type: .pdf, ext: "pdf") { [self] url in try await writePDF(to: url) }
    }

    @objc func exportDOCX(_ sender: Any?) {
        let docxType = UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(filenameExtension: "docx")!
        runExport(type: docxType, ext: "docx") { [self] url in try writeDOCX(to: url) }
    }

    @objc func exportHTML(_ sender: Any?) {
        runExport(type: .html, ext: "html") { [self] url in try writeHTML(to: url) }
    }

    @objc func exportEPUB(_ sender: Any?) {
        let epubType = UTType("org.idpf.epub-container") ?? UTType(filenameExtension: "epub")!
        runExport(type: epubType, ext: "epub") { [self] url in try writeEPUB(to: url) }
    }

    func writePDF(to url: URL) async throws {
        try await PDFExporter.writePDF(markdown: editor.string, options: exportOptions(), to: url)
    }

    func writeDOCX(to url: URL) throws {
        try DocxExporter.data(markdown: editor.string, options: exportOptions()).write(to: url, options: .atomic)
    }

    func writeHTML(to url: URL) throws {
        var options = exportOptions()
        options.headHTML = WebAssets.headHTML(for: .standaloneHTML)
        try PDFExporter.html(markdown: editor.string, options: options, forExport: false)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    func writeEPUB(to url: URL) throws {
        try EPUBWriter.makeEPUB(markdown: editor.string, options: exportOptions()).write(to: url, options: .atomic)
    }

    private func runExport(type: UTType, ext: String, write: @escaping (URL) async throws -> Void) {
        guard let window, !isLatex else { return }
        commitEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = exportBaseName + "." + ext
        panel.directoryURL = markdownDocument?.baseDirectory
        panel.message = LF("export.panelMessage", "Export as %@", ext.uppercased())
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.showMessage(L("export.inProgress", "Exporting…"))
            Task { @MainActor in
                do {
                    try await write(url)
                    self.showMessage(LF("export.done", "Exported: %@", url.lastPathComponent))
                } catch {
                    self.showMessage("")
                    let alert = NSAlert(error: error)
                    alert.messageText = L("export.failed", "Export failed")
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    // MARK: - Printing

    /// Prints the rendered document (same output as the PDF export).
    func printRendered() {
        guard let window, !isLatex else { return }
        commitEditing()
        let options = exportOptions()
        let markdown = editor.string
        let title = exportBaseName
        Task { @MainActor in
            do {
                let data = try await PDFExporter.pdfData(markdown: markdown, options: options)
                guard let pdf = PDFDocument(data: data) else { return }
                let info = NSPrintInfo.shared.copy() as! NSPrintInfo
                info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
                guard let op = pdf.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
                op.jobTitle = title
                op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    // MARK: - Toolbar

    private enum ItemID {
        static let sidebar = NSToolbarItem.Identifier("sidebar")
        static let mode = NSToolbarItem.Identifier("mode")
        static let bold = NSToolbarItem.Identifier("bold")
        static let italic = NSToolbarItem.Identifier("italic")
        static let strike = NSToolbarItem.Identifier("strike")
        static let heading = NSToolbarItem.Identifier("heading")
        static let bullet = NSToolbarItem.Identifier("bullet")
        static let numbered = NSToolbarItem.Identifier("numbered")
        static let task = NSToolbarItem.Identifier("task")
        static let quote = NSToolbarItem.Identifier("quote")
        static let code = NSToolbarItem.Identifier("code")
        static let codeBlock = NSToolbarItem.Identifier("codeBlock")
        static let link = NSToolbarItem.Identifier("link")
        static let image = NSToolbarItem.Identifier("image")
        static let table = NSToolbarItem.Identifier("table")
        static let rule = NSToolbarItem.Identifier("rule")
        static let footnote = NSToolbarItem.Identifier("footnote")
        static let math = NSToolbarItem.Identifier("math")
        static let focus = NSToolbarItem.Identifier("focus")
        static let export = NSToolbarItem.Identifier("export")
        static let citation = NSToolbarItem.Identifier("citation")
        static let comment = NSToolbarItem.Identifier("comment")
        static let live = NSToolbarItem.Identifier("live")
        static let stats = NSToolbarItem.Identifier("stats")
        static let search = NSToolbarItem.Identifier("search")
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ZMarkDownerToolbar3")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.sidebar, ItemID.heading, ItemID.bold, ItemID.italic, ItemID.strike, .space,
         ItemID.bullet, ItemID.numbered, ItemID.task, ItemID.quote, .space,
         ItemID.code, ItemID.codeBlock, ItemID.link, ItemID.image, ItemID.table, ItemID.citation,
         .flexibleSpace, ItemID.live, ItemID.mode, ItemID.export]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [ItemID.rule, ItemID.footnote, ItemID.math, ItemID.focus, ItemID.comment,
                                                  ItemID.stats, ItemID.search, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector, target: AnyObject? = nil) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
            item.target = target
            item.isBordered = true
            return item
        }

        switch id {
        case ItemID.sidebar: return button(L("toolbar.sidebar", "Sidebar"), "sidebar.left", #selector(toggleDocumentSidebar(_:)), target: self)
        case ItemID.bold: return button(L("toolbar.bold", "Bold (⌘B)"), "bold", #selector(EditorTextView.formatBold(_:)))
        case ItemID.italic: return button(L("toolbar.italic", "Italic (⌘I)"), "italic", #selector(EditorTextView.formatItalic(_:)))
        case ItemID.strike: return button(L("toolbar.strike", "Strikethrough"), "strikethrough", #selector(EditorTextView.formatStrikethrough(_:)))
        case ItemID.bullet: return button(L("toolbar.bullet", "Bulleted List"), "list.bullet", #selector(EditorTextView.formatBulletList(_:)))
        case ItemID.numbered: return button(L("toolbar.numbered", "Numbered List"), "list.number", #selector(EditorTextView.formatNumberedList(_:)))
        case ItemID.task: return button(L("toolbar.task", "Task List"), "checklist", #selector(EditorTextView.formatTaskList(_:)))
        case ItemID.quote: return button(L("toolbar.quote", "Quote"), "text.quote", #selector(EditorTextView.formatQuote(_:)))
        case ItemID.code: return button(L("toolbar.code", "Code"), "chevron.left.forwardslash.chevron.right", #selector(EditorTextView.formatInlineCode(_:)))
        case ItemID.codeBlock: return button(L("toolbar.codeBlock", "Code Block"), "curlybraces.square", #selector(EditorTextView.insertCodeBlock(_:)))
        case ItemID.link: return button(L("toolbar.link", "Link (⌘K)"), "link", #selector(EditorTextView.insertLink(_:)))
        case ItemID.image: return button(L("toolbar.image", "Image"), "photo", #selector(EditorTextView.insertImage(_:)))
        case ItemID.table: return button(L("toolbar.table", "Table"), "tablecells", #selector(EditorTextView.insertTable(_:)))
        case ItemID.rule: return button(L("toolbar.rule", "Horizontal Rule"), "minus", #selector(EditorTextView.insertHorizontalRule(_:)))
        case ItemID.footnote: return button(L("toolbar.footnote", "Footnote"), "text.append", #selector(EditorTextView.insertFootnote(_:)))
        case ItemID.math: return button(L("toolbar.math", "Formula"), "function", #selector(EditorTextView.insertMathBlock(_:)))
        case ItemID.focus: return button(L("toolbar.focus", "Focus Mode"), "scope", #selector(toggleFocusMode(_:)), target: self)
        case ItemID.citation: return button(L("toolbar.citation", "Citation"), "books.vertical", #selector(insertCitation(_:)), target: self)
        case ItemID.comment: return button(L("toolbar.comment", "Comment"), "text.bubble", #selector(EditorTextView.insertComment(_:)))
        case ItemID.live: return button(L("menu.liveFormatting", "Live Formatting"), "textformat", #selector(toggleLiveFormatting(_:)), target: self)
        case ItemID.stats: return button(L("menu.statistics", "Document Statistics"), "chart.bar.xaxis", #selector(showStatistics(_:)), target: self)
        case ItemID.search: return button(L("menu.searchFolder", "Search in Folder…"), "magnifyingglass", #selector(showFolderSearch(_:)), target: self)

        case ItemID.heading:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = L("toolbar.heading", "Heading")
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: "textformat.size", accessibilityDescription: item.label)
            let menu = NSMenu()
            menu.addItem(withTitle: L("menu.normalText", "Normal Text"), action: #selector(EditorTextView.formatParagraph(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            let actions: [Selector] = [
                #selector(EditorTextView.formatHeading1(_:)), #selector(EditorTextView.formatHeading2(_:)),
                #selector(EditorTextView.formatHeading3(_:)), #selector(EditorTextView.formatHeading4(_:)),
                #selector(EditorTextView.formatHeading5(_:)), #selector(EditorTextView.formatHeading6(_:)),
            ]
            for (i, action) in actions.enumerated() {
                let title = LF("menu.headingN", "Heading %d", i + 1)
                let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
                let size: CGFloat = [20, 17, 15, 13, 12, 11][i]
                mi.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: size)])
                menu.addItem(mi)
            }
            item.menu = menu
            item.showsIndicator = true
            return item

        case ItemID.mode:
            let control = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: L("view.editor", "Editor"))!,
                NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: L("view.split", "Split View"))!,
                NSImage(systemSymbolName: "eye", accessibilityDescription: L("view.preview", "Final View"))!,
            ], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
            control.setToolTip(L("view.editor", "Editor") + " (⌘1)", forSegment: 0)
            control.setToolTip(L("view.split", "Split View") + " (⌘2)", forSegment: 1)
            control.setToolTip(L("view.preview", "Final View") + " (⌘3)", forSegment: 2)
            control.selectedSegment = mode.rawValue
            modeControl = control
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = control
            item.label = L("toolbar.view", "View")
            item.paletteLabel = item.label
            return item

        case ItemID.export:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = L("toolbar.export", "Export")
            item.paletteLabel = item.label
            item.toolTip = L("toolbar.exportTip", "Export as PDF, Word, HTML or EPUB")
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: item.label)
            let menu = NSMenu()
            menu.addItem(withTitle: L("menu.exportPDF", "Export as PDF…"), action: #selector(exportPDF(_:)), keyEquivalent: "")
            menu.addItem(withTitle: L("menu.exportDOCX", "Export as Word (DOCX)…"), action: #selector(exportDOCX(_:)), keyEquivalent: "")
            menu.addItem(withTitle: L("menu.exportHTML", "Export as HTML…"), action: #selector(exportHTML(_:)), keyEquivalent: "")
            menu.addItem(withTitle: L("menu.exportEPUB", "Export as EPUB…"), action: #selector(exportEPUB(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L("menu.copyRich", "Copy as Formatted Text"), action: #selector(EditorTextView.copyAsRichText(_:)), keyEquivalent: "")
            item.menu = menu
            item.showsIndicator = true
            return item

        default:
            return nil
        }
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        previewWork?.cancel()
    }
}
