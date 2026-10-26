import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import MarkDownerCore

/// Quick Look preview for Markdown files (data based: returns a rendered HTML page).
@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let markdown = try DocumentImporter.markdown(fromFileAt: url)
        let options = ExportOptions(title: url.deletingPathExtension().lastPathComponent,
                                    baseURL: url.deletingLastPathComponent())
        let html = PDFExporter.html(markdown: markdown, options: options, forExport: false)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 900, height: 1100)) { reply in
            reply.stringEncoding = .utf8
            reply.title = url.lastPathComponent
            return Data(html.utf8)
        }
    }
}

/// SwiftPM links executables against `<module>_main`; the extension's real entry point is
/// `_NSExtensionMain` (set via linker flags), so this is never called.
@_cdecl("ZMarkDownerQuickLook_main")
func zmdQuickLookUnusedMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 { 0 }
