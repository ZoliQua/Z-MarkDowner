import XCTest
import AppKit
@testable import MarkDownerCore

final class CitationParsingTests: XCTestCase {

    func testBracketedCitations() {
        let inlines = MarkdownParser.parseInlines("Text [see @kovacs2020, p. 33; -@nagy2019].")
        guard case .citation(let c) = inlines[1] else { return XCTFail("\(inlines)") }
        XCTAssertFalse(c.inText)
        XCTAssertEqual(c.items.count, 2)
        XCTAssertEqual(c.items[0], MDCitationItem(key: "kovacs2020", prefix: "see", locator: "p. 33"))
        XCTAssertEqual(c.items[1].key, "nagy2019")
        XCTAssertTrue(c.items[1].suppressAuthor)
        XCTAssertEqual(inlines.last, .text("."))
    }

    func testBareCitationsAndEmails() {
        let inlines = MarkdownParser.parseInlines("As @smith04 [p. 4] shows; mail me@example.com, see @fig:plot.")
        let citations = inlines.compactMap { node -> MDCitation? in
            if case .citation(let c) = node { return c }
            return nil
        }
        XCTAssertEqual(citations.count, 2)
        XCTAssertEqual(citations[0].items[0].key, "smith04")
        XCTAssertEqual(citations[0].items[0].locator, "p. 4")
        XCTAssertTrue(citations[0].inText)
        XCTAssertEqual(citations[1].items[0].key, "fig:plot")
        XCTAssertTrue(citations[1].items[0].isCrossReference)
        XCTAssertTrue(inlines.plainText.contains("me@example.com"))
    }

    func testLinksAreNotCitations() {
        let inlines = MarkdownParser.parseInlines("[@user](https://example.com)")
        guard case .link = inlines[0] else { return XCTFail("\(inlines)") }
    }

    func testCriticMarkup() {
        let inlines = MarkdownParser.parseInlines("a {++new++} {--old--} {~~x~>y~~} {==hi==}{>>note<<}")
        XCTAssertTrue(inlines.contains(.insertion([.text("new")])))
        XCTAssertTrue(inlines.contains(.deletion([.text("old")])))
        XCTAssertTrue(inlines.contains(.deletion([.text("x")])))
        XCTAssertTrue(inlines.contains(.insertion([.text("y")])))
        XCTAssertTrue(inlines.contains(.highlight([.text("hi")])))
        XCTAssertTrue(inlines.contains(.comment("note")))
    }

    func testAttributesAndCaptions() {
        let md = """
        # Introduction {#sec:intro}

        ![A *nice* plot](plot.png){#fig:plot}

        | a | b |
        |---|---|
        | 1 | 2 |

        Table: Results {#tbl:res}

        $$ E = mc^2 $$ {#eq:energy}

        [TOC]
        """
        let doc = MDDocument(markdown: md)
        XCTAssertEqual(doc.blocks.count, 5)
        XCTAssertEqual(doc.blocks[0], .heading(level: 1, content: [.text("Introduction")], id: "sec:intro"))
        guard case .figure(let fig) = doc.blocks[1], case .figure(let tbl) = doc.blocks[2],
              case .figure(let eq) = doc.blocks[3] else { return XCTFail("\(doc.blocks)") }
        XCTAssertEqual(fig.kind, .figure)
        XCTAssertEqual(fig.caption, [.text("A "), .emphasis([.text("nice")]), .text(" plot")])
        XCTAssertEqual(tbl.kind, .table)
        XCTAssertEqual(tbl.id, "tbl:res")
        XCTAssertEqual(tbl.caption, [.text("Results")])
        XCTAssertEqual(eq.kind, .equation)
        XCTAssertEqual(eq.content, .mathBlock("E = mc^2"))
        XCTAssertEqual(doc.blocks[4], .tableOfContents(title: "", entries: []))
    }
}

final class BibliographyTests: XCTestCase {

    static let bibtex = """
    @string{nejm = "N Engl J Med"}
    % a comment
    @article{kovacs2020,
      author = {Kov{\\'a}cs, J{\\'a}nos and Nagy, Erzs{\\'e}bet and Sz{\\H{o}}ke, P{\\'e}ter},
      title = {{A} randomized trial of something},
      journal = nejm,
      year = 2020,
      volume = {382}, number = {5},
      pages = {401--410},
      doi = {10.1056/NEJMoa1234567}
    }
    @book{who2019,
      author = {{World Health Organization}},
      title = {Global report},
      publisher = {WHO Press}, address = {Geneva},
      year = {2019}
    }
    """

    func testBibTeXParsing() {
        let entries = BibTeX.parse(Self.bibtex)
        XCTAssertEqual(entries.count, 2)
        let a = entries[0]
        XCTAssertEqual(a.id, "kovacs2020")
        XCTAssertEqual(a.kind, .article)
        XCTAssertEqual(a.authors.map(\.family), ["Kovács", "Nagy", "Szőke"])
        XCTAssertEqual(a.authors[0].given, "János")
        XCTAssertEqual(a.title, "A randomized trial of something")
        XCTAssertEqual(a.container, "N Engl J Med")
        XCTAssertEqual(a.pages, "401–410")
        XCTAssertEqual(entries[1].authors.first?.literal, "World Health Organization")
    }

    func testCSLJSONParsing() throws {
        let json = """
        [{"id": "pmid:12345", "type": "article-journal", "title": "Gene <i>X</i> study",
          "author": [{"family": "Smith", "given": "Anna B."}], "container-title": "Nature",
          "container-title-short": "Nature", "issued": {"date-parts": [[2021, 3]]},
          "volume": "590", "page": "100-105", "DOI": "10.1038/x", "PMID": "12345"}]
        """
        let entries = try CSLJSON.parse(Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "pmid12345")
        XCTAssertEqual(entries[0].title, "Gene X study")
        XCTAssertEqual(entries[0].year, "2021")
        XCTAssertEqual(entries[0].authors[0].initials, "AB")
        // Round trip through BibTeX
        let again = BibTeX.parse(BibTeX.format(entries[0]))
        XCTAssertEqual(again.first?.title, "Gene X study")
        XCTAssertEqual(again.first?.doi, "10.1038/x")
        XCTAssertEqual(again.first?.pmid, "12345")
    }

    func testKeyGeneration() {
        var e = BibEntry(id: "")
        e.authors = [BibName(family: "Kovács", given: "J")]
        e.year = "2020"
        XCTAssertEqual(Bibliography.makeKey(for: e, existing: []), "kovacs2020")
        XCTAssertEqual(Bibliography.makeKey(for: e, existing: ["kovacs2020"]), "kovacs2020a")
    }
}

final class ProcessingTests: XCTestCase {

    private func withBibliography(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zmd-bib-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? BibliographyTests.bibtex.write(to: dir.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
        try body(dir)
    }

    func testVancouverCitationsAndReferenceList() {
        withBibliography { dir in
            let md = "---\nbibliography: refs.bib\n---\n\nFirst [@who2019], then [@kovacs2020; @who2019] and @kovacs2020.\n"
            let result = DocumentProcessor.process(markdown: md, options: ProcessingOptions(baseURL: dir))
            XCTAssertTrue(result.unresolved.isEmpty, "\(result.unresolved)")
            let html = HTMLRenderer.render(document: result.document)
            XCTAssertTrue(html.contains("First [<a href=\"#ref-who2019\">1</a>]"), html)
            XCTAssertTrue(html.contains("[<a href=\"#ref-who2019\">1</a>,<a href=\"#ref-kovacs2020\">2</a>]"), html)
            XCTAssertTrue(html.contains("Kovács et al. [<a href=\"#ref-kovacs2020\">2</a>]"), html)
            XCTAssertTrue(html.contains("<h1 id=\"references\">References</h1>"), html)
            XCTAssertTrue(html.contains("Kovács J, Nagy E, Szőke P. A randomized trial of something. N Engl J Med. 2020;382(5):401–410."), html)
            XCTAssertTrue(html.contains("World Health Organization. Global report. Geneva: WHO Press; 2019."), html)
        }
    }

    func testAPACitations() {
        withBibliography { dir in
            let md = "---\nbibliography: refs.bib\ncsl: apa\n---\n\nText [@kovacs2020, p. 5; @who2019]. @who2019 says.\n\n::: {#refs}\n:::\n\n# Appendix\n"
            let result = DocumentProcessor.process(markdown: md, options: ProcessingOptions(baseURL: dir))
            let html = HTMLRenderer.render(document: result.document)
            XCTAssertTrue(html.contains("(<a href=\"#ref-kovacs2020\">Kovács et al., 2020</a>, p. 5; <a href=\"#ref-who2019\">World Health Organization, 2019</a>)"), html)
            XCTAssertTrue(html.contains("<a href=\"#ref-who2019\">World Health Organization</a> (2019) says"), html)
            XCTAssertTrue(html.contains("Kovács, J., Nagy, E., &amp; Szőke, P. (2020). A randomized trial of something. <em>N Engl J Med</em>, <em>382</em>(5), 401–410."), html)
            // The placeholder puts the list before the appendix, without an extra heading
            let refs = html.range(of: "class=\"references\"")!.lowerBound
            XCTAssertLessThan(refs, html.range(of: "Appendix")!.lowerBound)
            XCTAssertFalse(html.contains(">References<"))
        }
    }

    func testUnknownKeysStayAsText() {
        let result = DocumentProcessor.process(markdown: "Follow @ZoliQua on GitHub.", options: ProcessingOptions())
        XCTAssertEqual(HTMLRenderer.render(document: result.document), "<p>Follow @ZoliQua on GitHub.</p>")
    }

    func testNumberingCrossReferencesAndTOC() {
        let md = """
        ---
        numbersections: true
        toc: true
        ---

        # Intro {#sec:intro}

        See @fig:plot, [@tbl:res] and @eq:e in @sec:methods.

        # Methods {#sec:methods}

        ## Details

        ![Plot](p.png){#fig:plot}

        | a |
        |---|
        | 1 |

        Table: Results {#tbl:res}

        $$ x = 1 $$ {#eq:e}
        """
        let result = DocumentProcessor.process(markdown: md, options: ProcessingOptions())
        XCTAssertTrue(result.unresolved.isEmpty, "\(result.unresolved)")
        let doc = result.document
        guard case .tableOfContents(let title, let entries) = doc.blocks[0] else { return XCTFail("\(doc.blocks[0])") }
        XCTAssertEqual(title, "Contents")
        XCTAssertEqual(entries.map(\.text), ["1 Intro", "2 Methods", "2.1 Details"])
        XCTAssertEqual(doc.blocks.count, doc.blockLines.count)
        let html = HTMLRenderer.render(document: doc)
        XCTAssertTrue(html.contains("<h1 id=\"sec:intro\">1 Intro</h1>"), html)
        XCTAssertTrue(html.contains("<h2 id=\"details\">2.1 Details</h2>"), html)
        XCTAssertTrue(html.contains("See <a href=\"#fig:plot\">Figure 1</a>, <a href=\"#tbl:res\">Table 1</a> and <a href=\"#eq:e\">Equation (1)</a> in <a href=\"#sec:methods\">Section 2</a>."), html)
        XCTAssertTrue(html.contains("<figcaption><span class=\"caption-label\">Figure 1:</span> Plot</figcaption>"), html)
        XCTAssertTrue(html.contains("<span class=\"eq-number\">(1)</span>"), html)
        XCTAssertTrue(html.contains("<a href=\"#details\"><span class=\"toc-text\">2.1 Details</span>"), html)
    }

    func testPlainDocumentIsUnchanged() {
        let doc = MDDocument(markdown: "# A\n\nText.")
        XCTAssertEqual(DocumentProcessor.process(doc, options: ProcessingOptions()).document, doc)
    }
}

final class WordReviewTests: XCTestCase {

    /// A minimal DOCX with a tracked insertion, a deletion and a comment.
    static func reviewDocx() -> Data {
        let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(w)><w:body><w:p>\
        <w:r><w:t xml:space="preserve">The </w:t></w:r>\
        <w:del w:id="1" w:author="Anna"><w:r><w:delText>old</w:delText></w:r></w:del>\
        <w:ins w:id="2" w:author="Anna"><w:r><w:t>new</w:t></w:r></w:ins>\
        <w:r><w:t xml:space="preserve"> </w:t></w:r>\
        <w:commentRangeStart w:id="0"/><w:r><w:t>result</w:t></w:r><w:commentRangeEnd w:id="0"/>\
        <w:r><w:commentReference w:id="0"/></w:r><w:r><w:t>.</w:t></w:r></w:p></w:body></w:document>
        """
        let comments = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:comments \(w)><w:comment w:id="0" w:author="Béla"><w:p><w:r><w:t>Check this</w:t></w:r></w:p></w:comment></w:comments>
        """
        var zip = ZipWriter()
        zip.add(path: "word/document.xml", string: document)
        zip.add(path: "word/comments.xml", string: comments)
        return zip.finish()
    }

    func testTrackedChangesAndCommentsImport() throws {
        let md = try DocxReader.markdown(from: Self.reviewDocx())
        XCTAssertEqual(md.trimmingCharacters(in: .whitespacesAndNewlines),
                       "The {--old--}{++new++} {==result==}{>>Béla: Check this<<}.")
        let accepted = try DocxReader.markdown(from: Self.reviewDocx(), revisions: .accept)
        XCTAssertEqual(accepted.trimmingCharacters(in: .whitespacesAndNewlines), "The new result.")
    }

    func testReviewMarksExportToWord() throws {
        var writer = DocxWriter(title: "T")
        let data = writer.makeDocx(markdown: "The {--old--}{++new++} {==result==}{>>Check this<<}.")
        let zip = try ZipReader(data: data)
        let document = String(decoding: try zip.contents(of: "word/document.xml")!, as: UTF8.self)
        XCTAssertTrue(document.contains("<w:del "), document)
        XCTAssertTrue(document.contains("<w:delText xml:space=\"preserve\">old</w:delText>"))
        XCTAssertTrue(document.contains("<w:ins "))
        XCTAssertTrue(document.contains("<w:commentRangeStart"))
        XCTAssertTrue(document.contains("<w:highlight w:val=\"yellow\"/>"))
        let comments = String(decoding: try zip.contents(of: "word/comments.xml")!, as: UTF8.self)
        XCTAssertTrue(comments.contains("Check this"))
        for part in ["word/document.xml", "word/comments.xml", "word/styles.xml", "[Content_Types].xml", "word/_rels/document.xml.rels"] {
            XCTAssertNoThrow(try XMLDocument(data: try zip.contents(of: part)!), part)
        }
        // And back again
        let reread = try DocxReader.markdown(from: data)
        XCTAssertTrue(reread.contains("{--old--}{++new++}"), reread)
        XCTAssertTrue(reread.contains("{==result==}{>>"), reread)
    }
}

final class WordTemplateTests: XCTestCase {

    /// A template as produced by a Hungarian Word: localized style ids, a header and Letter paper.
    static func templateDocx() -> Data {
        let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles \(w)><w:style w:type="paragraph" w:default="1" w:styleId="Norml"><w:name w:val="Normal"/>\
        <w:rPr><w:rFonts w:ascii="Georgia" w:hAnsi="Georgia"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Cmsor1"><w:name w:val="heading 1"/><w:basedOn w:val="Norml"/>\
        <w:rPr><w:color w:val="C00000"/></w:rPr></w:style></w:styles>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(w)><w:body><w:p/><w:sectPr><w:headerReference w:type="default" r:id="rId9"/>\
        <w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1800" w:bottom="1440" w:left="1800"/></w:sectPr></w:body></w:document>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/></Relationships>
        """
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:hdr \(w)><w:p><w:r><w:t>University</w:t></w:r></w:p></w:hdr>"
        let types = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/></Types>
        """
        var zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", string: types)
        zip.add(path: "word/document.xml", string: document)
        zip.add(path: "word/styles.xml", string: styles)
        zip.add(path: "word/_rels/document.xml.rels", string: rels)
        zip.add(path: "word/header1.xml", string: header)
        return zip.finish()
    }

    func testTemplateStylesAndHeader() throws {
        var writer = DocxWriter(title: "T")
        writer.template = try DocxTemplate(data: Self.templateDocx())
        let data = writer.makeDocx(markdown: "# Title\n\n> quoted\n\n- item\n")
        let zip = try ZipReader(data: data)
        let document = String(decoding: try zip.contents(of: "word/document.xml")!, as: UTF8.self)
        let styles = String(decoding: try zip.contents(of: "word/styles.xml")!, as: UTF8.self)
        XCTAssertTrue(document.contains("<w:pStyle w:val=\"Cmsor1\"/>"), document)
        XCTAssertFalse(document.contains("w:val=\"Heading1\""))
        XCTAssertTrue(document.contains("w:w=\"12240\""))
        XCTAssertTrue(document.contains("r:id=\"rIdT1\""))
        XCTAssertNotNil(try zip.contents(of: "word/header1.xml"))
        XCTAssertTrue(styles.contains("C00000"))
        XCTAssertTrue(styles.contains("w:styleId=\"Quote\""))        // added because the template lacks it
        XCTAssertTrue(styles.contains("<w:basedOn w:val=\"Norml\"/>")) // mapped to the template's Normal
        let rels = String(decoding: try zip.contents(of: "word/_rels/document.xml.rels")!, as: UTF8.self)
        XCTAssertTrue(rels.contains("Id=\"rIdT1\""))
        let types = String(decoding: try zip.contents(of: "[Content_Types].xml")!, as: UTF8.self)
        XCTAssertTrue(types.contains("/word/header1.xml"))
        for part in ["word/document.xml", "word/styles.xml", "word/numbering.xml", "[Content_Types].xml", "word/_rels/document.xml.rels"] {
            XCTAssertNoThrow(try XMLDocument(data: try zip.contents(of: part)!), part)
        }
    }

    func testDocxCrossReferencesAndTOC() throws {
        let md = "---\ntoc: true\nnumbersections: true\n---\n\n# Intro {#sec:intro}\n\nSee @fig:a.\n\n![Cap](missing.png){#fig:a}\n"
        let doc = DocumentProcessor.process(markdown: md, options: ProcessingOptions()).document
        var writer = DocxWriter(title: "T")
        let zip = try ZipReader(data: writer.makeDocx(document: doc))
        let document = String(decoding: try zip.contents(of: "word/document.xml")!, as: UTF8.self)
        XCTAssertTrue(document.contains("TOC \\o"), document)
        XCTAssertTrue(document.contains("w:name=\"sec_intro\""))
        XCTAssertTrue(document.contains("w:anchor=\"fig_a\""))
        XCTAssertTrue(document.contains("w:name=\"fig_a\""))
        XCTAssertTrue(document.contains("<w:pStyle w:val=\"Caption\"/>"))
        XCTAssertNoThrow(try XMLDocument(data: Data(document.utf8)))
        let settings = String(decoding: try zip.contents(of: "word/settings.xml")!, as: UTF8.self)
        XCTAssertTrue(settings.contains("updateFields"))
    }
}

final class WritingToolsTests: XCTestCase {

    func testStatisticsIgnoreMarkup() {
        let md = """
        ---
        title: Két szó
        ---

        # Bevezetés

        Ez egy **mondat** egy [linkkel](https://example.com/hosszu/url). Ez a második!

        ```swift
        let ignored = "code words here"
        ```

        - Lista elem {--törölt--}
        """
        let stats = TextStatistics(markdown: md)
        // "Két szó" + "Bevezetés" + 8 words in the paragraph + "Lista elem"
        XCTAssertEqual(stats.words, 2 + 1 + 8 + 2)
        XCTAssertEqual(stats.headings, 1)
        XCTAssertEqual(stats.paragraphs, 2)
        XCTAssertGreaterThanOrEqual(stats.sentences, 3)
        XCTAssertEqual(stats.readingMinutes, 13.0 / TextStatistics.readingSpeed, accuracy: 0.0001)
    }

    func testFolderSearchAndReplace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zmd-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Alpha beta\nGamma alpha\n".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "nothing\nALPHAbet\n".write(to: dir.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        try "alpha".write(to: dir.appendingPathComponent("c.docx"), atomically: true, encoding: .utf8)

        let plain = try FolderSearch.regex(for: "alpha", options: .init())
        let results = FolderSearch.search(folder: dir, regex: plain)
        XCTAssertEqual(results.map { $0.url.lastPathComponent }, ["a.md", "b.txt"])
        XCTAssertEqual(results[0].matches.map(\.line), [0, 1])
        XCTAssertEqual(results[1].matches.first?.line, 1)

        let word = try FolderSearch.regex(for: "alpha", options: .init(caseSensitive: true, wholeWord: true))
        XCTAssertEqual(FolderSearch.search(folder: dir, regex: word).flatMap(\.matches).count, 1)

        let options = FolderSearch.Options(regularExpression: true)
        let re = try FolderSearch.regex(for: #"(\w+) alpha"#, options: options)
        let replaced = FolderSearch.replace(in: "Gamma alpha", regex: re, with: "$1-Ω", options: options)
        XCTAssertEqual(replaced.text, "Gamma-Ω")
        XCTAssertEqual(replaced.count, 1)
        let literal = FolderSearch.replace(in: "a.b a.b", regex: try FolderSearch.regex(for: "a.b", options: .init()),
                                           with: "$1", options: .init())
        XCTAssertEqual(literal.text, "$1 $1")
    }
}

final class ReferenceLookupTests: XCTestCase {
    func testIdentifierRecognition() {
        XCTAssertEqual(ReferenceLookup.identifier(from: "https://doi.org/10.1056/NEJMoa2034577"), .doi("10.1056/NEJMoa2034577"))
        XCTAssertEqual(ReferenceLookup.identifier(from: "doi: 10.1038/s41586-020-2012-7."), .doi("10.1038/s41586-020-2012-7"))
        XCTAssertEqual(ReferenceLookup.identifier(from: "PMID: 33301246"), .pmid("33301246"))
        XCTAssertEqual(ReferenceLookup.identifier(from: "https://pubmed.ncbi.nlm.nih.gov/33301246/"), .pmid("33301246"))
        XCTAssertNil(ReferenceLookup.identifier(from: "hello"))
    }

    func testAppendToBibliographyFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zmd-append-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var e = BibEntry(id: "smith2020")
        e.authors = [BibName(family: "Smith", given: "Anna")]
        e.title = "Title"
        e.year = "2020"
        for name in ["refs.bib", "refs.json"] {
            let url = dir.appendingPathComponent(name)
            try ReferenceLookup.append(e, to: url)
            e.id = "jones2021"
            try ReferenceLookup.append(e, to: url)
            e.id = "smith2020"
            XCTAssertEqual(try Bibliography.load(url).map(\.id), ["smith2020", "jones2021"], name)
        }
    }
}
