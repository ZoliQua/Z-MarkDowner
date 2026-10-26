import AppKit
import WebKit
import UniformTypeIdentifiers
import MarkDownerCore

/// Rendered (final) view of the document.
final class PreviewView: NSView, WKNavigationDelegate, WKScriptMessageHandler {

    static let localScheme = "zmd-local"
    /// Base URL of the preview page: relative links resolve against it and are mapped to the document folder.
    static let pageURL = URL(string: "zmd-doc://document/index.html")!

    private let webView: WKWebView
    private var isLoaded = false
    private var pendingHTML: String?
    private var lastHTML: String?
    private var pendingLine: Double?
    var baseDirectory: URL?

    /// Called when the user scrolls the preview: source line (fractional), or -1 for "end of document".
    var onScroll: ((Double) -> Void)?
    /// Number of scroll messages received from the page (diagnostics).
    private(set) var scrollMessageCount = 0

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: Self.localScheme)
        if let dir = WebAssets.directory {
            config.setURLSchemeHandler(AssetSchemeHandler(root: dir), forURLScheme: AssetSchemeHandler.scheme)
        }
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frameRect)

        config.userContentController.add(WeakMessageHandler(self), name: "scroll")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setAccessibilityLabel(L("preview.accessibility", "Rendered document"))
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reloadShell()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// (Re)loads the page frame with the current theme and custom CSS; content is kept.
    func reloadShell() {
        isLoaded = false
        if let html = lastHTML { pendingHTML = html }
        let settings = Settings.shared
        let css = Stylesheets.css(theme: settings.previewTheme, custom: settings.customCSS)
        let shell = HTMLRenderer.page(body: "", title: "Preview", css: css,
                                      head: WebAssets.headHTML(for: .preview) + "<script>\(Self.syncScript)</script>",
                                      lang: AppLanguage.current)
        webView.loadHTMLString(shell, baseURL: Self.pageURL)
    }

    /// Renders Markdown and updates the page without reloading it (keeps the scroll position).
    func update(markdown: String) {
        let base = baseDirectory
        let options = HTMLRenderer.Options(imageURL: { PreviewView.resolveImageURL($0, base: base) }, sourceLines: true)
        let html = HTMLRenderer.render(document: MDDocument(markdown: markdown), options: options)
        guard html != lastHTML else { return }
        lastHTML = html
        if isLoaded { push(html) } else { pendingHTML = html }
    }

    private func push(_ html: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [html]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("zmdSetContent(\(json)[0])", completionHandler: nil)
    }

    /// Scrolls so that the given source line is at the top (-1 = end of document).
    func scroll(toLine line: Double) {
        guard isLoaded else { pendingLine = line; return }
        webView.evaluateJavaScript("zmdScrollToLine(\(line))", completionHandler: nil)
    }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(webView) ?? false
    }

    var webContentView: WKWebView { webView }

    // MARK: Images

    /// Relative and file paths are served through the local scheme so the web view can load them.
    static func resolveImageURL(_ src: String, base: URL?) -> String {
        if let url = URL(string: src), let scheme = url.scheme?.lowercased(), scheme != "file" {
            return src
        }
        guard let path = LocalImage.fileURL(for: src, base: base)?.standardizedFileURL.path else { return src }
        var comps = URLComponents()
        comps.scheme = localScheme
        comps.host = "file"
        comps.path = path
        return comps.string ?? src
    }

    // MARK: Scripts

    private static let syncScript = """
    window.__zmdSyncing = false;
    function zmdBlocks() { return Array.from(document.querySelectorAll('#content > [data-line]')); }
    function zmdSetContent(html) {
      document.getElementById('content').innerHTML = html;
      if (window.zmdRender) { window.zmdRender(); }
    }
    function zmdTop(el) { return el.getBoundingClientRect().top + window.scrollY; }
    function zmdScrollToLine(line) {
      let y = 0;
      if (line < 0) {
        y = document.documentElement.scrollHeight;
      } else {
        const els = zmdBlocks();
        let prev = null, next = null;
        for (const el of els) { if (+el.dataset.line <= line) { prev = el; } else { next = el; break; } }
        if (prev) {
          const pl = +prev.dataset.line, pt = zmdTop(prev);
          if (next) {
            const nl = +next.dataset.line, nt = zmdTop(next);
            y = pt + (nt - pt) * Math.min(1, (line - pl) / Math.max(1, nl - pl));
          } else {
            const end = document.documentElement.scrollHeight - window.innerHeight;
            y = pt + Math.min(prev.offsetHeight, (line - pl) * 24);
            y = Math.min(y, end);
          }
        }
      }
      window.__zmdSyncing = true;
      window.scrollTo(0, Math.max(0, y - 12));
      clearTimeout(window.__zmdSyncTimer);
      window.__zmdSyncTimer = setTimeout(function () { window.__zmdSyncing = false; }, 120);
    }
    window.addEventListener('scroll', function () {
      if (window.__zmdSyncing) { return; }
      const atEnd = window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 2;
      if (atEnd && window.scrollY > 0) { window.webkit.messageHandlers.scroll.postMessage(-1); return; }
      const y = window.scrollY + 12;
      const els = zmdBlocks();
      let prev = null, next = null;
      for (const el of els) { if (zmdTop(el) <= y) { prev = el; } else { next = el; break; } }
      let line = 0;
      if (prev) {
        const pl = +prev.dataset.line, pt = zmdTop(prev);
        const nl = next ? +next.dataset.line : pl + Math.max(1, Math.round(prev.offsetHeight / 24));
        const nt = next ? zmdTop(next) : pt + prev.offsetHeight;
        line = pl + (nl - pl) * Math.min(1, Math.max(0, (y - pt) / Math.max(1, nt - pt)));
      }
      window.webkit.messageHandlers.scroll.postMessage(line);
    }, { passive: true });
    """

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "scroll" { scrollMessageCount += 1 }
        if message.name == "scroll", let line = message.body as? Double {
            onScroll?(line)
        } else if message.name == "scroll", let line = message.body as? Int {
            onScroll?(Double(line))
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isLoaded else { return }
        isLoaded = true
        if let html = pendingHTML {
            pendingHTML = nil
            push(html)
        }
        if let line = pendingLine {
            pendingLine = nil
            scroll(toLine: line)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if url.scheme == "zmd-doc" {
                if url.path == Self.pageURL.path, url.fragment != nil {
                    decisionHandler(.allow) // in-page anchors (headings, footnotes)
                    return
                }
                // Relative link to a file next to the document
                if let base = baseDirectory {
                    let relative = String(url.path.dropFirst()).removingPercentEncoding ?? ""
                    let target = base.appendingPathComponent(relative)
                    if DocumentImporter.supportedExtensions.contains(target.pathExtension.lowercased()) {
                        NSDocumentController.shared.openDocument(withContentsOf: target, display: true) { _, _, _ in }
                    } else {
                        NSWorkspace.shared.open(target)
                    }
                }
            } else if url.scheme == Self.localScheme, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

/// Avoids the retain cycle between WKUserContentController and its handler.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
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
