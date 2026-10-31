import AppKit
import WebKit

/// Page geometry for PDF export and printing.
public struct PageSetup: Equatable {
    public var paperSize: NSSize
    public var margin: CGFloat
    public var pageNumbers: Bool

    public init(paperSize: NSSize = PageSetup.a4, margin: CGFloat = 56.7, pageNumbers: Bool = true) {
        self.paperSize = paperSize
        self.margin = margin
        self.pageNumbers = pageNumbers
    }

    public static let a4 = NSSize(width: 595.28, height: 841.89)
    public static let letter = NSSize(width: 612, height: 792)

    var contentWidth: CGFloat { paperSize.width - 2 * margin }
    var contentHeight: CGFloat { paperSize.height - 2 * margin - (pageNumbers ? 18 : 0) }
}

/// Renders HTML with WebKit (the preview engine) and paginates it into a multi-page PDF.
///
/// WebKit produces one tall vector page; it is cut into pages at line and block boundaries
/// measured in the DOM, so text lines are never split across pages.
@MainActor
public final class WebPDFRenderer: NSObject, WKNavigationDelegate {

    /// CSS pixels to PDF points (16px body text becomes 12pt).
    static let scale: CGFloat = 0.75

    private let webView: WKWebView
    private let window: NSWindow
    private var loadContinuation: CheckedContinuation<Void, Error>?

    public init(schemeHandlers: [String: WKURLSchemeHandler] = [:]) {
        let config = WKWebViewConfiguration()
        for (scheme, handler) in schemeHandlers {
            config.setURLSchemeHandler(handler, forURLScheme: scheme)
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 900), configuration: config)
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 900),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init()
        window.contentView = webView
        webView.navigationDelegate = self
        webView.appearance = NSAppearance(named: .aqua)
    }

    /// Renders an HTML page to paginated PDF data.
    public func pdf(html: String, baseURL: URL?, setup: PageSetup) async throws -> Data {
        let layoutWidth = setup.contentWidth / Self.scale
        window.setContentSize(NSSize(width: layoutWidth, height: 900))
        webView.frame = NSRect(x: 0, y: 0, width: layoutWidth, height: 900)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadContinuation = c
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        // Wait for fonts, images and asynchronous renderers (math, diagrams) declared by the page
        _ = try? await webView.callAsyncJavaScript(Self.waitScript, arguments: [:], in: nil, contentWorld: .page)

        var breaks = try await breakCandidates()
        let config = WKPDFConfiguration()
        var tall = try await webView.pdf(configuration: config)
        var slices = try pageSlices(tall, breaks: breaks, setup: setup)

        // Table of contents: write the page numbers, then lay out again (at most twice)
        if try await hasTableOfContents() {
            for _ in 0..<2 {
                let anchors = try await anchorPositions()
                let pages = anchors.mapValues { y in (slices.firstIndex { y >= $0.0 - 1 && y < $0.1 } ?? 0) + 1 }
                try await fillTableOfContents(pages)
                breaks = try await breakCandidates()
                tall = try await webView.pdf(configuration: config)
                let updated = try pageSlices(tall, breaks: breaks, setup: setup)
                let changed = updated.count != slices.count || zip(updated, slices).contains { abs($0.0 - $1.0) > 0.5 }
                slices = updated
                if !changed { break }
            }
        }
        let links = try await linkRects()
        let anchors = try await anchorPositions()
        return try paginate(tall, slices: slices, links: links, anchors: anchors, setup: setup)
    }

    private func hasTableOfContents() async throws -> Bool {
        let r = try await webView.callAsyncJavaScript("return document.querySelector('.toc-page') !== null;",
                                                      arguments: [:], in: nil, contentWorld: .page)
        return (r as? Bool) ?? false
    }

    /// Document y position (CSS px) of every element that an internal link points to.
    private func anchorPositions() async throws -> [String: CGFloat] {
        let script = """
        const out = {};
        const top = window.scrollY;
        const ids = new Set();
        document.querySelectorAll('a[href^="#"]').forEach(a => {
          try { ids.add(decodeURIComponent(a.getAttribute('href').slice(1))); } catch (e) {}
        });
        document.querySelectorAll('.toc-page[data-target]').forEach(el => ids.add(el.dataset.target));
        ids.forEach(id => {
          const el = document.getElementById(id);
          if (el) { out[id] = el.getBoundingClientRect().top + top; }
        });
        return JSON.stringify(out);
        """
        guard let json = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String,
              let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double] else { return [:] }
        return obj.mapValues { CGFloat($0) }
    }

    private func fillTableOfContents(_ pages: [String: Int]) async throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: pages), as: UTF8.self)
        _ = try await webView.callAsyncJavaScript("""
        const pages = JSON.parse(map);
        document.querySelectorAll('.toc-page[data-target]').forEach(el => {
          const p = pages[el.dataset.target]; el.textContent = p ? String(p) : '';
        });
        return true;
        """, arguments: ["map": json], in: nil, contentWorld: .page)
    }

    struct LinkRect { var rect: CGRect; var href: String }

    /// Rectangles of all links in document coordinates (CSS px).
    private func linkRects() async throws -> [LinkRect] {
        let script = """
        const out = [];
        const top = window.scrollY, left = window.scrollX;
        document.querySelectorAll('a[href]').forEach(a => {
          const href = a.getAttribute('href');
          for (const r of a.getClientRects()) {
            if (r.width > 0 && r.height > 0) { out.push([r.left + left, r.top + top, r.width, r.height, href]); }
          }
        });
        return JSON.stringify(out);
        """
        guard let json = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String,
              let list = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[Any]] else { return [] }
        return list.compactMap { item in
            guard item.count == 5, let x = item[0] as? Double, let y = item[1] as? Double, let w = item[2] as? Double,
                  let h = item[3] as? Double, let href = item[4] as? String else { return nil }
            return LinkRect(rect: CGRect(x: x, y: y, width: w, height: h), href: href)
        }
    }

    private static let waitScript = """
    if (document.fonts && document.fonts.ready) { await document.fonts.ready; }
    await Promise.all(Array.from(document.images).map(img => img.complete ? null :
        new Promise(r => { img.onload = img.onerror = r; })));
    if (window.__zmdReady) { await window.__zmdReady; }
    return true;
    """

    /// Y positions (CSS px, from the top of the document) where a page may end.
    private func breakCandidates() async throws -> [CGFloat] {
        let script = """
        const ys = [];
        const top = window.scrollY;
        const lineContainers = document.querySelectorAll('p, li, dd, dt, td, th, pre, blockquote, figcaption, .footnotes li');
        for (const el of lineContainers) {
          const range = document.createRange();
          range.selectNodeContents(el);
          for (const r of range.getClientRects()) { if (r.height > 0) ys.push(r.bottom + top); }
        }
        const blocks = document.querySelectorAll('p, li, tr, pre, blockquote, hr, img, table, ul, ol, .math-display, .mermaid, svg, figure, .front-matter, .csl-entry, .equation, nav.toc');
        for (const el of blocks) { const r = el.getBoundingClientRect(); ys.push(r.bottom + top); }
        // Prefer breaking before headings (keep a heading with the text that follows it)
        for (const h of document.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
          const r = h.getBoundingClientRect();
          ys.push(r.top + top - 1);
        }
        const heads = Array.from(document.querySelectorAll('h1, h2, h3, h4, h5, h6')).map(h => {
          const r = h.getBoundingClientRect(); return [r.top + top, r.bottom + top];
        });
        return JSON.stringify({ ys: ys, heads: heads, height: document.documentElement.scrollHeight });
        """
        guard let json = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String,
              let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let ys = (obj["ys"] as? [Double] ?? []).map { CGFloat($0) }
        let heads = (obj["heads"] as? [[Double]] ?? []).map { (CGFloat($0[0]), CGFloat($0[1])) }
        // Never end a page directly below a heading
        let filtered = ys.filter { y in !heads.contains { y > $0.0 + 1 && y <= $0.1 + 2 } }
        return Array(Set(filtered.map { ($0 * 2).rounded() / 2 })).sorted()
    }

    private func tallPage(_ data: Data) throws -> CGPDFPage {
        guard let provider = CGDataProvider(data: data as CFData),
              let source = CGPDFDocument(provider), let page = source.page(at: 1) else {
            throw ExportError.renderingFailed("PDF")
        }
        return page
    }

    /// Vertical ranges (CSS px) of the tall page that become the printed pages.
    private func pageSlices(_ data: Data, breaks: [CGFloat], setup: PageSetup) throws -> [(CGFloat, CGFloat)] {
        let totalHeight = try tallPage(data).getBoxRect(.mediaBox).height   // CSS px == PDF units of the tall page
        let pageCSSHeight = setup.contentHeight / Self.scale

        // Choose page slices
        var slices: [(CGFloat, CGFloat)] = []
        var y0: CGFloat = 0
        while y0 < totalHeight - 0.5 {
            let limit = y0 + pageCSSHeight
            if limit >= totalHeight {
                slices.append((y0, totalHeight))
                break
            }
            let minimum = y0 + pageCSSHeight * 0.4
            let candidate = breaks.last { $0 <= limit && $0 > minimum }
            let y1 = candidate ?? limit
            slices.append((y0, y1))
            y0 = y1
        }
        // Drop a trailing slice that only contains whitespace padding
        if slices.count > 1, let last = slices.last, last.1 - last.0 < 4 { slices.removeLast() }
        return slices
    }

    private func paginate(_ data: Data, slices: [(CGFloat, CGFloat)], links: [LinkRect], anchors: [String: CGFloat],
                          setup: PageSetup) throws -> Data {
        let page = try tallPage(data)
        let box = page.getBoxRect(.mediaBox)
        let totalHeight = box.height
        let out = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: setup.paperSize)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.renderingFailed("PDF")
        }
        let s = Self.scale
        let contentTop = setup.paperSize.height - setup.margin
        for (index, slice) in slices.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            let sliceHeight = (slice.1 - slice.0) * s
            ctx.clip(to: CGRect(x: setup.margin - 2, y: contentTop - sliceHeight,
                                width: setup.contentWidth + 4, height: sliceHeight))
            ctx.translateBy(x: setup.margin - box.minX * s,
                            y: contentTop - (totalHeight - slice.0) * s - box.minY * s)
            ctx.scaleBy(x: s, y: s)
            ctx.drawPDFPage(page)
            ctx.restoreGState()

            // Link annotations and named destinations for this page
            func pageY(_ y: CGFloat) -> CGFloat { contentTop - (y - slice.0) * s }
            for (name, y) in anchors where y >= slice.0 - 1 && y < slice.1 {
                ctx.addDestination(name as CFString, at: CGPoint(x: setup.margin, y: min(setup.paperSize.height, pageY(y) + 12)))
            }
            for link in links where link.rect.midY >= slice.0 && link.rect.midY < slice.1 {
                let rect = CGRect(x: setup.margin + link.rect.minX * s, y: pageY(link.rect.maxY),
                                  width: link.rect.width * s, height: link.rect.height * s)
                if link.href.hasPrefix("#") {
                    let name = String(link.href.dropFirst()).removingPercentEncoding ?? String(link.href.dropFirst())
                    if anchors[name] != nil { ctx.setDestination(name as CFString, for: rect) }
                } else if let url = URL(string: link.href), let scheme = url.scheme?.lowercased(),
                          ["http", "https", "mailto"].contains(scheme) {
                    ctx.setURL(url as CFURL, for: rect)
                }
            }

            if setup.pageNumbers {
                drawPageNumber(ctx, number: index + 1, total: slices.count, setup: setup)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    private func drawPageNumber(_ ctx: CGContext, number: Int, total: Int, setup: PageSetup) {
        let text = NSAttributedString(string: "\(number) / \(total)", attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (setup.paperSize.width - CGFloat(width)) / 2, y: setup.margin * 0.55)
        CTLineDraw(line, ctx)
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}
