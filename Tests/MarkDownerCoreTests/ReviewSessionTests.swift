import XCTest
@testable import MarkDownerCore

final class ReviewSessionTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    // MARK: Applying suggestions

    func testApplyReplace() throws {
        let text = "Results show bugs in coverage."
        let result = try ReviewSession.edit(applying: .replace(target: "bugs", with: "regressions"),
                                            at: range(of: "bugs", in: text), in: text)
        XCTAssertEqual(result.text, "Results show regressions in coverage.")
        XCTAssertEqual(result.delta, 7)
        XCTAssertEqual(result.range, NSRange(location: 13, length: 11))
    }

    func testApplyReplaceInsideWiderQuote() throws {
        let text = "Results show bugs in coverage."
        let result = try ReviewSession.edit(applying: .replace(target: "bugs", with: "holes"),
                                            at: range(of: "show bugs in", in: text), in: text)
        XCTAssertEqual(result.text, "Results show holes in coverage.")
        XCTAssertEqual(result.range, NSRange(location: 13, length: 5))
        XCTAssertEqual(result.delta, 1)
    }

    func testApplyInsertAfterAndDelete() throws {
        let text = "This is really good work."
        let inserted = try ReviewSession.edit(applying: .insertAfter(target: "good", text: " and careful"),
                                              at: range(of: "good", in: text), in: text)
        XCTAssertEqual(inserted.text, "This is really good and careful work.")
        XCTAssertEqual(inserted.range, NSRange(location: 19, length: 12))
        XCTAssertEqual(inserted.delta, 12)

        let before = try ReviewSession.edit(applying: .insertBefore(target: "work", text: "solid "),
                                            at: range(of: "work", in: text), in: text)
        XCTAssertEqual(before.text, "This is really good solid work.")

        let deleted = try ReviewSession.edit(applying: .delete(target: "really"),
                                             at: range(of: "really", in: text), in: text)
        XCTAssertEqual(deleted.text, "This is good work.")
        XCTAssertEqual(deleted.delta, -7)
        XCTAssertEqual(deleted.range, NSRange(location: 7, length: 0))
    }

    func testInsertAfterAtCaret() throws {
        let text = "We used the method here."
        let caret = NSRange(location: range(of: "method", in: text).upperBound, length: 0)
        let result = try ReviewSession.edit(applying: .insertAfter(target: "method", text: " proposed"), at: caret, in: text)
        XCTAssertEqual(result.text, "We used the method proposed here.")
    }

    func testInsertTargetMustBeAtEdge() {
        let text = "This is really good work."
        XCTAssertThrowsError(try ReviewSession.edit(applying: .insertAfter(target: "really", text: " very"),
                                                    at: range(of: "really good", in: text), in: text))
        XCTAssertThrowsError(try ReviewSession.edit(applying: .insertBefore(target: "good", text: "very "),
                                                    at: range(of: "really good", in: text), in: text))
    }

    func testTargetChangedThrows() {
        let text = "Results show gapz in coverage."
        XCTAssertThrowsError(try ReviewSession.edit(applying: .replace(target: "bugs", with: "regressions"),
                                                    at: NSRange(location: 13, length: 4), in: text)) { error in
            guard case ReviewSessionError.targetChanged(let target)? = error as? ReviewSessionError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(target, "bugs")
        }
        XCTAssertThrowsError(try ReviewSession.edit(applying: .delete(target: "bugs"),
                                                    at: NSRange(location: 28, length: 10), in: text))
    }

    func testApplyInLatexComparesProse() throws {
        let text = "We present \\textit{SetDiagramTool}~\\cite{x} here."
        let quote = range(of: "SetDiagramTool", in: text)
        let result = try ReviewSession.edit(applying: .replace(target: "SetDiagramTool", with: "SDT"),
                                            at: quote, in: text, format: .latex)
        XCTAssertEqual(result.text, "We present \\textit{SDT}~\\cite{x} here.")
        let wide = NSRange(location: 11, length: range(of: "~", in: text).location - 11)
        XCTAssertNoThrow(try ReviewSession.edit(applying: .insertAfter(target: "SetDiagramTool", text: " (SDT)"),
                                                at: wide, in: text, format: .latex))
    }

    func testReplaceKeepsLatexMarkup() throws {
        let text = "We study \\textit{rare} birds in winter."
        let anchor = range(of: "rare} birds", in: text)
        let replaced = try ReviewSession.edit(applying: .replace(target: "rare birds", with: "common finches"),
                                              at: anchor, in: text, format: .latex)
        XCTAssertEqual(replaced.text, "We study \\textit{common finches} in winter.")
        XCTAssertEqual(replaced.range, range(of: "common finches", in: replaced.text))
        XCTAssertEqual(replaced.delta, ("common finches}" as NSString).length - ("rare} birds" as NSString).length)
        let deleted = try ReviewSession.edit(applying: .delete(target: "rare birds"), at: anchor, in: text, format: .latex)
        XCTAssertEqual(deleted.text, "We study \\textit{} in winter.")
        let wide = NSRange(location: range(of: "study", in: text).location, length: anchor.upperBound - range(of: "study", in: text).location)
        let inner = try ReviewSession.edit(applying: .replace(target: "rare birds", with: "owls"), at: wide, in: text, format: .latex)
        XCTAssertEqual(inner.text, "We study \\textit{owls} in winter.")
    }

    func testReplaceKeepsMarkdownMarkup() throws {
        let text = "Some *quoted* words here."
        let whole = try ReviewSession.edit(applying: .replace(target: "quoted words", with: "cited terms"),
                                           at: range(of: "quoted* words", in: text), in: text, format: .markdown)
        XCTAssertEqual(whole.text, "Some *cited terms* here.")
        let bold = "A **bold** claim."
        let edge = try ReviewSession.edit(applying: .replace(target: "bold", with: "strong"),
                                          at: range(of: "**bold**", in: bold), in: bold, format: .markdown)
        XCTAssertEqual(edge.text, "A **strong** claim.")
    }

    func testEditAcrossLinkThrowsSpansMarkup() {
        let text = "See [the docs](https://example.com) now."
        XCTAssertThrowsError(try ReviewSession.edit(applying: .replace(target: "docs now", with: "manual"),
                                                    at: range(of: "docs](https://example.com) now", in: text),
                                                    in: text, format: .markdown)) { error in
            guard case ReviewSessionError.spansMarkup? = error as? ReviewSessionError else { return XCTFail("unexpected \(error)") }
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
    }

    // MARK: Persistence

    private func sampleSession() -> ReviewSession {
        let comments = [
            ReviewComment(id: "p0-0", page: 0, author: "Reviewer", date: Date(timeIntervalSince1970: 1_700_000_000),
                          kind: .highlight, quotedText: "bugs", contextBefore: "Results show", contextAfter: "in coverage",
                          comment: "Use regressions", suggestion: .replace(target: "bugs", with: "regressions"),
                          suggestionIsAI: true),
            ReviewComment(id: "p1-0", page: 1, author: "R2", kind: .note, comment: "Nice figure.", status: .done, reply: "Thanks."),
        ]
        return ReviewSession(pdfPath: "/tmp/review.pdf", mainPath: folder.appendingPathComponent("paper.tex").path,
                             sourceFormat: .latex, comments: comments, createdAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    func testSidecarRoundTrip() throws {
        let source = folder.appendingPathComponent("paper.tex")
        XCTAssertEqual(ReviewSession.sidecarURL(for: source).lastPathComponent, "paper.tex.review.json")
        XCTAssertEqual(ReviewSession.sidecarURL(for: source).deletingLastPathComponent().path, folder.path)
        let session = sampleSession()
        try session.save(for: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("paper.tex.review.json").path))
        XCTAssertEqual(ReviewSession.load(for: source), session)
    }

    func testSidecarStoresISODatesAndToleratesUnknownValues() throws {
        let source = folder.appendingPathComponent("paper.md")
        var session = sampleSession()
        session.comments[0].date = Date(timeIntervalSince1970: 1_700_000_000)
        try session.save(for: source)
        let json = try String(contentsOf: ReviewSession.sidecarURL(for: source), encoding: .utf8)
        XCTAssertTrue(json.contains(#""createdAt" : "2023-11-14T22:15:00Z""#), json)
        XCTAssertTrue(json.contains(#""date" : "2023-11-14T22:13:20Z""#), json)
        XCTAssertEqual(ReviewSession.load(for: source), session)

        let newer = """
        {"pdfPath":"/tmp/r.pdf","mainPath":"/tmp/paper.md","sourceFormat":"markdown","createdAt":"2026-10-31T08:30:00.250Z",
         "comments":[
          {"id":"p0-0","kind":"stamp","status":"archived","suggestion":{"rewrite":{"target":"a"}},"comment":"From a newer version.",
           "date":"2026-10-31T08:00:00Z"},
          {"id":"p0-1","kind":"note","status":"done","comment":"Fine.","reply":"Thanks."},
          {"id":"p0-2","kind":"highlight","suggestion":{"replace":{"target":"bugs","with":"regressions"}}}
         ]}
        """
        try Data(newer.utf8).write(to: ReviewSession.sidecarURL(for: source))
        let loaded = try XCTUnwrap(ReviewSession.load(for: source))
        XCTAssertEqual(loaded.comments.map(\.id), ["p0-0", "p0-1", "p0-2"])
        XCTAssertEqual(loaded.comments[0].kind, .highlight)
        XCTAssertEqual(loaded.comments[0].status, .open)
        XCTAssertNil(loaded.comments[0].suggestion)
        XCTAssertEqual(loaded.comments[0].comment, "From a newer version.")
        XCTAssertEqual(loaded.comments[0].date, Date(timeIntervalSince1970: 1_793_433_600))
        XCTAssertEqual(loaded.comments[1].status, .done)
        XCTAssertEqual(loaded.comments[1].reply, "Thanks.")
        XCTAssertEqual(loaded.comments[2].suggestion, .replace(target: "bugs", with: "regressions"))
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970, 1_793_435_400.25, accuracy: 0.001)
    }

    func testCorruptSidecarIgnored() throws {
        let source = folder.appendingPathComponent("paper.md")
        XCTAssertNil(ReviewSession.load(for: source))
        try Data("not json {".utf8).write(to: ReviewSession.sidecarURL(for: source))
        XCTAssertNil(ReviewSession.load(for: source))
    }

    func testSidecarFromOtherPDFIgnored() throws {
        let source = folder.appendingPathComponent("paper.tex")
        var session = sampleSession()
        let pdf = folder.appendingPathComponent("review.pdf")
        try Data("%PDF".utf8).write(to: pdf)
        session.pdfPath = pdf.path
        try session.save(for: source)
        XCTAssertEqual(ReviewSession.load(for: source, pdf: pdf), session)
        XCTAssertEqual(ReviewSession.load(for: source, pdf: folder.appendingPathComponent("./review.pdf")), session)
        XCTAssertEqual(ReviewSession.load(for: source), session)
        XCTAssertNil(ReviewSession.load(for: source, pdf: folder.appendingPathComponent("other.pdf")))

        session.pdfPath = "/no/longer/here/review.pdf"
        try session.save(for: source)
        XCTAssertEqual(ReviewSession.load(for: source, pdf: pdf), session, "a moved PDF is recognised by name")
        XCTAssertNil(ReviewSession.load(for: source, pdf: folder.appendingPathComponent("round2.pdf")))
    }

    // MARK: Review marks

    func testCriticMarks() {
        XCTAssertEqual(ReviewSession.criticMarks(for: .replace(target: "bugs", with: "regressions")), "{~~bugs~>regressions~~}")
        XCTAssertEqual(ReviewSession.criticMarks(for: .insertAfter(target: "x", text: " more")), "{++ more++}")
        XCTAssertEqual(ReviewSession.criticMarks(for: .insertBefore(target: "x", text: "new ")), "{++new ++}")
        XCTAssertEqual(ReviewSession.criticMarks(for: .delete(target: "old")), "{--old--}")
        XCTAssertEqual(ReviewSession.criticMarks(for: .replace(target: "a", with: "b~~}\nc")), "{~~a~>b~~ } c~~}")
    }

    func testMarkdownMarks() {
        let comment = ReviewComment(id: "p0-0", page: 0, author: "Reviewer", kind: .highlight, quotedText: "bugs",
                                    contextBefore: "Results show", contextAfter: "", comment: "Say <<} regressions\ninstead",
                                    suggestion: .replace(target: "bugs", with: "regressions"))
        let note = ReviewComment(id: "p0-1", page: 0, author: "Reviewer", kind: .highlight, quotedText: "Results",
                                 comment: "Good")
        let session = ReviewSession(pdfPath: "r.pdf", mainPath: "/x/paper.md", sourceFormat: .markdown,
                                    comments: [comment, note], createdAt: Date())
        let marked = session.markdownMarks(source: "Results show bugs.")
        XCTAssertEqual(marked, "{==Results==}{>>Reviewer: Good<<} show {~~bugs~>regressions~~}{>>Reviewer: Say << } regressions instead<<}.")
        XCTAssertTrue(marked.contains("{~~bugs~>regressions~~}"))

        let latex = ReviewSession(pdfPath: "r.pdf", mainPath: "/x/paper.tex", sourceFormat: .latex,
                                  comments: [comment], createdAt: Date())
        XCTAssertEqual(latex.markdownMarks(source: "Results show bugs."), "Results show bugs.")
    }

    func testMarkdownMarksInsertAndUnanchored() {
        let insert = ReviewComment(id: "p0-0", page: 0, author: "", kind: .highlight, quotedText: "bugs",
                                   comment: "add more", suggestion: .insertAfter(target: "bugs", text: " and errors"))
        let lost = ReviewComment(id: "p0-1", page: 0, kind: .highlight, quotedText: "nowhere to be found", comment: "x")
        let session = ReviewSession(pdfPath: "r.pdf", mainPath: "/x/paper.md", sourceFormat: .markdown,
                                    comments: [insert, lost], createdAt: Date())
        XCTAssertEqual(session.markdownMarks(source: "# Results\n\nResults show bugs."),
                       "# Results\n\nResults show {==bugs==}{>>add more<<}{++ and errors++}.")
    }

    func testMarkdownMarksLeaveSuggestionAcrossMarkupOut() {
        let comment = ReviewComment(id: "p0-0", page: 0, author: "R", kind: .highlight, quotedText: "quoted words",
                                    comment: "reword", suggestion: .replace(target: "quoted words", with: "cited terms"))
        let session = ReviewSession(pdfPath: "r.pdf", mainPath: "/x/p.md", sourceFormat: .markdown, comments: [comment])
        let marked = session.markdownMarks(source: "Some *quoted* words here.")
        XCTAssertFalse(marked.contains("{~~"), marked)
        XCTAssertTrue(marked.contains("{>>R: reword<<}"), marked)
    }

    // MARK: Response letter

    func testResponseLetter() {
        var session = sampleSession()
        session.comments[1].reply = "Fixed."
        let letter = session.responseLetter(title: "Response to Reviewers")
        XCTAssertTrue(letter.hasPrefix("# Response to Reviewers\n"), letter)
        XCTAssertTrue(letter.contains("### 1. p. 1 — Reviewer"), letter)
        XCTAssertTrue(letter.contains("### 2. p. 2 — R2"), letter)
        XCTAssertTrue(letter.contains("> bugs"), letter)
        XCTAssertTrue(letter.contains("Use regressions"), letter)
        XCTAssertTrue(letter.contains("**Status:** Open"), letter)
        XCTAssertTrue(letter.contains("**Status:** Done"), letter)
        XCTAssertTrue(letter.contains("**Reply:** Fixed."), letter)
        XCTAssertEqual(letter.components(separatedBy: "**Reply:**").count, 2, letter)
    }

    func testResponseLetterEscapesMarkdown() {
        let comment = ReviewComment(id: "p0-0", page: 0, author: "Dr *Star*", kind: .highlight, quotedText: "a *bold* _claim_",
                                    comment: "> not a quote\n1. not a list", status: .done,
                                    reply: "Fixed *all*.\n\n# heading\n---")
        let session = ReviewSession(pdfPath: "r.pdf", mainPath: "/x/p.md", sourceFormat: .markdown, comments: [comment])
        let letter = session.responseLetter(title: "# Reply to *R1*")
        XCTAssertTrue(letter.hasPrefix("# \\# Reply to \\*R1\\*\n"), letter)
        XCTAssertTrue(letter.contains("### 1. p. 1 — Dr \\*Star\\*"), letter)
        XCTAssertTrue(letter.contains("> a \\*bold\\* \\_claim\\_"), letter)
        XCTAssertTrue(letter.contains("\\> not a quote\n1\\. not a list"), letter)
        XCTAssertTrue(letter.contains("**Reply:** Fixed \\*all\\*.\n\n\\# heading\n\\---"), letter)
        let blocks = MarkdownParser.parseBlocks(letter)
        XCTAssertEqual(blocks.filter { if case .heading = $0 { return true } else { return false } }.count, 2, "\(blocks)")
    }
}
