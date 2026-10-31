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

    // MARK: Persistence

    private func sampleSession() -> ReviewSession {
        let comments = [
            ReviewComment(id: "p0-0", page: 0, author: "Reviewer", date: Date(timeIntervalSince1970: 1_700_000_000.25),
                          kind: .highlight, quotedText: "bugs", contextBefore: "Results show", contextAfter: "in coverage",
                          comment: "Use regressions", suggestion: .replace(target: "bugs", with: "regressions"),
                          suggestionIsAI: true),
            ReviewComment(id: "p1-0", page: 1, author: "R2", kind: .note, comment: "Nice figure.", status: .done, reply: "Thanks."),
        ]
        return ReviewSession(pdfPath: "/tmp/review.pdf", mainPath: folder.appendingPathComponent("paper.tex").path,
                             sourceFormat: .latex, comments: comments, createdAt: Date(timeIntervalSince1970: 1_700_000_100.5))
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

    func testCorruptSidecarIgnored() throws {
        let source = folder.appendingPathComponent("paper.md")
        XCTAssertNil(ReviewSession.load(for: source))
        try Data("not json {".utf8).write(to: ReviewSession.sidecarURL(for: source))
        XCTAssertNil(ReviewSession.load(for: source))
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
}
