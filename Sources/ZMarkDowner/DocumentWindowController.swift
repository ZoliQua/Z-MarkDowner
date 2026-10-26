import AppKit
import UniformTypeIdentifiers
import MarkDownerCore

enum ViewMode: Int {
    case editor = 0, split = 1, preview = 2

    static var preferred: ViewMode {
        get { ViewMode(rawValue: UserDefaults.standard.integer(forKey: "viewMode")) ?? .split }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "viewMode") }
    }
}

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate,
                                      NSToolbarDelegate, NSSplitViewDelegate, NSMenuItemValidation {

    private let splitView = NSSplitView()
    private let editorScroll = NSScrollView()
    private(set) var editor: EditorTextView!
    private let preview = PreviewView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private var modeControl: NSSegmentedControl?

    private let highlighter: MarkdownHighlighter
    private var previewWork: DispatchWorkItem?
    private var highlightWork: DispatchWorkItem?
    private var messageWork: DispatchWorkItem?

    private(set) var mode: ViewMode = .split

    /// Set at init; NSDocument.addWindowController assigns `document` afterwards
    /// (assigning it ourselves beforehand makes addWindowController skip registration).
    private weak var ownerDocument: MarkdownDocument?

    var markdownDocument: MarkdownDocument? { (document as? MarkdownDocument) ?? ownerDocument }

    static var editorFontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: "editorFontSize")
            return v > 0 ? CGFloat(v) : 14
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "editorFontSize") }
    }

    init(document: MarkdownDocument) {
        highlighter = MarkdownHighlighter(fontSize: Self.editorFontSize)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 560, height: 360)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titlebarSeparatorStyle = .line
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        super.init(window: window)
        ownerDocument = document
        window.delegate = self
        buildUI()
        buildToolbar()
        loadDocumentText()
        setMode(document.importedFrom != nil ? .split : ViewMode.preferred, remember: false)
        window.setFrameAutosaveName("ZMarkDownerDocumentWindow")
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        editor.isContinuousSpellCheckingEnabled = true
        editor.smartInsertDeleteEnabled = false
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.insertionPointColor = .controlAccentColor
        editor.delegate = self
        editor.typingAttributes = highlighter.baseAttributes
        editor.setAccessibilityLabel("Markdown szerkesztő")

        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = .textBackgroundColor
        editorScroll.borderType = .noBorder

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(editorScroll)
        splitView.addArrangedSubview(preview)
        splitView.translatesAutoresizingMaskIntoConstraints = false

        // Status bar
        let statusBar = NSVisualEffectView()
        statusBar.material = .titlebar
        statusBar.blendingMode = .withinWindow
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        for label in [statusLabel, messageLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            statusBar.addSubview(label)
        }
        messageLabel.alignment = .right
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusBar.addSubview(separator)

        content.addSubview(splitView)
        content.addSubview(statusBar)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            separator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            messageLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
    }

    // MARK: - Document text

    private func loadDocumentText() {
        let text = markdownDocument?.text ?? ""
        editor.string = text
        preview.baseDirectory = markdownDocument?.baseDirectory
        rehighlight()
        preview.update(markdown: text)
        updateStatus()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        markdownDocument?.undoManager?.removeAllActions()
    }

    /// Called when the document re-reads its file (e.g. Revert).
    func documentTextDidChangeExternally() {
        guard editor != nil, let doc = markdownDocument, editor.string != doc.text else { return }
        loadDocumentText()
    }

    func commitEditing() {
        guard editor != nil else { return }
        markdownDocument?.text = editor.string
    }

    func textDidChange(_ notification: Notification) {
        markdownDocument?.text = editor.string
        scheduleHighlight()
        schedulePreview()
        updateStatus()
    }

    private func scheduleHighlight() {
        highlightWork?.cancel()
        let length = (editor.string as NSString).length
        if length < 60_000 {
            rehighlight()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.rehighlight() }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func rehighlight() {
        guard let storage = editor.textStorage else { return }
        highlighter.highlight(storage)
        editor.typingAttributes = highlighter.baseAttributes
    }

    private func schedulePreview() {
        guard mode != .editor else { return }
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.preview.update(markdown: self.editor.string)
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func updateStatus() {
        let text = editor.string
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        statusLabel.stringValue = "\(words) szó · \(text.count) karakter · \(lines) sor"
    }

    func showMessage(_ message: String) {
        messageLabel.stringValue = message
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.messageLabel.stringValue = "" }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    // MARK: - View modes

    func setMode(_ newMode: ViewMode, remember: Bool = true) {
        mode = newMode
        if remember { ViewMode.preferred = newMode }
        editorScroll.isHidden = newMode == .preview
        preview.isHidden = newMode == .editor
        splitView.adjustSubviews()
        if newMode == .split {
            splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
        }
        if newMode != .editor {
            preview.baseDirectory = markdownDocument?.baseDirectory
            preview.update(markdown: editor.string)
        }
        modeControl?.selectedSegment = newMode.rawValue
        if newMode == .preview {
            window?.makeFirstResponder(preview)
        } else {
            window?.makeFirstResponder(editor)
        }
        window?.toolbar?.validateVisibleItems()
    }

    @objc func showEditorOnly(_ sender: Any?) { setMode(.editor) }
    @objc func showSplit(_ sender: Any?) { setMode(.split) }
    @objc func showPreviewOnly(_ sender: Any?) { setMode(.preview) }
    @objc func toggleEditPreview(_ sender: Any?) { setMode(mode == .preview ? .editor : .preview) }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setMode(ViewMode(rawValue: sender.selectedSegment) ?? .split)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 240)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 240)
    }

    func windowDidResize(_ notification: Notification) {
        // Keep the split balanced when entering/leaving full screen
        if mode == .split, !editorScroll.isHidden, !preview.isHidden {
            let w = splitView.bounds.width
            let current = editorScroll.frame.width
            if current < 240 || current > w - 240 { splitView.setPosition(w / 2, ofDividerAt: 0) }
        }
    }

    // MARK: - Editor font size

    @objc func increaseFontSize(_ sender: Any?) { changeFontSize(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { changeFontSize(by: -1) }
    @objc func resetFontSize(_ sender: Any?) { changeFontSize(to: 14) }

    private func changeFontSize(by delta: CGFloat) {
        changeFontSize(to: highlighter.fontSize + delta)
    }

    private func changeFontSize(to size: CGFloat) {
        let clamped = min(max(size, 9), 36)
        highlighter.fontSize = clamped
        Self.editorFontSize = clamped
        rehighlight()
    }

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
        #selector(EditorTextView.pasteAsMarkdown(_:)),
    ]

    override func responds(to aSelector: Selector!) -> Bool {
        if let aSelector, Self.formattingSelectors.contains(aSelector) {
            return mode != .preview
        }
        return super.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let aSelector, Self.formattingSelectors.contains(aSelector), mode != .preview {
            if window?.firstResponder !== editor { window?.makeFirstResponder(editor) }
            return editor
        }
        return super.forwardingTarget(for: aSelector)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showEditorOnly(_:)): menuItem.state = mode == .editor ? .on : .off
        case #selector(showSplit(_:)): menuItem.state = mode == .split ? .on : .off
        case #selector(showPreviewOnly(_:)): menuItem.state = mode == .preview ? .on : .off
        default: break
        }
        return true
    }

    // MARK: - Export

    private var exportBaseName: String {
        markdownDocument?.displayName.map { ($0 as NSString).deletingPathExtension } ?? "Dokumentum"
    }

    @objc func exportPDF(_ sender: Any?) {
        runExport(type: .pdf, ext: "pdf", write: writePDF(to:))
    }

    @objc func exportDOCX(_ sender: Any?) {
        let docxType = UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(filenameExtension: "docx")!
        runExport(type: docxType, ext: "docx", write: writeDOCX(to:))
    }

    @objc func exportHTML(_ sender: Any?) {
        runExport(type: .html, ext: "html", write: writeHTML(to:))
    }

    func writePDF(to url: URL) throws {
        try PDFExporter.writePDF(markdown: editor.string, title: exportBaseName,
                                 baseURL: markdownDocument?.baseDirectory, to: url)
    }

    func writeDOCX(to url: URL) throws {
        let base = markdownDocument?.baseDirectory
        var writer = DocxWriter(title: exportBaseName) { src in ImageLoader.load(src, base: base) }
        try writer.makeDocx(markdown: editor.string).write(to: url, options: .atomic)
    }

    func writeHTML(to url: URL) throws {
        let base = markdownDocument?.baseDirectory
        let body = HTMLRenderer.render(markdown: editor.string) { src in
            // Embed local images so the exported page is self-contained
            guard let image = ImageLoader.load(src, base: base) else { return src }
            return "data:image/\(image.fileExtension);base64,\(image.data.base64EncodedString())"
        }
        let html = HTMLRenderer.page(body: body, title: exportBaseName, css: Stylesheets.preview)
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    private func runExport(type: UTType, ext: String, write: @escaping (URL) throws -> Void) {
        guard let window else { return }
        commitEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = exportBaseName + "." + ext
        panel.directoryURL = markdownDocument?.baseDirectory
        panel.message = "Exportálás \(ext.uppercased()) formátumba"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try write(url)
                self.showMessage("Exportálva: \(url.lastPathComponent)")
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Az exportálás nem sikerült"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
    }

    // MARK: - Toolbar

    private enum ItemID {
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
        static let export = NSToolbarItem.Identifier("export")
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ZMarkDownerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.heading, ItemID.bold, ItemID.italic, ItemID.strike, .space,
         ItemID.bullet, ItemID.numbered, ItemID.task, ItemID.quote, .space,
         ItemID.code, ItemID.codeBlock, ItemID.link, ItemID.image, ItemID.table,
         .flexibleSpace, ItemID.mode, ItemID.export]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [ItemID.rule, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
            item.target = nil
            item.isBordered = true
            return item
        }

        switch id {
        case ItemID.bold: return button("Félkövér (⌘B)", "bold", #selector(EditorTextView.formatBold(_:)))
        case ItemID.italic: return button("Dőlt (⌘I)", "italic", #selector(EditorTextView.formatItalic(_:)))
        case ItemID.strike: return button("Áthúzott", "strikethrough", #selector(EditorTextView.formatStrikethrough(_:)))
        case ItemID.bullet: return button("Felsorolás", "list.bullet", #selector(EditorTextView.formatBulletList(_:)))
        case ItemID.numbered: return button("Számozott lista", "list.number", #selector(EditorTextView.formatNumberedList(_:)))
        case ItemID.task: return button("Feladatlista", "checklist", #selector(EditorTextView.formatTaskList(_:)))
        case ItemID.quote: return button("Idézet", "text.quote", #selector(EditorTextView.formatQuote(_:)))
        case ItemID.code: return button("Kód", "chevron.left.forwardslash.chevron.right", #selector(EditorTextView.formatInlineCode(_:)))
        case ItemID.codeBlock: return button("Kódblokk", "curlybraces.square", #selector(EditorTextView.insertCodeBlock(_:)))
        case ItemID.link: return button("Link (⌘K)", "link", #selector(EditorTextView.insertLink(_:)))
        case ItemID.image: return button("Kép", "photo", #selector(EditorTextView.insertImage(_:)))
        case ItemID.table: return button("Táblázat", "tablecells", #selector(EditorTextView.insertTable(_:)))
        case ItemID.rule: return button("Vízszintes vonal", "minus", #selector(EditorTextView.insertHorizontalRule(_:)))

        case ItemID.heading:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Címsor"
            item.paletteLabel = "Címsor"
            item.toolTip = "Címsor"
            item.image = NSImage(systemSymbolName: "textformat.size", accessibilityDescription: "Címsor")
            let menu = NSMenu()
            menu.addItem(withTitle: "Normál szöveg", action: #selector(EditorTextView.formatParagraph(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            let headingActions: [Selector] = [
                #selector(EditorTextView.formatHeading1(_:)), #selector(EditorTextView.formatHeading2(_:)),
                #selector(EditorTextView.formatHeading3(_:)), #selector(EditorTextView.formatHeading4(_:)),
                #selector(EditorTextView.formatHeading5(_:)), #selector(EditorTextView.formatHeading6(_:)),
            ]
            for (i, action) in headingActions.enumerated() {
                let mi = NSMenuItem(title: "Címsor \(i + 1)", action: action, keyEquivalent: "")
                let size: CGFloat = [20, 17, 15, 13, 12, 11][i]
                mi.attributedTitle = NSAttributedString(string: "Címsor \(i + 1)",
                                                        attributes: [.font: NSFont.boldSystemFont(ofSize: size)])
                menu.addItem(mi)
            }
            item.menu = menu
            item.showsIndicator = true
            return item

        case ItemID.mode:
            let control = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Szerkesztő")!,
                NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Osztott nézet")!,
                NSImage(systemSymbolName: "eye", accessibilityDescription: "Előnézet")!,
            ], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
            control.setToolTip("Szerkesztő (⌘1)", forSegment: 0)
            control.setToolTip("Osztott nézet (⌘2)", forSegment: 1)
            control.setToolTip("Végleges nézet / előnézet (⌘3)", forSegment: 2)
            control.selectedSegment = mode.rawValue
            modeControl = control
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = control
            item.label = "Nézet"
            item.paletteLabel = "Nézet"
            return item

        case ItemID.export:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Exportálás"
            item.paletteLabel = "Exportálás"
            item.toolTip = "Exportálás PDF / DOCX / HTML formátumba"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Exportálás")
            let menu = NSMenu()
            menu.addItem(withTitle: "Exportálás PDF-be…", action: #selector(exportPDF(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Exportálás Word (DOCX) formátumba…", action: #selector(exportDOCX(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Exportálás HTML-be…", action: #selector(exportHTML(_:)), keyEquivalent: "")
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
        highlightWork?.cancel()
    }
}

/// Loads images referenced from Markdown for DOCX embedding.
enum ImageLoader {
    static func load(_ src: String, base: URL?) -> DocxImage? {
        var url: URL?
        if let u = URL(string: src), let scheme = u.scheme?.lowercased() {
            guard scheme == "file" else { return nil } // remote images are not downloaded
            url = u
        } else if src.hasPrefix("/") {
            url = URL(fileURLWithPath: src.removingPercentEncoding ?? src)
        } else if let base {
            url = base.appendingPathComponent(src.removingPercentEncoding ?? src)
        }
        guard let url, let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        let ext = url.pathExtension.lowercased()
        // Use point size (96 dpi equivalents) so high-res images keep their intended size
        let width = rep.size.width > 0 ? Int(rep.size.width * 96 / 72) : rep.pixelsWide
        let height = rep.size.height > 0 ? Int(rep.size.height * 96 / 72) : rep.pixelsHigh
        if ["png", "jpg", "jpeg", "gif"].contains(ext) {
            return DocxImage(data: data, fileExtension: ext == "jpg" ? "jpeg" : ext, pixelWidth: width, pixelHeight: height)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return DocxImage(data: png, fileExtension: "png", pixelWidth: width, pixelHeight: height)
    }
}
