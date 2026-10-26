import AppKit
import MarkDownerCore

/// Stores pasted / dropped images in an `images` folder next to the document.
enum ImageStore {

    static let folderName = "images"

    /// Markdown path for an existing image file: relative if it is inside the document folder,
    /// otherwise the file is copied into `images/` (or referenced absolutely for unsaved documents).
    static func reference(for url: URL, document: MarkdownDocument?) -> String? {
        guard let docURL = document?.fileURL else { return encode(url.path) }
        let base = docURL.deletingLastPathComponent().standardizedFileURL
        let file = url.standardizedFileURL
        if file.path.hasPrefix(base.path + "/") {
            return encode(String(file.path.dropFirst(base.path.count + 1)))
        }
        let folder = base.appendingPathComponent(folderName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = DocumentConverter.uniqueURL(in: folder, base: url.deletingPathExtension().lastPathComponent,
                                                     ext: url.pathExtension.lowercased())
            try FileManager.default.copyItem(at: url, to: target)
            return encode(folderName + "/" + target.lastPathComponent)
        } catch {
            return encode(url.path)
        }
    }

    /// Saves image data; asks the user to save the document first if it has no location yet.
    static func store(data: Data, ext: String, suggestedName: String, for document: MarkdownDocument?, window: NSWindow?) -> String? {
        guard let docURL = document?.fileURL else {
            let alert = NSAlert()
            alert.messageText = L("image.saveFirst.title", "Save the document first")
            alert.informativeText = L("image.saveFirst.text", "Pasted images are stored in an “images” folder next to the document. Please save the document, then paste again.")
            alert.addButton(withTitle: L("button.save", "Save…"))
            alert.addButton(withTitle: L("button.cancel", "Cancel"))
            if let window {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn { document?.save(nil) }
                }
            } else if alert.runModal() == .alertFirstButtonReturn {
                document?.save(nil)
            }
            return nil
        }
        let folder = docURL.deletingLastPathComponent().appendingPathComponent(folderName)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(suggestedName)-\(formatter.string(from: Date()))"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = DocumentConverter.uniqueURL(in: folder, base: name, ext: ext)
            try data.write(to: target)
            return encode(folderName + "/" + target.lastPathComponent)
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
            return nil
        }
    }

    private static func encode(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }
}
