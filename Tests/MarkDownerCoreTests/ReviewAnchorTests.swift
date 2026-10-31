import XCTest
@testable import MarkDownerCore

final class ReviewAnchorTests: XCTestCase {

    private func source(_ text: String, _ range: NSRange?) -> String? {
        guard let range else { return nil }
        return (text as NSString).substring(with: range)
    }

    private func normalizedRange(of needle: String, in normalized: NormalizedText) -> NSRange {
        (normalized.text as NSString).range(of: needle)
    }

    private func sourceRange(_ r: NSRange, _ n: NormalizedText) -> NSRange {
        NSRange(location: n.map[r.location], length: n.ends[NSMaxRange(r) - 1] - n.map[r.location])
    }

    // MARK: Source format

    func testSourceFormatFromExtension() {
        XCTAssertEqual(SourceFormat(fileExtension: "tex"), .latex)
        XCTAssertEqual(SourceFormat(fileExtension: "LTX"), .latex)
        XCTAssertEqual(SourceFormat(fileExtension: "latex"), .latex)
        XCTAssertEqual(SourceFormat(fileExtension: "md"), .markdown)
        XCTAssertEqual(SourceFormat(fileExtension: "markdown"), .markdown)
        XCTAssertEqual(SourceFormat(fileExtension: "txt"), .plain)
        XCTAssertEqual(SourceFormat(fileExtension: ""), .plain)
    }

    // MARK: Normalisation

    func testLatexNormalization() {
        let text = "We present \\textit{SetDiagramTool}~\\cite{x} for vi\\-sual data % note\n"
        let n = NormalizedText(source: text, format: .latex)
        XCTAssertEqual(n.map.count, n.text.utf16.count + 1)
        XCTAssertTrue(n.text.contains("we present setdiagramtool for"), n.text)
        XCTAssertEqual(n.text, "we present setdiagramtool for visual data ")
        XCTAssertTrue(n.text.contains("for visual data"), n.text)
        XCTAssertFalse(n.text.contains("note"), n.text)
        XCTAssertFalse(n.text.contains("x"), n.text)
        let r = normalizedRange(of: "setdiagramtool", in: n)
        XCTAssertEqual(source(text, sourceRange(r, n)), "SetDiagramTool")
    }

    func testLatexSpecialCharacters() {
        let text = "``Fast'' tools---and 50\\% gains, see \\href{http://x.org}{our site}; 1--2 \\emph{Zolt\\'an} \\label{s1}\\ref{f}"
        let n = NormalizedText(source: text, format: .latex)
        XCTAssertTrue(n.text.contains("\"fast\" tools-and 50% gains, see our site; 1-2 zoltán"), n.text)
        XCTAssertFalse(n.text.contains("http"), n.text)
        XCTAssertFalse(n.text.contains("s1"), n.text)
        let r = normalizedRange(of: "50%", in: n)
        XCTAssertEqual(source(text, sourceRange(r, n)), "50\\%")
    }

    func testMarkdownNormalization() {
        let text = "# Title\n\nSee **bold** and [the link](http://x)\n- item `code`\n> quoted _text_ in snake_case"
        let n = NormalizedText(source: text, format: .markdown)
        XCTAssertEqual(n.map.count, n.text.utf16.count + 1)
        XCTAssertTrue(n.text.contains("see bold and the link"), n.text)
        XCTAssertFalse(n.text.contains("http"), n.text)
        XCTAssertFalse(n.text.contains("#"), n.text)
        XCTAssertTrue(n.text.contains(" item code"), n.text)
        XCTAssertTrue(n.text.contains(" quoted text in snake_case"), n.text)
        XCTAssertFalse(n.text.contains("- item"), n.text)
        let r = normalizedRange(of: "the link", in: n)
        XCTAssertEqual(source(text, sourceRange(r, n)), "the link")
    }

    func testPlainNormalizationFoldsTypography() {
        let text = "The “e\u{FB03}cient”  tool\u{2014}really\nworks"
        let n = NormalizedText(source: text, format: .plain)
        XCTAssertEqual(n.text, "the \"efficient\" tool-really works")
    }

    // MARK: Search

    func testUniqueExactMatch() {
        let text = "Intro.\n\nWe built a desktop-class editor for quick analysis."
        let n = NormalizedText(source: text, format: .plain)
        let r = ReviewAnchor.locate(quote: "Desktop-class editor", before: "", after: "", in: n)
        XCTAssertEqual(source(text, r), "desktop-class editor")
    }

    func testLocateComment() {
        let text = "We present \\textbf{SetDiagramTool}, a tool."
        let n = NormalizedText(source: text, format: .latex)
        let comment = ReviewComment(id: "p0-0", page: 0, kind: .highlight, quotedText: "SetDiagramTool, a tool")
        XCTAssertEqual(source(text, ReviewAnchor.locate(comment, in: n)), "SetDiagramTool}, a tool")
    }

    func testAmbiguousQuoteUsesContext() {
        let text = "First load the data. Then filter the data carefully. Finally plot the data."
        let n = NormalizedText(source: text, format: .plain)
        let r = ReviewAnchor.locate(quote: "data", before: "filter the ", after: "", in: n)
        let second = (text as NSString).range(of: "data", options: [], range: NSRange(location: 25, length: 30))
        XCTAssertEqual(r, second)
    }

    func testAmbiguousWithoutContextIsNil() {
        let text = "First load the data. Then filter the data carefully. Finally plot the data."
        let n = NormalizedText(source: text, format: .plain)
        XCTAssertNil(ReviewAnchor.locate(quote: "data", before: "", after: "", in: n))
    }

    func testFuzzyMatchAcrossLineNumbersAndHyphenation() {
        let text = "SetDiagramTool is a desk\\-top-class editor\nfor quick set analysis of large data."
        let n = NormalizedText(source: text, format: .latex)
        let r = ReviewAnchor.locate(quote: "desktop-class editor for quick", before: "", after: "", in: n)
        XCTAssertEqual(source(text, r), "desk\\-top-class editor\nfor quick")
        // A stray line number left inside the quote still anchors through the fuzzy step.
        let fuzzy = ReviewAnchor.locate(quote: "desktop-class editor 12 for quick set analysis", before: "", after: "", in: n)
        XCTAssertEqual(source(text, fuzzy), "desk\\-top-class editor\nfor quick set analysis")
    }

    func testGarbledLigatureAnchorsFuzzily() {
        let text = "Our method is efficient and scales to large inputs without loss."
        let n = NormalizedText(source: text, format: .plain)
        let r = ReviewAnchor.locate(quote: "method is e!cient and scales to large", before: "", after: "", in: n)
        XCTAssertEqual(source(text, r), "method is efficient and scales to large")
    }

    func testCitationBracketsInQuoteAnchorLatex() {
        let text = "Set diagrams are common~\\cite{venn1880,ruskey} in biology and medicine."
        let n = NormalizedText(source: text, format: .latex)
        let r = ReviewAnchor.locate(quote: "Set diagrams are common [12, 13] in biology", before: "", after: "", in: n)
        XCTAssertEqual(source(text, r), "Set diagrams are common~\\cite{venn1880,ruskey} in biology")
        let single = ReviewAnchor.locate(quote: "common [4] in biology and medicine", before: "", after: "", in: n)
        XCTAssertEqual(source(text, single), "common~\\cite{venn1880,ruskey} in biology and medicine")
    }

    func testShortQuoteNeedsContext() {
        let text = "This is a tool for data analysis with a plot."
        let n = NormalizedText(source: text, format: .plain)
        let r = ReviewAnchor.locate(quote: "a", before: "This is ", after: " tool for", in: n)
        XCTAssertEqual(r?.length, 1)
        XCTAssertEqual(r?.location, 8)
        XCTAssertNil(ReviewAnchor.locate(quote: "a", before: "", after: "", in: n))
        // Even a unique short quote is not trusted without context.
        XCTAssertNil(ReviewAnchor.locate(quote: "is", before: "", after: "", in: NormalizedText(source: "It is.", format: .plain)))
    }

    func testFuzzyTieIsNil() {
        let text = "alpha beta gamma delta one stop. alpha beta gamma delta two go."
        let n = NormalizedText(source: text, format: .plain)
        XCTAssertNil(ReviewAnchor.locate(quote: "alpha beta gamma delta epsilon", before: "", after: "", in: n))
        let r = ReviewAnchor.locate(quote: "alpha beta gamma delta epsilon", before: "", after: " go", in: n)
        XCTAssertEqual(source(text, r), "alpha beta gamma delta two")
    }

    func testUnrelatedQuoteIsNil() {
        let n = NormalizedText(source: "Completely different words live here.", format: .plain)
        XCTAssertNil(ReviewAnchor.locate(quote: "nothing of this appears anywhere", before: "", after: "", in: n))
    }

    func testCaretAnchorsBetweenContexts() {
        let text = "We tested the tool on three datasets and found bugs."
        let n = NormalizedText(source: text, format: .plain)
        let r = ReviewAnchor.locate(quote: "", before: "We tested the tool on three", after: " datasets and found", in: n)
        XCTAssertEqual(r, NSRange(location: NSMaxRange((text as NSString).range(of: "three")), length: 0))
    }
    func testLargeSourceAnchorsQuickly() {
        let paragraphs = (0..<2000).map { "Paragraph \($0) reports measurement \($0 * 7) for sample \($0 % 13) in detail." }
        let text = paragraphs.joined(separator: "\n\n")
        XCTAssertGreaterThan(text.utf16.count, 100_000)
        let started = Date()
        let n = NormalizedText(source: text, format: .markdown)
        let exact = ReviewAnchor.locate(quote: "Paragraph 1500 reports measurement 10500", before: "", after: "", in: n)
        XCTAssertEqual(source(text, exact), "Paragraph 1500 reports measurement 10500")
        let fuzzy = ReviewAnchor.locate(quote: "Paragraph 1500 reports measurement 10501 for sample", before: "", after: "", in: n)
        XCTAssertEqual(source(text, fuzzy), "Paragraph 1500 reports measurement 10500 for sample")
        let short = ReviewAnchor.locate(quote: "in", before: "for sample 9 ", after: " detail. Paragraph 1830", in: n)
        let expected = (text as NSString).range(of: "in detail.\n\nParagraph 1830 ")
        XCTAssertEqual(short, NSRange(location: expected.location, length: 2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testMarkdownQuoteMapsToMarkup() {
        let text = "## Results\n\nThe **efficient** method ([details](#d)) is fast."
        let n = NormalizedText(source: text, format: .markdown)
        let r = ReviewAnchor.locate(quote: "The e\u{FB03}cient method (details) is", before: "", after: "", in: n)
        XCTAssertEqual(source(text, r), "The **efficient** method ([details](#d)) is")
    }
    func testWrongOrIncidentalContextIsNil() {
        let text = "First load the data. Then filter the data carefully. Finally plot the data."
        let n = NormalizedText(source: text, format: .plain)
        XCTAssertNil(ReviewAnchor.locate(quote: "data", before: "we never measured ", after: " yesterday at all", in: n))
        // One stray shared word ("carefully" follows only the second occurrence) is not enough evidence.
        XCTAssertNil(ReviewAnchor.locate(quote: "data", before: "we never measured ", after: " so carefully again today", in: n))
        // "the" precedes every occurrence: agreement, but not unique.
        XCTAssertNil(ReviewAnchor.locate(quote: "data", before: "compute the ", after: "", in: n))
    }

    func testQuoteOnlyInsideLongerWordNeedsContext() {
        let text = "We store the metadata in a separate table."
        let n = NormalizedText(source: text, format: .plain)
        XCTAssertNil(ReviewAnchor.locate(quote: "data", before: "", after: "", in: n))
        let r = ReviewAnchor.locate(quote: "data", before: "We store the meta", after: " in a separate", in: n)
        XCTAssertEqual(r, (text as NSString).range(of: "data"))
    }
    func testGluedQuoteFromSpacelessPDFAnchors() {
        let text = "Existing tools fall short.\nWe present \\textbf{Set Diagram Tool}, a small program that compares\nlists of genes quickly. It runs offline."
        let n = NormalizedText(source: text, format: .latex)
        let quote = "WepresentSetDiagramTool,asmallprogramthatcompareslistsofgenesquickly."
        XCTAssertEqual(source(text, ReviewAnchor.locate(quote: quote, before: "", after: "", in: n)),
                       "We present \\textbf{Set Diagram Tool}, a small program that compares\nlists of genes quickly.")
    }

    func testRepeatedGluedQuoteIsNilUnlessContextDecides() {
        let sentence = "The interactive diagram updates instantly."
        let text = "Intro. \(sentence) Middle part. \(sentence) End."
        let n = NormalizedText(source: text, format: .plain)
        let quote = "Theinteractivediagramupdatesinstantly."
        XCTAssertNil(ReviewAnchor.locate(quote: quote, before: "", after: "", in: n))
        let r = ReviewAnchor.locate(quote: quote, before: "Middlepart.", after: "", in: n)
        XCTAssertEqual(r?.location, (text as NSString).range(of: "Middle part. ").upperBound)
    }

    func testShortGluedQuoteDoesNotUseDespacedPath() {
        let text = "We present a small program."
        let n = NormalizedText(source: text, format: .plain)
        XCTAssertNil(ReviewAnchor.locate(quote: "asmallprogram", before: "", after: "", in: n))
        XCTAssertNotNil(ReviewAnchor.locate(quote: "wepresentasmallprogram.", before: "", after: "", in: n))
    }
}
