import Foundation

/// A Word document or template (.docx / .dotx) whose styles, theme, page setup, headers and footers
/// are used for DOCX export (like Pandoc's `--reference-doc`).
public struct DocxTemplate {
    /// Complete `word/styles.xml` of the template.
    let stylesXML: String
    /// Lowercased style name → style id (localized Word versions use localized ids, e.g. "Cmsor1").
    let styleIDsByName: [String: String]
    let styleIDs: Set<String>
    /// Opening tag and children of `word/numbering.xml`, kept so styles that use numbering keep working.
    let numberingRoot: String?
    let numPicBullets: [String]
    let abstractNums: [String]
    let nums: [String]
    let maxAbstractID: Int
    let maxNumID: Int
    /// Body-level section properties with relationship ids rewritten to `rIdT…`.
    let sectPr: String?
    /// Parts copied verbatim (headers, footers, their relationships and media, theme).
    let parts: [(path: String, data: Data)]
    /// Relationships of `word/document.xml` needed by the copied parts.
    let relationships: [(id: String, type: String, target: String)]
    /// Content type overrides (`/word/header1.xml` → type) and defaults (extension → type).
    let overrides: [(String, String)]
    let defaults: [(String, String)]
    /// Usable text width in twips (page width minus left and right margins).
    let textWidth: Int

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        let zip = try ZipReader(data: data)
        func text(_ path: String) throws -> String? {
            try zip.contents(of: path).map { String(decoding: $0, as: UTF8.self) }
        }
        guard let styles = try text("word/styles.xml") else { throw ZipError.corrupt("word/styles.xml") }
        stylesXML = styles

        var byName: [String: String] = [:]
        var ids: Set<String> = []
        if let doc = try? XMLDocument(xmlString: styles), let root = doc.rootElement() {
            for case let el as XMLElement in root.children ?? [] where el.localName == "style" {
                guard let id = Self.attr(el, "styleId") else { continue }
                ids.insert(id)
                let name = (el.children ?? []).compactMap { $0 as? XMLElement }.first { $0.localName == "name" }
                    .flatMap { Self.attr($0, "val") } ?? id
                if byName[name.lowercased()] == nil { byName[name.lowercased()] = id }
            }
        }
        styleIDsByName = byName
        styleIDs = ids

        // Numbering
        if let numbering = try text("word/numbering.xml"), let rootEnd = numbering.range(of: ">", range: (numbering.range(of: "<w:numbering")?.upperBound ?? numbering.startIndex)..<numbering.endIndex) {
            let start = numbering.range(of: "<w:numbering")!.lowerBound
            numberingRoot = String(numbering[start..<rootEnd.upperBound])
            numPicBullets = Self.matches(#"<w:numPicBullet\b[\s\S]*?</w:numPicBullet>"#, in: numbering)
            abstractNums = Self.matches(#"<w:abstractNum\b[\s\S]*?</w:abstractNum>"#, in: numbering)
            nums = Self.matches(#"<w:num\b[^>]*>[\s\S]*?</w:num>"#, in: numbering)
            maxAbstractID = abstractNums.compactMap { Self.firstGroup(#"w:abstractNumId="(\d+)""#, in: $0).flatMap(Int.init) }.max() ?? -1
            maxNumID = nums.compactMap { Self.firstGroup(#"w:numId="(\d+)""#, in: $0).flatMap(Int.init) }.max() ?? 0
        } else {
            numberingRoot = nil
            numPicBullets = []
            abstractNums = []
            nums = []
            maxAbstractID = -1
            maxNumID = 0
        }

        // Relationships of the main document
        var docRels: [String: (type: String, target: String)] = [:]
        if let rels = try text("word/_rels/document.xml.rels") {
            for rel in Self.matches(#"<Relationship\b[^>]*/>"#, in: rels) {
                guard let id = Self.firstGroup(#"Id="([^"]+)""#, in: rel),
                      let type = Self.firstGroup(#"Type="([^"]+)""#, in: rel),
                      let target = Self.firstGroup(#"Target="([^"]+)""#, in: rel) else { continue }
                if rel.contains("TargetMode=\"External\"") { continue }
                docRels[id] = (type, target)
            }
        }

        var copied: [(String, Data)] = []
        var rels: [(String, String, String)] = []
        func copyPart(_ target: String) throws {
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "word/" + target
            guard !copied.contains(where: { $0.0 == path }), let data = try zip.contents(of: path) else { return }
            copied.append((path, data))
            // The part's own relationships and the media they point to
            let dir = (path as NSString).deletingLastPathComponent
            let relsPath = dir + "/_rels/" + (path as NSString).lastPathComponent + ".rels"
            if let relsData = try zip.contents(of: relsPath) {
                copied.append((relsPath, relsData))
                let relsText = String(decoding: relsData, as: UTF8.self)
                for rel in Self.matches(#"<Relationship\b[^>]*/>"#, in: relsText) where !rel.contains("TargetMode=\"External\"") {
                    if let t = Self.firstGroup(#"Target="([^"]+)""#, in: rel) {
                        let mediaPath = t.hasPrefix("/") ? String(t.dropFirst()) : (dir + "/" + t)
                        let normalized = (mediaPath as NSString).standardizingPath
                        if !copied.contains(where: { $0.0 == normalized }), let media = try zip.contents(of: normalized) {
                            copied.append((normalized, media))
                        }
                    }
                }
            }
        }

        // Theme
        if let theme = docRels.first(where: { $0.value.type.hasSuffix("/theme") }) {
            try copyPart(theme.value.target)
            rels.append(("rIdT0", theme.value.type, theme.value.target))
        }

        // Section properties (the last sectPr of the body) with headers and footers
        var sect: String?
        if let document = try text("word/document.xml"), let start = document.range(of: "<w:sectPr", options: .backwards),
           let end = document.range(of: "</w:sectPr>", range: start.upperBound..<document.endIndex) {
            var s = String(document[start.lowerBound..<end.upperBound])
            var counter = 1
            for ref in Self.matches(#"<w:(?:header|footer)Reference\b[^>]*/>"#, in: s) {
                guard let rid = Self.firstGroup(#"r:id="([^"]+)""#, in: ref), let rel = docRels[rid] else {
                    s = s.replacingOccurrences(of: ref, with: "")
                    continue
                }
                let newID = "rIdT\(counter)"
                counter += 1
                try copyPart(rel.target)
                rels.append((newID, rel.type, rel.target))
                s = s.replacingOccurrences(of: ref, with: ref.replacingOccurrences(of: "r:id=\"\(rid)\"", with: "r:id=\"\(newID)\""))
            }
            sect = s
        }
        sectPr = sect
        parts = copied
        relationships = rels

        // Content types for the copied parts
        var overrides: [(String, String)] = []
        var defaults: [(String, String)] = []
        if let types = try text("[Content_Types].xml") {
            for d in Self.matches(#"<Default\b[^>]*/>"#, in: types) {
                if let ext = Self.firstGroup(#"Extension="([^"]+)""#, in: d), let ct = Self.firstGroup(#"ContentType="([^"]+)""#, in: d) {
                    defaults.append((ext.lowercased(), ct))
                }
            }
            for o in Self.matches(#"<Override\b[^>]*/>"#, in: types) {
                if let part = Self.firstGroup(#"PartName="([^"]+)""#, in: o), let ct = Self.firstGroup(#"ContentType="([^"]+)""#, in: o),
                   copied.contains(where: { "/" + $0.0 == part }) {
                    overrides.append((part, ct))
                }
            }
        }
        self.overrides = overrides
        self.defaults = defaults

        // Text width from the page size and margins
        var width = 9638
        if let sect, let w = Self.firstGroup(#"<w:pgSz\b[^>]*w:w="(\d+)""#, in: sect).flatMap(Int.init) {
            let left = Self.firstGroup(#"<w:pgMar\b[^>]*w:left="(\d+)""#, in: sect).flatMap(Int.init) ?? 1134
            let right = Self.firstGroup(#"<w:pgMar\b[^>]*w:right="(\d+)""#, in: sect).flatMap(Int.init) ?? 1134
            width = max(2000, w - left - right)
        }
        textWidth = width
    }

    // MARK: Helpers

    static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func firstGroup(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return (s as NSString).substring(with: m.range(at: 1))
    }

    private static func attr(_ el: XMLElement, _ name: String) -> String? {
        for a in el.attributes ?? [] where a.localName == name { return a.stringValue }
        return nil
    }
}
