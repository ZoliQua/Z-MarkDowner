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
    /// Optional pre-rendered math images keyed by TeX source (`display` = block math).
    public var mathImage: ((_ tex: String, _ display: Bool) -> DocxImage?)?
    /// Styles, page setup, headers and footers come from this Word document or template when set.
    public var template: DocxTemplate?
    /// Paper size in points (ignored when a template is used).
    public var paperSize = NSSize(width: 595.28, height: 841.89)
    /// Document language for spell checking in Word ("hu", "en-US"…); front matter `lang` wins.
    public var language = ""
    /// Author of tracked changes and comments written from CriticMarkup.
    public var reviewAuthor = ""

    private var relationships: [(id: String, type: String, target: String, external: Bool)] = []
    private var nums: [(numId: Int, abstractId: Int, level: Int, start: Int?)] = []
    private var media: [(name: String, data: Data)] = []
    private var drawingCounter = 0
    private var footnoteDefinitions: [String: MDFootnote] = [:]
    private var footnoteNumbers: [String: Int] = [:]
    private var footnoteBodies: [(Int, String)] = []
    private var frontMatter: [String: String] = [:]
    private var annotationID = 0
    private var bookmarkNames: [String: String] = [:]
    private var comments: [(id: Int, text: String)] = []
    private var hasTOC = false
    private var textWidth = 9638
    private var numOffset = 0
    private var bulletAbstract = 0
    private var orderedAbstract = 1
    private var revisionDate = ""

    private static let relHyperlink = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
    private static let relImage = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"

    private static let relComments = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"

    /// Usable text width in EMU (1 twip = 635 EMU).
    private var maxImageWidthEMU: Int { textWidth * 635 }

    public init(title: String = "Document", imageLoader: ((String) -> DocxImage?)? = nil) {
        self.title = title
        self.imageLoader = imageLoader
    }

    public mutating func makeDocx(markdown: String) -> Data {
        makeDocx(document: MDDocument(markdown: markdown))
    }

    public mutating func makeDocx(blocks: [MDBlock]) -> Data {
        makeDocx(document: MDDocument(blocks: blocks))
    }

    public mutating func makeDocx(document: MDDocument) -> Data {
        relationships = []
        nums = []
        media = []
        drawingCounter = 0
        footnoteNumbers = [:]
        footnoteBodies = []
        footnoteDefinitions = Dictionary(document.footnotes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        frontMatter = document.frontMatter
        annotationID = 0
        bookmarkNames = [:]
        comments = []
        hasTOC = false
        revisionDate = ISO8601DateFormatter().string(from: Date())
        let pageWidth = Int((paperSize.width * 20).rounded())
        let pageHeight = Int((paperSize.height * 20).rounded())
        textWidth = template?.textWidth ?? (pageWidth - 2 * 1134)
        numOffset = template?.maxNumID ?? 0
        bulletAbstract = (template?.maxAbstractID ?? -1) + 1
        orderedAbstract = bulletAbstract + 1

        var body = frontMatterParagraphs()
        let ctx = Context()
        for block in document.blocks {
            body += render(block, ctx)
        }
        if body.isEmpty { body = "<w:p/>" }

        let sectPr = template?.sectPr ?? """
        <w:sectPr><w:pgSz w:w="\(pageWidth)" w:h="\(pageHeight)"/>\
        <w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="567" w:footer="567" w:gutter="0"/>\
        </w:sectPr>
        """
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(DocxWriter.namespaces) mc:Ignorable="w14 w15 wp14">
        <w:body>\(body)\(sectPr)</w:body></w:document>
        """
        let footnotes = footnotesXML()
        let (stylesXML, styleMap) = makeStyles()

        var zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", string: contentTypes())
        zip.add(path: "_rels/.rels", string: rootRels)
        zip.add(path: "docProps/core.xml", string: coreProps())
        zip.add(path: "docProps/app.xml", string: appProps)
        zip.add(path: "word/document.xml", string: Self.mapStyles(documentXML, styleMap))
        zip.add(path: "word/styles.xml", string: stylesXML)
        zip.add(path: "word/numbering.xml", string: numbering())
        zip.add(path: "word/settings.xml", string: settings())
        zip.add(path: "word/footnotes.xml", string: Self.mapStyles(footnotes, styleMap))
        if !comments.isEmpty {
            zip.add(path: "word/comments.xml", string: Self.mapStyles(commentsXML(), styleMap))
        }
        zip.add(path: "word/_rels/document.xml.rels", string: documentRels())
        // Footnotes may contain links and images, so they get the same relationships
        zip.add(path: "word/_rels/footnotes.xml.rels", string: documentRels(forFootnotes: true))
        for m in media {
            zip.add(path: "word/media/\(m.name)", data: m.data)
        }
        for part in template?.parts ?? [] {
            zip.add(path: part.path, data: part.data)
        }
        return zip.finish()
    }

    static let namespaces = """
    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" \
    xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
    xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" \
    xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml" \
    xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing" \
    xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" \
    xmlns:w10="urn:schemas-microsoft-com:office:word" \
    xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"
    """

    // MARK: - Bookmarks and annotations

    private mutating func nextID() -> Int {
        annotationID += 1
        return annotationID
    }

    /// Word bookmark name for an anchor (letters, digits and underscores, at most 40 characters).
    private mutating func bookmarkName(_ anchor: String) -> String {
        if let existing = bookmarkNames[anchor] { return existing }
        var name = String(anchor.map { ($0.isLetter || $0.isNumber) && $0.isASCII ? $0 : "_" })
        if let first = name.first, !first.isLetter { name = "a" + name }
        if name.isEmpty { name = "a" }
        name = String(name.prefix(36))
        var candidate = name
        var n = 2
        let used = Set(bookmarkNames.values)
        while used.contains(candidate) { candidate = name + "_\(n)"; n += 1 }
        bookmarkNames[anchor] = candidate
        return candidate
    }

    /// Wraps runs in a bookmark so `#anchor` links and cross-references can point at them.
    private mutating func bookmarked(_ anchor: String?, _ runs: String) -> String {
        guard let anchor, !anchor.isEmpty else { return runs }
        let id = nextID()
        return "<w:bookmarkStart w:id=\"\(id)\" w:name=\"\(xml(bookmarkName(anchor)))\"/>\(runs)<w:bookmarkEnd w:id=\"\(id)\"/>"
    }

    // MARK: - Block rendering

    private struct Context {
        var quoteDepth = 0
        var listLevel = -1
        var numId: Int?
        var isFirstInItem = false
        var taskPrefix: String?
        var paragraphStyle: String?
    }

    private func frontMatterParagraphs() -> String {
        var out = ""
        if let title = frontMatter["title"], !title.isEmpty {
            out += "<w:p><w:pPr><w:pStyle w:val=\"Title\"/></w:pPr>\(textRun(title, RunStyle()))</w:p>"
        }
        if let subtitle = frontMatter["subtitle"], !subtitle.isEmpty {
            out += "<w:p><w:pPr><w:pStyle w:val=\"Subtitle\"/></w:pPr>\(textRun(subtitle, RunStyle()))</w:p>"
        }
        let meta = [frontMatter["author"], frontMatter["date"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if !meta.isEmpty {
            out += "<w:p><w:pPr><w:pStyle w:val=\"DocMeta\"/></w:pPr>\(textRun(meta, RunStyle()))</w:p>"
        }
        return out
    }

    private mutating func render(_ block: MDBlock, _ ctx: Context) -> String {
        switch block {
        case .heading(let level, let content, let id):
            let anchor = id ?? HTMLRenderer.slug(content.plainText)
            return paragraph(style: "Heading\(level)", ctx: ctx, runs: bookmarked(anchor, runs(content, RunStyle())))

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
            let numId = numOffset + nums.count + 1
            nums.append((numId, list.ordered ? orderedAbstract : bulletAbstract,
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

        case .mathBlock(let tex):
            return "<w:p><w:pPr><w:pStyle w:val=\"MathBlock\"/></w:pPr>\(mathRuns(tex))</w:p>"

        case .horizontalRule:
            return "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"AAAAAA\"/></w:pBdr></w:pPr></w:p>"

        case .figure(let figure):
            return renderFigure(figure, ctx)

        case .tableOfContents(let title, let entries):
            return tableOfContents(title: title, entries: entries)

        case .bibliography(let items):
            return items.map { item -> String in
                var r = ""
                if let label = item.label { r += textRun(label, RunStyle()) + "<w:r><w:tab/></w:r>" }
                r += runs(item.content, RunStyle())
                let style = item.label == nil ? "Bibliography" : "BibliographyNumbered"
                return "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>\(bookmarked(item.anchor, r))</w:p>"
            }.joined()
        }
    }

    private mutating func mathRuns(_ tex: String) -> String {
        if let image = mathImage?(tex, true) { return drawing(image, alt: tex) }
        var style = RunStyle(); style.math = true
        return textRun(tex, style)
    }

    private mutating func caption(_ figure: MDFigure, keepNext: Bool) -> String {
        guard !figure.caption.isEmpty || figure.label != nil else { return "" }
        var r = ""
        if let label = figure.label {
            var bold = RunStyle(); bold.bold = true
            r += textRun(label + (figure.caption.isEmpty ? "" : ": "), bold)
        }
        r += runs(figure.caption, RunStyle())
        let keep = keepNext ? "<w:keepNext/>" : ""
        return "<w:p><w:pPr><w:pStyle w:val=\"Caption\"/>\(keep)</w:pPr>\(bookmarked(figure.id, r))</w:p>"
    }

    private mutating func renderFigure(_ figure: MDFigure, _ ctx: Context) -> String {
        switch figure.kind {
        case .figure:
            var content = ""
            if case .paragraph(let inlines) = figure.content {
                content = "<w:p><w:pPr><w:keepNext/><w:jc w:val=\"center\"/></w:pPr>\(runs(inlines, RunStyle()))</w:p>"
            } else {
                content = render(figure.content, ctx)
            }
            return content + caption(figure, keepNext: false)
        case .table:
            return caption(figure, keepNext: true) + render(figure.content, ctx)
        case .equation:
            guard case .mathBlock(let tex) = figure.content else { return render(figure.content, ctx) }
            // Centered formula with the number at the right margin
            let tabs = "<w:tabs><w:tab w:val=\"center\" w:pos=\"\(textWidth / 2)\"/><w:tab w:val=\"right\" w:pos=\"\(textWidth)\"/></w:tabs>"
            var r = "<w:r><w:tab/></w:r>" + mathRuns(tex)
            if let label = figure.label { r += "<w:r><w:tab/></w:r>" + textRun(label, RunStyle()) }
            return "<w:p><w:pPr><w:pStyle w:val=\"MathBlock\"/>\(tabs)<w:jc w:val=\"left\"/></w:pPr>\(bookmarked(figure.id, r))</w:p>"
        }
    }

    /// A Word TOC field, pre-filled with the headings (page numbers appear after Word updates the field).
    private mutating func tableOfContents(title: String, entries: [MDTocEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        hasTOC = true
        var out = "<w:sdt><w:sdtPr><w:docPartObj><w:docPartGallery w:val=\"Table of Contents\"/><w:docPartUnique/></w:docPartObj></w:sdtPr><w:sdtContent>"
        if !title.isEmpty {
            out += "<w:p><w:pPr><w:pStyle w:val=\"TOCHeading\"/></w:pPr>\(textRun(title, RunStyle()))</w:p>"
        }
        let maxLevel = entries.map(\.level).max() ?? 3
        for (i, e) in entries.enumerated() {
            let level = min(max(e.level, 1), 9)
            var r = ""
            if i == 0 {
                r += "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>"
                    + "<w:r><w:instrText xml:space=\"preserve\"> TOC \\o \"1-\(min(maxLevel, 9))\" \\h \\z \\u </w:instrText></w:r>"
                    + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r>"
            }
            let mark = bookmarkName(e.anchor)
            r += "<w:hyperlink w:anchor=\"\(xml(mark))\" w:history=\"1\">\(textRun(e.text, RunStyle()))<w:r><w:tab/></w:r>"
                + "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\"> PAGEREF \(mark) \\h </w:instrText></w:r>"
                + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:hyperlink>"
            out += "<w:p><w:pPr><w:pStyle w:val=\"TOC\(level)\"/><w:tabs><w:tab w:val=\"right\" w:leader=\"dot\" w:pos=\"\(textWidth)\"/></w:tabs></w:pPr>\(r)</w:p>"
        }
        out += "<w:p><w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p>"
        return out + "</w:sdtContent></w:sdt>"
    }

    private func paragraph(style: String?, ctx: Context, runs: String) -> String {
        var ppr = ""
        var styleName = style
        if styleName == nil {
            if ctx.quoteDepth > 0 { styleName = "Quote" }
            else if ctx.listLevel >= 0 { styleName = "ListParagraph" }
            else { styleName = ctx.paragraphStyle }
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
        let totalWidth = textWidth
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
        var math = false
        var highlight = false
        /// Inside a tracked insertion or deletion (no hyperlinks or comments allowed there).
        var revision = false
        var deleted = false
    }

    private mutating func runs(_ inlines: [MDInline], _ style: RunStyle) -> String {
        var out = ""
        var index = 0
        while index < inlines.count {
            let node = inlines[index]
            index += 1
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
                if style.revision {
                    out += runs(text, style)
                } else if url.hasPrefix("#") {
                    let anchor = bookmarkName(String(url.dropFirst()))
                    var s = style; s.hyperlink = true
                    out += "<w:hyperlink w:anchor=\"\(xml(anchor))\" w:history=\"1\">\(runs(text, s))</w:hyperlink>"
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
            case .math(let tex):
                if let image = mathImage?(tex, false) {
                    out += drawing(image, alt: tex)
                } else {
                    var s = style; s.math = true
                    out += textRun(tex, s)
                }
            case .footnoteRef(let id):
                out += footnoteReference(id, style)
            case .citation(let c):
                out += textRun(c.raw, style)
            case .insertion(let c):
                var s = style; s.revision = true
                let inner = runs(c, s)
                if style.revision || inner.isEmpty { out += inner; break }
                out += "<w:ins w:id=\"\(nextID())\" w:author=\"\(xml(author))\" w:date=\"\(revisionDate)\">\(inner)</w:ins>"
            case .deletion(let c):
                var s = style; s.revision = true; s.deleted = true
                let inner = runs(c, s)
                if style.revision || inner.isEmpty { out += inner; break }
                out += "<w:del w:id=\"\(nextID())\" w:author=\"\(xml(author))\" w:date=\"\(revisionDate)\">\(inner)</w:del>"
            case .highlight(let c):
                var s = style; s.highlight = true
                // A comment directly after the highlight is anchored to the highlighted text
                if !style.revision, index < inlines.count, case .comment(let text) = inlines[index] {
                    index += 1
                    out += commented(text, runs(c, s))
                } else {
                    out += runs(c, s)
                }
            case .comment(let text):
                out += style.revision ? "" : commented(text, "")
            }
        }
        return out
    }

    private var author: String {
        if !reviewAuthor.isEmpty { return reviewAuthor }
        return frontMatter["author"].flatMap { $0.isEmpty ? nil : $0 } ?? "Z-MarkDowner"
    }

    /// A Word comment spanning `content` (which may be empty).
    private mutating func commented(_ text: String, _ content: String) -> String {
        let id = nextID()
        comments.append((id, text))
        return "<w:commentRangeStart w:id=\"\(id)\"/>\(content)<w:commentRangeEnd w:id=\"\(id)\"/>"
            + "<w:r><w:rPr><w:rStyle w:val=\"CommentReference\"/></w:rPr><w:commentReference w:id=\"\(id)\"/></w:r>"
    }

    private func commentsXML() -> String {
        let initials = author.split(separator: " ").compactMap { $0.first.map(String.init) }.joined().prefix(4)
        var body = ""
        for c in comments {
            let paragraphs = c.text.components(separatedBy: "\n").enumerated().map { idx, line -> String in
                let ref = idx == 0 ? "<w:r><w:rPr><w:rStyle w:val=\"CommentReference\"/></w:rPr><w:annotationRef/></w:r>" : ""
                return "<w:p><w:pPr><w:pStyle w:val=\"CommentText\"/></w:pPr>\(ref)\(textRun(line, RunStyle()))</w:p>"
            }.joined()
            body += "<w:comment w:id=\"\(c.id)\" w:author=\"\(xml(author))\" w:date=\"\(revisionDate)\" w:initials=\"\(xml(String(initials)))\">\(paragraphs)</w:comment>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:comments \(DocxWriter.namespaces)>\(body)</w:comments>
        """
    }

    private func textRun(_ text: String, _ style: RunStyle) -> String {
        guard !text.isEmpty else { return "" }
        var rpr = ""
        if style.hyperlink { rpr += "<w:rStyle w:val=\"Hyperlink\"/>" }
        else if style.code { rpr += "<w:rStyle w:val=\"InlineCode\"/>" }
        if style.code {
            rpr += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>"
        }
        if style.math {
            rpr += "<w:rFonts w:ascii=\"Cambria Math\" w:hAnsi=\"Cambria Math\" w:cs=\"Cambria Math\"/><w:i/>"
        }
        if style.bold { rpr += "<w:b/><w:bCs/>" }
        if style.italic { rpr += "<w:i/><w:iCs/>" }
        if style.strike { rpr += "<w:strike/>" }
        if style.highlight { rpr += "<w:highlight w:val=\"yellow\"/>" }
        let rPr = rpr.isEmpty ? "" : "<w:rPr>\(rpr)</w:rPr>"
        let tag = style.deleted ? "w:delText" : "w:t"
        return "<w:r>\(rPr)<\(tag) xml:space=\"preserve\">\(xml(text))</\(tag)></w:r>"
    }

    // MARK: - Footnotes

    private mutating func footnoteReference(_ id: String, _ style: RunStyle) -> String {
        guard let def = footnoteDefinitions[id] else { return textRun("[^\(id)]", style) }
        let number: Int
        if let n = footnoteNumbers[id] {
            number = n
        } else {
            number = footnoteNumbers.count + 1
            footnoteNumbers[id] = number
            var ctx = Context()
            ctx.paragraphStyle = "FootnoteText"
            var body = def.blocks.map { render($0, ctx) }.joined()
            let refRun = "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/></w:r>"
                + "<w:r><w:t xml:space=\"preserve\"> </w:t></w:r>"
            if let range = body.range(of: "</w:pPr>") {
                body.insert(contentsOf: refRun, at: range.upperBound)
            } else {
                body = "<w:p><w:pPr><w:pStyle w:val=\"FootnoteText\"/></w:pPr>\(refRun)</w:p>" + body
            }
            footnoteBodies.append((number, body))
        }
        return "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"\(number)\"/></w:r>"
    }

    private func footnotesXML() -> String {
        var notes = """
        <w:footnote w:type="separator" w:id="-1"><w:p><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>\
        <w:r><w:separator/></w:r></w:p></w:footnote>\
        <w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>\
        <w:r><w:continuationSeparator/></w:r></w:p></w:footnote>
        """
        for (n, body) in footnoteBodies {
            notes += "<w:footnote w:id=\"\(n)\">\(body)</w:footnote>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:footnotes \(DocxWriter.namespaces)>\(notes)</w:footnotes>
        """
    }

    private mutating func drawing(_ image: DocxImage, alt: String) -> String {
        drawingCounter += 1
        let n = drawingCounter
        let ext = image.fileExtension == "jpg" ? "jpeg" : image.fileExtension
        let name = "zmd-image\(n).\(ext)"
        media.append((name, image.data))
        let rid = addRelationship(type: DocxWriter.relImage, target: "media/\(name)", external: false)

        // 96 dpi pixels to EMU
        var cx = image.pixelWidth * 9525
        var cy = image.pixelHeight * 9525
        if cx > maxImageWidthEMU {
            cy = Int(Double(cy) * Double(maxImageWidthEMU) / Double(cx))
            cx = maxImageWidthEMU
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
        var exts: [String: String] = [:]
        for m in media {
            let ext = (m.name as NSString).pathExtension.lowercased()
            exts[ext] = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : "image/jpeg"
        }
        for (ext, type) in template?.defaults ?? [] where ext != "rels" && ext != "xml" && exts[ext] == nil {
            exts[ext] = type
        }
        for (ext, mime) in exts.sorted(by: { $0.key < $1.key }) {
            defaults += "<Default Extension=\"\(ext)\" ContentType=\"\(mime)\"/>"
        }
        var overrides = ""
        if !comments.isEmpty {
            overrides += "<Override PartName=\"/word/comments.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml\"/>"
        }
        for (part, type) in template?.overrides ?? [] {
            overrides += "<Override PartName=\"\(xml(part))\" ContentType=\"\(xml(type))\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\(defaults)\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
        <Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>\
        <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
        \(overrides)</Types>
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

    private func documentRels(forFootnotes: Bool = false) -> String {
        var rels = """
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>\
        <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/>
        """
        for r in relationships {
            let mode = r.external ? " TargetMode=\"External\"" : ""
            rels += "<Relationship Id=\"\(r.id)\" Type=\"\(r.type)\" Target=\"\(xml(r.target))\"\(mode)/>"
        }
        if !forFootnotes {
            if !comments.isEmpty {
                rels += "<Relationship Id=\"rId5\" Type=\"\(DocxWriter.relComments)\" Target=\"comments.xml\"/>"
            }
            for r in template?.relationships ?? [] {
                rels += "<Relationship Id=\"\(r.id)\" Type=\"\(xml(r.type))\" Target=\"\(xml(r.target))\"/>"
            }
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
        <dc:title>\(xml(frontMatter["title"] ?? title))</dc:title><dc:creator>\(xml(frontMatter["author"] ?? "Z-MarkDowner"))</dc:creator>\
        \(frontMatter["keywords"].map { "<cp:keywords>\(xml($0))</cp:keywords>" } ?? "")\
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
        let ours = """
        <w:abstractNum w:abstractNumId="\(bulletAbstract)"><w:multiLevelType w:val="hybridMultilevel"/>\(bulletLevels)</w:abstractNum>\
        <w:abstractNum w:abstractNumId="\(orderedAbstract)"><w:multiLevelType w:val="hybridMultilevel"/>\(orderedLevels)</w:abstractNum>
        """
        // Keep the template's own list definitions (styles such as numbered headings refer to them)
        if let t = template, let root = t.numberingRoot {
            return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + root
                + t.numPicBullets.joined() + t.abstractNums.joined() + ours + t.nums.joined() + numsXML + "</w:numbering>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        \(ours)\(numsXML)</w:numbering>
        """
    }

    private func settings() -> String {
        // Word refreshes the table of contents (page numbers) when the document is opened
        let update = hasTOC ? "<w:updateFields w:val=\"true\"/>" : ""
        return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    \(update)<w:defaultTabStop w:val="708"/><w:characterSpacingControl w:val="doNotCompress"/>\
    <w:footnotePr><w:footnote w:id="-1"/><w:footnote w:id="0"/></w:footnotePr>\
    <w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat>\
    </w:settings>
    """
    }

    private static func headingStyle(_ level: Int, size: Int, color: String, italic: Bool = false) -> StyleDef {
        StyleDef(id: "Heading\(level)", name: "heading \(level)", xml: """
        <w:style w:type="paragraph" w:styleId="Heading\(level)"><w:name w:val="heading \(level)"/>\
        <w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>\
        <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="\(level <= 2 ? 360 : 240)" w:after="120"/>\
        <w:outlineLvl w:val="\(level - 1)"/></w:pPr>\
        <w:rPr><w:b/><w:bCs/>\(italic ? "<w:i/>" : "")<w:color w:val="\(color)"/><w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr></w:style>
        """)
    }

    private struct StyleDef {
        let id: String
        let name: String
        let xml: String
    }

    private static func tocStyle(_ level: Int) -> StyleDef {
        StyleDef(id: "TOC\(level)", name: "toc \(level)", xml: """
        <w:style w:type="paragraph" w:styleId="TOC\(level)"><w:name w:val="toc \(level)"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:uiPriority w:val="39"/><w:unhideWhenUsed/>\
        <w:pPr><w:spacing w:after="60"/><w:ind w:left="\((level - 1) * 240)"/></w:pPr>\
        \(level == 1 ? "<w:rPr><w:b/></w:rPr>" : "")</w:style>
        """)
    }

    private static let styleDefinitions: [StyleDef] = [
        StyleDef(id: "Normal", name: "Normal", xml: "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"),
        headingStyle(1, size: 36, color: "1F2328"),
        headingStyle(2, size: 30, color: "1F2328"),
        headingStyle(3, size: 26, color: "1F2328"),
        headingStyle(4, size: 24, color: "1F2328"),
        headingStyle(5, size: 22, color: "1F2328"),
        headingStyle(6, size: 22, color: "595959", italic: true),
        StyleDef(id: "Title", name: "Title", xml: """
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:spacing w:after="80"/><w:contextualSpacing/></w:pPr><w:rPr><w:b/><w:sz w:val="52"/><w:szCs w:val="52"/></w:rPr></w:style>
        """),
        StyleDef(id: "Subtitle", name: "Subtitle", xml: """
        <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:spacing w:after="80"/></w:pPr><w:rPr><w:color w:val="595959"/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style>
        """),
        StyleDef(id: "DocMeta", name: "Document Meta", xml: """
        <w:style w:type="paragraph" w:styleId="DocMeta"><w:name w:val="Document Meta"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
        <w:pPr><w:pBdr><w:bottom w:val="single" w:sz="4" w:space="6" w:color="D0D7DE"/></w:pBdr><w:spacing w:after="360"/></w:pPr>\
        <w:rPr><w:i/><w:color w:val="595959"/></w:rPr></w:style>
        """),
        StyleDef(id: "FootnoteText", name: "footnote text", xml: """
        <w:style w:type="paragraph" w:styleId="FootnoteText"><w:name w:val="footnote text"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>
        """),
        StyleDef(id: "FootnoteReference", name: "footnote reference", xml: "<w:style w:type=\"character\" w:styleId=\"FootnoteReference\"><w:name w:val=\"footnote reference\"/><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr></w:style>"),
        StyleDef(id: "MathBlock", name: "Math Block", xml: "<w:style w:type=\"paragraph\" w:styleId=\"MathBlock\"><w:name w:val=\"Math Block\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:jc w:val=\"center\"/></w:pPr></w:style>"),
        StyleDef(id: "Quote", name: "Quote", xml: """
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="D0D7DE"/></w:pBdr><w:ind w:left="567"/></w:pPr>\
        <w:rPr><w:color w:val="59636E"/></w:rPr></w:style>
        """),
        StyleDef(id: "ListParagraph", name: "List Paragraph", xml: """
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>\
        <w:qFormat/><w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/></w:pPr></w:style>
        """),
        StyleDef(id: "CodeBlock", name: "Code Block", xml: """
        <w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/><w:basedOn w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F4F4F4"/><w:spacing w:after="160" w:line="240" w:lineRule="auto"/></w:pPr>\
        <w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr></w:style>
        """),
        StyleDef(id: "TableText", name: "Table Text", xml: """
        <w:style w:type="paragraph" w:styleId="TableText"><w:name w:val="Table Text"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:spacing w:before="40" w:after="40" w:line="240" w:lineRule="auto"/></w:pPr></w:style>
        """),
        StyleDef(id: "Caption", name: "caption", xml: """
        <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
        <w:uiPriority w:val="35"/><w:unhideWhenUsed/><w:qFormat/><w:pPr><w:spacing w:after="200" w:line="240" w:lineRule="auto"/><w:jc w:val="center"/></w:pPr>\
        <w:rPr><w:i/><w:iCs/><w:color w:val="44546A"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>
        """),
        StyleDef(id: "TOCHeading", name: "TOC Heading", xml: """
        <w:style w:type="paragraph" w:styleId="TOCHeading"><w:name w:val="TOC Heading"/><w:basedOn w:val="Heading1"/><w:next w:val="Normal"/>\
        <w:uiPriority w:val="39"/><w:unhideWhenUsed/><w:qFormat/><w:pPr><w:outlineLvl w:val="9"/></w:pPr></w:style>
        """),
        tocStyle(1), tocStyle(2), tocStyle(3), tocStyle(4), tocStyle(5), tocStyle(6),
        StyleDef(id: "Bibliography", name: "Bibliography", xml: """
        <w:style w:type="paragraph" w:styleId="Bibliography"><w:name w:val="Bibliography"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:uiPriority w:val="37"/><w:unhideWhenUsed/><w:pPr><w:spacing w:after="120"/><w:ind w:left="720" w:hanging="720"/></w:pPr></w:style>
        """),
        StyleDef(id: "BibliographyNumbered", name: "Bibliography Numbered", xml: """
        <w:style w:type="paragraph" w:styleId="BibliographyNumbered"><w:name w:val="Bibliography Numbered"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:tabs><w:tab w:val="left" w:pos="567"/></w:tabs><w:spacing w:after="120"/><w:ind w:left="567" w:hanging="567"/></w:pPr></w:style>
        """),
        StyleDef(id: "CommentText", name: "annotation text", xml: """
        <w:style w:type="paragraph" w:styleId="CommentText"><w:name w:val="annotation text"/><w:basedOn w:val="Normal"/>\
        <w:uiPriority w:val="99"/><w:unhideWhenUsed/><w:pPr><w:spacing w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>
        """),
        StyleDef(id: "CommentReference", name: "annotation reference", xml: """
        <w:style w:type="character" w:styleId="CommentReference"><w:name w:val="annotation reference"/>\
        <w:uiPriority w:val="99"/><w:unhideWhenUsed/><w:rPr><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr></w:style>
        """),
        StyleDef(id: "DefaultParagraphFont", name: "Default Paragraph Font", xml: "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"DefaultParagraphFont\"><w:name w:val=\"Default Paragraph Font\"/><w:uiPriority w:val=\"1\"/><w:semiHidden/></w:style>"),
        StyleDef(id: "InlineCode", name: "Inline Code", xml: """
        <w:style w:type="character" w:styleId="InlineCode"><w:name w:val="Inline Code"/>\
        <w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/><w:shd w:val="clear" w:color="auto" w:fill="EFEFEF"/></w:rPr></w:style>
        """),
        StyleDef(id: "Hyperlink", name: "Hyperlink", xml: "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>"),
        StyleDef(id: "TableNormal", name: "Normal Table", xml: """
        <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:semiHidden/>\
        <w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/>\
        <w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
        """),
        StyleDef(id: "TableGrid", name: "Table Grid", xml: """
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/>\
        <w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="999999"/>\
        <w:left w:val="single" w:sz="4" w:space="0" w:color="999999"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="999999"/>\
        <w:right w:val="single" w:sz="4" w:space="0" w:color="999999"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="999999"/>\
        <w:insideV w:val="single" w:sz="4" w:space="0" w:color="999999"/></w:tblBorders></w:tblPr></w:style>
        """),
    ]

    /// Word language tag for a language code ("hu" → "hu-HU").
    private var languageTag: String {
        let code = frontMatter["lang"] ?? frontMatter["language"] ?? (language.isEmpty ? "en-US" : language)
        if code.contains("-") { return code }
        let regions = ["hu": "HU", "en": "US", "de": "DE", "es": "ES", "it": "IT", "fr": "FR", "pt": "PT",
                       "ru": "RU", "sk": "SK", "cs": "CZ", "ro": "RO", "tr": "TR"]
        return regions[code.lowercased()].map { "\(code.lowercased())-\($0)" } ?? code
    }

    /// styles.xml and the mapping from our style ids to the ids used in it.
    private func makeStyles() -> (String, [String: String]) {
        guard let t = template else {
            let xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
            <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/>\
            <w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="\(languageTag)" w:eastAsia="en-US" w:bidi="ar-SA"/></w:rPr></w:rPrDefault>\
            <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
            \(Self.styleDefinitions.map(\.xml).joined())</w:styles>
            """
            return (xml, [:])
        }
        // Use the template's styles; ours are matched by (built-in, English) name and added when missing
        var map: [String: String] = [:]
        var renamed: [String: String] = [:]
        for def in Self.styleDefinitions {
            if let existing = t.styleIDsByName[def.name.lowercased()] {
                if existing != def.id { map[def.id] = existing }
            } else if t.styleIDs.contains(def.id) {
                renamed[def.id] = "Zmd" + def.id
                map[def.id] = "Zmd" + def.id
            }
        }
        var additions = ""
        for def in Self.styleDefinitions where t.styleIDsByName[def.name.lowercased()] == nil {
            var xml = def.xml
            if let newID = renamed[def.id] {
                xml = xml.replacingOccurrences(of: "w:styleId=\"\(def.id)\"", with: "w:styleId=\"\(newID)\"")
            }
            // Only the template's default styles may be marked as default
            xml = xml.replacingOccurrences(of: " w:default=\"1\"", with: "")
            additions += Self.mapStyles(xml, map, references: ["basedOn", "next", "link"])
        }
        var styles = t.stylesXML
        if let close = styles.range(of: "</w:styles>", options: .backwards) {
            styles.insert(contentsOf: additions, at: close.lowerBound)
        }
        return (styles, map)
    }

    /// Replaces style ids in `w:pStyle`, `w:rStyle`, `w:tblStyle` (and optionally other) references.
    private static func mapStyles(_ xml: String, _ map: [String: String],
                                  references: [String] = ["pStyle", "rStyle", "tblStyle"]) -> String {
        guard !map.isEmpty else { return xml }
        var out = xml
        for (from, to) in map {
            for ref in references {
                out = out.replacingOccurrences(of: "<w:\(ref) w:val=\"\(from)\"/>", with: "<w:\(ref) w:val=\"\(to)\"/>")
            }
        }
        return out
    }

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
