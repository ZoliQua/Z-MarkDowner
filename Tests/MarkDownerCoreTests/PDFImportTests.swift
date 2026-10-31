import XCTest
import PDFKit
@testable import MarkDownerCore

final class PDFImportTests: XCTestCase {

    private typealias Line = (text: String, fontSize: CGFloat, bold: Bool)

    private func body(_ text: String) -> Line { (text, 11, false) }

    /// Body paragraphs of the extracted Markdown (front matter and headings excluded).
    private func paragraphs(_ markdown: String) -> [String] {
        markdown.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("---") }
    }

    func testParagraphsAndHeadings() {
        let doc = SyntheticPDF.make(pages: [[
            ("Introduction", 20, true),
            body("Data visualisation tools help researchers explore large"),
            body("biological datasets and communicate their findings to"),
            body("a broad audience in a clear way."),
            body(""),
            body("A second paragraph follows after a visible gap and"),
            body("ends here."),
        ]])
        let result = PDFTextExtractor.extract(doc)
        XCTAssertTrue(result.markdown.hasPrefix("# Introduction\n\n"), result.markdown)
        let paras = paragraphs(result.markdown)
        XCTAssertEqual(paras.count, 2, result.markdown)
        XCTAssertEqual(paras.first, "Data visualisation tools help researchers explore large biological datasets and communicate their findings to a broad audience in a clear way.")
        XCTAssertEqual(paras.last, "A second paragraph follows after a visible gap and ends here.")
    }

    func testLineNumbersRemoved() {
        let words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu"]
        let lines = words.map { body("The \($0) platform for") }
        let doc = SyntheticPDF.make(pages: [lines], lineNumbers: true)
        let result = PDFTextExtractor.extract(doc)
        for line in result.markdown.components(separatedBy: "\n") {
            XCTAssertFalse(line.last?.isNumber ?? false, "Line ends with a digit: \(line)")
        }
        for word in words { XCTAssertTrue(result.markdown.contains("\(word) platform for"), word) }
    }

    func testStripLineNumbers() {
        XCTAssertEqual(PDFTextExtractor.stripLineNumbers("platform for1"), "platform for")
        XCTAssertEqual(PDFTextExtractor.stripLineNumbers("visualisation tools 112"), "visualisation tools")
        XCTAssertEqual(PDFTextExtractor.stripLineNumbers("12 the data"), "the data")
        XCTAssertEqual(PDFTextExtractor.stripLineNumbers("no numbers here"), "no numbers here")
    }

    private func pdfLines(_ texts: [String], page: Int = 0) -> [PDFLine] {
        texts.enumerated().map { i, text in
            PDFLine(text: text, bounds: CGRect(x: 72, y: 700 - CGFloat(i) * 14, width: 400, height: 11),
                    fontSize: 11, isBold: false, page: page)
        }
    }

    func testCleanLinesLeadingAndGluedNumbers() {
        let leading = pdfLines(["15 The study was", "16published in", "17", "18 2020 and later revised."])
        XCTAssertEqual(PDFTextExtractor.cleanLines([leading]).first?.map(\.text),
                       ["The study was", "published in", "2020 and later revised."])
        let trailing = pdfLines(["The study was 15", "published in 202016", "17", "and later revised.18"])
        XCTAssertEqual(PDFTextExtractor.cleanLines([trailing]).first?.map(\.text),
                       ["The study was", "published in 2020", "and later revised."])
    }

    func testCleanLinesKeepsOrdinaryNumbers() {
        let lines = pdfLines(["We sampled 120", "patients in total and", "found 3 cases of the", "disease among them."])
        XCTAssertEqual(PDFTextExtractor.cleanLines([lines]).first?.map(\.text), lines.map(\.text))
    }

    func testIndentedParagraphsWithoutGap() {
        let doc = SyntheticPDF.make(pages: [[
            body("The first paragraph is typeset like LaTeX does it and"),
            body("its last line is long enough to look like a full line."),
            body("      The second paragraph starts with an indent only,"),
            body("without any vertical space between the two paragraphs."),
        ]])
        XCTAssertEqual(paragraphs(PDFTextExtractor.extract(doc).markdown).count, 2)
    }

    func testHyphenationJoined() {
        let doc = SyntheticPDF.make(pages: [[
            body("We study the visua-"),
            body("lisation of data in this work."),
        ]])
        XCTAssertTrue(PDFTextExtractor.extract(doc).markdown.contains("visualisation of data"))
    }

    func testRunningHeaderRemoved() {
        let page = [body("Some body text on this page for testing."), body("Another line of the same paragraph.")]
        let doc = SyntheticPDF.make(pages: [page, page, page], header: "Journal X — Preprint")
        let result = PDFTextExtractor.extract(doc)
        XCTAssertFalse(result.markdown.contains("Journal X"), result.markdown)
        for line in result.markdown.components(separatedBy: "\n") {
            XCTAssertNil(line.range(of: #"^\s*\d+\s*$"#, options: .regularExpression), "Page number left: \(line)")
        }
        XCTAssertTrue(result.markdown.contains("Some body text on this page for testing."))
    }

    func testLigatures() {
        XCTAssertEqual(PDFTextExtractor.normalizeCharacters("ﬁgure ﬂow"), "figure flow")
        XCTAssertEqual(PDFTextExtractor.normalizeCharacters("eﬀect oﬃce baﬄe"), "effect office baffle")
        XCTAssertEqual(PDFTextExtractor.normalizeCharacters("soft\u{00AD}hyphen\u{00A0}space"), "softhyphen space")
    }

    func testMetadataFrontMatter() {
        let doc = SyntheticPDF.make(pages: [[body("Some text.")]])
        doc.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Study",
                                  PDFDocumentAttribute.authorAttribute: "A. Author"]
        let result = PDFTextExtractor.extract(doc)
        XCTAssertTrue(result.markdown.hasPrefix("---\ntitle: Study\nauthor: A. Author\n---\n"), result.markdown)
    }

    func testTwoColumnsReadingOrder() {
        let left = (1...5).map { body("L\($0) words of the left column which is rather wide") }
        let right = (1...5).map { body("R\($0) words of the right column") }
        let doc = SyntheticPDF.make(pages: [left + right], lineNumbers: true, twoColumns: true)
        let markdown = PDFTextExtractor.extract(doc).markdown
        let lastL = (1...5).compactMap { markdown.range(of: "L\($0) ")?.lowerBound }.max()
        let firstR = (1...5).compactMap { markdown.range(of: "R\($0) ")?.lowerBound }.min()
        XCTAssertEqual((1...10).compactMap { i in markdown.range(of: i <= 5 ? "L\(i) " : "R\(i - 5) ") }.count, 10, markdown)
        if let lastL, let firstR { XCTAssertLessThan(lastL, firstR, markdown) }
    }

    func testListItems() {
        let doc = SyntheticPDF.make(pages: [[
            body("The tools are:"),
            body("• first item"),
            body("• second item"),
        ]])
        let markdown = PDFTextExtractor.extract(doc).markdown
        XCTAssertTrue(markdown.contains("- first item\n- second item"), markdown)
    }

    func testBoldLineBecomesSubheading() {
        let doc = SyntheticPDF.make(pages: [[
            ("Data sources", 11, true),
            body("We used three public databases for the analysis of"),
            body("orthologous genes."),
        ]])
        let markdown = PDFTextExtractor.extract(doc).markdown
        XCTAssertTrue(markdown.hasPrefix("### Data sources\n\n"), markdown)
    }

    func testNumberedBoldLineBecomesHeading() {
        let doc = SyntheticPDF.make(pages: [[
            ("2. Methods", 11, true),
            body("We used three public databases for the analysis of"),
            body("orthologous genes."),
        ]])
        let markdown = PDFTextExtractor.extract(doc).markdown
        XCTAssertTrue(markdown.hasPrefix("### 2. Methods\n\n"), markdown)
    }

    func testWrappedLineStartingWithNumberStaysInParagraph() {
        let doc = SyntheticPDF.make(pages: [[
            body("The cohort was followed for a period of more than"),
            body("5. years in total, and the results were consistent."),
        ]])
        let markdown = PDFTextExtractor.extract(doc).markdown
        XCTAssertEqual(paragraphs(markdown), ["The cohort was followed for a period of more than 5. years in total, and the results were consistent."])
    }

    func testImporterRejectsLockedPDF() throws {
        let doc = SyntheticPDF.make(pages: [[body("A secret text in a locked file.")]])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("locked.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(doc.write(to: url, withOptions: [.userPasswordOption: "user", .ownerPasswordOption: "owner"]))
        XCTAssertTrue(PDFDocument(url: url)?.isLocked ?? false)
        XCTAssertThrowsError(try DocumentImporter.markdown(fromFileAt: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains(CoreStrings.pdfLocked), error.localizedDescription)
        }
    }

    func testImporterRoutesPDF() throws {
        let doc = SyntheticPDF.make(pages: [[body("Imported from a PDF file.")]])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("x.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(doc.write(to: url))
        XCTAssertTrue(DocumentImporter.supportedExtensions.contains("pdf"))
        let markdown = try DocumentImporter.markdown(fromFileAt: url)
        XCTAssertTrue(markdown.contains("Imported from a PDF file."), markdown)
    }

    func testScannedPageRecognized() {
        let doc = SyntheticPDF.makeScanned(pages: ["Scanned sample text"])
        let result = PDFTextExtractor.extract(doc)
        XCTAssertTrue(result.markdown.lowercased().contains("scanned sample text"), result.markdown)
        XCTAssertEqual(result.ocrPages, [0])
    }

    func testBlankScanGivesWarning() {
        let doc = SyntheticPDF.makeScanned(pages: [nil])
        let result = PDFTextExtractor.extract(doc)
        XCTAssertTrue(result.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testOCRDisabled() {
        let doc = SyntheticPDF.makeScanned(pages: ["Scanned sample text"])
        XCTAssertTrue(PDFTextExtractor.extract(doc, ocr: false).ocrPages.isEmpty)
    }

    func testImporterReportsOCRWarning() throws {
        let doc = SyntheticPDF.makeScanned(pages: ["Scanned sample text"])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("scan.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(doc.write(to: url))
        _ = try DocumentImporter.markdown(fromFileAt: url)
        XCTAssertEqual(DocumentImporter.lastImportWarnings, [CoreStrings.pdfOCRPages(1)], "\(DocumentImporter.lastImportWarnings)")
    }
}
