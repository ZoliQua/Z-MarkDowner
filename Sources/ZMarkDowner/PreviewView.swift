import AppKit
import WebKit
import UniformTypeIdentifiers
import MarkDownerCore

/// Rendered (final) view of the document.
final class PreviewView: NSView, WKNavigationDelegate {

    static let localScheme = "zmd-local"

    private let webView: WKWebView
    private var isLoaded = false
    private var pendingHTML: String?
    private var lastHTML: String?
    var baseDirectory: URL?

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: Self.localScheme)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frameRect)

        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let shell = HTMLRenderer.page(body: "", title: "Preview", css: Stylesheets.preview)
            .replacingOccurrences(of: "<article class=\"markdown-body\">",
                                  with: "<article class=\"markdown-body\" id=\"content\">")
            .replacingOccurrences(of: "</body>", with: """
            <script>
            function setContent(html) { document.getElementById('content').innerHTML = html; }
            </script></body>
            """)
        webView.loadHTMLString(shell, baseURL: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Renders Markdown and updates the page without reloading it (keeps the scroll position).
    func update(markdown: String) {
        let base = baseDirectory
        let html = HTMLRenderer.render(markdown: markdown) { src in
            PreviewView.resolveImageURL(src, base: base)
        }
        guard html != lastHTML else { return }
        lastHTML = html
        if isLoaded { push(html) } else { pendingHTML = html }
    }

    private func push(_ html: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [html]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("setContent(\(json)[0])", completionHandler: nil)
    }

    /// Relative and file paths are served through the local scheme so the web view can load them.
    static func resolveImageURL(_ src: String, base: URL?) -> String {
        if let url = URL(string: src), let scheme = url.scheme?.lowercased(), scheme != "file" {
            return src
        }
        var fileURL: URL?
        if src.lowercased().hasPrefix("file://") {
            fileURL = URL(string: src)
        } else if src.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: src.removingPercentEncoding ?? src)
        } else if let base {
            fileURL = base.appendingPathComponent(src.removingPercentEncoding ?? src)
        }
        guard let path = fileURL?.standardizedFileURL.path else { return src }
        var comps = URLComponents()
        comps.scheme = localScheme
        comps.host = "file"
        comps.path = path
        return comps.string ?? src
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        if let html = pendingHTML {
            pendingHTML = nil
            push(html)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if url.scheme == "about" || url.fragment != nil && url.absoluteString.hasPrefix("about:") {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

/// Serves local image files referenced by the document.
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
              let data = FileManager.default.contents(atPath: path) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
