import Foundation

/// Reads WordprocessingML (.docx) directly, honouring paragraph styles, numbering and hyperlinks,
/// which the AppKit DOCX reader ignores.
public struct DocxReader {

    private struct RunProps {
        var bold: Bool?
        var italic: Bool?
        var strike: Bool?
        var mono: Bool?
        var size: Int?          // half-points

        func merged(over base: RunProps) -> RunProps {
            RunProps(bold: bold ?? base.bold, italic: italic ?? base.italic, strike: strike ?? base.strike,
                     mono: mono ?? base.mono, size: size ?? base.size)
        }
    }

    private struct Style {
        var name: String = ""
        var basedOn: String?
        var outlineLevel: Int?
        var numId: String?
        var numLevel: Int?
        var run = RunProps()
    }

    private var styles: [String: Style] = [:]
    private var defaultParagraphStyle: String?
    private var defaultRun = RunProps(size: 20)
    private var numFormats: [String: [Int: String]] = [:]   // numId -> level -> numFmt
    private var relationships: [String: String] = [:]
    private var referencedFootnotes: [String] = []
    private var revisions: DocumentImporter.RevisionMode = .markup
    private var comments: [String: (author: String, text: String)] = [:]

    public static func markdown(from data: Data, revisions: DocumentImporter.RevisionMode = .markup) throws -> String {
        var reader = DocxReader()
        reader.revisions = revisions
        return try reader.convert(data)
    }

    // MARK: - Loading

    private mutating func convert(_ data: Data) throws -> String {
        let zip = try ZipReader(data: data)
        guard let documentData = try zip.contents(of: "word/document.xml") else {
            throw ZipError.corrupt("word/document.xml")
        }
        if let stylesData = try zip.contents(of: "word/styles.xml") { loadStyles(stylesData) }
        if let numberingData = try zip.contents(of: "word/numbering.xml") { loadNumbering(numberingData) }
        if let relsData = try zip.contents(of: "word/_rels/document.xml.rels") { loadRelationships(relsData) }
        if revisions == .markup, let commentsData = try zip.contents(of: "word/comments.xml") { loadComments(commentsData) }

        let doc = try XMLDocument(data: Self.protectWhitespace(documentData), options: [.nodePreserveWhitespace])
        guard let root = doc.rootElement(), let body = child(root, "body") else { return "" }

        var paras: [AttributedToMarkdown.Para] = []
        processContainer(body, into: &paras)
        if let notesData = try zip.contents(of: "word/footnotes.xml") {
            paras += footnoteDefinitions(notesData)
        }
        return AttributedToMarkdown.assemble(paras)
    }

    private mutating func loadStyles(_ data: Data) {
        guard let doc = try? XMLDocument(data: data), let root = doc.rootElement() else { return }
        if let defaults = child(root, "docDefaults"),
           let rPrDefault = child(defaults, "rPrDefault"), let rPr = child(rPrDefault, "rPr") {
            defaultRun = runProps(rPr).merged(over: defaultRun)
        }
        for el in children(root, "style") {
            guard let id = attr(el, "styleId") else { continue }
            var style = Style()
            style.name = child(el, "name").flatMap { attr($0, "val") }?.lowercased() ?? id.lowercased()
            style.basedOn = child(el, "basedOn").flatMap { attr($0, "val") }
            if let pPr = child(el, "pPr") {
                style.outlineLevel = child(pPr, "outlineLvl").flatMap { attr($0, "val") }.flatMap(Int.init)
                if let numPr = child(pPr, "numPr") {
                    style.numId = child(numPr, "numId").flatMap { attr($0, "val") }
                    style.numLevel = child(numPr, "ilvl").flatMap { attr($0, "val") }.flatMap(Int.init)
                }
            }
            if let rPr = child(el, "rPr") { style.run = runProps(rPr) }
            styles[id] = style
            if attr(el, "type") == "paragraph", let d = attr(el, "default"), d == "1" || d == "true" {
                defaultParagraphStyle = id
            }
        }
    }

    private mutating func loadNumbering(_ data: Data) {
        guard let doc = try? XMLDocument(data: data), let root = doc.rootElement() else { return }
        var abstract: [String: [Int: String]] = [:]
        for el in children(root, "abstractNum") {
            guard let id = attr(el, "abstractNumId") else { continue }
            var levels: [Int: String] = [:]
            for lvl in children(el, "lvl") {
                if let ilvl = attr(lvl, "ilvl").flatMap(Int.init) {
                    levels[ilvl] = child(lvl, "numFmt").flatMap { attr($0, "val") } ?? "decimal"
                }
            }
            abstract[id] = levels
        }
        for el in children(root, "num") {
            guard let numId = attr(el, "numId"),
                  let absId = child(el, "abstractNumId").flatMap({ attr($0, "val") }) else { continue }
            numFormats[numId] = abstract[absId] ?? [:]
        }
    }

    private mutating func loadRelationships(_ data: Data) {
        guard let doc = try? XMLDocument(data: data), let root = doc.rootElement() else { return }
        for el in children(root, "Relationship") {
            if let id = attr(el, "Id"), let target = attr(el, "Target") {
                relationships[id] = target
            }
        }
    }

    private mutating func loadComments(_ data: Data) {
        guard let doc = try? XMLDocument(data: Self.protectWhitespace(data), options: [.nodePreserveWhitespace]),
              let root = doc.rootElement() else { return }
        for el in children(root, "comment") {
            guard let id = attr(el, "id") else { continue }
            var texts: [String] = []
            for p in children(el, "p") {
                var segs: [AttributedToMarkdown.Segment] = []
                var maxSize = 0
                collectRuns(p, base: RunProps(), link: nil, into: &segs, maxSize: &maxSize)
                let t = segs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { texts.append(t) }
            }
            comments[id] = (attr(el, "author") ?? "", texts.joined(separator: " "))
        }
    }

    /// Footnotes that were referenced in the body, as `[^n]: text` definitions.
    private mutating func footnoteDefinitions(_ data: Data) -> [AttributedToMarkdown.Para] {
        guard !referencedFootnotes.isEmpty,
              let doc = try? XMLDocument(data: Self.protectWhitespace(data), options: [.nodePreserveWhitespace]),
              let root = doc.rootElement() else { return [] }
        var result: [AttributedToMarkdown.Para] = []
        for note in children(root, "footnote") {
            guard let id = attr(note, "id"), referencedFootnotes.contains(id) else { continue }
            var texts: [String] = []
            for p in children(note, "p") {
                var segs: [AttributedToMarkdown.Segment] = []
                var maxSize = 0
                collectRuns(p, base: styleRunProps(nil), link: nil, into: &segs, maxSize: &maxSize)
                let md = AttributedToMarkdown.inline(from: segs).trimmingCharacters(in: .whitespacesAndNewlines)
                if !md.isEmpty { texts.append(md) }
            }
            result.append(.init(kind: .rawBlock, markdown: "[^\(id)]: " + texts.joined(separator: " "), raw: ""))
        }
        return result
    }

    // MARK: - Style resolution

    private func resolvedStyleChain(_ id: String?) -> [Style] {
        var chain: [Style] = []
        var current = id ?? defaultParagraphStyle
        var guardCount = 0
        while let c = current, let s = styles[c], guardCount < 20 {
            chain.append(s)
            current = s.basedOn
            guardCount += 1
        }
        return chain
    }

    private func styleRunProps(_ id: String?) -> RunProps {
        var props = defaultRun
        for s in resolvedStyleChain(id).reversed() { props = s.run.merged(over: props) }
        return props
    }

    // MARK: - Body traversal

    private mutating func processContainer(_ container: XMLElement, into paras: inout [AttributedToMarkdown.Para]) {
        for case let el as XMLElement in container.children ?? [] {
            switch el.localName {
            case "p":
                paras.append(paragraph(el))
            case "tbl":
                if let table = tableMarkdown(el) {
                    paras.append(.init(kind: .rawBlock, markdown: table, raw: ""))
                }
            case "sdt":
                if let content = child(el, "sdtContent") { processContainer(content, into: &paras) }
            case "customXml", "ins", "moveTo":
                processContainer(el, into: &paras)
            default:
                break
            }
        }
    }

    private mutating func paragraph(_ p: XMLElement) -> AttributedToMarkdown.Para {
        let pPr = child(p, "pPr")
        let styleId = pPr.flatMap { child($0, "pStyle") }.flatMap { attr($0, "val") }
        let chain = resolvedStyleChain(styleId)
        let styleName = chain.first?.name ?? ""
        let baseRun = styleRunProps(styleId)

        var segments: [AttributedToMarkdown.Segment] = []
        var maxSize = 0
        collectRuns(p, base: baseRun, link: nil, into: &segments, maxSize: &maxSize)

        let plain = segments.map(\.text).joined()
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let pPr, let border = child(pPr, "pBdr"), child(border, "bottom") != nil || child(border, "top") != nil {
                return .init(kind: .rawBlock, markdown: "---", raw: "")
            }
            return .init(kind: .blank, markdown: "", raw: "")
        }

        // Numbering (direct or inherited from the paragraph style)
        var numId = pPr.flatMap { child($0, "numPr") }.flatMap { child($0, "numId") }.flatMap { attr($0, "val") }
        var level = pPr.flatMap { child($0, "numPr") }.flatMap { child($0, "ilvl") }.flatMap { attr($0, "val") }.flatMap(Int.init)
        if numId == nil, let s = chain.first(where: { $0.numId != nil }) {
            numId = s.numId
            level = level ?? s.numLevel
        }

        // Heading detection: style name, outline level, then font size
        var headingLevel: Int?
        if let range = styleName.range(of: #"^heading (\d)$"#, options: .regularExpression) {
            headingLevel = Int(styleName[range].filter(\.isNumber))
        } else if styleName == "title" {
            headingLevel = 1
        } else if styleName == "subtitle" {
            headingLevel = 2
        } else if let outline = pPr.flatMap({ child($0, "outlineLvl") }).flatMap({ attr($0, "val") }).flatMap(Int.init)
                    ?? chain.compactMap(\.outlineLevel).first, outline < 6 {
            headingLevel = outline + 1
        }

        if let h = headingLevel {
            let md = AttributedToMarkdown.inline(from: segments.map { var s = $0; s.bold = false; return s })
            return .init(kind: .heading(min(max(h, 1), 6)), markdown: md.trimmingCharacters(in: .whitespaces), raw: plain)
        }

        if let numId, numId != "0" {
            let lvl = level ?? 0
            let format = numFormats[numId]?[lvl] ?? "bullet"
            let ordered = format != "bullet" && format != "none"
            var md = AttributedToMarkdown.inline(from: segments).trimmingCharacters(in: .whitespaces)
            var checked: Bool?
            if md.hasPrefix("☐ ") || md.hasPrefix("□ ") { checked = false; md = String(md.dropFirst(2)) }
            else if md.hasPrefix("☒ ") || md.hasPrefix("☑ ") { checked = true; md = String(md.dropFirst(2)) }
            return .init(kind: .listItem(level: lvl, ordered: ordered, checked: checked), markdown: md, raw: plain)
        }

        if styleName.contains("quote") {
            return .init(kind: .quote, markdown: AttributedToMarkdown.inline(from: segments).trimmingCharacters(in: .whitespaces), raw: plain)
        }

        let nonBlank = segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if styleName.contains("code") || styleName == "html preformatted" || styleName == "plain text"
            || (!nonBlank.isEmpty && nonBlank.allSatisfy(\.code)) {
            return .init(kind: .code, markdown: plain, raw: plain)
        }

        // Large or bold-and-large text used as a heading through direct formatting
        let bodySize = styleRunProps(nil).size ?? 20
        if trimmed.count <= 160, !plain.contains("\n"), maxSize > 0 {
            let ratio = Double(maxSize) / Double(bodySize)
            let allBold = !nonBlank.isEmpty && nonBlank.allSatisfy(\.bold)
            var level: Int?
            if ratio >= 1.6 { level = 1 }
            else if ratio >= 1.3 { level = 2 }
            else if ratio >= 1.12 && allBold { level = 3 }
            if let level {
                let md = AttributedToMarkdown.inline(from: segments.map { var s = $0; s.bold = false; return s })
                return .init(kind: .heading(level), markdown: md.trimmingCharacters(in: .whitespaces), raw: plain)
            }
        }

        return .init(kind: .normal, markdown: AttributedToMarkdown.inline(from: segments).trimmingCharacters(in: .whitespaces), raw: plain)
    }

    private struct FieldState {
        var inInstruction = false
        var link: String?
        var revision: AttributedToMarkdown.Revision = .none
        /// Comment id → index in the segment list where its highlighted range starts.
        var commentStarts: [String: Int] = [:]
    }

    private mutating func collectRuns(_ el: XMLElement, base: RunProps, link: String?,
                                      into segments: inout [AttributedToMarkdown.Segment], maxSize: inout Int) {
        var field = FieldState()
        collectRuns(el, base: base, link: link, field: &field, into: &segments, maxSize: &maxSize)
    }

    private mutating func collectRuns(_ el: XMLElement, base: RunProps, link: String?, field: inout FieldState,
                                      into segments: inout [AttributedToMarkdown.Segment], maxSize: inout Int) {
        for case let node as XMLElement in el.children ?? [] {
            switch node.localName {
            case "r":
                var props = base
                if let rPr = child(node, "rPr") {
                    let rStyle = child(rPr, "rStyle").flatMap { attr($0, "val") }
                    if let rStyle {
                        var styleProps = RunProps()
                        for s in resolvedStyleChain(rStyle).reversed() { styleProps = s.run.merged(over: styleProps) }
                        props = styleProps.merged(over: props)
                    }
                    props = runProps(rPr).merged(over: props)
                }
                let effectiveLink = link ?? field.link
                for case let item as XMLElement in node.children ?? [] {
                    var text: String?
                    switch item.localName {
                    case "t":
                        if !field.inInstruction { text = Self.restoreWhitespace(item.stringValue ?? "") }
                    case "delText":
                        if !field.inInstruction, field.revision == .delete { text = Self.restoreWhitespace(item.stringValue ?? "") }
                    case "commentReference":
                        if let id = attr(item, "id"), let c = comments[id] {
                            let body = (c.author.isEmpty ? "" : c.author + ": ") + c.text
                            segments.append(.init(text: "{>>\(body.replacingOccurrences(of: "<<}", with: "<< }"))<<}", bold: false, italic: false,
                                                  strike: false, code: false, link: nil, raw: true))
                        }
                    case "tab", "ptab": text = "\t"
                    case "br", "cr":
                        if attr(item, "type") != "page" && attr(item, "type") != "column" { text = "\n" }
                    case "noBreakHyphen": text = "-"
                    case "footnoteReference":
                        if let id = attr(item, "id") {
                            if !referencedFootnotes.contains(id) { referencedFootnotes.append(id) }
                            segments.append(.init(text: "[^\(id)]", bold: false, italic: false, strike: false,
                                                  code: false, link: nil, raw: true))
                        }
                    case "footnoteRef":
                        break // the number inside the footnote itself
                    case "sym":
                        if let code = attr(item, "char").flatMap({ UInt32($0, radix: 16) }),
                           let scalar = Unicode.Scalar(code >= 0xF000 ? code - 0xF000 : code) {
                            text = String(Character(scalar))
                        }
                    case "instrText":
                        let instr = item.stringValue ?? ""
                        if let r = instr.range(of: #"HYPERLINK\s+"([^"]+)""#, options: .regularExpression) {
                            let inner = instr[r]
                            if let q1 = inner.firstIndex(of: "\""), let q2 = inner.lastIndex(of: "\""), q1 < q2 {
                                field.link = String(inner[inner.index(after: q1)..<q2])
                            }
                        }
                    case "fldChar":
                        switch attr(item, "fldCharType") {
                        case "begin": field.inInstruction = true; field.link = nil
                        case "separate": field.inInstruction = false
                        case "end": field.inInstruction = false; field.link = nil
                        default: break
                        }
                    default:
                        break
                    }
                    guard let t = text, !t.isEmpty else { continue }
                    if let size = props.size, !t.trimmingCharacters(in: .whitespaces).isEmpty {
                        maxSize = max(maxSize, size)
                    }
                    segments.append(.init(text: t, bold: props.bold ?? false, italic: props.italic ?? false,
                                          strike: props.strike ?? false, code: props.mono ?? false,
                                          link: effectiveLink, revision: field.revision))
                }

            case "hyperlink":
                var target: String?
                if let rid = attr(node, "id"), let t = relationships[rid] { target = t }
                if let anchor = attr(node, "anchor") { target = (target ?? "") + "#" + anchor }
                collectRuns(node, base: base, link: target ?? link, field: &field, into: &segments, maxSize: &maxSize)

            case "ins", "moveTo", "del", "moveFrom":
                let isDeletion = node.localName == "del" || node.localName == "moveFrom"
                if isDeletion && revisions == .accept { break }
                let saved = field.revision
                if revisions == .markup { field.revision = isDeletion ? .delete : .insert }
                collectRuns(node, base: base, link: link, field: &field, into: &segments, maxSize: &maxSize)
                field.revision = saved

            case "commentRangeStart":
                if revisions == .markup, let id = attr(node, "id"), comments[id] != nil { field.commentStarts[id] = segments.count }

            case "commentRangeEnd":
                // Highlight the commented text when the range lies inside this paragraph
                if let id = attr(node, "id"), let start = field.commentStarts[id], start < segments.count {
                    segments.insert(.init(text: "{==", bold: false, italic: false, strike: false, code: false, link: nil, raw: true), at: start)
                    segments.append(.init(text: "==}", bold: false, italic: false, strike: false, code: false, link: nil, raw: true))
                    for (other, index) in field.commentStarts where index > start { field.commentStarts[other] = index + 1 }
                    field.commentStarts[id] = nil
                }

            case "smartTag", "customXml", "fldSimple", "dir", "bdo":
                var nestedLink = link
                if node.localName == "fldSimple", let instr = attr(node, "instr"),
                   let r = instr.range(of: #"HYPERLINK\s+"([^"]+)""#, options: .regularExpression) {
                    nestedLink = instr[r].components(separatedBy: "\"").dropFirst().first
                }
                collectRuns(node, base: base, link: nestedLink, field: &field, into: &segments, maxSize: &maxSize)

            case "sdt":
                if let content = child(node, "sdtContent") {
                    collectRuns(content, base: base, link: link, field: &field, into: &segments, maxSize: &maxSize)
                }

            default:
                break // deleted text, bookmarks, proofing marks, drawings…
            }
        }
    }

    private func runProps(_ rPr: XMLElement) -> RunProps {
        var p = RunProps()
        if let b = child(rPr, "b") { p.bold = toggle(b) }
        if let i = child(rPr, "i") { p.italic = toggle(i) }
        if let s = child(rPr, "strike") { p.strike = toggle(s) }
        if let s = child(rPr, "dstrike"), toggle(s) { p.strike = true }
        if let fonts = child(rPr, "rFonts"), let name = attr(fonts, "ascii") ?? attr(fonts, "hAnsi") {
            let lower = name.lowercased()
            p.mono = ["courier", "consolas", "menlo", "monaco", "mono", "lucida console", "andale"].contains { lower.contains($0) }
        }
        if let sz = child(rPr, "sz").flatMap({ attr($0, "val") }).flatMap(Int.init) { p.size = sz }
        return p
    }

    private func toggle(_ el: XMLElement) -> Bool {
        guard let v = attr(el, "val")?.lowercased() else { return true }
        return !(v == "0" || v == "false" || v == "off" || v == "none")
    }

    // MARK: - Tables

    private mutating func tableMarkdown(_ tbl: XMLElement) -> String? {
        var rows: [[String]] = []
        for tr in children(tbl, "tr") {
            var row: [String] = []
            for tc in children(tr, "tc") {
                var cellParas: [String] = []
                for case let el as XMLElement in tc.children ?? [] {
                    if el.localName == "p" {
                        var segs: [AttributedToMarkdown.Segment] = []
                        var maxSize = 0
                        let styleId = child(el, "pPr").flatMap { child($0, "pStyle") }.flatMap { attr($0, "val") }
                        collectRuns(el, base: styleRunProps(styleId), link: nil, into: &segs, maxSize: &maxSize)
                        let md = AttributedToMarkdown.inline(from: segs).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !md.isEmpty { cellParas.append(md) }
                    } else if el.localName == "tbl", let nested = tableMarkdown(el) {
                        cellParas.append(nested.replacingOccurrences(of: "\n", with: " "))
                    }
                }
                let text = cellParas.joined(separator: " ")
                    .replacingOccurrences(of: "  \n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
                row.append(text)
                let span = child(tc, "tcPr").flatMap { child($0, "gridSpan") }.flatMap { attr($0, "val") }.flatMap(Int.init) ?? 1
                if span > 1 { row += Array(repeating: "", count: span - 1) }
            }
            rows.append(row)
        }
        guard !rows.isEmpty else { return nil }
        let cols = rows.map(\.count).max() ?? 0
        guard cols > 0 else { return nil }

        // Header cells are bold in Markdown output anyway
        var header = rows[0].map { cell -> String in
            var c = cell
            if c.hasPrefix("**") && c.hasSuffix("**") && c.count > 4 { c = String(c.dropFirst(2).dropLast(2)) }
            return c
        }
        header += Array(repeating: "", count: cols - header.count)
        var lines = ["| " + header.joined(separator: " | ") + " |",
                     "|" + Array(repeating: " --- |", count: cols).joined()]
        for row in rows.dropFirst() {
            let padded = row + Array(repeating: "", count: cols - row.count)
            lines.append("| " + padded.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - XML helpers

    /// XMLDocument drops text nodes that contain only whitespace (even with `.nodePreserveWhitespace`),
    /// which loses spaces Word keeps in separate runs. They are swapped for private-use characters first.
    static func protectWhitespace(_ data: Data) -> Data {
        let xml = String(decoding: data, as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: #"(<w:(?:t|delText)\b[^>]*>)([ \t]+)(</w:(?:t|delText)>)"#) else { return data }
        let ns = xml as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range(at: 2).location - last))
            out += ns.substring(with: m.range(at: 2)).replacingOccurrences(of: " ", with: "\u{E020}").replacingOccurrences(of: "\t", with: "\u{E009}")
            last = NSMaxRange(m.range(at: 2))
        }
        guard last > 0 else { return data }
        out += ns.substring(from: last)
        return Data(out.utf8)
    }

    static func restoreWhitespace(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value == 0xE020 || $0.value == 0xE009 }) else { return s }
        return s.replacingOccurrences(of: "\u{E020}", with: " ").replacingOccurrences(of: "\u{E009}", with: "\t")
    }

    private func child(_ el: XMLElement, _ name: String) -> XMLElement? {
        for case let c as XMLElement in el.children ?? [] where c.localName == name { return c }
        return nil
    }

    private func children(_ el: XMLElement, _ name: String) -> [XMLElement] {
        (el.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
    }

    private func attr(_ el: XMLElement, _ name: String) -> String? {
        for a in el.attributes ?? [] where a.localName == name { return a.stringValue }
        return nil
    }
}
