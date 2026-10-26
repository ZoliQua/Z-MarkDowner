import AppKit

public enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    case unreadable(String, underlying: Error?)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "A(z) „.\(ext)” formátum nem támogatott."
        case .unreadable(let name, let underlying):
            var msg = "A(z) „\(name)” fájl nem olvasható."
            if let underlying { msg += " (\(underlying.localizedDescription))" }
            return msg
        }
    }
}

/// Reads MD, TXT, RTF, DOC and DOCX files and turns them into Markdown text.
public enum DocumentImporter {

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
    public static let plainTextExtensions: Set<String> = ["txt", "text"]
    public static let richTextExtensions: Set<String> = ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm"]

    public static var supportedExtensions: Set<String> {
        markdownExtensions.union(plainTextExtensions).union(richTextExtensions)
    }

    public static func markdown(fromFileAt url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) || plainTextExtensions.contains(ext) || ext.isEmpty {
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                throw ImportError.unreadable(url.lastPathComponent, underlying: error)
            }
            return decodeText(data)
        }

        if ext == "docx" {
            do {
                return try DocxReader.markdown(from: Data(contentsOf: url))
            } catch {
                // Fall back to the AppKit reader below (e.g. for unusual packages)
            }
        }

        let type: NSAttributedString.DocumentType
        switch ext {
        case "rtf": type = .rtf
        case "rtfd": type = .rtfd
        case "doc": type = .docFormat
        case "docx": type = .officeOpenXML
        case "odt": type = .openDocument
        case "html", "htm": type = .html
        default: throw ImportError.unsupportedFormat(ext)
        }

        do {
            let attributed = try NSAttributedString(url: url,
                                                    options: [.documentType: type,
                                                              .characterEncoding: String.Encoding.utf8.rawValue],
                                                    documentAttributes: nil)
            return AttributedToMarkdown.convert(attributed)
        } catch {
            throw ImportError.unreadable(url.lastPathComponent, underlying: error)
        }
    }

    /// Decodes text data trying UTF-8/UTF-16 first, then common Central European and Western encodings.
    public static func decodeText(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) {
            return s
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        // Windows-1250 covers Hungarian accented letters (ő, ű)
        if let s = String(data: data, encoding: .windowsCP1250) { return s }
        if let s = String(data: data, encoding: .isoLatin2) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Converts rich text (as produced by the AppKit document readers) into Markdown.
public enum AttributedToMarkdown {

    enum ParaKind {
        case heading(Int)
        case quote
        case rawBlock
        case listItem(level: Int, ordered: Bool, checked: Bool?)
        case code
        case tableCell(table: ObjectIdentifier, row: Int, column: Int)
        case normal
        case blank
    }

    struct Para {
        var kind: ParaKind
        var markdown: String
        var raw: String
    }

    public static func convert(_ attr: NSAttributedString) -> String {
        let ns = attr.string as NSString
        let bodySize = dominantFontSize(attr)
        var paras: [Para] = []

        var location = 0
        while location < ns.length {
            let full = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(full)
            var content = full
            // Exclude paragraph terminators
            while content.length > 0 {
                let last = ns.character(at: NSMaxRange(content) - 1)
                if last == 0x0A || last == 0x0D || last == 0x2029 || last == 0x0C {
                    content.length -= 1
                } else { break }
            }
            paras.append(classify(attr, range: content, fullRange: full, bodySize: bodySize))
        }
        return assemble(paras)
    }

    // MARK: Paragraph classification

    private static func classify(_ attr: NSAttributedString, range: NSRange, fullRange: NSRange, bodySize: CGFloat) -> Para {
        let ns = attr.string as NSString
        let raw = ns.substring(with: range)
        let style = attr.length > 0
            ? attr.attribute(.paragraphStyle, at: min(fullRange.location, attr.length - 1), effectiveRange: nil) as? NSParagraphStyle
            : nil

        // Table cells
        if let style, let block = style.textBlocks.last as? NSTextTableBlock {
            let md = inlineMarkdown(attr, range: range).trimmingCharacters(in: .whitespacesAndNewlines)
            return Para(kind: .tableCell(table: ObjectIdentifier(block.table), row: block.startingRow,
                                         column: block.startingColumn),
                        markdown: md, raw: raw)
        }

        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{FFFC}", with: "")
        if trimmedRaw.isEmpty {
            return Para(kind: .blank, markdown: "", raw: raw)
        }

        // Lists
        if let style, !style.textLists.isEmpty {
            let lists = style.textLists
            let level = lists.count - 1
            let ordered = isOrdered(lists[level])
            var r = range
            // Remove the marker text ("\t•\t", "\t1.\t") that the reader puts in front of list items
            if let markerLength = listMarkerLength(raw) {
                r = NSRange(location: range.location + markerLength, length: range.length - markerLength)
            }
            var md = inlineMarkdown(attr, range: r).trimmingCharacters(in: .whitespaces)
            var checked: Bool?
            if md.hasPrefix("☐ ") || md.hasPrefix("□ ") { checked = false; md = String(md.dropFirst(2)) }
            else if md.hasPrefix("☒ ") || md.hasPrefix("☑ ") { checked = true; md = String(md.dropFirst(2)) }
            return Para(kind: .listItem(level: level, ordered: ordered, checked: checked), markdown: md, raw: raw)
        }

        // Plain text bullets ("• item", "- item")
        if let bullet = textualBullet(raw) {
            let r = NSRange(location: range.location + bullet.length, length: range.length - bullet.length)
            let md = inlineMarkdown(attr, range: r).trimmingCharacters(in: .whitespaces)
            return Para(kind: .listItem(level: 0, ordered: bullet.ordered, checked: nil), markdown: md, raw: raw)
        }

        // Code (entire paragraph monospaced)
        if isMonospaced(attr, range: range) {
            return Para(kind: .code, markdown: raw, raw: raw)
        }

        // Headings
        if let level = headingLevel(attr, range: range, style: style, bodySize: bodySize, text: trimmedRaw) {
            let md = inlineMarkdown(attr, range: range, suppressBold: true)
                .trimmingCharacters(in: .whitespaces)
            return Para(kind: .heading(level), markdown: md, raw: raw)
        }

        return Para(kind: .normal, markdown: inlineMarkdown(attr, range: range).trimmingCharacters(in: .whitespaces), raw: raw)
    }

    private static func isOrdered(_ list: NSTextList) -> Bool {
        let format = list.markerFormat.rawValue.lowercased()
        return format.contains("decimal") || format.contains("alpha") || format.contains("roman")
            || format.contains("octal") || format.contains("hex")
    }

    private static func listMarkerLength(_ raw: String) -> Int? {
        let ns = raw as NSString
        let regex = try! NSRegularExpression(pattern: #"^\t?[^\t\n]{0,16}\t"#)
        guard let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return m.range.length
    }

    private static func textualBullet(_ raw: String) -> (length: Int, ordered: Bool)? {
        let ns = raw as NSString
        let regex = try! NSRegularExpression(pattern: #"^[ \t]*[•●○◦▪■‣–][ \t]+"#)
        if let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            return (m.range.length, false)
        }
        return nil
    }

    private static func isMonospaced(_ attr: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        var allMono = true
        attr.enumerateAttribute(.font, in: range) { value, sub, stop in
            let text = (attr.string as NSString).substring(with: sub)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { return }
            guard let font = value as? NSFont, isMonospacedFont(font) else {
                allMono = false; stop.pointee = true; return
            }
        }
        return allMono
    }

    static func isMonospacedFont(_ font: NSFont) -> Bool {
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return true }
        let name = font.fontName.lowercased()
        return ["courier", "menlo", "monaco", "consolas", "mono", "andale"].contains { name.contains($0) }
    }

    private static func headingLevel(_ attr: NSAttributedString, range: NSRange, style: NSParagraphStyle?,
                                     bodySize: CGFloat, text: String) -> Int? {
        if let style, style.headerLevel > 0 { return min(style.headerLevel, 6) }
        guard text.count <= 160, !text.contains("\n") else { return nil }

        var maxSize: CGFloat = 0
        var allBold = true
        attr.enumerateAttribute(.font, in: range) { value, sub, _ in
            let s = (attr.string as NSString).substring(with: sub)
            if s.trimmingCharacters(in: .whitespaces).isEmpty { return }
            guard let font = value as? NSFont else { allBold = false; return }
            maxSize = max(maxSize, font.pointSize)
            if !font.fontDescriptor.symbolicTraits.contains(.bold) { allBold = false }
        }
        guard bodySize > 0, maxSize > 0 else { return nil }
        let ratio = maxSize / bodySize
        if ratio >= 1.6 { return 1 }
        if ratio >= 1.3 { return 2 }
        if ratio >= 1.12 && (allBold || text.count < 80) { return 3 }
        if ratio >= 1.04 && allBold && text.count < 80 { return 4 }
        return nil
    }

    private static func dominantFontSize(_ attr: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            if let font = value as? NSFont {
                counts[(font.pointSize * 2).rounded() / 2, default: 0] += range.length
            }
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }

    // MARK: Inline conversion

    struct Segment {
        var text: String
        var bold: Bool
        var italic: Bool
        var strike: Bool
        var code: Bool
        var link: String?
    }

    static func inlineMarkdown(_ attr: NSAttributedString, range: NSRange, suppressBold: Bool = false) -> String {
        guard range.length > 0 else { return "" }
        var segments: [Segment] = []
        let ns = attr.string as NSString

        attr.enumerateAttributes(in: range) { attrs, sub, _ in
            var text = ns.substring(with: sub)
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            text = text.replacingOccurrences(of: "\u{2028}", with: "\n")
            text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
            guard !text.isEmpty else { return }
            var seg = Segment(text: text, bold: false, italic: false, strike: false, code: false, link: nil)
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                seg.bold = traits.contains(.bold) && !suppressBold
                seg.italic = traits.contains(.italic)
                seg.code = isMonospacedFont(font)
            }
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { seg.strike = true }
            if let link = attrs[.link] {
                if let url = link as? URL { seg.link = url.absoluteString }
                else if let s = link as? String { seg.link = s }
            }
            if let last = segments.last, last.bold == seg.bold, last.italic == seg.italic,
               last.strike == seg.strike, last.code == seg.code, last.link == seg.link {
                segments[segments.count - 1].text += seg.text
            } else {
                segments.append(seg)
            }
        }

        return inline(from: segments)
    }

    /// Converts formatted segments (with optional links) into inline Markdown.
    static func inline(from segments: [Segment]) -> String {
        // Group consecutive segments with the same link
        var out = ""
        var i = 0
        while i < segments.count {
            if let link = segments[i].link {
                var j = i
                var group: [Segment] = []
                while j < segments.count, segments[j].link == link { group.append(segments[j]); j += 1 }
                let inner = formatted(group)
                let lead = String(inner.prefix(while: { $0 == " " }))
                let trail = String(inner.reversed().prefix(while: { $0 == " " }))
                let core = inner.trimmingCharacters(in: .whitespaces)
                if core.isEmpty {
                    out += inner
                } else {
                    out += lead + "[\(core)](\(link.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: ")", with: "%29")))" + trail
                }
                i = j
            } else {
                var j = i
                var group: [Segment] = []
                while j < segments.count, segments[j].link == nil { group.append(segments[j]); j += 1 }
                out += formatted(group)
                i = j
            }
        }
        // Hard line breaks inside paragraphs
        return out.replacingOccurrences(of: "\n", with: "  \n")
    }

    /// Emits Markdown for a run of segments, opening and closing markers only where the style changes.
    static func formatted(_ segments: [Segment]) -> String {
        var out = ""
        var open: [String] = []   // stack of open markers

        func wanted(_ s: Segment) -> [String] {
            var m: [String] = []
            if s.bold { m.append("**") }
            if s.italic { m.append("*") }
            if s.strike { m.append("~~") }
            return m
        }

        func closeAll(downTo count: Int) {
            while open.count > count {
                // Move trailing whitespace outside the closing marker
                let trail = String(out.reversed().prefix(while: { $0 == " " || $0 == "\t" }))
                out.removeLast(trail.count)
                out += open.removeLast() + trail
            }
        }

        for seg in segments {
            if seg.code {
                closeAll(downTo: 0)
                out += codeSpan(seg.text)
                continue
            }
            let w = wanted(seg)
            // Keep the common prefix of open markers, close the rest
            var common = 0
            while common < open.count, common < w.count, open[common] == w[common] { common += 1 }
            let isBlankSegment = seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlankSegment {
                // Whitespace does not need to change formatting state
                out += seg.text
                continue
            }
            closeAll(downTo: common)
            var text = escape(seg.text)
            let lead = String(text.prefix(while: { $0 == " " || $0 == "\t" }))
            text.removeFirst(lead.count)
            out += lead
            for marker in w[common...] {
                out += marker
                open.append(marker)
            }
            out += text
        }
        closeAll(downTo: 0)
        return out
    }

    private static func codeSpan(_ text: String) -> String {
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        let lead = String(text.prefix(while: { $0 == " " }))
        let trail = String(text.reversed().prefix(while: { $0 == " " }))
        if core.contains("`") { return lead + "`` \(core) ``" + trail }
        return lead + "`\(core)`" + trail
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\`*_[]<>".contains(ch) { out.append("\\") }
            if ch == "~" && out.hasSuffix("~") { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Escapes characters at the start of a line that would otherwise create a block construct.
    private static func escapeLineStart(_ line: String) -> String {
        if line.range(of: #"^(#{1,6}\s|>|[-+]\s|\d+[.)]\s|={3,}\s*$|-{3,}\s*$)"#, options: .regularExpression) != nil {
            if let first = line.first, first.isNumber {
                // "1. " -> "1\. "
                let digits = line.prefix(while: { $0.isNumber })
                return digits + "\\" + line.dropFirst(digits.count)
            }
            return "\\" + line
        }
        return line
    }

    // MARK: Assembly

    static func assemble(_ paras: [Para]) -> String {
        var blocks: [String] = []
        var i = 0

        while i < paras.count {
            let p = paras[i]
            switch p.kind {
            case .blank:
                i += 1

            case .rawBlock:
                blocks.append(p.markdown)
                i += 1

            case .quote:
                var lines: [String] = []
                while i < paras.count, case .quote = paras[i].kind {
                    if !lines.isEmpty { lines.append(">") }
                    lines += paras[i].markdown.components(separatedBy: "\n").map { "> " + escapeLineStart($0) }
                    i += 1
                }
                blocks.append(lines.joined(separator: "\n"))

            case .heading(let level):
                blocks.append(String(repeating: "#", count: level) + " " + p.markdown)
                i += 1

            case .code:
                var lines: [String] = []
                while i < paras.count {
                    if case .code = paras[i].kind { lines.append(paras[i].raw); i += 1 }
                    else if case .blank = paras[i].kind, i + 1 < paras.count, case .code = paras[i + 1].kind {
                        lines.append(""); i += 1
                    } else { break }
                }
                blocks.append("```\n" + lines.joined(separator: "\n") + "\n```")

            case .listItem:
                var lines: [String] = []
                var counters: [Int: Int] = [:]
                var topOrdered: Bool?
                while i < paras.count, case .listItem(let level, let ordered, let checked) = paras[i].kind {
                    // A top-level switch between bullets and numbers starts a new list
                    if level == 0 {
                        if let t = topOrdered, t != ordered { break }
                        topOrdered = ordered
                    }
                    let indent = String(repeating: "    ", count: level)
                    // Reset counters of deeper levels
                    for key in counters.keys where key > level { counters[key] = nil }
                    let marker: String
                    if ordered {
                        let n = (counters[level] ?? 0) + 1
                        counters[level] = n
                        marker = "\(n)."
                    } else {
                        marker = "-"
                    }
                    let box = checked.map { $0 ? "[x] " : "[ ] " } ?? ""
                    let text = paras[i].markdown.replacingOccurrences(of: "\n", with: "\n" + indent + "    ")
                    lines.append(indent + marker + " " + box + text)
                    i += 1
                }
                blocks.append(lines.joined(separator: "\n"))

            case .tableCell(let table, _, _):
                var cells: [Int: [Int: String]] = [:]
                var maxCol = 0
                while i < paras.count, case .tableCell(let t, let row, let col) = paras[i].kind, t == table {
                    let text = paras[i].markdown
                        .replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "  \n", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                    if let existing = cells[row]?[col], !existing.isEmpty {
                        cells[row, default: [:]][col] = existing + (text.isEmpty ? "" : " " + text)
                    } else {
                        cells[row, default: [:]][col] = text
                    }
                    maxCol = max(maxCol, col)
                    i += 1
                }
                let rows = cells.keys.sorted()
                var lines: [String] = []
                for (idx, r) in rows.enumerated() {
                    let row = (0...maxCol).map { cells[r]?[$0] ?? "" }
                    lines.append("| " + row.joined(separator: " | ") + " |")
                    if idx == 0 {
                        lines.append("|" + Array(repeating: " --- |", count: maxCol + 1).joined())
                    }
                }
                if !lines.isEmpty { blocks.append(lines.joined(separator: "\n")) }

            case .normal:
                let lines = p.markdown.components(separatedBy: "\n").map(escapeLineStart)
                blocks.append(lines.joined(separator: "\n"))
                i += 1
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }
}
