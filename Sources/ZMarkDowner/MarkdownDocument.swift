import AppKit
import UniformTypeIdentifiers
import MarkDownerCore

enum DocumentTypes {
    static let markdown = "net.daringfireball.markdown"
    static let plainText = "public.plain-text"

    /// Types that are converted to Markdown when opened (never written back in their own format).
    static let importOnly: Set<String> = [
        "public.rtf", "com.apple.rtfd", "com.microsoft.word.doc",
        "org.openxmlformats.wordprocessingml.document", "org.oasis-open.opendocument.text", "public.html",
    ]
}

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {

    /// The Markdown source. The editor keeps it up to date.
    var text: String = ""

    /// Name of the original file when the document was imported from another format.
    private(set) var importedFrom: URL?

    var windowController: DocumentWindowController? {
        windowControllers.first as? DocumentWindowController
    }

    /// Plain text documents are saved back as .txt; everything else as Markdown.
    private var isPlainText = false

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
        isPlainText = false
        fileType = DocumentTypes.markdown
        updateChangeCount(.changeDone)
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
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
        text = try DocumentImporter.markdown(fromFileAt: url)
        isPlainText = typeName == DocumentTypes.plainText
        windowController?.documentTextDidChangeExternally()
    }

    override func data(ofType typeName: String) throws -> Data {
        windowController?.commitEditing()
        return Data(text.utf8)
    }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        // Note: must not read `fileType` here (NSDocument derives a default fileType from this method)
        if isPlainText { return [DocumentTypes.plainText, DocumentTypes.markdown] }
        return [DocumentTypes.markdown]
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        typeName == DocumentTypes.plainText ? "txt" : "md"
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
    static func isEditableType(_ typeName: String, url: URL) -> Bool {
        if typeName == markdown || typeName == plainText { return true }
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
