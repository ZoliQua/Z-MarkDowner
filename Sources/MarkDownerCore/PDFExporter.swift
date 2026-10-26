import AppKit
import WebKit
import UniformTypeIdentifiers

public enum ExportError: LocalizedError {
    case renderingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .renderingFailed(let what):
            return CoreStrings.exportFailed(what)
        }
    }
}

/// Settings shared by the exporters.
public struct ExportOptions {
    public var title: String
    /// Directory used to resolve relative image paths.
    public var baseURL: URL?
    public var theme: PreviewTheme
    public var customCSS: String
    public var pageSetup: PageSetup
    /// Extra `<head>` content (e.g. math / diagram renderers supplied by the app).
    public var headHTML: String
    /// Directory served as `zmd-asset://` (bundled JavaScript renderers and fonts).
    public var assetsDirectory: URL?
    public var language: String

    public init(title: String, baseURL: URL? = nil, theme: PreviewTheme = .github, customCSS: String = "",
                pageSetup: PageSetup = PageSetup(), headHTML: String = "", assetsDirectory: URL? = nil,
                language: String = "") {
        self.assetsDirectory = assetsDirectory
        self.title = title
        self.baseURL = baseURL
        self.theme = theme
        self.customCSS = customCSS
        self.pageSetup = pageSetup
        self.headHTML = headHTML
        self.language = language
    }
}

/// Loads images referenced from Markdown (local files only).
public enum LocalImage {
    public static func fileURL(for src: String, base: URL?) -> URL? {
        if let u = URL(string: src), let scheme = u.scheme?.lowercased() {
            return scheme == "file" ? u : nil
        }
        let path = src.removingPercentEncoding ?? src
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return base?.appendingPathComponent(path)
    }

    public static func load(_ src: String, base: URL?) -> DocxImage? {
        guard let url = fileURL(for: src, base: base), let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        let ext = url.pathExtension.lowercased()
        // Point size at 96 dpi so high-resolution images keep their intended size
        let width = rep.size.width > 0 ? Int(rep.size.width * 96 / 72) : rep.pixelsWide
        let height = rep.size.height > 0 ? Int(rep.size.height * 96 / 72) : rep.pixelsHigh
        if ["png", "jpg", "jpeg", "gif"].contains(ext) {
            return DocxImage(data: data, fileExtension: ext == "jpg" ? "jpeg" : ext, pixelWidth: width, pixelHeight: height)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return DocxImage(data: png, fileExtension: "png", pixelWidth: width, pixelHeight: height)
    }

    /// `data:` URI for a local image, or the original source when it cannot be loaded.
    public static func dataURI(_ src: String, base: URL?) -> String {
        if let url = fileURL(for: src, base: base), url.pathExtension.lowercased() == "svg",
           let data = try? Data(contentsOf: url) {
            return "data:image/svg+xml;base64," + data.base64EncodedString()
        }
        guard let image = load(src, base: base) else { return src }
        return "data:image/\(image.fileExtension);base64,\(image.data.base64EncodedString())"
    }
}

/// Renders Markdown into a print-ready HTML page and paginated PDF (WebKit).
public enum PDFExporter {

    /// Standalone HTML page with embedded local images.
    public static func html(markdown: String, options: ExportOptions, forExport: Bool = true) -> String {
        let doc = MDDocument(markdown: markdown)
        let base = options.baseURL
        let body = HTMLRenderer.render(document: doc, options: .init(imageURL: { LocalImage.dataURI($0, base: base) }))
        let title = doc.title ?? options.title
        return HTMLRenderer.page(body: body, title: title,
                                 css: Stylesheets.css(theme: options.theme, forExport: forExport, custom: options.customCSS),
                                 head: options.headHTML, lang: options.language)
    }

    @MainActor
    public static func pdfData(markdown: String, options: ExportOptions) async throws -> Data {
        let page = html(markdown: markdown, options: options)
        var handlers: [String: WKURLSchemeHandler] = [:]
        if let dir = options.assetsDirectory { handlers[AssetSchemeHandler.scheme] = AssetSchemeHandler(root: dir) }
        let renderer = WebPDFRenderer(schemeHandlers: handlers)
        return try await renderer.pdf(html: page, baseURL: options.baseURL, setup: options.pageSetup)
    }

    @MainActor
    public static func writePDF(markdown: String, options: ExportOptions, to url: URL) async throws {
        let data = try await pdfData(markdown: markdown, options: options)
        try data.write(to: url, options: .atomic)
    }
}

/// Serves files below a directory for `zmd-asset://host/path` URLs (bundled web renderers).
public final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "zmd-asset"
    private let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let relative = ((url.host ?? "") + url.path).removingPercentEncoding ?? ""
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
