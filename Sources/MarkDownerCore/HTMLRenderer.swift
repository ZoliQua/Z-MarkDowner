import Foundation

public struct HTMLRenderer {

    public struct Options {
        /// Rewrites image sources (e.g. to resolve relative paths or embed data URIs).
        public var imageURL: ((String) -> String)?
        /// Adds `data-line` attributes to top-level blocks (used for scroll synchronisation).
        public var sourceLines = false
        /// Self-closing tags for XHTML output (EPUB).
        public var xhtml = false
        public var highlightCode = true
        /// Renders the front matter title/author/date as a header.
        public var frontMatterHeader = true

        public init(imageURL: ((String) -> String)? = nil, sourceLines: Bool = false, xhtml: Bool = false,
                    highlightCode: Bool = true, frontMatterHeader: Bool = true) {
            self.imageURL = imageURL
            self.sourceLines = sourceLines
            self.xhtml = xhtml
            self.highlightCode = highlightCode
            self.frontMatterHeader = frontMatterHeader
        }
    }

    private let options: Options
    private var usedIDs: [String: Int] = [:]
    private var footnoteNumbers: [String: Int] = [:]
    private var footnoteOrder: [String] = []
    private var footnoteDefinitions: [String: MDFootnote] = [:]

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Convenience API

    public static func render(markdown: String, imageURL: ((String) -> String)? = nil) -> String {
        render(document: MDDocument(markdown: markdown), options: Options(imageURL: imageURL))
    }

    public static func render(document: MDDocument, options: Options = Options()) -> String {
        var renderer = HTMLRenderer(options: options)
        return renderer.render(document)
    }

    public static func render(_ blocks: [MDBlock]) -> String {
        render(document: MDDocument(blocks: blocks))
    }

    /// A complete standalone HTML page.
    public static func page(body: String, title: String, css: String, head: String = "", lang: String = "") -> String {
        let langAttr = lang.isEmpty ? "" : " lang=\"\(escape(lang))\""
        return """
        <!DOCTYPE html>
        <html\(langAttr)><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        \(head)
        </head><body><article class="markdown-body" id="content">\(body)</article></body></html>
        """
    }

    // MARK: Document

    public mutating func render(_ doc: MDDocument) -> String {
        for f in doc.footnotes where footnoteDefinitions[f.id] == nil { footnoteDefinitions[f.id] = f }
        var parts: [String] = []
        if options.frontMatterHeader, let header = frontMatterHeader(doc.frontMatter) {
            parts.append(header)
        }
        for (index, block) in doc.blocks.enumerated() {
            var html = render(block, tight: false)
            if options.sourceLines, index < doc.blockLines.count {
                html = Self.addAttribute("data-line=\"\(doc.blockLines[index])\"", to: html)
            }
            parts.append(html)
        }
        if !footnoteOrder.isEmpty {
            parts.append(footnotesSection())
        }
        return parts.joined(separator: "\n")
    }

    private func frontMatterHeader(_ fm: [String: String]) -> String? {
        let title = fm["title"] ?? ""
        let subtitle = fm["subtitle"] ?? ""
        let meta = [fm["author"], fm["date"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        guard !title.isEmpty || !subtitle.isEmpty || !meta.isEmpty else { return nil }
        var html = "<header class=\"front-matter\">"
        if !title.isEmpty { html += "<h1 class=\"doc-title\">\(Self.escape(title))</h1>" }
        if !subtitle.isEmpty { html += "<p class=\"doc-subtitle\">\(Self.escape(subtitle))</p>" }
        if !meta.isEmpty { html += "<p class=\"doc-meta\">\(Self.escape(meta))</p>" }
        return html + "</header>"
    }

    static func addAttribute(_ attribute: String, to html: String) -> String {
        guard html.hasPrefix("<"), let end = html.firstIndex(where: { $0 == ">" || $0 == " " }) else { return html }
        var out = html
        out.insert(contentsOf: " " + attribute, at: end)
        return out
    }

    private var voidClose: String { options.xhtml ? " />" : ">" }

    // MARK: Blocks

    mutating func render(_ block: MDBlock, tight: Bool) -> String {
        switch block {
        case .heading(let level, let content, let explicitID):
            var id = explicitID ?? Self.slug(content.plainText)
            if explicitID == nil {
                if let n = usedIDs[id] { usedIDs[id] = n + 1; id += "-\(n)" } else { usedIDs[id] = 1 }
            }
            return "<h\(level) id=\"\(Self.escape(id))\">\(render(content))</h\(level)>"

        case .paragraph(let content):
            return tight ? render(content) : "<p>\(render(content))</p>"

        case .codeBlock(let language, let code):
            if language.lowercased() == "mermaid" {
                return "<pre class=\"mermaid\">\(Self.escape(code))</pre>"
            }
            let cls = language.isEmpty ? "" : " class=\"language-\(Self.escape(language))\""
            let body = options.highlightCode && !language.isEmpty
                ? CodeHighlighter.html(code, language: language) : Self.escape(code)
            return "<pre><code\(cls)>\(body)\n</code></pre>"

        case .mathBlock(let tex):
            return "<div class=\"math math-display\">\(Self.escape(tex))</div>"

        case .blockquote(let blocks):
            return "<blockquote>\n" + blocks.map { render($0, tight: false) }.joined(separator: "\n") + "\n</blockquote>"

        case .list(let list):
            let isTask = list.items.contains { $0.checked != nil }
            let tag = list.ordered ? "ol" : "ul"
            var open = "<\(tag)"
            if list.ordered && list.start != 1 { open += " start=\"\(list.start)\"" }
            if isTask { open += " class=\"task-list\"" }
            open += ">"
            var items: [String] = []
            for item in list.items {
                var inner = item.blocks.map { render($0, tight: list.tight) }.joined(separator: "\n")
                var liOpen = "<li>"
                if let checked = item.checked {
                    liOpen = "<li class=\"task-list-item\">"
                    let box = options.xhtml
                        ? "<input type=\"checkbox\" disabled=\"disabled\"\(checked ? " checked=\"checked\"" : "") /> "
                        : "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                    if inner.hasPrefix("<p>") {
                        inner = "<p>" + box + inner.dropFirst(3)
                    } else {
                        inner = box + inner
                    }
                }
                items.append(liOpen + inner + "</li>")
            }
            return open + "\n" + items.joined(separator: "\n") + "\n</\(tag)>"

        case .table(let table):
            func align(_ i: Int) -> String {
                guard i < table.alignments.count else { return "" }
                switch table.alignments[i] {
                case .left: return " style=\"text-align:left\""
                case .center: return " style=\"text-align:center\""
                case .right: return " style=\"text-align:right\""
                case .none: return ""
                }
            }
            var html = "<table>\n<thead><tr>"
            for (i, cell) in table.header.enumerated() {
                html += "<th\(align(i))>\(render(cell))</th>"
            }
            html += "</tr></thead>\n"
            if !table.rows.isEmpty {
                html += "<tbody>\n"
                for row in table.rows {
                    html += "<tr>"
                    for (i, cell) in row.enumerated() {
                        html += "<td\(align(i))>\(render(cell))</td>"
                    }
                    html += "</tr>\n"
                }
                html += "</tbody>\n"
            }
            return html + "</table>"

        case .horizontalRule:
            return "<hr\(voidClose)"

        case .figure(let figure):
            let idAttr = figure.id.map { " id=\"\(Self.escape($0))\"" } ?? ""
            switch figure.kind {
            case .equation:
                let number = figure.label.map { "<span class=\"eq-number\">\(Self.escape($0))</span>" } ?? ""
                return "<div class=\"equation\"\(idAttr)>\(render(figure.content, tight: false))\(number)</div>"
            case .figure:
                return "<figure class=\"figure\"\(idAttr)>\(render(figure.content, tight: true))\(caption(figure))</figure>"
            case .table:
                return "<figure class=\"table-figure\"\(idAttr)>\(caption(figure))\(render(figure.content, tight: false))</figure>"
            }

        case .tableOfContents(let title, let entries):
            guard !entries.isEmpty else { return "" }
            var html = "<nav class=\"toc\">"
            if !title.isEmpty { html += "<p class=\"toc-title\">\(Self.escape(title))</p>" }
            html += "<ul>"
            for e in entries {
                let anchor = Self.escape(e.anchor)
                html += "<li class=\"toc-level-\(e.level)\"><a href=\"#\(anchor)\"><span class=\"toc-text\">\(Self.escape(e.text))</span>"
                    + "<span class=\"toc-page\" data-target=\"\(anchor)\"></span></a></li>"
            }
            return html + "</ul></nav>"

        case .bibliography(let items):
            var html = "<div class=\"references\" id=\"refs\">"
            for item in items {
                let label = item.label.map { "<span class=\"csl-label\">\(Self.escape($0))</span> " } ?? ""
                let cls = item.label == nil ? "csl-entry hanging" : "csl-entry numbered"
                html += "<div class=\"\(cls)\" id=\"\(Self.escape(item.anchor))\">\(label)<span class=\"csl-body\">\(render(item.content))</span></div>"
            }
            return html + "</div>"
        }
    }

    private mutating func caption(_ figure: MDFigure) -> String {
        guard !figure.caption.isEmpty || figure.label != nil else { return "" }
        var html = "<figcaption>"
        if let label = figure.label {
            html += "<span class=\"caption-label\">\(Self.escape(label))\(figure.caption.isEmpty ? "" : ":")</span> "
        }
        return html + render(figure.caption) + "</figcaption>"
    }

    // MARK: Inlines

    public mutating func render(_ inlines: [MDInline]) -> String {
        var out = ""
        for node in inlines {
            switch node {
            case .text(let s): out += Self.escape(s)
            case .emphasis(let c): out += "<em>\(render(c))</em>"
            case .strong(let c): out += "<strong>\(render(c))</strong>"
            case .strikethrough(let c): out += "<del>\(render(c))</del>"
            case .code(let s): out += "<code>\(Self.escape(s))</code>"
            case .link(let text, let url, let title):
                let t = title.map { " title=\"\(Self.escape($0))\"" } ?? ""
                out += "<a href=\"\(Self.escape(Self.safeURL(url)))\"\(t)>\(render(text))</a>"
            case .image(let alt, let url, let title):
                let t = title.map { " title=\"\(Self.escape($0))\"" } ?? ""
                let src = options.imageURL?(url) ?? url
                out += "<img src=\"\(Self.escape(Self.safeURL(src)))\" alt=\"\(Self.escape(alt))\"\(t)\(voidClose)"
            case .lineBreak: out += "<br\(voidClose)\n"
            case .softBreak: out += "\n"
            case .math(let tex):
                out += "<span class=\"math math-inline\">\(Self.escape(tex))</span>"
            case .citation(let c):
                out += Self.escape(c.raw)
            case .insertion(let c):
                out += "<ins class=\"critic\">\(render(c))</ins>"
            case .deletion(let c):
                out += "<del class=\"critic\">\(render(c))</del>"
            case .highlight(let c):
                out += "<mark class=\"critic\">\(render(c))</mark>"
            case .comment(let text):
                out += "<span class=\"critic-comment\">\(Self.escape(text))</span>"
            case .footnoteRef(let id):
                guard footnoteDefinitions[id] != nil else {
                    out += Self.escape("[^\(id)]")
                    continue
                }
                let n: Int
                if let existing = footnoteNumbers[id] {
                    n = existing
                } else {
                    n = footnoteOrder.count + 1
                    footnoteNumbers[id] = n
                    footnoteOrder.append(id)
                }
                let sid = Self.escape(Self.slug(id))
                out += "<sup class=\"footnote-ref\"><a href=\"#fn-\(sid)\" id=\"fnref-\(sid)\">\(n)</a></sup>"
            }
        }
        return out
    }

    private mutating func footnotesSection() -> String {
        var html = "<section class=\"footnotes\"><hr\(voidClose)<ol>"
        var index = 0
        // Footnotes may reference further footnotes, so iterate until the list is stable
        while index < footnoteOrder.count {
            let id = footnoteOrder[index]
            let sid = Self.escape(Self.slug(id))
            var body = (footnoteDefinitions[id]?.blocks ?? []).map { render($0, tight: false) }.joined(separator: "\n")
            let back = "<a href=\"#fnref-\(sid)\" class=\"footnote-back\">↩</a>"
            if body.hasSuffix("</p>") {
                body = String(body.dropLast(4)) + " " + back + "</p>"
            } else {
                body += back
            }
            html += "<li id=\"fn-\(sid)\">\(body)</li>"
            index += 1
        }
        return html + "</ol></section>"
    }

    // MARK: Helpers

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func safeURL(_ url: String) -> String {
        let lower = url.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") { return "#" }
        return url
    }

    public static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        return out.isEmpty ? "section" : out
    }
}
