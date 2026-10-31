import Foundation

/// A pragmatic CommonMark + GFM (tables, task lists, strikethrough, autolinks) parser.
public enum MarkdownParser {

    // MARK: - Public API

    public static func parseBlocks(_ text: String) -> [MDBlock] {
        parseDocument(text).blocks
    }

    /// Parses a complete document: front matter, blocks (with source lines) and footnotes.
    public static func parseDocument(_ text: String) -> MDDocument {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n").map(expandLeadingTabs)
        let (frontMatter, bodyStart) = parseFrontMatter(lines)
        lines = Array(lines[bodyStart...])
        let ctx = ParseContext(lineOffset: bodyStart)
        let blocks = parseBlocks(lines: lines, ctx: ctx)
        return MDDocument(blocks: blocks, blockLines: ctx.starts, footnotes: ctx.footnotes, frontMatter: frontMatter)
    }

    /// Characters allowed inside citation keys (`@key`).
    public static func isCitationKeyCharacter(_ ch: Character) -> Bool { InlineParser.isCitationKeyChar(ch) }

    /// Only the front matter of a document (cheap; reads at most the first 300 lines).
    public static func frontMatter(of text: String) -> [String: String] {
        guard text.hasPrefix("---") else { return [:] }
        let lines = text.prefix(20_000).replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n").prefix(300)
        return parseFrontMatter(Array(lines)).0
    }

    /// State collected while parsing the top level of a document.
    final class ParseContext {
        let lineOffset: Int
        var starts: [Int] = []
        var footnotes: [MDFootnote] = []
        init(lineOffset: Int) { self.lineOffset = lineOffset }
    }

    /// Extracts a leading YAML front matter block (`---` … `---`), returning its keys and the first body line.
    static func parseFrontMatter(_ lines: [String]) -> ([String: String], Int) {
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---", lines.count > 2 else {
            return ([:], 0)
        }
        var end: Int?
        for k in 1..<min(lines.count, 300) {
            let t = lines[k].trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." { end = k; break }
        }
        guard let end, end > 1 else { return ([:], 0) }
        var result: [String: String] = [:]
        var sawKey = false
        var lastKey: String?
        for line in lines[1..<end] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("-") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard key.range(of: #"^[A-Za-z0-9_\-]+$"#, options: .regularExpression) != nil else { return ([:], 0) }
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let f = value.first, let l = value.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                    value = String(value.dropFirst().dropLast())
                }
                if value.hasPrefix("[") && value.hasSuffix("]") {
                    value = value.dropFirst().dropLast().split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                        .joined(separator: ", ")
                }
                result[key] = value
                lastKey = key
                sawKey = true
            } else if let key = lastKey {
                // YAML list items ("- a") or folded continuation lines
                var item = line.trimmingCharacters(in: .whitespaces)
                if item.hasPrefix("- ") { item.removeFirst(2) }
                let existing = result[key] ?? ""
                result[key] = existing.isEmpty ? item : existing + ", " + item
            } else {
                return ([:], 0)
            }
        }
        return sawKey ? (result, end + 1) : ([:], 0)
    }

    // MARK: - Block parsing

    static func parseBlocks(lines: [String], ctx: ParseContext? = nil) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var i = 0
        var pendingStart = 0

        while i < lines.count {
            if let ctx {
                while ctx.starts.count < blocks.count { ctx.starts.append(pendingStart) }
            }
            let line = lines[i]
            if isBlank(line) { i += 1; continue }
            pendingStart = i + (ctx?.lineOffset ?? 0)

            let indent = leadingSpaces(line)
            let trimmed = String(line.dropFirst(indent))

            // Footnote definition (top level only)
            if let ctx, indent < 4, let def = footnoteDefinition(trimmed) {
                var body: [String] = [def.text]
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if isBlank(l) {
                        if i + 1 < lines.count, leadingSpaces(lines[i + 1]) >= 4 { body.append(""); i += 1; continue }
                        break
                    }
                    if leadingSpaces(l) >= 4 { body.append(String(l.dropFirst(4))); i += 1; continue }
                    if let last = body.last, !isBlank(last), !startsBlock(l), footnoteDefinition(l) == nil {
                        body.append(l); i += 1; continue
                    }
                    break
                }
                ctx.footnotes.append(MDFootnote(id: def.id, blocks: parseBlocks(lines: body)))
                continue
            }

            // Display math (optionally labelled: `$$ … $$ {#eq:label}`)
            if indent < 4, trimmed.hasPrefix("$$") {
                func equation(_ tex: String, _ label: String?) -> MDBlock {
                    guard let label else { return .mathBlock(tex) }
                    return .figure(MDFigure(kind: .equation, id: label, caption: [], content: .mathBlock(tex)))
                }
                let first = trailingAttribute(String(trimmed.dropFirst(2)))
                let rest = first.text
                if rest.hasSuffix("$$"), rest.count > 2 {
                    let tex = rest.dropLast(2)
                    blocks.append(equation(tex.trimmingCharacters(in: .whitespaces), first.id))
                    i += 1
                    continue
                }
                var tex: [String] = []
                if !rest.isEmpty { tex.append(rest) }
                var j = i + 1
                var closed = false
                var label: String?
                while j < lines.count {
                    let closing = trailingAttribute(lines[j].trimmingCharacters(in: .whitespaces))
                    let t = closing.text
                    if t.hasSuffix("$$") {
                        let before = t.dropLast(2)
                        if !before.isEmpty { tex.append(String(before)) }
                        label = closing.id
                        closed = true
                        break
                    }
                    tex.append(lines[j])
                    j += 1
                }
                if closed {
                    blocks.append(equation(tex.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), label))
                    i = j + 1
                    continue
                }
            }

            // Fenced code block
            if indent < 4, let fence = fenceStart(trimmed) {
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if isFenceClose(l, char: fence.char, count: fence.count) { i += 1; break }
                    code.append(removeIndent(l, upTo: indent))
                    i += 1
                }
                if fence.info.lowercased() == "math" || fence.info.lowercased() == "latex" {
                    blocks.append(.mathBlock(code.joined(separator: "\n")))
                } else {
                    blocks.append(.codeBlock(language: fence.info, code: code.joined(separator: "\n")))
                }
                continue
            }

            // Indented code block
            if indent >= 4 {
                var code: [String] = []
                while i < lines.count, isBlank(lines[i]) || leadingSpaces(lines[i]) >= 4 {
                    code.append(removeIndent(lines[i], upTo: 4))
                    i += 1
                }
                while let last = code.last, isBlank(last) { code.removeLast() }
                blocks.append(.codeBlock(language: "", code: code.joined(separator: "\n")))
                continue
            }

            // ATX heading
            if let heading = atxHeading(trimmed) {
                let attr = trailingAttribute(heading.text)
                blocks.append(.heading(level: heading.level, content: parseInlines(attr.text), id: attr.id))
                i += 1
                continue
            }

            // Horizontal rule
            if isHorizontalRule(trimmed) {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    let ind = leadingSpaces(l)
                    let t = String(l.dropFirst(ind))
                    if ind < 4, t.hasPrefix(">") {
                        var rest = String(t.dropFirst())
                        if rest.hasPrefix(" ") { rest.removeFirst() }
                        inner.append(rest)
                        i += 1
                    } else if !isBlank(l), let last = inner.last, !isBlank(last), !startsBlock(l) {
                        inner.append(t) // lazy continuation
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(parseBlocks(lines: inner)))
                continue
            }

            // List
            if let marker = listMarker(line) {
                let (list, next) = parseList(lines: lines, from: i, first: marker)
                blocks.append(.list(list))
                i = next
                continue
            }

            // Table
            if i + 1 < lines.count, line.contains("|"), isTableDelimiterRow(lines[i + 1]) {
                let header = splitTableRow(line)
                let alignments = splitTableRow(lines[i + 1]).map(parseAlignment)
                if header.count == alignments.count {
                    var rows: [[[MDInline]]] = []
                    i += 2
                    while i < lines.count, !isBlank(lines[i]), lines[i].contains("|"), !startsBlock(lines[i]) {
                        var cells = splitTableRow(lines[i])
                        if cells.count < header.count {
                            cells += Array(repeating: "", count: header.count - cells.count)
                        } else if cells.count > header.count {
                            cells = Array(cells.prefix(header.count))
                        }
                        rows.append(cells.map(parseInlines))
                        i += 1
                    }
                    let table = MDBlock.table(MDTable(header: header.map(parseInlines),
                                                      alignments: alignments,
                                                      rows: rows))
                    // Caption below the table: `Table: Text {#tbl:label}` or `: Text {#tbl:label}`
                    var k = i
                    if k < lines.count, isBlank(lines[k]), k + 1 < lines.count { k += 1 }
                    if k < lines.count, let caption = tableCaption(lines[k]) {
                        let attr = trailingAttribute(caption)
                        blocks.append(.figure(MDFigure(kind: .table, id: attr.id, caption: parseInlines(attr.text), content: table)))
                        i = k + 1
                    } else {
                        blocks.append(table)
                    }
                    continue
                }
            }

            // Paragraph (possibly setext heading)
            var para: [String] = [trimmed]
            i += 1
            var setextLevel: Int?
            while i < lines.count {
                let l = lines[i]
                if isBlank(l) { break }
                let t = l.trimmingCharacters(in: .whitespaces)
                if leadingSpaces(l) < 4, let level = setextUnderline(t) {
                    setextLevel = level
                    i += 1
                    break
                }
                if startsBlock(l) { break }
                para.append(String(l.dropFirst(leadingSpaces(l))))
                i += 1
            }
            let text = para.joined(separator: "\n")
            if let level = setextLevel {
                let attr = trailingAttribute(text.trimmingCharacters(in: .whitespaces))
                blocks.append(.heading(level: level, content: parseInlines(attr.text), id: attr.id))
            } else if isTOCPlaceholder(text) {
                blocks.append(.tableOfContents(title: "", entries: []))
            } else {
                blocks.append(paragraphOrFigure(trimTrailingWhitespace(text)))
            }
        }
        if let ctx {
            while ctx.starts.count < blocks.count { ctx.starts.append(pendingStart) }
        }
        return blocks
    }

    // MARK: Lists

    struct ListMarker {
        var ordered: Bool
        var number: Int
        var symbol: Character     // bullet char or delimiter (. or ))
        var indent: Int           // spaces before the marker
        var contentOffset: Int    // column where item content starts
        var content: String       // text after the marker
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = leadingSpaces(line)
        guard indent < 4 else { return nil }
        let chars = Array(line.dropFirst(indent))
        guard !chars.isEmpty else { return nil }

        var markerWidth = 0
        var ordered = false
        var number = 0
        var symbol: Character = "-"

        if "-*+".contains(chars[0]) {
            markerWidth = 1
            symbol = chars[0]
        } else {
            var digits = ""
            var k = 0
            while k < chars.count, k < 9, chars[k].isASCII, chars[k].isNumber {
                digits.append(chars[k]); k += 1
            }
            guard !digits.isEmpty, k < chars.count, chars[k] == "." || chars[k] == ")" else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            symbol = chars[k]
            markerWidth = k + 1
        }

        // Marker must be followed by whitespace or end of line
        if markerWidth < chars.count {
            guard chars[markerWidth] == " " else { return nil }
        }
        var spaces = 0
        while markerWidth + spaces < chars.count, chars[markerWidth + spaces] == " " { spaces += 1 }
        let restIsEmpty = markerWidth + spaces >= chars.count
        if restIsEmpty || spaces > 4 { spaces = 1 }
        let contentStart = min(markerWidth + spaces, chars.count)
        return ListMarker(ordered: ordered, number: number, symbol: symbol, indent: indent,
                          contentOffset: indent + markerWidth + spaces,
                          content: String(chars[contentStart...]))
    }

    static func parseList(lines: [String], from start: Int, first: ListMarker) -> (MDList, Int) {
        var items: [MDListItem] = []
        var tight = true
        var i = start

        while i < lines.count, let m = listMarker(lines[i]),
              m.ordered == first.ordered, m.symbol == first.symbol,
              m.indent < first.contentOffset,
              !(isHorizontalRule(lines[i].trimmingCharacters(in: .whitespaces)) && !m.ordered) {
            var itemLines: [String] = [m.content]
            let contentCol = m.contentOffset
            i += 1
            var previousBlank = false
            var inFence: (char: Character, count: Int)?

            while i < lines.count {
                let l = lines[i]
                if isBlank(l) {
                    itemLines.append("")
                    previousBlank = true
                    i += 1
                    continue
                }
                let ind = leadingSpaces(l)
                if ind >= contentCol {
                    let stripped = String(l.dropFirst(contentCol))
                    if let fence = inFence {
                        if isFenceClose(stripped, char: fence.char, count: fence.count) { inFence = nil }
                    } else if let f = fenceStart(stripped.trimmingCharacters(in: .whitespaces)) {
                        inFence = (f.char, f.count)
                    }
                    itemLines.append(stripped)
                    previousBlank = false
                    i += 1
                    continue
                }
                if !previousBlank, inFence == nil, listMarker(l) == nil, !startsBlock(l) {
                    itemLines.append(String(l.dropFirst(ind))) // lazy continuation
                    i += 1
                    continue
                }
                break
            }

            var trailingBlank = false
            while let last = itemLines.last, isBlank(last), itemLines.count > 1 {
                itemLines.removeLast()
                trailingBlank = true
            }

            // Task list item
            var checked: Bool?
            if let firstLine = itemLines.first {
                let lower = firstLine.lowercased()
                if lower.hasPrefix("[ ] ") || lower == "[ ]" {
                    checked = false
                    itemLines[0] = String(firstLine.dropFirst(min(4, firstLine.count)))
                } else if lower.hasPrefix("[x] ") || lower == "[x]" {
                    checked = true
                    itemLines[0] = String(firstLine.dropFirst(min(4, firstLine.count)))
                }
            }

            let blocks = parseBlocks(lines: itemLines)
            // An internal blank line separating direct children makes the list loose
            if blocks.count > 1, hasInternalBlankBetweenBlocks(itemLines) {
                tight = false
            }
            items.append(MDListItem(checked: checked, blocks: blocks))

            if trailingBlank {
                if i < lines.count, let next = listMarker(lines[i]),
                   next.ordered == first.ordered, next.symbol == first.symbol,
                   next.indent < first.contentOffset {
                    tight = false
                } else {
                    break
                }
            }
        }
        return (MDList(ordered: first.ordered, start: first.number, tight: tight, items: items), i)
    }

    private static func hasInternalBlankBetweenBlocks(_ lines: [String]) -> Bool {
        // Blank lines at item top level (not inside nested, indented content or fences)
        var inFence = false
        for (idx, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle() }
            if inFence { continue }
            if isBlank(l), idx + 1 < lines.count, !isBlank(lines[idx + 1]),
               leadingSpaces(lines[idx + 1]) == 0, listMarker(lines[idx + 1]) == nil {
                return true
            }
        }
        return false
    }

    // MARK: Block helpers

    static func startsBlock(_ line: String) -> Bool {
        let indent = leadingSpaces(line)
        guard indent < 4 else { return false }
        let t = String(line.dropFirst(indent))
        if atxHeading(t) != nil { return true }
        if fenceStart(t) != nil { return true }
        if isHorizontalRule(t) { return true }
        if t.hasPrefix(">") { return true }
        if t.hasPrefix("$$") { return true }
        if let m = listMarker(line), !m.content.trimmingCharacters(in: .whitespaces).isEmpty {
            if !m.ordered || m.number == 1 { return true }
        }
        return false
    }

    static func footnoteDefinition(_ t: String) -> (id: String, text: String)? {
        guard t.hasPrefix("[^"), let close = t.firstIndex(of: "]") else { return nil }
        let id = String(t[t.index(t.startIndex, offsetBy: 2)..<close])
        let after = t[t.index(after: close)...]
        guard !id.isEmpty, !id.contains(" "), after.hasPrefix(":") else { return nil }
        return (id, after.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    static func atxHeading(_ t: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in t {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence of #
        if let range = text.range(of: #"(^|\s)#+\s*$"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    static func isHorizontalRule(_ t: String) -> Bool {
        let stripped = t.filter { $0 != " " && $0 != "\t" }
        guard stripped.count >= 3, let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    static func setextUnderline(_ t: String) -> Int? {
        guard !t.isEmpty else { return nil }
        if t.allSatisfy({ $0 == "=" }) { return 1 }
        if t.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    /// Splits a trailing Pandoc attribute block (`{#id}`, `{#id .class}`, `{-}`) from a line.
    static func trailingAttribute(_ s: String) -> (text: String, id: String?) {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("}"), let open = trimmed.range(of: "{", options: .backwards) else { return (trimmed, nil) }
        let inner = trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)]
        guard let first = inner.first, first == "#" || first == "." || first == "-",
              !inner.contains("{"), inner.count < 120 else { return (trimmed, nil) }
        var id: String?
        for part in inner.split(separator: " ") where part.hasPrefix("#") && part.count > 1 {
            let candidate = String(part.dropFirst())
            guard candidate.allSatisfy({ $0.isLetter || $0.isNumber || "_:.-".contains($0) }) else { return (trimmed, nil) }
            id = candidate
        }
        let text = String(trimmed[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        return (text, id)
    }

    /// `Table: caption` or `: caption` directly below a table.
    static func tableCaption(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["Table:", "table:", ":"] where t.hasPrefix(prefix) {
            let rest = t.dropFirst(prefix.count)
            guard rest.first == " " else { continue }
            return rest.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func isTOCPlaceholder(_ text: String) -> Bool {
        ["[toc]", "[[toc]]", "[[_toc_]]", "${toc}"].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// A paragraph that holds only an image with a `{#fig:label}` attribute becomes a numbered figure.
    static func paragraphOrFigure(_ text: String) -> MDBlock {
        let attr = trailingAttribute(text)
        if let id = attr.id, attr.text.hasPrefix("![") {
            let inlines = parseInlines(attr.text)
            let chars = Array(attr.text)
            if inlines.count == 1, case .image = inlines[0],
               let (alt, _, _, end) = InlineParser(chars).linkAt(1), end == chars.count {
                // The alt text (with its formatting) is the caption
                return .figure(MDFigure(kind: .figure, id: id, caption: parseInlines(alt), content: .paragraph(inlines)))
            }
        }
        return .paragraph(parseInlines(text))
    }

    static func fenceStart(_ t: String) -> (char: Character, count: Int, info: String)? {
        guard let first = t.first, first == "`" || first == "~" else { return nil }
        let count = t.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let info = t.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        let lang = info.split(separator: " ").first.map(String.init) ?? ""
        return (first, count, lang)
    }

    static func isFenceClose(_ line: String, char: Character, count: Int) -> Bool {
        let indent = leadingSpaces(line)
        guard indent < 4 else { return false }
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= count else { return false }
        return t.allSatisfy { $0 == char }
    }

    // MARK: Tables

    public static func splitTableRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in t {
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    public static func isTableDelimiterRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.allSatisfy({ "|:- \t".contains($0) }) else { return false }
        let cells = splitTableRow(t)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil
        }
    }

    public static func parseAlignment(_ cell: String) -> MDAlignment {
        let left = cell.hasPrefix(":")
        let right = cell.hasSuffix(":")
        switch (left, right) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        default: return .none
        }
    }

    // MARK: String helpers

    static func isBlank(_ s: String) -> Bool {
        s.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func leadingSpaces(_ s: String) -> Int {
        s.prefix(while: { $0 == " " }).count
    }

    static func removeIndent(_ s: String, upTo n: Int) -> String {
        let k = min(n, leadingSpaces(s))
        return String(s.dropFirst(k))
    }

    static func expandLeadingTabs(_ s: String) -> String {
        guard s.contains("\t") else { return s }
        var result = ""
        var column = 0
        var leading = true
        for ch in s {
            if leading && ch == "\t" {
                let spaces = 4 - (column % 4)
                result += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                if ch != " " { leading = false }
                result.append(ch)
                column += 1
            }
        }
        return result
    }

    static func trimTrailingWhitespace(_ s: String) -> String {
        var s = s
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return s
    }

    // MARK: - Inline parsing

    public static func parseInlines(_ text: String) -> [MDInline] {
        var parser = InlineParser(Array(text))
        return parser.parse()
    }
}

// MARK: - Inline parser

struct InlineParser {
    let c: [Character]
    var i = 0
    var result: [MDInline] = []
    var buffer = ""

    init(_ chars: [Character]) {
        self.c = chars
    }

    static let asciiPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    mutating func parse() -> [MDInline] {
        while i < c.count {
            let ch = c[i]
            switch ch {
            case "\\":
                if i + 1 < c.count {
                    let next = c[i + 1]
                    if next == "\n" {
                        flush(); result.append(.lineBreak); i += 2; skipSpaces(); continue
                    }
                    if InlineParser.asciiPunctuation.contains(next) {
                        buffer.append(next); i += 2; continue
                    }
                }
                buffer.append(ch); i += 1

            case "\n":
                let hard = buffer.hasSuffix("  ")
                while let last = buffer.last, last == " " { buffer.removeLast() }
                flush()
                result.append(hard ? .lineBreak : .softBreak)
                i += 1
                skipSpaces()

            case "`":
                if let (code, end) = codeSpan(at: i) {
                    flush(); result.append(.code(code)); i = end
                } else {
                    let run = runLength(at: i, of: "`")
                    buffer += String(repeating: "`", count: run); i += run
                }

            case "!":
                if i + 1 < c.count, c[i + 1] == "[", let (text, url, title, end) = linkAt(i + 1) {
                    flush()
                    result.append(.image(alt: MarkdownParser.parseInlines(text).plainText, url: url, title: title))
                    i = end
                } else {
                    buffer.append(ch); i += 1
                }

            case "[":
                if i + 1 < c.count, c[i + 1] == "^", let (id, end) = footnoteRef(at: i) {
                    flush(); result.append(.footnoteRef(id)); i = end
                } else if let (text, url, title, end) = linkAt(i) {
                    flush()
                    result.append(.link(text: MarkdownParser.parseInlines(text), url: url, title: title))
                    i = end
                } else if let (citation, end) = citationGroup(at: i) {
                    flush(); result.append(.citation(citation)); i = end
                } else {
                    buffer.append(ch); i += 1
                }

            case "@":
                if let (citation, end) = bareCitation(at: i) {
                    flush(); result.append(.citation(citation)); i = end
                } else {
                    buffer.append(ch); i += 1
                }

            case "{":
                if let (nodes, end) = criticMarkup(at: i) {
                    flush(); result += nodes; i = end
                } else {
                    buffer.append(ch); i += 1
                }

            case "<":
                if let (url, end) = autolink(at: i) {
                    flush()
                    let display = url.hasPrefix("mailto:") && !String(c[(i + 1)..<(end - 1)]).hasPrefix("mailto:")
                        ? String(url.dropFirst(7)) : String(c[(i + 1)..<(end - 1)])
                    result.append(.link(text: [.text(display)], url: url, title: nil))
                    i = end
                } else {
                    buffer.append(ch); i += 1
                }

            case "*", "_", "~":
                if let (node, end) = emphasis(at: i) {
                    flush(); result.append(node); i = end
                } else {
                    let run = runLength(at: i, of: ch)
                    buffer += String(repeating: ch, count: run); i += run
                }

            case "$":
                if let (tex, end) = inlineMath(at: i) {
                    flush(); result.append(.math(tex)); i = end
                } else {
                    buffer.append(ch); i += 1
                }

            case "h", "w":
                if let (url, display, end) = bareURL(at: i) {
                    flush()
                    result.append(.link(text: [.text(display)], url: url, title: nil))
                    i = end
                } else {
                    buffer.append(ch); i += 1
                }

            default:
                buffer.append(ch); i += 1
            }
        }
        flush()
        return result
    }

    mutating func flush() {
        guard !buffer.isEmpty else { return }
        if case .text(let prev)? = result.last {
            result[result.count - 1] = .text(prev + buffer)
        } else {
            result.append(.text(buffer))
        }
        buffer = ""
    }

    mutating func skipSpaces() {
        while i < c.count, c[i] == " " { i += 1 }
    }

    func runLength(at pos: Int, of ch: Character) -> Int {
        var k = pos
        while k < c.count, c[k] == ch { k += 1 }
        return k - pos
    }

    // MARK: Code spans

    func codeSpan(at pos: Int) -> (String, Int)? {
        let n = runLength(at: pos, of: "`")
        var k = pos + n
        while k < c.count {
            if c[k] == "`" {
                let m = runLength(at: k, of: "`")
                if m == n {
                    var content = String(c[(pos + n)..<k]).replacingOccurrences(of: "\n", with: " ")
                    if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
                       !content.allSatisfy({ $0 == " " }) {
                        content = String(content.dropFirst().dropLast())
                    }
                    return (content, k + m)
                }
                k += m
            } else {
                k += 1
            }
        }
        return nil
    }

    /// Skips over an escape or code span starting at `k`; returns new index or nil if nothing to skip.
    func skipAtomic(_ k: Int) -> Int? {
        if c[k] == "\\" { return min(k + 2, c.count) }
        if c[k] == "`" {
            if let (_, end) = codeSpan(at: k) { return end }
            return k + runLength(at: k, of: "`")
        }
        return nil
    }

    // MARK: Footnotes and math

    func footnoteRef(at pos: Int) -> (String, Int)? {
        var k = pos + 2
        var id = ""
        while k < c.count, c[k] != "]" {
            if c[k].isWhitespace || c[k] == "[" { return nil }
            id.append(c[k]); k += 1
        }
        guard k < c.count, !id.isEmpty else { return nil }
        // "[^x](url)" is a link, not a footnote
        if k + 1 < c.count, c[k + 1] == "(" { return nil }
        return (id, k + 1)
    }

    func inlineMath(at pos: Int) -> (String, Int)? {
        let double = pos + 1 < c.count && c[pos + 1] == "$"
        let open = double ? 2 : 1
        let start = pos + open
        guard start < c.count, !c[start].isWhitespace else { return nil }
        var k = start
        while k < c.count {
            if c[k] == "\\" { k += 2; continue }
            if c[k] == "$" {
                if double {
                    if k + 1 < c.count, c[k + 1] == "$", k > start { return (String(c[start..<k]), k + 2) }
                } else {
                    // Closing $ must follow non-space and must not be followed by a digit (currency)
                    if k > start, !c[k - 1].isWhitespace, !(k + 1 < c.count && c[k + 1].isNumber) {
                        return (String(c[start..<k]), k + 1)
                    }
                }
            }
            if c[k] == "\n" && k + 1 < c.count && c[k + 1] == "\n" { return nil }
            k += 1
        }
        return nil
    }

    // MARK: Citations

    static func isCitationKeyChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || "_:.#$%&-+?~/".contains(ch)
    }

    /// Reads a citation key starting at `pos` (after `@`); trailing punctuation is not part of the key.
    func citationKey(from pos: Int) -> Int? {
        guard pos < c.count, c[pos].isLetter || c[pos].isNumber || c[pos] == "_" else { return nil }
        var k = pos
        while k < c.count, InlineParser.isCitationKeyChar(c[k]) { k += 1 }
        while k > pos + 1, ".:#$%&-+?~/".contains(c[k - 1]) { k -= 1 }
        return k
    }

    /// `[see @key, p. 33; @other]`
    func citationGroup(at pos: Int) -> (MDCitation, Int)? {
        var k = pos + 1
        while k < c.count, c[k] != "]" {
            if c[k] == "[" { return nil }
            if c[k] == "\n", k + 1 < c.count, c[k + 1] == "\n" { return nil }
            k += 1
        }
        guard k < c.count, k > pos + 1 else { return nil }
        let inner = String(c[(pos + 1)..<k])
        guard inner.contains("@") else { return nil }
        var items: [MDCitationItem] = []
        for part in inner.split(separator: ";", omittingEmptySubsequences: false) {
            guard let item = InlineParser.citationItem(String(part)) else { return nil }
            items.append(item)
        }
        let raw = String(c[pos...k])
        return (MDCitation(items: items, inText: false, raw: raw), k + 1)
    }

    static func citationItem(_ part: String) -> MDCitationItem? {
        let chars = Array(part)
        var at: Int?
        for (idx, ch) in chars.enumerated() where ch == "@" {
            let before = idx > 0 ? chars[idx - 1] : " "
            if before.isWhitespace || before == "-" { at = idx; break }
        }
        guard let at else { return nil }
        let parser = InlineParser(chars)
        guard let end = parser.citationKey(from: at + 1) else { return nil }
        var prefixEnd = at
        var suppress = false
        if at > 0, chars[at - 1] == "-", at < 2 || chars[at - 2].isWhitespace {
            suppress = true
            prefixEnd = at - 1
        }
        let prefix = String(chars[..<prefixEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        var locator = String(chars[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if locator.hasPrefix(",") { locator = String(locator.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return MDCitationItem(key: String(chars[(at + 1)..<end]), prefix: prefix, locator: locator, suppressAuthor: suppress)
    }

    /// `@key` in running text, optionally followed by a locator: `@key [p. 33]`.
    func bareCitation(at pos: Int) -> (MDCitation, Int)? {
        if pos > 0 {
            let prev = c[pos - 1]
            if prev.isLetter || prev.isNumber || "_.-@/\\`:+".contains(prev) { return nil }
        }
        guard let end = citationKey(from: pos + 1) else { return nil }
        var item = MDCitationItem(key: String(c[(pos + 1)..<end]))
        var stop = end
        if end + 1 < c.count, c[end] == " ", c[end + 1] == "[" {
            var k = end + 2
            while k < c.count, c[k] != "]", c[k] != "[", c[k] != "@", c[k] != "\n" { k += 1 }
            if k < c.count, c[k] == "]", k > end + 2, !(k + 1 < c.count && (c[k + 1] == "(" || c[k + 1] == "[")) {
                item.locator = String(c[(end + 2)..<k]).trimmingCharacters(in: .whitespaces)
                stop = k + 1
            }
        }
        return (MDCitation(items: [item], inText: true, raw: String(c[pos..<stop])), stop)
    }

    // MARK: CriticMarkup

    func criticMarkup(at pos: Int) -> ([MDInline], Int)? {
        guard pos + 2 < c.count else { return nil }
        let opener = String(c[(pos + 1)...(pos + 2)])
        let closers = ["++": "++}", "--": "--}", "~~": "~~}", "==": "==}", ">>": "<<}"]
        guard let closer = closers[opener] else { return nil }
        let closeChars = Array(closer)
        var k = pos + 3
        while k + 2 < c.count {
            if c[k] == closeChars[0], c[k + 1] == closeChars[1], c[k + 2] == closeChars[2] {
                let inner = String(c[(pos + 3)..<k])
                let end = k + 3
                switch opener {
                case "++": return ([.insertion(MarkdownParser.parseInlines(inner))], end)
                case "--": return ([.deletion(MarkdownParser.parseInlines(inner))], end)
                case "==": return ([.highlight(MarkdownParser.parseInlines(inner))], end)
                case ">>": return ([.comment(inner.trimmingCharacters(in: .whitespacesAndNewlines))], end)
                default:
                    let parts = inner.components(separatedBy: "~>")
                    guard parts.count == 2 else { return nil }
                    return ([.deletion(MarkdownParser.parseInlines(parts[0])),
                             .insertion(MarkdownParser.parseInlines(parts[1]))], end)
                }
            }
            if c[k] == "\n", k + 1 < c.count, c[k + 1] == "\n" { return nil }
            k += 1
        }
        return nil
    }

    // MARK: Links

    func linkAt(_ pos: Int) -> (String, String, String?, Int)? {
        guard c[pos] == "[" else { return nil }
        var depth = 0
        var k = pos
        var close = -1
        while k < c.count {
            if let next = skipAtomic(k), k != pos { k = next; continue }
            if c[k] == "[" { depth += 1 }
            if c[k] == "]" {
                depth -= 1
                if depth == 0 { close = k; break }
            }
            k += 1
        }
        guard close > 0, close + 1 < c.count, c[close + 1] == "(" else { return nil }
        let text = String(c[(pos + 1)..<close])

        var j = close + 2
        while j < c.count, c[j] == " " || c[j] == "\n" { j += 1 }
        var url = ""
        if j < c.count, c[j] == "<" {
            j += 1
            while j < c.count, c[j] != ">", c[j] != "\n" { url.append(c[j]); j += 1 }
            guard j < c.count, c[j] == ">" else { return nil }
            j += 1
        } else {
            var parens = 0
            while j < c.count {
                let ch = c[j]
                if ch == "\\", j + 1 < c.count, InlineParser.asciiPunctuation.contains(c[j + 1]) {
                    url.append(c[j + 1]); j += 2; continue
                }
                if ch == " " || ch == "\n" { break }
                if ch == "(" { parens += 1 }
                if ch == ")" {
                    if parens == 0 { break }
                    parens -= 1
                }
                url.append(ch); j += 1
            }
        }
        while j < c.count, c[j] == " " || c[j] == "\n" { j += 1 }
        var title: String?
        if j < c.count, c[j] == "\"" || c[j] == "'" || c[j] == "(" {
            let closer: Character = c[j] == "(" ? ")" : c[j]
            var t = ""
            j += 1
            while j < c.count, c[j] != closer {
                if c[j] == "\\", j + 1 < c.count { t.append(c[j + 1]); j += 2; continue }
                t.append(c[j]); j += 1
            }
            guard j < c.count else { return nil }
            j += 1
            title = t
            while j < c.count, c[j] == " " || c[j] == "\n" { j += 1 }
        }
        guard j < c.count, c[j] == ")" else { return nil }
        return (text, url, title, j + 1)
    }

    func autolink(at pos: Int) -> (String, Int)? {
        var k = pos + 1
        var content = ""
        while k < c.count, c[k] != ">" {
            if c[k] == " " || c[k] == "\n" || c[k] == "<" { return nil }
            content.append(c[k]); k += 1
        }
        guard k < c.count else { return nil }
        if content.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^\s<>]*$"#, options: .regularExpression) != nil {
            return (content, k + 1)
        }
        if content.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*$"#,
                         options: .regularExpression) != nil {
            return ("mailto:" + content, k + 1)
        }
        return nil
    }

    func bareURL(at pos: Int) -> (String, String, Int)? {
        if pos > 0 {
            let prev = c[pos - 1]
            if prev.isLetter || prev.isNumber || prev == "/" || prev == "." { return nil }
        }
        let rest = String(c[pos..<min(c.count, pos + 8)])
        let isWWW = rest.hasPrefix("www.")
        guard rest.hasPrefix("http://") || rest.hasPrefix("https://") || isWWW else { return nil }
        var k = pos
        while k < c.count, !c[k].isWhitespace, c[k] != "<" { k += 1 }
        // Trim trailing punctuation
        while k > pos, ".,:;!?\"'*_~".contains(c[k - 1]) { k -= 1 }
        // Balance trailing parenthesis
        var display = String(c[pos..<k])
        while display.hasSuffix(")"),
              display.filter({ $0 == ")" }).count > display.filter({ $0 == "(" }).count {
            display.removeLast(); k -= 1
        }
        let minLength = isWWW ? 5 : 9
        guard display.count >= minLength else { return nil }
        let url = isWWW ? "http://" + display : display
        return (url, display, k)
    }

    // MARK: Emphasis

    func isLeftFlanking(_ pos: Int, run: Int, ch: Character) -> Bool {
        let after = pos + run
        guard after < c.count, !c[after].isWhitespace else { return false }
        if ch == "_", pos > 0, c[pos - 1].isLetter || c[pos - 1].isNumber { return false }
        return true
    }

    func findCloser(from start: Int, ch: Character, length: Int) -> Int? {
        var k = start
        while k < c.count {
            if let next = skipAtomic(k) { k = next; continue }
            if c[k] == "[", let (_, _, _, end) = linkAt(k) { k = end; continue }
            if c[k] == ch {
                let run = runLength(at: k, of: ch)
                let prevOK = k > start && !c[k - 1].isWhitespace
                var nextOK = true
                if ch == "_", k + run < c.count, c[k + run].isLetter || c[k + run].isNumber { nextOK = false }
                if run >= length, prevOK, nextOK {
                    // Inner delimiters close first, the remainder of the run belongs to outer ones
                    return k
                }
                // A nested opener: skip over the whole nested span
                if isLeftFlanking(k, run: run, ch: ch), let (_, end) = emphasis(at: k) {
                    k = end
                    continue
                }
                k += run
                continue
            }
            k += 1
        }
        return nil
    }

    func emphasis(at pos: Int) -> (MDInline, Int)? {
        let ch = c[pos]
        let run = runLength(at: pos, of: ch)

        if ch == "~" {
            guard run == 2, isLeftFlanking(pos, run: 2, ch: ch),
                  let close = findCloser(from: pos + 2, ch: "~", length: 2) else { return nil }
            let inner = MarkdownParser.parseInlines(String(c[(pos + 2)..<close]))
            return (.strikethrough(inner), close + 2)
        }

        guard isLeftFlanking(pos, run: run, ch: ch) else { return nil }

        if run >= 3, let close = findCloser(from: pos + 3, ch: ch, length: 3) {
            let inner = MarkdownParser.parseInlines(String(c[(pos + 3)..<close]))
            return (.strong([.emphasis(inner)]), close + 3)
        }
        func strong() -> (MDInline, Int)? {
            guard run >= 2, let close = findCloser(from: pos + 2, ch: ch, length: 2) else { return nil }
            return (.strong(MarkdownParser.parseInlines(String(c[(pos + 2)..<close]))), close + 2)
        }
        func emph() -> (MDInline, Int)? {
            guard let close = findCloser(from: pos + 1, ch: ch, length: 1) else { return nil }
            return (.emphasis(MarkdownParser.parseInlines(String(c[(pos + 1)..<close]))), close + 1)
        }
        // For a run of three, "***a** b*" is emphasis around strong; otherwise prefer strong
        return run >= 3 ? (emph() ?? strong()) : (strong() ?? emph())
    }
}
