import Foundation

public enum HTMLRenderer {

    /// Optional rewriting of image sources (e.g. to resolve relative paths).
    public typealias URLTransform = (String) -> String

    public static func render(markdown: String, imageURL: URLTransform? = nil) -> String {
        render(MDDocument(markdown: markdown).blocks, imageURL: imageURL)
    }

    public static func render(_ blocks: [MDBlock], imageURL: URLTransform? = nil) -> String {
        var usedIDs: [String: Int] = [:]
        let previous = currentImageTransform
        currentImageTransform = imageURL
        defer { currentImageTransform = previous }
        return blocks.map { render($0, tight: false, ids: &usedIDs) }.joined(separator: "\n")
    }

    // Rendering happens synchronously on one thread at a time per call site (main thread in the app).
    nonisolated(unsafe) private static var currentImageTransform: URLTransform?

    /// A complete standalone HTML page.
    public static func page(body: String, title: String, css: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head><body><article class="markdown-body">\(body)</article></body></html>
        """
    }

    // MARK: Blocks

    static func render(_ block: MDBlock, tight: Bool, ids: inout [String: Int]) -> String {
        switch block {
        case .heading(let level, let content):
            var id = slug(content.plainText)
            if let n = ids[id] { ids[id] = n + 1; id += "-\(n)" } else { ids[id] = 1 }
            return "<h\(level) id=\"\(escape(id))\">\(render(content))</h\(level)>"

        case .paragraph(let content):
            return tight ? render(content) : "<p>\(render(content))</p>"

        case .codeBlock(let language, let code):
            let cls = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
            return "<pre><code\(cls)>\(escape(code))\n</code></pre>"

        case .blockquote(let blocks):
            return "<blockquote>\n" + blocks.map { render($0, tight: false, ids: &ids) }.joined(separator: "\n") + "\n</blockquote>"

        case .list(let list):
            let isTask = list.items.contains { $0.checked != nil }
            let tag = list.ordered ? "ol" : "ul"
            var open = "<\(tag)"
            if list.ordered && list.start != 1 { open += " start=\"\(list.start)\"" }
            if isTask { open += " class=\"task-list\"" }
            open += ">"
            let items = list.items.map { item -> String in
                var inner = item.blocks.map { render($0, tight: list.tight, ids: &ids) }.joined(separator: "\n")
                var liOpen = "<li>"
                if let checked = item.checked {
                    liOpen = "<li class=\"task-list-item\">"
                    let box = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                    if inner.hasPrefix("<p>") {
                        inner = "<p>" + box + inner.dropFirst(3)
                    } else {
                        inner = box + inner
                    }
                }
                return liOpen + inner + "</li>"
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
            return "<hr>"
        }
    }

    // MARK: Inlines

    public static func render(_ inlines: [MDInline]) -> String {
        inlines.map { node -> String in
            switch node {
            case .text(let s): return escape(s)
            case .emphasis(let c): return "<em>\(render(c))</em>"
            case .strong(let c): return "<strong>\(render(c))</strong>"
            case .strikethrough(let c): return "<del>\(render(c))</del>"
            case .code(let s): return "<code>\(escape(s))</code>"
            case .link(let text, let url, let title):
                let t = title.map { " title=\"\(escape($0))\"" } ?? ""
                return "<a href=\"\(escape(safeURL(url)))\"\(t)>\(render(text))</a>"
            case .image(let alt, let url, let title):
                let t = title.map { " title=\"\(escape($0))\"" } ?? ""
                let src = currentImageTransform?(url) ?? url
                return "<img src=\"\(escape(safeURL(src)))\" alt=\"\(escape(alt))\"\(t)>"
            case .lineBreak: return "<br>\n"
            case .softBreak: return "\n"
            }
        }.joined()
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
            else if ch == " " || ch == "-" { out.append("-") }
        }
        return out.isEmpty ? "section" : out
    }
}
