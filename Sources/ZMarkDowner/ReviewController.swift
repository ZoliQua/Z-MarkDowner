import AppKit
import PDFKit
import UniformTypeIdentifiers
import MarkDownerCore

/// Why review comments could not be imported or applied.
enum ReviewImportError: LocalizedError {
    case unsaved
    case unreadablePDF(String)
    case noComments
    case cannotOpen(String)

    var errorDescription: String? {
        switch self {
        case .unsaved:
            return L("review.error.unsaved", "Save the document first: the review is stored next to it.")
        case .unreadablePDF(let name):
            return LF("review.error.unreadablePDF", "“%@” could not be read as a PDF.", name)
        case .noComments:
            return L("review.error.noComments", "The PDF contains no comments or markups.")
        case .cannotOpen(let name):
            return LF("review.error.cannotOpen", "“%@” could not be opened for editing.", name)
        }
    }
}

/// The review of one manuscript in a document window: the comments imported from a reviewer's PDF,
/// where they lie in the source files, and the user's work on them.
///
/// The review belongs to the window of the main source file. For LaTeX the source is the main file with
/// the files it pulls in through `\input` / `\include`; comments are anchored across all of them at once
/// against their current texts (the editor text of open documents, the file on disk otherwise), and an
/// anchor is a file with a range in that file's text. Suggestions are applied through the editor of the
/// file they lie in, opening it when needed, so every change is undoable and never written behind the
/// user's back. Every change of state is saved to the sidecar next to the main file.
final class ReviewController {
    weak var windowController: DocumentWindowController?
    private(set) var session: ReviewSession?
    /// Anchor of each anchored comment (by id) in the text of `anchorFiles[id]`.
    private(set) var anchors: [String: NSRange] = [:]
    private(set) var anchorFiles: [String: URL] = [:]
    /// The source files in document order (the main file first).
    private(set) var sourceFiles: [URL] = []
    /// Called after the session, a status or the anchors changed.
    var onChange: (() -> Void)?
    /// The text of each source file (by path) the anchors were computed against.
    private var snapshots: [String: String] = [:]

    var mainURL: URL? { windowController?.markdownDocument?.fileURL }

    /// Review marks can be written into the text only for a single Markdown file.
    var canInsertMarks: Bool { session?.sourceFormat == .markdown && sourceFiles.count <= 1 }

    func comment(_ id: String) -> ReviewComment? {
        session?.comments.first { $0.id == id }
    }

    func count(_ status: ReviewStatus) -> Int {
        session?.comments.filter { $0.status == status }.count ?? 0
    }

    // MARK: Import and persistence

    /// Whether the sidecar holds a review made from `pdf`.
    func hasReview(from pdf: URL) -> Bool {
        guard let main = mainURL else { return false }
        return ReviewSession.load(for: main, pdf: pdf) != nil
    }

    /// Reads the comments of `url` and starts a review with them. With `continueExisting` the progress
    /// stored for the same PDF (statuses, replies, suggestions) is kept for every comment that is unchanged.
    func importPDF(_ url: URL, continueExisting: Bool = false) throws {
        guard let main = mainURL, let document = windowController?.markdownDocument else { throw ReviewImportError.unsaved }
        guard let pdf = PDFDocument(url: url) else { throw ReviewImportError.unreadablePDF(url.lastPathComponent) }
        var comments = PDFReviewExtractor.comments(from: pdf)
        guard !comments.isEmpty else { throw ReviewImportError.noComments }
        var createdAt = Date()
        if continueExisting, let existing = ReviewSession.load(for: main, pdf: url) {
            let stored = Dictionary(existing.comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            comments = comments.map { fresh in
                guard let old = stored[fresh.id], old.quotedText == fresh.quotedText, old.comment == fresh.comment else { return fresh }
                return old
            }
            createdAt = existing.createdAt
        }
        session = ReviewSession(pdfPath: url.path, mainPath: main.path, sourceFormat: document.sourceFormat,
                                comments: comments, createdAt: createdAt)
        reanchor()
        saveSidecar()
    }

    /// Loads the review stored next to the main file (none: the panel is emptied).
    func loadSidecar() {
        session = mainURL.flatMap { ReviewSession.load(for: $0) }
        reanchor()
    }

    func saveSidecar() {
        guard var session, let main = mainURL else { return }
        session.mainPath = main.path
        do {
            try session.save(for: main)
        } catch {
            windowController?.showMessage(LF("review.saveFailed", "The review could not be saved: %@", error.localizedDescription))
        }
    }

    /// The main file was saved under a new name: an open review moves with it, otherwise the one stored
    /// next to the new location is loaded.
    func mainLocationChanged() {
        if session != nil { saveSidecar(); reanchor() } else { loadSidecar() }
    }

    // MARK: Anchors

    /// Places every comment in the current texts of the source files.
    func reanchor() {
        anchors = [:]
        anchorFiles = [:]
        snapshots = [:]
        sourceFiles = []
        guard let session, let main = mainURL else { onChange?(); return }
        let files = session.sourceFormat == .latex ? ((try? SourceTree(main: main).files) ?? [main]) : [main]
        let texts = files.map { (url: $0, text: currentText(of: $0)) }
        let tree = SourceTree(files: texts, format: session.sourceFormat)
        sourceFiles = tree.files
        for item in texts { snapshots[Self.key(item.url)] = item.text }
        for comment in session.comments {
            guard let found = tree.locate(comment) else { continue }
            anchors[comment.id] = found.range
            anchorFiles[comment.id] = found.file
        }
        onChange?()
    }

    /// Re-anchors when any source file changed since the anchors were computed.
    func refresh() {
        guard session != nil else { return }
        if sourceFiles.isEmpty || sourceFiles.contains(where: isStale) { reanchor() }
    }

    /// Re-anchors when the file the comment lies in (or, unanchored, any file) changed since.
    private func refresh(for id: String) {
        if let file = anchorFiles[id] {
            if isStale(file) { reanchor() }
        } else {
            refresh()
        }
    }

    private func isStale(_ file: URL) -> Bool {
        snapshots[Self.key(file)] != currentText(of: file)
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    private func isMain(_ url: URL) -> Bool {
        mainURL.map { Self.key($0) == Self.key(url) } ?? false
    }

    /// The editor text of an open document, else the file on disk.
    private func currentText(of url: URL) -> String {
        if isMain(url), let editor = windowController?.editor { return editor.string }
        if let document = NSDocumentController.shared.document(for: url) as? MarkdownDocument {
            return document.windowController?.editor.string ?? document.text
        }
        return (try? Data(contentsOf: url)).map(DocumentImporter.decodeText) ?? ""
    }

    /// The editor of `url`, opening the document in its own window when it is not open yet.
    private func editor(for url: URL) throws -> EditorTextView {
        if isMain(url), let editor = windowController?.editor { return editor }
        let controller = NSDocumentController.shared
        if let open = controller.document(for: url) as? MarkdownDocument, let editor = open.windowController?.editor {
            return editor
        }
        do {
            let type = try controller.typeForContents(of: url)
            guard let document = try controller.makeDocument(withContentsOf: url, ofType: type) as? MarkdownDocument,
                  document.fileURL != nil else { throw ReviewImportError.cannotOpen(url.lastPathComponent) }
            controller.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            windowController?.window?.makeKeyAndOrderFront(nil)
            guard let editor = document.windowController?.editor else { throw ReviewImportError.cannotOpen(url.lastPathComponent) }
            return editor
        } catch let error as ReviewImportError {
            throw error
        } catch {
            throw ReviewImportError.cannotOpen(url.lastPathComponent)
        }
    }

    // MARK: Actions

    /// Selects the comment's passage in the editor of its file (opened when needed) and focuses it.
    func select(_ id: String) {
        guard let windowController else { return }
        refresh(for: id)
        guard let file = anchorFiles[id], let range = anchors[id] else {
            windowController.showMessage(L("review.unanchored", "Not found in the source"))
            return
        }
        windowController.openSearchResult(file, range)
    }

    /// Shows the comment's passage when it lies in the main file, leaving the focus in the panel.
    func highlight(_ id: String) {
        guard let editor = windowController?.editor else { return }
        refresh(for: id)
        guard let file = anchorFiles[id], isMain(file), let range = anchors[id],
              NSMaxRange(range) <= (editor.string as NSString).length else { return }
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
        editor.showFindIndicator(for: range)
        windowController?.scrollPreview(toCharacter: range.location)
    }

    /// Applies the comment's suggestion to its source file as one undoable edit and marks it applied.
    /// The target is verified in the current text first (`ReviewSession.edit`), so a stale anchor never
    /// edits other words.
    func apply(_ id: String) throws {
        try apply(id, save: true)
    }

    private func apply(_ id: String, save: Bool) throws {
        guard let session, let index = session.comments.firstIndex(where: { $0.id == id }) else { return }
        guard let suggestion = session.comments[index].suggestion else { throw ReviewSessionError.noSuggestion }
        refresh(for: id)
        guard let file = anchorFiles[id], let range = anchors[id] else { throw ReviewSessionError.unanchored }
        let editor = try editor(for: file)
        let old = editor.string
        let result = try ReviewSession.edit(applying: suggestion, at: range, in: old, format: session.sourceFormat)
        let change = Self.changedRange(from: old as NSString, to: result.text as NSString)
        let inserted = (result.text as NSString).substring(with: NSRange(location: change.location, length: change.length + result.delta))
        editor.replace(change, with: inserted,
                       select: NSRange(location: result.range.location - change.location, length: result.range.length))
        guard editor.string == result.text else {
            reanchor()
            throw ReviewSessionError.targetChanged(suggestion.target)
        }
        snapshots[Self.key(file)] = result.text
        for (other, anchor) in anchors where other != id && anchorFiles[other].map(Self.key) == Self.key(file)
            && anchor.location >= NSMaxRange(change) {
            anchors[other] = NSRange(location: anchor.location + result.delta, length: anchor.length)
        }
        anchors[id] = result.range
        registerStatusUndo(id, on: editor.undoManager)
        self.session?.comments[index].status = .applied
        if save {
            saveSidecar()
            onChange?()
        }
    }

    /// Registers the comment's current status on `undoManager`, in the undo group of the edit made in the
    /// same event, so undoing an applied suggestion also reopens the comment (and redo applies it again).
    private func registerStatusUndo(_ id: String, on undoManager: UndoManager?) {
        guard let undoManager, let status = comment(id)?.status else { return }
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            self?.restoreStatus(id, status, undoManager: undoManager)
        }
    }

    private func restoreStatus(_ id: String, _ status: ReviewStatus, undoManager: UndoManager) {
        registerStatusUndo(id, on: undoManager)
        setStatus(id, status)
    }

    /// The part of `old` that differs from `new` (common prefix and suffix removed).
    private static func changedRange(from old: NSString, to new: NSString) -> NSRange {
        var prefix = 0
        let shorter = min(old.length, new.length)
        while prefix < shorter && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix
                && old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        return NSRange(location: prefix, length: old.length - prefix - suffix)
    }

    /// The open comments with a suggestion, which Apply All works through.
    var applicableIDs: [String] {
        session?.comments.filter { $0.status == .open && $0.suggestion != nil }.map(\.id) ?? []
    }

    /// Applies every open suggestion, from the end of each file backwards; suggestions whose target is no
    /// longer where the comment points are skipped and stay open.
    func applyAll() -> (applied: Int, failed: Int) {
        reanchor()
        let ids = applicableIDs.sorted { a, b in
            let fileA = anchorFiles[a].map(Self.key) ?? "", fileB = anchorFiles[b].map(Self.key) ?? ""
            if fileA != fileB { return fileA < fileB }
            return (anchors[a]?.location ?? 0) > (anchors[b]?.location ?? 0)
        }
        var applied = 0, failed = 0
        for id in ids {
            do {
                try apply(id, save: false)
                applied += 1
            } catch {
                failed += 1
            }
        }
        saveSidecar()
        onChange?()
        return (applied, failed)
    }

    func setStatus(_ id: String, _ status: ReviewStatus) {
        modify(id) { $0.status = status }
    }

    func setReply(_ id: String, _ text: String) {
        modify(id) { $0.reply = text }
    }

    /// Replaces a comment (matched by id) with an edited version, e.g. one with a new suggestion.
    func update(_ comment: ReviewComment) {
        modify(comment.id) { $0 = comment }
    }

    private func modify(_ id: String, _ change: (inout ReviewComment) -> Void) {
        guard let index = session?.comments.firstIndex(where: { $0.id == id }) else { return }
        change(&session!.comments[index])
        saveSidecar()
        onChange?()
    }

    /// Writes every anchored comment into the Markdown text as review marks (one undoable edit).
    func insertMarks() {
        guard canInsertMarks, let session, let windowController else { return }
        let text = windowController.editor.string
        let marked = session.markdownMarks(source: text)
        guard marked != text else { return }
        windowController.replaceAllText(with: marked)
        reanchor()
    }

    // MARK: Response letter

    var letterTitle: String {
        let name = mainURL?.deletingPathExtension().lastPathComponent ?? ""
        return name.isEmpty ? L("review.letter.title", "Response to Reviewers")
            : LF("review.letter.titleFor", "Response to Reviewers: %@", name)
    }

    /// Writes the response letter as Markdown or, with `asDOCX`, as a Word document.
    func exportResponse(to url: URL, asDOCX: Bool) throws {
        guard let session else { return }
        let letter = session.responseLetter(title: letterTitle)
        if asDOCX {
            let options = Settings.shared.exportOptions(title: letterTitle, baseURL: mainURL?.deletingLastPathComponent())
            try DocxExporter.data(markdown: letter, options: options).write(to: url, options: .atomic)
        } else {
            try letter.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

extension DocumentWindowController {

    /// File ▸ Import Review Comments from PDF…
    @objc func importReviewComments(_ sender: Any?) {
        guard let window else { return }
        guard markdownDocument?.fileURL != nil else {
            let alert = NSAlert()
            alert.messageText = L("review.import.title", "Import Review Comments")
            alert.informativeText = ReviewImportError.unsaved.localizedDescription
            alert.beginSheetModal(for: window, completionHandler: nil)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = L("review.import.panel", "Choose the PDF with the reviewer's comments")
        panel.prompt = L("review.import.prompt", "Import")
        panel.directoryURL = markdownDocument?.baseDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { self?.importReview(from: url) }
        }
    }

    /// Imports `url`, asking first whether to continue a review of the same PDF or to replace a review of
    /// another one.
    private func importReview(from url: URL) {
        guard let window else { return }
        if review.hasReview(from: url) {
            let alert = NSAlert()
            alert.messageText = L("review.continue.title", "Continue the existing review?")
            alert.informativeText = LF("review.continue.text", "Comments from “%@” were imported before. Continue where you left off, or start again with the comments as they are in the PDF?", url.lastPathComponent)
            alert.addButton(withTitle: L("review.continue.continue", "Continue Review"))
            alert.addButton(withTitle: L("review.continue.fresh", "Start Fresh"))
            alert.addButton(withTitle: L("button.cancel", "Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response != .alertThirdButtonReturn else { return }
                self?.runImport(url, continueExisting: response == .alertFirstButtonReturn)
            }
        } else if let current = review.session {
            let alert = NSAlert()
            alert.messageText = L("review.replace.title", "Replace the current review?")
            alert.informativeText = LF("review.replace.text", "The review of “%@” and your progress on it will be replaced.",
                                       URL(fileURLWithPath: current.pdfPath).lastPathComponent)
            alert.addButton(withTitle: L("review.replace.button", "Replace"))
            alert.addButton(withTitle: L("button.cancel", "Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.runImport(url, continueExisting: false)
            }
        } else {
            runImport(url, continueExisting: false)
        }
    }

    private func runImport(_ url: URL, continueExisting: Bool) {
        do {
            try review.importPDF(url, continueExisting: continueExisting)
            showComments(nil)
            showMessage(LF("review.imported", "%d comments imported, %d found in the source",
                           review.session?.comments.count ?? 0, review.anchors.count))
        } catch {
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = L("review.import.failed", "The review comments could not be imported")
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    /// File ▸ Export Response to Reviewers… (Markdown or Word).
    @objc func exportResponseLetter(_ sender: Any?) {
        guard let window, review.session != nil else { return }
        let docxType = UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(filenameExtension: "docx")!
        let markdownType = UTType(DocumentTypes.markdown) ?? UTType(filenameExtension: "md")!
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = markdownDocument?.baseDirectory
        panel.message = L("review.export.panel", "Export the response to the reviewers")
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: [L("review.export.markdown", "Markdown (.md)"), L("review.export.word", "Word (.docx)")])
        let label = NSTextField(labelWithString: L("review.export.format", "Format:"))
        let accessory = NSStackView(views: [label, format])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory
        let base = review.letterTitle.replacingOccurrences(of: ":", with: " –").replacingOccurrences(of: "/", with: "-")
        let handler = SaveFormatHandler(panel: panel, base: base, types: [markdownType, docxType], extensions: ["md", "docx"])
        format.target = handler
        format.action = #selector(SaveFormatHandler.formatChanged(_:))
        handler.select(0)
        panel.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(handler) {}
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.review.exportResponse(to: url, asDOCX: format.indexOfSelectedItem == 1)
                self.showMessage(LF("export.done", "Exported: %@", url.lastPathComponent))
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = L("export.failed", "Export failed")
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// View ▸ Comments: the review panel in the sidebar.
    @objc func showComments(_ sender: Any?) {
        setSidebarVisible(true)
        sidebar.selectedTab = SidebarView.commentsTab
        review.refresh()
    }
}

/// Keeps a save panel's file type and extension in step with a format popup.
private final class SaveFormatHandler: NSObject {
    private weak var panel: NSSavePanel?
    private let base: String
    private let types: [UTType]
    private let extensions: [String]

    init(panel: NSSavePanel, base: String, types: [UTType], extensions: [String]) {
        self.panel = panel
        self.base = base
        self.types = types
        self.extensions = extensions
    }

    func select(_ index: Int) {
        guard let panel else { return }
        panel.allowedContentTypes = [types[index]]
        let current = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = (current.isEmpty ? base : current) + "." + extensions[index]
    }

    @objc func formatChanged(_ sender: NSPopUpButton) {
        select(sender.indexOfSelectedItem)
    }
}
