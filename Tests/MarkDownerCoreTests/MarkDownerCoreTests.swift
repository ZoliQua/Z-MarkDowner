import XCTest
import AppKit
@testable import MarkDownerCore

final class ParserTests: XCTestCase {

    func testHeadingsAndParagraphs() {
        let doc = MDDocument(markdown: "# Cím\n\nElső *dőlt* és **félkövér** szöveg.\n\nAlcím\n-----")
        XCTAssertEqual(doc.blocks.count, 3)
        XCTAssertEqual(doc.blocks[0], .heading(level: 1, content: [.text("Cím")]))
        XCTAssertEqual(doc.blocks[1], .paragraph([.text("Első "), .emphasis([.text("dőlt")]), .text(" és "),
                                                  .strong([.text("félkövér")]), .text(" szöveg.")]))
        XCTAssertEqual(doc.blocks[2], .heading(level: 2, content: [.text("Alcím")]))
    }

    func testNestedEmphasis() {
        XCTAssertEqual(MarkdownParser.parseInlines("*a **b** c*"),
                       [.emphasis([.text("a "), .strong([.text("b")]), .text(" c")])])
        XCTAssertEqual(MarkdownParser.parseInlines("**a *b***"),
                       [.strong([.text("a "), .emphasis([.text("b")])])])
        XCTAssertEqual(MarkdownParser.parseInlines("***x***"), [.strong([.emphasis([.text("x")])])])
        XCTAssertEqual(MarkdownParser.parseInlines("snake_case_name"), [.text("snake_case_name")])
        XCTAssertEqual(MarkdownParser.parseInlines("~~del~~"), [.strikethrough([.text("del")])])
    }

    func testLinksCodeAndEscapes() {
        XCTAssertEqual(MarkdownParser.parseInlines("[a](http://x.hu \"T\") `c*d*` \\*e\\*"),
                       [.link(text: [.text("a")], url: "http://x.hu", title: "T"), .text(" "),
                        .code("c*d*"), .text(" *e*")])
        XCTAssertEqual(MarkdownParser.parseInlines("lásd https://example.com."),
                       [.text("lásd "), .link(text: [.text("https://example.com")], url: "https://example.com", title: nil), .text(".")])
    }

    func testLists() {
        let md = """
        - egy
        - kettő
            - beágyazott
        - [x] kész

        1. első
        2. második
        """
        let blocks = MDDocument(markdown: md).blocks
        XCTAssertEqual(blocks.count, 2)
        guard case .list(let ul) = blocks[0], case .list(let ol) = blocks[1] else { return XCTFail() }
        XCTAssertFalse(ul.ordered)
        XCTAssertEqual(ul.items.count, 3)
        XCTAssertEqual(ul.items[2].checked, true)
        guard case .list(let nested) = ul.items[1].blocks.last else { return XCTFail("nested list missing") }
        XCTAssertEqual(nested.items.count, 1)
        XCTAssertTrue(ol.ordered)
        XCTAssertEqual(ol.items.count, 2)
    }

    func testTableAndCode() {
        let md = """
        | Név | Kor |
        |:----|----:|
        | Anna | 30 |

        ```swift
        let x = 1
        ```
        """
        let blocks = MDDocument(markdown: md).blocks
        guard case .table(let t) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(t.alignments, [.left, .right])
        XCTAssertEqual(t.rows.count, 1)
        XCTAssertEqual(blocks[1], .codeBlock(language: "swift", code: "let x = 1"))
    }

    func testHTMLEscapesRawHTML() {
        let html = HTMLRenderer.render(markdown: "<script>alert(1)</script> [x](javascript:alert(1))")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("href=\"#\""))
    }
}

final class ExportImportTests: XCTestCase {

    static let sample = """
    # Főcím

    Bekezdés **félkövér**, *dőlt* és ~~áthúzott~~ szöveggel, valamint `kóddal`.

    ## Lista

    - első elem
    - második elem
        - beágyazott elem

    1. egy
    2. kettő

    > Idézet szöveg.

    | Oszlop A | Oszlop B |
    |----------|----------|
    | a1 | b1 |
    | a2 | b2 |

    ```
    print("hello")
    ```

    [Link](https://example.com)

    ---

    Árvíztűrő tükörfúrógép.
    """

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zmd-test-\(UUID().uuidString)-\(name)")
    }

    func testDocxIsValidZipAndRoundTrips() throws {
        var writer = DocxWriter(title: "Teszt")
        let data = writer.makeDocx(markdown: Self.sample)
        let url = tempURL("out.docx")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Validate the archive with the system unzip tool
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-tq", url.path]
        unzip.standardOutput = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0, "docx is not a valid zip")

        // Validate the XML parts are well formed
        for part in ["word/document.xml", "word/styles.xml", "word/numbering.xml", "[Content_Types].xml"] {
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", url.path, part.replacingOccurrences(of: "[", with: "\\[")]
            p.standardOutput = pipe
            try p.run()
            let xml = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            XCTAssertNoThrow(try XMLDocument(data: xml), "\(part) is not well-formed XML")
        }

        // Read it back through the AppKit DOCX reader and our Markdown converter
        let md = try DocumentImporter.markdown(fromFileAt: url)
        XCTAssertTrue(md.hasPrefix("# Főcím"), md)
        XCTAssertTrue(md.contains("## Lista"), md)
        XCTAssertTrue(md.contains("1. egy"), md)
        XCTAssertTrue(md.contains("    - beágyazott elem"), md)
        XCTAssertTrue(md.contains("> Idézet szöveg."), md)
        XCTAssertTrue(md.contains("```\nprint(\"hello\")\n```"), md)
        XCTAssertTrue(md.contains("~~áthúzott~~"), md)
        XCTAssertTrue(md.contains("`kóddal`"), md)
        XCTAssertTrue(md.contains("**félkövér**"), md)
        XCTAssertTrue(md.contains("*dőlt*"), md)
        XCTAssertTrue(md.contains("- első elem"), md)
        XCTAssertTrue(md.contains("| a1 | b1 |"), md)
        XCTAssertTrue(md.contains("Árvíztűrő tükörfúrógép."), md)
        XCTAssertTrue(md.contains("[Link](https://example.com)"), md)
        XCTAssertTrue(md.contains("| Oszlop A | Oszlop B |"), md)
    }

    @MainActor
    func testPDFExport() throws {
        let long = Array(repeating: Self.sample, count: 6).joined(separator: "\n\n")
        let data = try PDFExporter.pdfData(markdown: long, title: "Teszt", baseURL: nil)
        XCTAssertTrue(data.starts(with: Array("%PDF".utf8)))
        let pdf = try XCTUnwrap(NSPDFImageRep(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 1, "long document should paginate")
        XCTAssertEqual(pdf.bounds.width, PDFExporter.pageSize.width, accuracy: 1)
    }

    func testRTFImport() throws {
        let attr = NSMutableAttributedString(string: "Nagy cím\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
        attr.append(NSAttributedString(string: "Normál ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        attr.append(NSAttributedString(string: "vastag", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        attr.append(NSAttributedString(string: " szöveg és még több normál szöveg a törzsben.\n",
                                       attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let url = tempURL("in.rtf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let md = try DocumentImporter.markdown(fromFileAt: url)
        XCTAssertTrue(md.hasPrefix("# Nagy cím"), md)
        XCTAssertTrue(md.contains("Normál **vastag** szöveg"), md)
    }

    func testTextDecoding() {
        let cp1250 = "Árvíztűrő tükörfúrógép".data(using: .windowsCP1250)!
        XCTAssertEqual(DocumentImporter.decodeText(cp1250), "Árvíztűrő tükörfúrógép")
        let utf8bom = Data([0xEF, 0xBB, 0xBF]) + Data("őű".utf8)
        XCTAssertEqual(DocumentImporter.decodeText(utf8bom), "őű")
    }
}
