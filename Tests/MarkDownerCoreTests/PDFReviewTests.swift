import XCTest
import PDFKit
@testable import MarkDownerCore

final class PDFReviewTests: XCTestCase {

    private typealias Line = (text: String, fontSize: CGFloat, bold: Bool)

    private func body(_ text: String) -> Line { (text, 11, false) }

    // MARK: Extraction

    func testExtractsHighlightNoteAndStrikeOut() {
        let doc = SyntheticPDF.make(pages: [[body("Results show bugs in current tools for visualization.")]])
        let page = doc.page(at: 0)!
        let bugs = SyntheticPDF.bounds(of: "bugs", in: doc)
        let current = SyntheticPDF.bounds(of: "current", in: doc)

        let highlight = SyntheticPDF.markup(.highlight, over: [bugs], contents: #"Change "bugs" to "regressions"."#, author: "Reviewer")
        let popup = PDFAnnotation(bounds: CGRect(x: 400, y: 500, width: 150, height: 80), forType: .popup, withProperties: nil)
        popup.contents = highlight.contents
        highlight.popup = popup
        let strike = SyntheticPDF.markup(.strikeOut, over: [current], author: "Reviewer")
        let note = PDFAnnotation(bounds: CGRect(x: 72, y: 400, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Please cite the original study."
        note.userName = "Reviewer"
        let link = PDFAnnotation(bounds: bugs.insetBy(dx: -2, dy: -2), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.org")
        // Added out of reading order on purpose.
        for annotation in [note, strike, link, popup, highlight] { page.addAnnotation(annotation) }

        let comments = PDFReviewExtractor.comments(from: SyntheticPDF.reloaded(doc))
        XCTAssertEqual(comments.count, 3, "\(comments)")
        guard comments.count == 3 else { return }
        XCTAssertEqual(comments.map(\.kind), [.highlight, .strikeOut, .note])
        XCTAssertEqual(comments.map(\.id), ["p0-0", "p0-1", "p0-2"])
        XCTAssertEqual(comments[0].quotedText, "bugs")
        XCTAssertEqual(comments[1].quotedText, "current")
        XCTAssertEqual(comments[0].author, "Reviewer")
        XCTAssertEqual(comments[0].page, 0)
        XCTAssertEqual(comments[0].comment, #"Change "bugs" to "regressions"."#)
        XCTAssertNotNil(comments[0].date)
        XCTAssertTrue(comments[0].contextBefore.hasSuffix("Results show "), comments[0].contextBefore)
        XCTAssertTrue(comments[0].contextAfter.hasPrefix(" in current tools"), comments[0].contextAfter)
        XCTAssertEqual(comments[0].suggestion, .replace(target: "bugs", with: "regressions"))
        XCTAssertEqual(comments[1].suggestion, .delete(target: "current"))
        XCTAssertEqual(comments[2].comment, "Please cite the original study.")
        XCTAssertEqual(comments[2].quotedText, "")
        XCTAssertNil(comments[2].suggestion)
        XCTAssertTrue(comments.allSatisfy { $0.status == .open && !$0.suggestionIsAI && $0.reply.isEmpty })
    }

    func testCaretInsertsAfterPrecedingWord() {
        let doc = SyntheticPDF.make(pages: [[body("Results show bugs in current tools for visualization.")]])
        let tools = SyntheticPDF.bounds(of: "tools", in: doc)
        let caret = PDFAnnotation(bounds: CGRect(x: tools.maxX - 2, y: tools.minY - 3, width: 5, height: 7), forType: PDFAnnotationSubtype(rawValue: "/Caret"), withProperties: nil)
        caret.contents = ", however,"
        caret.userName = "Reviewer"
        doc.page(at: 0)!.addAnnotation(caret)

        let comments = PDFReviewExtractor.comments(from: SyntheticPDF.reloaded(doc))
        XCTAssertEqual(comments.count, 1)
        guard let comment = comments.first else { return }
        XCTAssertEqual(comment.kind, .caret)
        XCTAssertEqual(comment.quotedText, "")
        XCTAssertTrue(comment.contextBefore.hasSuffix("current tools"), comment.contextBefore)
        XCTAssertTrue(comment.contextAfter.hasPrefix(" for visualization"), comment.contextAfter)
        XCTAssertEqual(comment.suggestion, .insertAfter(target: "tools", text: ", however,"))
    }

    func testMultiLineQuoteJoinsHyphenatedWord() {
        let doc = SyntheticPDF.make(pages: [[body("Interactive data visua-"), body("lisation tools help researchers.")]])
        let first = SyntheticPDF.bounds(of: "visua-", in: doc)
        let second = SyntheticPDF.bounds(of: "lisation", in: doc)
        doc.page(at: 0)!.addAnnotation(SyntheticPDF.markup(.underline, over: [first, second], contents: "Spell it the American way."))

        let comments = PDFReviewExtractor.comments(from: SyntheticPDF.reloaded(doc))
        XCTAssertEqual(comments.count, 1)
        guard let comment = comments.first else { return }
        XCTAssertEqual(comment.kind, .underline)
        XCTAssertEqual(comment.quotedText, "visualisation")
        XCTAssertEqual(comment.contextBefore, "Interactive data ")
        XCTAssertEqual(comment.contextAfter, " tools help researchers.")
        XCTAssertNil(comment.suggestion)
    }

    func testContextIsCleanedOfLineNumbersAndLimited() {
        let words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
        let doc = SyntheticPDF.make(pages: [words.map { body("The \($0) platform for") }], lineNumbers: true)
        let target = SyntheticPDF.bounds(of: "epsilon", in: doc)
        doc.page(at: 0)!.addAnnotation(SyntheticPDF.markup(.highlight, over: [target], contents: "delete"))

        let comments = PDFReviewExtractor.comments(from: SyntheticPDF.reloaded(doc))
        XCTAssertEqual(comments.count, 1)
        guard let comment = comments.first else { return }
        XCTAssertEqual(comment.quotedText, "epsilon")
        XCTAssertLessThanOrEqual(comment.contextBefore.count, 60)
        XCTAssertLessThanOrEqual(comment.contextAfter.count, 60)
        XCTAssertFalse(comment.contextBefore.contains { $0.isNumber }, comment.contextBefore)
        XCTAssertFalse(comment.contextAfter.contains { $0.isNumber }, comment.contextAfter)
        XCTAssertTrue(comment.contextBefore.hasSuffix("The delta platform for The "), comment.contextBefore)
        XCTAssertTrue(comment.contextAfter.hasPrefix(" platform for The zeta platform for"), comment.contextAfter)
        XCTAssertEqual(comment.suggestion, .delete(target: "epsilon"))
    }

    func testRepliesAuthorAndCreationDate() {
        let doc = SyntheticPDF.makeRaw(text: "Results show bugs in current tools.", annotations: [
            "<< /Type /Annot /Subtype /Highlight /Rect [140 697 164 708] /QuadPoints [140 708 164 708 140 697 164 697] /Contents (Too vague.) /T (Reviewer) /CreationDate (D:20260102030405Z) /Popup 8 0 R >>",
            "<< /Type /Annot /Subtype /Text /Rect [500 700 520 720] /Contents (I agree, will fix.) /T (Author) /IRT 6 0 R >>",
            "<< /Type /Annot /Subtype /Popup /Rect [400 600 500 650] /Parent 6 0 R >>",
        ])
        let comments = PDFReviewExtractor.comments(from: doc)
        XCTAssertEqual(comments.count, 1, "\(comments)")
        guard let comment = comments.first else { return }
        XCTAssertEqual(comment.quotedText, "bugs")
        XCTAssertEqual(comment.author, "Reviewer")
        XCTAssertEqual(comment.comment, "Too vague.")
        XCTAssertEqual(comment.replies, ["I agree, will fix."])
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute, components.second) = (2026, 1, 2, 3, 4, 5)
        components.timeZone = TimeZone(identifier: "UTC")
        XCTAssertEqual(comment.date, Calendar(identifier: .gregorian).date(from: components))
    }

    func testCommentRoundTripsThroughJSON() throws {
        var comment = ReviewComment(id: "p2-0", page: 2, author: "Reviewer", date: Date(timeIntervalSince1970: 1_000_000),
                                    kind: .highlight, quotedText: "bugs", contextBefore: "Results show ",
                                    contextAfter: " in current", comment: "Change it")
        comment.suggestion = .insertBefore(target: "bugs", text: "major ")
        comment.status = .applied
        comment.replies = ["ok"]
        let data = try JSONEncoder().encode([comment])
        XCTAssertEqual(try JSONDecoder().decode([ReviewComment].self, from: data), [comment])
    }

    func testReplyThreadingSkipsMismatchedPairs() {
        // PDFKit drops the Text annotation without /Rect (object 7), so ranking by subtype alone would pair
        // the reply (object 8) with the note (object 9) and swallow the note as a reply.
        let doc = SyntheticPDF.makeRaw(text: "Results show bugs in current tools.", annotations: [
            "<< /Type /Annot /Subtype /Highlight /Rect [140 697 164 708] /QuadPoints [140 708 164 708 140 697 164 697] /Contents (Too vague.) /T (Reviewer) >>",
            "<< /Type /Annot /Subtype /Text /Contents (No rect.) >>",
            "<< /Type /Annot /Subtype /Text /Rect [500 700 520 720] /Contents (I agree.) /T (Author) /IRT 6 0 R >>",
            "<< /Type /Annot /Subtype /Text /Rect [72 400 92 420] /Contents (Separate note.) /T (Reviewer) >>",
        ])
        XCTAssertEqual(doc.page(at: 0)?.annotations.filter { $0.type == "Text" }.count, 2, "fixture assumption: PDFKit drops the Rect-less note")
        let comments = PDFReviewExtractor.comments(from: doc)
        XCTAssertTrue(comments.contains { $0.comment == "Separate note." }, "\(comments)")
        XCTAssertFalse(comments.contains { $0.replies.contains("Separate note.") }, "\(comments)")
        XCTAssertEqual(comments.first { $0.kind == .highlight }?.replies.contains("Separate note."), false)
    }

    func testCommentDecodingIsTolerant() throws {
        let minimal = try JSONDecoder().decode(ReviewComment.self, from: Data(#"{"id":"p0-0"}"#.utf8))
        XCTAssertEqual(minimal, ReviewComment(id: "p0-0", page: 0, kind: .highlight))
        XCTAssertEqual(minimal.status, .open)
        XCTAssertEqual(minimal.replies, [])
        XCTAssertNil(minimal.suggestion)
        let extra = try JSONDecoder().decode(ReviewComment.self, from: Data(#"{"id":"p1-2","page":1,"status":"done","reply":"Fixed.","futureField":{"x":1}}"#.utf8))
        XCTAssertEqual(extra.id, "p1-2")
        XCTAssertEqual(extra.page, 1)
        XCTAssertEqual(extra.status, .done)
        XCTAssertEqual(extra.reply, "Fixed.")
        XCTAssertThrowsError(try JSONDecoder().decode(ReviewComment.self, from: Data(#"{"page":1}"#.utf8)))
    }

    // MARK: Instructions

    func testInstructionPatterns() {
        let cases: [(String, String, String, Suggestion?)] = [
            ("tools", #"Add after this: "(SDT)" so readers know the abbreviation."#, "", .insertAfter(target: "tools", text: " (SDT)")),
            ("visualization", #"This journal uses British spelling: "visualisation"."#, "", .replace(target: "visualization", with: "visualisation")),
            ("very", "delete", "", .delete(target: "very")),
            ("color", "should be “colour”", "", .replace(target: "color", with: "colour")),
            ("the method", #"Replace "method" with "approach""#, "", .replace(target: "method", with: "approach")),
            ("Data", "I think this paragraph could be shortened.", "", nil),
        ]
        for (q, c, s, expected) in cases {
            XCTAssertEqual(ReviewInstructionParser.suggestion(kind: .highlight, quoted: q, comment: c, sentence: s), expected, c)
        }
    }

    func testMoreInstructionPatterns() {
        func parse(_ q: String, _ c: String, _ s: String = "", kind: AnnotationKind = .highlight) -> Suggestion? {
            ReviewInstructionParser.suggestion(kind: kind, quoted: q, comment: c, sentence: s)
        }
        XCTAssertEqual(parse("in", #"change "in" to "on""#), .replace(target: "in", with: "on"))
        XCTAssertEqual(parse("results", #"Change "data" to "datasets""#, "Our data and results agree."), .replace(target: "data", with: "datasets"))
        XCTAssertNil(parse("results", #"Change "data" to "datasets""#, "Our results agree."))
        XCTAssertEqual(parse("big", "change to ‘large’"), .replace(target: "big", with: "large"))
        XCTAssertEqual(parse("big", "→ „large”"), .replace(target: "big", with: "large"))
        XCTAssertEqual(parse("big", "Replace with 'large'."), .replace(target: "big", with: "large"))
        XCTAssertEqual(parse("cohort", #"Add "independent" before"#), .insertBefore(target: "cohort", text: "independent "))
        XCTAssertEqual(parse("cohort", #"insert before this: "independent""#), .insertBefore(target: "cohort", text: "independent "))
        XCTAssertEqual(parse("tools", #"add ", for example," after"#), .insertAfter(target: "tools", text: ", for example,"))
        XCTAssertEqual(parse("very", "Remove this."), .delete(target: "very"))
        XCTAssertEqual(parse("very", "OMIT!"), .delete(target: "very"))
        XCTAssertNil(parse("very", "Do not delete this word."))
        XCTAssertNil(parse("data", "It's the authors' choice."))
        XCTAssertNil(parse("a", #"Maybe "the following" reads better."#))
        XCTAssertEqual(parse("current", "", kind: .strikeOut), .delete(target: "current"))
        XCTAssertEqual(parse("current", "existing", kind: .strikeOut), .replace(target: "current", with: "existing"))
        XCTAssertEqual(parse("current", "“existing”", kind: .strikeOut), .replace(target: "current", with: "existing"))
        XCTAssertEqual(parse("current", "delete", kind: .strikeOut), .delete(target: "current"))
        XCTAssertEqual(parse("", "very", "Results show bugs", kind: .caret), .insertAfter(target: "bugs", text: " very"))
        XCTAssertNil(parse("", "very", "", kind: .caret))
        XCTAssertNil(parse("", "delete", kind: .note))
        XCTAssertNil(parse("bugs", "", kind: .highlight))
    }
}
