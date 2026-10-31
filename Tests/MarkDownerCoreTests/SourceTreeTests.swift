import XCTest
@testable import MarkDownerCore

final class SourceTreeTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SourceTreeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sections"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func write(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let mainText = """
        \\documentclass{article}
        \\begin{document}
        \\input{sections/intro}
        % \\input{sections/old}
        \\include{sections/methods.tex}
        \\input{sections/results}
        \\end{document}
        """

    private func makeTree() throws -> URL {
        try write("sections/intro.tex", "\\section{Introduction}\nWe study \\textit{rare} birds in winter. The data were cleaned.\nThis ends the introduction.\n")
        try write("sections/methods.tex", "\\section{Methods}\nMethods begin with sampling. The data were cleaned.\n")
        try write("sections/results.tex", "\\section{Results}\nScores rose sharply. The data were cleaned.\n")
        try write("sections/old.tex", "Obsolete text that must not appear.\n")
        return try write("main.tex", mainText)
    }

    private func text(_ url: URL, _ range: NSRange) throws -> String {
        (try String(contentsOf: url, encoding: .utf8) as NSString).substring(with: range)
    }

    func testFilesInDocumentOrder() throws {
        let tree = try SourceTree(main: try makeTree())
        XCTAssertEqual(tree.format, .latex)
        XCTAssertEqual(tree.files.map(\.lastPathComponent), ["main.tex", "intro.tex", "methods.tex", "results.tex"])
    }

    func testUniqueQuoteResolvesToFile() throws {
        let tree = try SourceTree(main: try makeTree())
        let comment = ReviewComment(id: "p0-0", page: 0, kind: .highlight, quotedText: "Methods begin with sampling")
        let found = try XCTUnwrap(tree.locate(comment))
        XCTAssertEqual(found.file.lastPathComponent, "methods.tex")
        XCTAssertEqual(try text(found.file, found.range), "Methods begin with sampling")

        let rare = ReviewComment(id: "p0-1", page: 0, kind: .highlight, quotedText: "rare birds")
        let inIntro = try XCTUnwrap(tree.locate(rare))
        XCTAssertEqual(inIntro.file.lastPathComponent, "intro.tex")
        XCTAssertEqual(try text(inIntro.file, inIntro.range), "rare} birds")
    }

    func testContextPicksFile() throws {
        let tree = try SourceTree(main: try makeTree())
        let comment = ReviewComment(id: "p2-0", page: 2, kind: .highlight, quotedText: "The data were cleaned.",
                                    contextBefore: "Results Scores rose sharply.", contextAfter: "")
        let found = try XCTUnwrap(tree.locate(comment))
        XCTAssertEqual(found.file.lastPathComponent, "results.tex")
        XCTAssertEqual(try text(found.file, found.range), "The data were cleaned.")
        let methods = ReviewComment(id: "p1-0", page: 1, kind: .highlight, quotedText: "The data were cleaned.",
                                    contextBefore: "Methods begin with sampling.", contextAfter: "Results Scores rose")
        XCTAssertEqual(tree.locate(methods)?.file.lastPathComponent, "methods.tex")
    }

    func testRangeCrossingFilesIsNil() throws {
        let tree = try SourceTree(main: try makeTree())
        let comment = ReviewComment(id: "p0-0", page: 0, kind: .highlight, quotedText: "This ends the introduction. Methods begin")
        XCTAssertNil(tree.locate(comment))
        let joined = SourceTree(files: [(folder.appendingPathComponent("x.tex"), "This ends the introduction.\n\nMethods begin.")], format: .latex)
        XCTAssertNotNil(joined.locate(comment), "the quote itself is findable; only the file boundary rejects it")
    }

    func testInputCycleTerminates() throws {
        try write("a.tex", "Alpha text here.\n\\input{b}\n")
        try write("b.tex", "Beta text here.\n\\input{a}\n\\input{missing}\n")
        let tree = try SourceTree(main: folder.appendingPathComponent("a.tex"))
        XCTAssertEqual(tree.files.map(\.lastPathComponent), ["a.tex", "b.tex"])
        let comment = ReviewComment(id: "p0-0", page: 0, kind: .highlight, quotedText: "Beta text")
        XCTAssertEqual(tree.locate(comment)?.file.lastPathComponent, "b.tex")
    }

    func testMissingMainThrows() {
        XCTAssertThrowsError(try SourceTree(main: folder.appendingPathComponent("none.tex")))
    }

    func testInMemoryFilesSpliceLikeDisk() throws {
        let main = folder.appendingPathComponent("main.tex")
        let tree = SourceTree(files: [(main, "Start \\input{part} end of main."),
                                      (folder.appendingPathComponent("part.tex"), "Inner words.")], format: .latex)
        XCTAssertEqual(tree.files.map(\.lastPathComponent), ["main.tex", "part.tex"])
        let comment = ReviewComment(id: "p0-0", page: 0, kind: .highlight, quotedText: "end of main")
        let found = try XCTUnwrap(tree.locate(comment))
        XCTAssertEqual(found.file, main)
        XCTAssertEqual(found.range, ("Start \\input{part} end of main." as NSString).range(of: "end of main"))
    }

    func testMarkdownIsSingleFile() throws {
        let url = try write("paper.md", "# Title\n\nSome *quoted* words.\n")
        let tree = try SourceTree(main: url)
        XCTAssertEqual(tree.format, .markdown)
        XCTAssertEqual(tree.files, [url])
        let found = try XCTUnwrap(tree.locate(ReviewComment(id: "p0-0", page: 0, kind: .highlight, quotedText: "quoted words")))
        XCTAssertEqual(found.file, url)
        XCTAssertEqual(try text(url, found.range), "quoted* words")
    }
}
