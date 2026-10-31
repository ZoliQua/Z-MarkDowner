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

    // MARK: Import as review marks

    private func annotatedSample() -> PDFDocument {
        let doc = SyntheticPDF.make(pages: [[body("Results show bugs in current tools for visualization.")]])
        let page = doc.page(at: 0)!
        let bugs = SyntheticPDF.bounds(of: "bugs", in: doc)
        let current = SyntheticPDF.bounds(of: "current", in: doc)
        page.addAnnotation(SyntheticPDF.markup(.highlight, over: [bugs], contents: #"Change "bugs" to "regressions"."#, author: "Reviewer"))
        page.addAnnotation(SyntheticPDF.markup(.strikeOut, over: [current], author: "Reviewer"))
        return SyntheticPDF.reloaded(doc)
    }

    func testImportedPDFContainsReviewMarks() {
        let doc = annotatedSample()
        let marked = PDFTextExtractor.extract(doc, ocr: false, includeAnnotations: true).markdown
        XCTAssertTrue(marked.contains(#"{==bugs==}{>>Reviewer: Change "bugs" to "regressions".<<}"#), marked)
        XCTAssertTrue(marked.contains("{--current--}"), marked)
        XCTAssertFalse(marked.contains("## "), marked)
        let plain = PDFTextExtractor.extract(doc, ocr: false, includeAnnotations: false).markdown
        XCTAssertFalse(plain.contains("{=="), plain)
        XCTAssertFalse(plain.contains("{--"), plain)
        XCTAssertFalse(plain.contains("{>>"), plain)
    }

    func testReviewMarksDefaultFollowsRevisionMode() {
        let saved = DocumentImporter.revisionMode
        defer { DocumentImporter.revisionMode = saved }
        let doc = annotatedSample()
        DocumentImporter.revisionMode = .markup
        XCTAssertTrue(PDFTextExtractor.extract(doc, ocr: false).markdown.contains("{=="))
        DocumentImporter.revisionMode = .accept
        XCTAssertFalse(PDFTextExtractor.extract(doc, ocr: false).markdown.contains("{=="))
    }

    func testUnanchoredCommentsGoToCommentsSection() {
        let doc = SyntheticPDF.make(pages: [[body("Results show bugs in current tools for visualization.")]])
        let note = PDFAnnotation(bounds: CGRect(x: 400, y: 100, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Please cite the original study."
        note.userName = "Reviewer"
        doc.page(at: 0)!.addAnnotation(note)
        let marked = PDFTextExtractor.extract(SyntheticPDF.reloaded(doc), ocr: false, includeAnnotations: true).markdown
        XCTAssertTrue(marked.contains("## Comments"), marked)
        XCTAssertTrue(marked.contains("- p. 1, Reviewer: Please cite the original study."), marked)
        XCTAssertFalse(marked.contains("{>>"), marked)
    }

    func testReviewMarkFormatting() {
        let c = ReviewComment(id: "p0-0", page: 0, author: "A", kind: .highlight, quotedText: "bugs", comment: "x <<} y")
        XCTAssertEqual(PDFTextExtractor.reviewMark(for: c, quote: "bugs"), "{==bugs==}{>>A: x << } y<<}")
        let bare = ReviewComment(id: "p0-0", page: 0, kind: .underline, quotedText: "bugs")
        XCTAssertEqual(PDFTextExtractor.reviewMark(for: bare, quote: "bugs"), "{==bugs==}")
        let strike = ReviewComment(id: "p0-0", page: 0, author: "A", kind: .strikeOut, quotedText: "bugs", comment: "no")
        XCTAssertEqual(PDFTextExtractor.reviewMark(for: strike, quote: "bugs"), "{--bugs--}{>>A: no<<}")
        let caret = ReviewComment(id: "p0-0", page: 0, author: "A", kind: .caret, comment: ", however,")
        XCTAssertEqual(PDFTextExtractor.reviewMark(for: caret, quote: ""), "{>>A: , however,<<}")
        let insert = ReviewComment(id: "p0-0", page: 0, kind: .highlight, quotedText: "tools", comment: "add",
                                   suggestion: .insertAfter(target: "tools", text: " here"))
        XCTAssertEqual(PDFTextExtractor.reviewMark(for: insert, quote: "tools"), "{==tools==}{>>add<<}{++ here++}")
    }

    func testMarksAvoidMarkdownLinePrefix() {
        let source = "# Title words\n\n- first item here\n"
        let ranges = PDFTextExtractor.insertionRanges(for: [NSRange(location: 0, length: 7), NSRange(location: 15, length: 8)], in: source)
        XCTAssertEqual(ranges[0], NSRange(location: 2, length: 5))
        XCTAssertEqual(ranges[1], NSRange(location: 17, length: 6))
    }

    func testCommentWithBlankLineStaysOneMark() {
        let c = ReviewComment(id: "p0-0", page: 0, author: "A", kind: .highlight, quotedText: "bugs",
                              comment: "First.\n\nSecond.", suggestion: .insertAfter(target: "bugs", text: " a\n\nb"))
        XCTAssertEqual(PDFTextExtractor.reviewMark(for: c, quote: "bugs"), "{==bugs==}{>>A: First. Second.<<}{++ a b++}")
    }

    func testRangesStayOnOneLineAndOutsideSpans() {
        let list = "- a\n- b\n"
        XCTAssertEqual(PDFTextExtractor.insertionRanges(for: [NSRange(location: 2, length: 6)], in: list), [NSRange(location: 2, length: 1)])
        let bold = "x **bugs** y"
        XCTAssertEqual(PDFTextExtractor.insertionRanges(for: [NSRange(location: 4, length: 3)], in: bold), [NSRange(location: 2, length: 8)])
        XCTAssertEqual(PDFTextExtractor.insertionRanges(for: [NSRange(location: 0, length: 6)], in: bold), [NSRange(location: 0, length: 10)])
        let code = "use `foo bar` now"
        XCTAssertEqual(PDFTextExtractor.insertionRanges(for: [NSRange(location: 8, length: 0)], in: code), [NSRange(location: 13, length: 0)])
    }

    func testReviewMarksParseBack() {
        let source = "# Title\n\n- first bugs item\n- second **bold words** item\n\nPlain text here.\n"
        let comments = [
            ReviewComment(id: "a", page: 0, author: "R", kind: .highlight, quotedText: "bugs item second bold", comment: "One.\n\nTwo."),
            ReviewComment(id: "b", page: 0, author: "R", kind: .highlight, quotedText: "bold", comment: "Bold one."),
        ]
        let marked = PDFTextExtractor.addingReviewMarks(from: comments, to: source)
        let blocks = MarkdownParser.parseBlocks(marked)
        let text = "\(blocks)"
        XCTAssertTrue(text.contains("highlight"), text)
        XCTAssertTrue(text.contains("comment(\"R: Bold one.\")") || text.contains("comment(\"R: One. Two.\")"), text)
        XCTAssertTrue(marked.contains("{==**bold words**==}"), marked)
        XCTAssertTrue(marked.contains("{==bugs item==}{>>R: One. Two.<<}\n- second"), marked)
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

    /// The quote of one highlight whose quad is `rect` on a one-line page.
    private func quote(over rect: (PDFDocument) -> CGRect, line: String, lineNumbers: Bool = false) -> String? {
        let doc = SyntheticPDF.make(pages: [[body(line)]], lineNumbers: lineNumbers)
        doc.page(at: 0)!.addAnnotation(SyntheticPDF.markup(.highlight, over: [rect(doc)], contents: "x"))
        return PDFReviewExtractor.comments(from: SyntheticPDF.reloaded(doc)).first?.quotedText
    }

    func testQuoteSnapsToWholeWords() {
        let line = "Results show bugs in current tools for visualization of data."
        // Overshoots by one character into the next word.
        XCTAssertEqual(quote(over: { SyntheticPDF.bounds(of: "current t", in: $0) }, line: line), "current")
        // Stops one or two characters short.
        XCTAssertEqual(quote(over: { SyntheticPDF.bounds(of: "visualizatio", in: $0) }, line: line), "visualization")
        XCTAssertEqual(quote(over: { SyntheticPDF.bounds(of: "visualizati", in: $0) }, line: line), "visualization")
        // Starts one character late and overshoots by part of a character.
        XCTAssertEqual(quote(over: { doc in
            let r = SyntheticPDF.bounds(of: "tools", in: doc)
            return CGRect(x: r.minX + 2, y: r.minY, width: r.width + 1, height: r.height)
        }, line: line), "tools")
        // A quad reaching over the lineno number after the word.
        XCTAssertEqual(quote(over: { doc in
            SyntheticPDF.bounds(of: "controls", in: doc).union(SyntheticPDF.bounds(of: "1", in: doc))
        }, line: "interpretations of negative controls", lineNumbers: true), "controls")
    }

    func testQuoteKeepsSpacesBetweenSpacelessWords() {
        let doc = SyntheticPDF.makeSpaceless(lines: [["We", "present", "alpha", "beta", "gamma", "today"],
                                                     ["and", "delta", "epsilon", "here."]])
        let page = doc.page(at: 0)!
        let quad = SyntheticPDF.bounds(of: "alpha", in: doc).union(SyntheticPDF.bounds(of: "gamma", in: doc))
        page.addAnnotation(SyntheticPDF.markup(.highlight, over: [quad], contents: "x"))
        let twoLines = [SyntheticPDF.bounds(of: "today", in: doc), SyntheticPDF.bounds(of: "delta", in: doc)]
        page.addAnnotation(SyntheticPDF.markup(.underline, over: twoLines, contents: "y"))

        let comments = PDFReviewExtractor.comments(from: SyntheticPDF.reloaded(doc))
        XCTAssertEqual(comments.map(\.quotedText), ["alpha beta gamma", "today delta"])
        guard let first = comments.first else { return }
        XCTAssertEqual(first.contextBefore, "We present ")
        XCTAssertEqual(first.contextAfter, " today and delta epsilon here.")
    }

    func testWordsJoinWithSpacesAtBugsEvenWithoutSpaceCharacters() {
        // pdfTeX's justified text can come back from PDFKit without space characters between words; the
        // glyph bugs still separate them.
        typealias Word = PDFReviewExtractor.GlyphWord
        let words = [Word(text: "alpha", minX: 72, maxX: 98, spaceBefore: false),
                     Word(text: "beta", minX: 101, maxX: 122, spaceBefore: false),
                     Word(text: "gamma", minX: 125, maxX: 158, spaceBefore: false)]
        XCTAssertEqual(PDFReviewExtractor.joinWords(words, em: 11), "alpha beta gamma")
        // A gap under a fifth of the line height (0.2 pt with an 11 pt line) is not a word boundary.
        let split = [Word(text: "visual", minX: 72, maxX: 100, spaceBefore: false),
                     Word(text: "isation", minX: 100.2, maxX: 130, spaceBefore: false)]
        XCTAssertEqual(PDFReviewExtractor.joinWords(split, em: 11), "visualisation")
        let spaced = [Word(text: "a", minX: 72, maxX: 78, spaceBefore: false), Word(text: "b", minX: 78.5, maxX: 84, spaceBefore: true)]
        XCTAssertEqual(PDFReviewExtractor.joinWords(spaced, em: 11), "a b")
    }

    func testGlyphWithoutBoxNeverAddsASpace() {
        // An edge glyph PDFKit gives no box has no position, so there is no gap to measure: only whitespace
        // in the page string separates the words. A 0 stand-in would read as a gap of the full x-position.
        typealias Word = PDFReviewExtractor.GlyphWord
        let noLeftEdge = [Word(text: "visual", minX: 72, maxX: nil, spaceBefore: false),
                          Word(text: "isation", minX: 104, maxX: 130, spaceBefore: false)]
        XCTAssertEqual(PDFReviewExtractor.joinWords(noLeftEdge, em: 11), "visualisation")
        let noRightEdge = [Word(text: "visual", minX: 72, maxX: 100, spaceBefore: false),
                           Word(text: "isation", minX: nil, maxX: 130, spaceBefore: false)]
        XCTAssertEqual(PDFReviewExtractor.joinWords(noRightEdge, em: 11), "visualisation")
        let spaced = [Word(text: "a", minX: 72, maxX: nil, spaceBefore: false),
                      Word(text: "b", minX: nil, maxX: 84, spaceBefore: true)]
        XCTAssertEqual(PDFReviewExtractor.joinWords(spaced, em: 11), "a b")
    }

    func testGlyphWithoutBoxStaysInsideItsWord() {
        // "vis?al": the "?" has no box. It neither splits the word nor is dropped from it; a real gap still splits.
        func glyph(_ x: CGFloat?) -> (isSpace: Bool, box: CGRect?) {
            (false, x.map { CGRect(x: $0, y: 700, width: 5, height: 10) })
        }
        let glyphs = [glyph(72), glyph(77), glyph(82), glyph(nil), glyph(92), glyph(97), // "vis?al"
                      glyph(110), glyph(115),                                           // gap of 8 pt: "be"
                      (isSpace: true, box: nil), glyph(nil), glyph(130)]                // " ?x"
        XCTAssertEqual(PDFReviewExtractor.splitWords(glyphs, em: 10), [0...5, 6...7, 9...10])
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
        // Punctuation attached to the quote stays outside the target.
        XCTAssertEqual(parse("visualization,", #""visualisation""#), .replace(target: "visualization", with: "visualisation"))
        XCTAssertEqual(parse("(colour)", "should be “color”"), .replace(target: "colour", with: "color"))
        XCTAssertEqual(parse("colour,", "should be “color,”"), .replace(target: "colour", with: "color"))
        // An ellipsis marks a partial rewrite, not an applicable edit.
        XCTAssertNil(parse("the", #"I would change to: ".... a trailing ellipsis (three dots i.e. ... ), the.....""#))
        XCTAssertNil(parse("tools", "add after: “and so on…”"))
        XCTAssertEqual(parse("formatting regressions", #"I would change to: "formatting regressions that change project styling""#),
                       .replace(target: "formatting regressions", with: "formatting regressions that change project styling"))
    }
}
