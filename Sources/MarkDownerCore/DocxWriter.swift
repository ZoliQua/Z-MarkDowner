import Foundation

/// Image data that can be embedded into a DOCX file.
public struct DocxImage {
    public var data: Data
    /// File extension: "png", "jpeg" or "gif".
    public var fileExtension: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(data: Data, fileExtension: String, pixelWidth: Int, pixelHeight: Int) {
        self.data = data
        self.fileExtension = fileExtension
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Converts a Markdown document into a Word (.docx) package with real Word styles.
public struct DocxWriter {
    public var title: String
    /// Resolves an image URL from the Markdown source into embeddable data.
    public var imageLoader: ((String) -> DocxImage?)?

    private var relationships: [(id: String, type: String, target: String, external: Bool)] = []
    private var nums: [(numId: Int, abstractId: Int, level: Int, start: Int?)] = []
    private var media: [(name: String, data: Data)] = []
    private var drawingCounter = 0

    private static let relHyperlink = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
    private static let relImage = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"

    // Abstract numbering definitions
    private static let bulletAbstract = 0
    private static let orderedAbstract = 1

    /// Usable text width for A4 with 2 cm margins, in EMU.
    private static let maxImageWidthEMU = 6_120_000

    public init(title: String = "Document", imageLoader: ((String) -> DocxImage?)? = nil) {
        self.title = title
        self.imageLoader = imageLoader
    }

    public mutating func makeDocx(markdown: String) -> Data {
        makeDocx(blocks: MDDocument(markdown: markdown).blocks)
    }

    public mutating func makeDocx(blocks: [MDBlock]) -> Data {
        relationships = []
        nums = []
        media = []
        drawingCounter = 0

        var body = ""
        let ctx = Context()
        for block in blocks {
            body += render(block, ctx)
        }
        if body.isEmpty { body = "<w:p/>" }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>\
        <w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="567" w:footer="567" w:gutter="0"/>\
        </w:sectPr></w:body></w:document>
        """

        var zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", string: contentTypes())
        zip.add(path: "_rels/.rels", string: rootRels)
        zip.add(path: "docProps/core.xml", string: coreProps())
        zip.add(path: "docProps/app.xml", string: appProps)
        zip.add(path: "word/document.xml", string: document)
        zip.add(path: "word/styles.xml", string: DocxWriter.styles)
        zip.add(path: "word/numbering.xml", string: numbering())
        zip.add(path: "word/settings.xml", string: DocxWriter.settings)
        zip.add(path: "word/_rels/document.xml.rels", string: documentRels())
        for m in media {
            zip.add(path: "word/media/\(m.name)", data: m.data)
        }
        return zip.finish()
    }

    // MARK: - Block rendering

    private struct Context {
        var quoteDepth = 0
        var listLevel = -1
        var numId: Int?
        var isFirstInItem = false
        var taskPrefix: String?
    }

    private mutating func render(_ block: MDBlock, _ ctx: Context) -> String {
        switch block {
        case .heading(let level, let content):
            return paragraph(style: "Heading\(level)", ctx: ctx, runs: runs(content, RunStyle()))

        case .paragraph(let content):
            var r = ""
            if let prefix = ctx.taskPrefix, ctx.isFirstInItem {
                r += textRun(prefix, RunStyle())
            }
            r += runs(content, RunStyle())
            return paragraph(style: nil, ctx: ctx, runs: r)

        case .codeBlock(_, let code):
            let lines = code.components(separatedBy: "\n")
            var r = ""
            for (idx, line) in lines.enumerated() {
                if idx > 0 { r += "<w:r><w:br/></w:r>" }
                if !line.isEmpty {
                    r += "<w:r><w:rPr><w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>"
                        + "<w:sz w:val=\"19\"/></w:rPr><w:t xml:space=\"preserve\">\(xml(line))</w:t></w:r>"
                }
            }
            return paragraph(style: "CodeBlock", ctx: ctx, runs: r)

        case .blockquote(let blocks):
            var inner = ctx
            inner.quoteDepth += 1
            return blocks.map { render($0, inner) }.joined()

        case .list(let list):
            let level = min(ctx.listLevel + 1, 8)
            let numId = nums.count + 1
            nums.append((numId, list.ordered ? DocxWriter.orderedAbstract : DocxWriter.bulletAbstract,
                         level, list.ordered ? list.start : nil))
            var out = ""
            for item in list.items {
                var itemCtx = ctx
                itemCtx.listLevel = level
                itemCtx.numId = numId
                itemCtx.taskPrefix = item.checked.map { $0 ? "☒ " : "☐ " }
                if item.blocks.isEmpty {
                    itemCtx.isFirstInItem = true
                    out += paragraph(style: nil, ctx: itemCtx, runs: itemCtx.taskPrefix.map { textRun($0, RunStyle()) } ?? "")
                    continue
                }
                for (idx, b) in item.blocks.enumerated() {
                    itemCtx.isFirstInItem = idx == 0
                    if case .list = b {
                        var nested = itemCtx
                        nested.taskPrefix = nil
                        out += render(b, nested)
                    } else {
                        out += render(b, itemCtx)
                    }
                }
            }
            return out

        case .table(let table):
            return renderTable(table, ctx)

        case .horizontalRule:
            return "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"AAAAAA\"/></w:pBdr></w:pPr></w:p>"
        }
    }

    private func paragraph(style: String?, ctx: Context, runs: String) -> String {
        var ppr = ""
        var styleName = style
        if styleName == nil {
            if ctx.quoteDepth > 0 { styleName = "Quote" }
            else if ctx.listLevel >= 0 { styleName = "ListParagraph" }
        }
        if let s = styleName { ppr += "<w:pStyle w:val=\"\(s)\"/>" }
        if ctx.listLevel >= 0, let numId = ctx.numId {
            if ctx.isFirstInItem {
                ppr += "<w:numPr><w:ilvl w:val=\"\(ctx.listLevel)\"/><w:numId w:val=\"\(numId)\"/></w:numPr>"
            }
        }
        var indent = 0
        if ctx.listLevel >= 0 { indent += 720 * (ctx.listLevel + 1) }
        if ctx.quoteDepth > 0 { indent += 567 * ctx.quoteDepth }
        if indent > 0 && (ctx.quoteDepth > 0 || !ctx.isFirstInItem || style != nil) {
            ppr += "<w:ind w:left=\"\(indent)\"/>"
        }
        if ctx.listLevel >= 0 && style == nil {
            ppr += "<w:contextualSpacing/>"
        }
        let pPr = ppr.isEmpty ? "" : "<w:pPr>\(ppr)</w:pPr>"
        return "<w:p>\(pPr)\(runs)</w:p>"
    }

    private mutating func renderTable(_ table: MDTable, _ ctx: Context) -> String {
        let cols = max(1, table.header.count)
        let totalWidth = 9638 // twips, A4 minus 2 cm margins
        let colWidth = totalWidth / cols
        var out = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"5000\" w:type=\"pct\"/>"
        // Direct borders as well, for readers that ignore table styles (Quick Look, TextEdit)
        out += "<w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map {
            "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\"/>"
        }.joined() + "</w:tblBorders>"
        if ctx.listLevel >= 0 || ctx.quoteDepth > 0 {
            let indent = 720 * (ctx.listLevel + 1) + 567 * ctx.quoteDepth
            out += "<w:tblInd w:w=\"\(indent)\" w:type=\"dxa\"/>"
        }
        out += "<w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/></w:tblPr><w:tblGrid>"
        for _ in 0..<cols { out += "<w:gridCol w:w=\"\(colWidth)\"/>" }
        out += "</w:tblGrid>"

        func cell(_ content: [MDInline], col: Int, header: Bool, writer: inout DocxWriter) -> String {
            var jc = ""
            if col < table.alignments.count {
                switch table.alignments[col] {
                case .center: jc = "<w:jc w:val=\"center\"/>"
                case .right: jc = "<w:jc w:val=\"right\"/>"
                default: break
                }
            }
            var style = RunStyle()
            style.bold = header
            let shade = header ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"EEEEEE\"/>" : ""
            return "<w:tc><w:tcPr><w:tcW w:w=\"\(colWidth)\" w:type=\"dxa\"/>\(shade)</w:tcPr>"
                + "<w:p><w:pPr><w:pStyle w:val=\"TableText\"/>\(jc)</w:pPr>\(writer.runs(content, style))</w:p></w:tc>"
        }

        out += "<w:tr><w:trPr><w:tblHeader/></w:trPr>"
        for (c, content) in table.header.enumerated() {
            out += cell(content, col: c, header: true, writer: &self)
        }
        out += "</w:tr>"
        for row in table.rows {
            out += "<w:tr>"
            for c in 0..<cols {
                out += cell(c < row.count ? row[c] : [], col: c, header: false, writer: &self)
            }
            out += "</w:tr>"
        }
        out += "</w:tbl>"
        // Word requires a paragraph between consecutive tables; also gives spacing after the table
        out += "<w:p><w:pPr><w:spacing w:after=\"0\"/></w:pPr></w:p>"
        return out
    }

    // MARK: - Inline rendering

    private struct RunStyle {
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var hyperlink = false
    }

    private mutating func runs(_ inlines: [MDInline], _ style: RunStyle) -> String {
        var out = ""
        for node in inlines {
            switch node {
            case .text(let s):
                out += textRun(s, style)
            case .emphasis(let c):
                var s = style; s.italic = true
                out += runs(c, s)
            case .strong(let c):
                var s = style; s.bold = true
                out += runs(c, s)
            case .strikethrough(let c):
                var s = style; s.strike = true
                out += runs(c, s)
            case .code(let code):
                var s = style; s.code = true
                out += textRun(code, s)
            case .link(let text, let url, _):
                if url.hasPrefix("#") {
                    let anchor = String(url.dropFirst())
                    var s = style; s.hyperlink = true
                    out += "<w:hyperlink w:anchor=\"\(xml(anchor))\">\(runs(text, s))</w:hyperlink>"
                } else {
                    let rid = addRelationship(type: DocxWriter.relHyperlink, target: url, external: true)
                    var s = style; s.hyperlink = true
                    out += "<w:hyperlink r:id=\"\(rid)\" w:history=\"1\">\(runs(text, s))</w:hyperlink>"
                }
            case .image(let alt, let url, _):
                if let image = imageLoader?(url), image.pixelWidth > 0, image.pixelHeight > 0 {
                    out += drawing(image, alt: alt)
                } else {
                    var s = style; s.italic = true
                    out += textRun("[\(alt.isEmpty ? "image" : alt)]", s)
                }
            case .lineBreak:
                out += "<w:r><w:br/></w:r>"
            case .softBreak:
                out += textRun(" ", style)
            }
        }
        return out
    }

    private func textRun(_ text: String, _ style: RunStyle) -> String {
        guard !text.isEmpty else { return "" }
        var rpr = ""
        if style.hyperlink { rpr += "<w:rStyle w:val=\"Hyperlink\"/>" }
        else if style.code { rpr += "<w:rStyle w:val=\"InlineCode\"/>" }
        if style.code {
            rpr += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>"
        }
        if style.bold { rpr += "<w:b/><w:bCs/>" }
        if style.italic { rpr += "<w:i/><w:iCs/>" }
        if style.strike { rpr += "<w:strike/>" }
        let rPr = rpr.isEmpty ? "" : "<w:rPr>\(rpr)</w:rPr>"
        return "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(xml(text))</w:t></w:r>"
    }

    private mutating func drawing(_ image: DocxImage, alt: String) -> String {
        drawingCounter += 1
        let n = drawingCounter
        let ext = image.fileExtension == "jpg" ? "jpeg" : image.fileExtension
        let name = "image\(n).\(ext)"
        media.append((name, image.data))
        let rid = addRelationship(type: DocxWriter.relImage, target: "media/\(name)", external: false)

        // 96 dpi pixels to EMU
        var cx = image.pixelWidth * 9525
        var cy = image.pixelHeight * 9525
        if cx > DocxWriter.maxImageWidthEMU {
            cy = Int(Double(cy) * Double(DocxWriter.maxImageWidthEMU) / Double(cx))
            cx = DocxWriter.maxImageWidthEMU
        }
        return """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:docPr id="\(n)" name="Picture \(n)" descr="\(xml(alt))"/><wp:cNvGraphicFramePr>\
        <a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic>\
        <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
        <pic:nvPicPr><pic:cNvPr id="\(n)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>\
        </wp:inline></w:drawing></w:r>
        """
    }

    private mutating func addRelationship(type: String, target: String, external: Bool) -> String {
        let id = "rId\(relationships.count + 10)"
        relationships.append((id, type, target, external))
        return id
    }

    // MARK: - Package parts

    private func contentTypes() -> String {
        var defaults = """
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>
        """
        let exts = Set(media.map { ($0.name as NSString).pathExtension.lowercased() })
        for ext in exts.sorted() {
            let mime = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : "image/jpeg"
            defaults += "<Default Extension=\"\(ext)\" ContentType=\"\(mime)\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\(defaults)\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
        <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
        </Types>
        """
    }

    private let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
    </Relationships>
    """

    private func documentRels() -> String {
        var rels = """
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
        """
        for r in relationships {
            let mode = r.external ? " TargetMode=\"External\"" : ""
            rels += "<Relationship Id=\"\(r.id)\" Type=\"\(r.type)\" Target=\"\(xml(r.target))\"\(mode)/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
    }

    private func coreProps() -> String {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(xml(title))</dc:title><dc:creator>Z-MarkDowner</dc:creator>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>\
        </cp:coreProperties>
        """
    }

    private let appProps = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
    xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Z-MarkDowner</Application></Properties>
    """

    private func numbering() -> String {
        let bulletChars = ["•", "◦", "▪"]
        var bulletLevels = ""
        var orderedLevels = ""
        let orderedFormats = ["decimal", "lowerLetter", "lowerRoman"]
        for lvl in 0..<9 {
            let left = 720 * (lvl + 1)
            let symbol = bulletChars[lvl % 3]
            bulletLevels += """
            <w:lvl w:ilvl="\(lvl)"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="\(symbol)"/>\
            <w:lvlJc w:val="left"/><w:pPr><w:ind w:left="\(left)" w:hanging="360"/></w:pPr>\
            <w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial" w:hint="default"/></w:rPr></w:lvl>
            """
            orderedLevels += """
            <w:lvl w:ilvl="\(lvl)"><w:start w:val="1"/><w:numFmt w:val="\(orderedFormats[lvl % 3])"/>\
            <w:lvlText w:val="%\(lvl + 1)."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="\(left)" w:hanging="360"/></w:pPr></w:lvl>
            """
        }
        var numsXML = ""
        for n in nums {
            numsXML += "<w:num w:numId=\"\(n.numId)\"><w:abstractNumId w:val=\"\(n.abstractId)\"/>"
            numsXML += "<w:lvlOverride w:ilvl=\"\(n.level)\"><w:startOverride w:val=\"\(n.start ?? 1)\"/></w:lvlOverride>"
            numsXML += "</w:num>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:abstractNum w:abstractNumId="\(DocxWriter.bulletAbstract)"><w:multiLevelType w:val="hybridMultilevel"/>\(bulletLevels)</w:abstractNum>\
        <w:abstractNum w:abstractNumId="\(DocxWriter.orderedAbstract)"><w:multiLevelType w:val="hybridMultilevel"/>\(orderedLevels)</w:abstractNum>\
        \(numsXML)</w:numbering>
        """
    }

    private static let settings = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:defaultTabStop w:val="708"/><w:characterSpacingControl w:val="doNotCompress"/>\
    <w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat>\
    </w:settings>
    """

    private static func headingStyle(_ level: Int, size: Int, color: String, italic: Bool = false) -> String {
        """
        <w:style w:type="paragraph" w:styleId="Heading\(level)"><w:name w:val="heading \(level)"/>\
        <w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>\
        <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="\(level <= 2 ? 360 : 240)" w:after="120"/>\
        <w:outlineLvl w:val="\(level - 1)"/></w:pPr>\
        <w:rPr><w:b/><w:bCs/>\(italic ? "<w:i/>" : "")<w:color w:val="\(color)"/><w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr></w:style>
        """
    }

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/>\
    <w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="hu-HU" w:eastAsia="en-US" w:bidi="ar-SA"/></w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
    \(headingStyle(1, size: 36, color: "1F2328"))\
    \(headingStyle(2, size: 30, color: "1F2328"))\
    \(headingStyle(3, size: 26, color: "1F2328"))\
    \(headingStyle(4, size: 24, color: "1F2328"))\
    \(headingStyle(5, size: 22, color: "1F2328"))\
    \(headingStyle(6, size: 22, color: "595959", italic: true))\
    <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="D0D7DE"/></w:pBdr><w:ind w:left="567"/></w:pPr>\
    <w:rPr><w:color w:val="59636E"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>\
    <w:qFormat/><w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/></w:pPr></w:style>\
    <w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/><w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F4F4F4"/><w:spacing w:after="160" w:line="240" w:lineRule="auto"/></w:pPr>\
    <w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="TableText"><w:name w:val="Table Text"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:spacing w:before="40" w:after="40" w:line="240" w:lineRule="auto"/></w:pPr></w:style>\
    <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/></w:style>\
    <w:style w:type="character" w:styleId="InlineCode"><w:name w:val="Inline Code"/>\
    <w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/><w:shd w:val="clear" w:color="auto" w:fill="EFEFEF"/></w:rPr></w:style>\
    <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>\
    <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:semiHidden/>\
    <w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/>\
    <w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
    <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/>\
    <w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="999999"/>\
    <w:left w:val="single" w:sz="4" w:space="0" w:color="999999"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="999999"/>\
    <w:right w:val="single" w:sz="4" w:space="0" w:color="999999"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="999999"/>\
    <w:insideV w:val="single" w:sz="4" w:space="0" w:color="999999"/></w:tblBorders></w:tblPr></w:style>\
    </w:styles>
    """

    // MARK: - XML escaping

    private func xml(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                let v = scalar.value
                // Drop characters that are not allowed in XML 1.0
                if v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v <= 0xD7FF)
                    || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000 {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
