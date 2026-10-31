import AppKit
import MarkDownerCore

/// Finder services / Quick Actions: convert selected files next to the originals.
/// Declared in Info.plist (NSServices); the message names match the methods below.
final class ServiceProvider: NSObject {

    /// Shows the converted files in Finder (disabled by the self test).
    static var revealResults = true
    static var lastResults: [URL] = []

    @objc func convertToPDF(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        run(pboard, .pdf)
    }

    @objc func convertToDOCX(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        run(pboard, .docx)
    }

    @objc func convertToMarkdown(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        run(pboard, .markdown)
    }

    @objc func openInZMarkDowner(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        for url in fileURLs(pboard) {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    private func fileURLs(_ pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { DocumentImporter.importableExtensions.contains($0.pathExtension.lowercased()) }
    }

    private func run(_ pboard: NSPasteboard, _ format: DocumentConverter.Format) {
        let urls = fileURLs(pboard)
        guard !urls.isEmpty else { return }
        let options = Settings.shared.exportOptions(title: "", baseURL: nil)
        Task { @MainActor in
            var written: [URL] = []
            var failures: [String] = []
            for url in urls {
                do {
                    written.append(try await DocumentConverter.convert(url, to: format, into: url.deletingLastPathComponent(), options: options))
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !written.isEmpty, Self.revealResults { NSWorkspace.shared.activateFileViewerSelecting(written) }
            Self.lastResults = written
            if !failures.isEmpty {
                let alert = NSAlert()
                alert.messageText = L("export.failed", "Export failed")
                alert.informativeText = failures.joined(separator: "\n")
                alert.runModal()
            }
        }
    }
}
