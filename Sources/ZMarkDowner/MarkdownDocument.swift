import AppKit
import UniformTypeIdentifiers
import MarkDownerCore

enum DocumentTypes {
    static let markdown = "net.daringfireball.markdown"
    static let plainText = "public.plain-text"
    /// LaTeX source. Systems with a TeX distribution report `.tex` / `.ltx` files as `org.tug.tex` / `org.tug.ltx`.
    static let latex = "org.tug"
    static let latexTypes: Set<String> = [latex, "org.tug.tex", "org.tug.ltx", "org.tug.tex.latex"]

    /// Types that are converted to Markdown when opened (never written back in their own format).
    static let importOnly: Set<String> = [
        "public.rtf", "com.apple.rtfd", "com.microsoft.word.doc",
        "org.openxmlformats.wordprocessingml.document", "org.oasis-open.opendocument.text", "public.html",
        "com.adobe.pdf",
    ]
}

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {

    /// The Markdown source. The editor keeps it up to date.
    var text: String = ""

    /// Text as last opened or explicitly saved (autosaves do not count), for Compare With ▸ Last Saved Version.
    private(set) var savedText: String?
    /// When `savedText` was saved; `nil` when it is the text the document was opened with.
    private(set) var savedDate: Date?

    /// Name of the original file when the document was imported from another format.
    private(set) var importedFrom: URL?

    var windowController: DocumentWindowController? {
        windowControllers.first as? DocumentWindowController
    }

    /// Format of the source on disk: plain text is saved back as .txt, LaTeX as .tex (unchanged),
    /// everything else as Markdown.
    private(set) var sourceFormat: SourceFormat = .markdown

    /// The type a LaTeX file was opened with (saved back with the same type).
    private var latexTypeName = DocumentTypes.latex

    override init() {
        super.init()
        fileType = DocumentTypes.markdown
    }

    /// Creates an untitled Markdown document from a file in another format (DOCX, DOC, RTF…),
    /// so the original file is never overwritten.
    init(importing url: URL, ofType typeName: String) throws {
        super.init()
        try read(from: url, ofType: typeName)
        importedFrom = url
        sourceFormat = .markdown
        fileType = DocumentTypes.markdown
        updateChangeCount(.changeDone)
    }

    override class var autosavesInPlace: Bool { true }

    /// Notes from importing a PDF (OCR use, pages without text), shown once the window exists.
    private var pendingImportWarnings: [String] = []

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
        showPendingImportWarnings()
    }

    private func showPendingImportWarnings() {
        guard !pendingImportWarnings.isEmpty, let controller = windowController else { return }
        controller.showMessage(pendingImportWarnings.joined(separator: " "))
        pendingImportWarnings = []
    }

    override var displayName: String! {
        get {
            if fileURL == nil, let importedFrom {
                return importedFrom.deletingPathExtension().lastPathComponent
            }
            return super.displayName
        }
        set { super.displayName = newValue }
    }

    // MARK: Reading & writing

    override func read(from url: URL, ofType typeName: String) throws {
        if DocumentTypes.isLatex(typeName, url: url) {
            do {
                text = DocumentImporter.decodeText(try Data(contentsOf: url))
            } catch {
                throw ImportError.unreadable(url.lastPathComponent, underlying: error)
            }
            sourceFormat = .latex
            latexTypeName = typeName
        } else {
            text = try DocumentImporter.markdown(fromFileAt: url)
            pendingImportWarnings = DocumentImporter.lastImportWarnings
            showPendingImportWarnings()
            sourceFormat = typeName == DocumentTypes.plainText ? .plain : .markdown
        }
        savedText = text
        savedDate = nil
        windowController?.documentTextDidChangeExternally()
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        windowController?.commitEditing()
        let snapshot = text
        let explicit = [.saveOperation, .saveAsOperation, .saveToOperation].contains(saveOperation)
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, explicit, let self {
                self.savedText = snapshot
                self.savedDate = Date()
            }
            completionHandler(error)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        windowController?.commitEditing()
        return Data(text.utf8)
    }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        // Note: must not read `fileType` here (NSDocument derives a default fileType from this method)
        switch sourceFormat {
        case .latex: return [latexTypeName]
        case .plain: return [DocumentTypes.plainText, DocumentTypes.markdown]
        case .markdown: return [DocumentTypes.markdown]
        }
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        if sourceFormat == .latex {
            let ext = fileURL?.pathExtension.lowercased() ?? ""
            return SourceFormat(fileExtension: ext) == .latex ? ext : "tex"
        }
        return typeName == DocumentTypes.plainText ? "txt" : "md"
    }

    override var shouldRunSavePanelWithAccessoryView: Bool { false }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        if fileURL == nil, let importedFrom {
            savePanel.directoryURL = importedFrom.deletingLastPathComponent()
        }
        return true
    }

    // MARK: Printing

    /// Printing renders the document exactly like the PDF export (WebKit), asynchronously.
    override func printDocument(_ sender: Any?) {
        windowController?.printRendered()
    }

    /// Printing renders Markdown, so it is disabled for LaTeX sources.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(printDocument(_:)), sourceFormat == .latex { return false }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(printDocument(_:)), sourceFormat == .latex { return false }
        return super.validateMenuItem(menuItem)
    }

    override var fileURL: URL? {
        didSet {
            if oldValue != fileURL { windowController?.documentLocationChanged() }
        }
    }

    /// Directory used to resolve relative image paths.
    var baseDirectory: URL? {
        (fileURL ?? importedFrom)?.deletingLastPathComponent()
    }
}

extension DocumentTypes {
    /// LaTeX sources are recognised by type or, when the system reports plain text, by extension.
    static func isLatex(_ typeName: String, url: URL) -> Bool {
        latexTypes.contains(typeName) || SourceFormat(fileExtension: url.pathExtension) == .latex
    }

    static func isEditableType(_ typeName: String, url: URL) -> Bool {
        if typeName == markdown || typeName == plainText || isLatex(typeName, url: url) { return true }
        guard let type = UTType(typeName) else {
            let ext = url.pathExtension.lowercased()
            return DocumentImporter.markdownExtensions.contains(ext) || DocumentImporter.plainTextExtensions.contains(ext)
        }
        if let md = UTType(markdown), type.conforms(to: md) { return true }
        return type == .plainText
    }
}

/// Opens import-only formats as new Markdown documents.
final class DocumentController: NSDocumentController {
    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        if DocumentTypes.importOnly.contains(typeName) || !DocumentTypes.isEditableType(typeName, url: url) {
            return try MarkdownDocument(importing: url, ofType: typeName)
        }
        return try super.makeDocument(withContentsOf: url, ofType: typeName)
    }
}
