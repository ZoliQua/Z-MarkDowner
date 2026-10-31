import XCTest
@testable import MarkDownerCore

final class TextDiffTests: XCTestCase {

    func testWordLevelChanges() {
        let r = TextDiff.compare("The quick brown fox", "The slow brown dog")
        XCTAssertEqual(r.segments, [
            DiffSegment(kind: .equal, text: "The "),
            DiffSegment(kind: .delete, text: "quick"),
            DiffSegment(kind: .insert, text: "slow"),
            DiffSegment(kind: .equal, text: " brown "),
            DiffSegment(kind: .delete, text: "fox"),
            DiffSegment(kind: .insert, text: "dog")
        ])
        XCTAssertEqual(r.insertedWords, 2)
        XCTAssertEqual(r.deletedWords, 2)
    }

    func testCriticMarkup() {
        let r = TextDiff.compare("The quick brown fox", "The slow brown dog")
        XCTAssertEqual(TextDiff.criticMarkup(r.segments), "The {--quick--}{++slow++} brown {--fox--}{++dog++}")
    }

    /// Text, insertion and deletion contents of a parsed document (recursively).
    private func inlineSummary(_ markdown: String) -> (texts: [String], insertions: [String], deletions: [String], blocks: [MDBlock]) {
        let doc = MDDocument(markdown: markdown)
        var texts: [String] = [], ins: [String] = [], del: [String] = []
        func walk(_ inlines: [MDInline]) {
            for i in inlines {
                switch i {
                case .text(let t): texts.append(t)
                case .insertion(let c): ins.append(c.plainText); walk(c)
                case .deletion(let c): del.append(c.plainText); walk(c)
                case .emphasis(let c), .strong(let c), .strikethrough(let c), .highlight(let c): walk(c)
                case .link(let c, _, _): walk(c)
                default: break
                }
            }
        }
        func walk(_ blocks: [MDBlock]) {
            for b in blocks {
                switch b {
                case .heading(_, let c, _), .paragraph(let c): walk(c)
                case .blockquote(let bs): walk(bs)
                case .list(let l): l.items.forEach { walk($0.blocks) }
                case .table(let t): t.header.forEach(walk); t.rows.forEach { $0.forEach(walk) }
                default: break
                }
            }
        }
        walk(doc.blocks)
        return (texts, ins, del, doc.blocks)
    }

    private func assertNoLiteralMarks(_ texts: [String], _ markdown: String, file: StaticString = #filePath, line: UInt = #line) {
        for t in texts {
            for m in ["{++", "++}", "{--", "--}"] {
                XCTAssertFalse(t.contains(m), "literal \(m) in \(t) — \(markdown)", file: file, line: line)
            }
        }
    }

    func testCriticMarkupInsertedParagraphAndList() {
        let old = "First paragraph.\n\nLast paragraph."
        let new = "First paragraph.\n\nA brand new paragraph here.\n\n- item one\n- item two\n\nLast paragraph."
        let md = TextDiff.criticMarkup(TextDiff.compare(old, new).segments)
        XCTAssertEqual(md, "First paragraph.\n\n{++A brand new paragraph here.++}\n\n- {++item one++}\n- {++item two++}\n\nLast paragraph.")
        let s = inlineSummary(md)
        assertNoLiteralMarks(s.texts, md)
        XCTAssertEqual(s.insertions, ["A brand new paragraph here.", "item one", "item two"])
        XCTAssertEqual(s.blocks.count, 4)
        if case .list(let l) = s.blocks[2] { XCTAssertEqual(l.items.count, 2) } else { XCTFail("list expected: \(md)") }
    }

    func testCriticMarkupHeadingLevelChange() {
        let md = TextDiff.criticMarkup(TextDiff.compare("# Old heading\n\nBody.", "## New heading\n\nBody.").segments)
        XCTAssertEqual(md, "## {--Old--}{++New++} heading\n\nBody.")
        let s = inlineSummary(md)
        assertNoLiteralMarks(s.texts, md)
        XCTAssertEqual(s.insertions, ["New"])
        XCTAssertEqual(s.deletions, ["Old"])
        if case .heading(let level, _, _) = s.blocks.first { XCTAssertEqual(level, 2) } else { XCTFail("heading expected: \(md)") }
    }

    func testCriticMarkupRemovedParagraphAndListItem() {
        let old = "Intro.\n\nThis paragraph goes away.\n\n- keep\n- drop this\n\n> quoted old\n\nEnd."
        let new = "Intro.\n\n- keep\n\n> quoted new\n\nEnd."
        let md = TextDiff.criticMarkup(TextDiff.compare(old, new).segments)
        let s = inlineSummary(md)
        assertNoLiteralMarks(s.texts, md)
        XCTAssertTrue(s.deletions.contains("This paragraph goes away."), md)
        XCTAssertTrue(s.deletions.contains { $0.contains("drop this") }, md)
        XCTAssertTrue(md.contains("> {--old--}{++new++}") || md.contains("> quoted {--old--}{++new++}"), md)
        XCTAssertFalse(md.contains("{--\n") || md.contains("\n--}") || md.contains("{++\n") || md.contains("\n++}"), md)
    }

    func testCriticMarkupTableRowsAndStructuralLines() {
        let old = "| A | B |\n|---|---|\n| 1 | 2 |\n\nText."
        let new = "| A | B |\n|---|---|\n| 1 | 3 |\n| 4 | 5 |\n\n---\n\nText."
        let md = TextDiff.criticMarkup(TextDiff.compare(old, new).segments)
        let s = inlineSummary(md)
        assertNoLiteralMarks(s.texts, md)
        guard case .table(let t) = s.blocks.first else { return XCTFail("table expected: \(md)") }
        XCTAssertEqual(t.rows.count, 2, md)
        XCTAssertTrue(s.blocks.contains(.horizontalRule), md)
        XCTAssertTrue(s.insertions.contains("4") && s.insertions.contains("5"), md)
    }

    func testCriticMarkupWordExportTracksParagraphChanges() throws {
        let old = "# Old heading\n\nFirst paragraph.\n\nGone paragraph.\n\nLast paragraph."
        let new = "## New heading\n\nFirst paragraph.\n\nA brand new paragraph here.\n\n- item one\n- item two\n\nLast paragraph."
        let md = TextDiff.criticMarkup(TextDiff.compare(old, new).segments)
        let data = try DocxExporter.data(markdown: md, options: ExportOptions(title: "T"))
        let document = String(decoding: try ZipReader(data: data).contents(of: "word/document.xml")!, as: UTF8.self)
        XCTAssertTrue(document.contains("<w:ins "), md)
        XCTAssertTrue(document.contains("<w:del "), md)
        XCTAssertFalse(document.contains("{++") || document.contains("{--") || document.contains("++}") || document.contains("--}"), md)
        XCTAssertTrue(document.contains("item one") && document.contains("Gone"), md)
    }

    func testRowsAlignInsertedLines() {
        let r = TextDiff.compare("a\nb\nc", "a\nX\nb\nc")
        XCTAssertEqual(r.rows.count, 4)
        XCTAssertNil(r.rows[1].old)
        XCTAssertNil(r.rows[1].oldLine)
        XCTAssertEqual(r.rows[1].newLine, 1)
        XCTAssertEqual(r.rows[1].new, [DiffSegment(kind: .insert, text: "X")])
        XCTAssertEqual(r.rows[2].oldLine, 1)
        XCTAssertEqual(r.rows[2].newLine, 2)
        XCTAssertEqual(r.rows[2].old, [DiffSegment(kind: .equal, text: "b")])
    }

    func testChangedLineRowCarriesWordKinds() {
        let r = TextDiff.compare("one two\nsame", "one three\nsame")
        XCTAssertEqual(r.rows.count, 2)
        XCTAssertEqual(r.rows[0].old, [DiffSegment(kind: .equal, text: "one "), DiffSegment(kind: .delete, text: "two")])
        XCTAssertEqual(r.rows[0].new, [DiffSegment(kind: .equal, text: "one "), DiffSegment(kind: .insert, text: "three")])
    }

    func testIgnoreWhitespaceAndCase() {
        let r = TextDiff.compare("Hello  World", "hello world", options: DiffOptions(ignoreWhitespace: true, ignoreCase: true))
        XCTAssertEqual(r.segments.count, 1)
        XCTAssertEqual(r.segments.first?.kind, .equal)
        XCTAssertEqual(r.insertedWords + r.deletedWords, 0)
    }

    func testEqualRowsKeepOldTextUnderIgnoreOptions() {
        let options = DiffOptions(ignoreWhitespace: true, ignoreCase: true)
        let r = TextDiff.compare("Hello  World\nsame", "hello world\nsame", options: options)
        XCTAssertEqual(r.rows.count, 2)
        XCTAssertEqual(r.rows[0].old, [DiffSegment(kind: .equal, text: "Hello  World")])
        XCTAssertEqual(r.rows[0].new, [DiffSegment(kind: .equal, text: "hello world")])
        let changed = TextDiff.compare("Alpha  Beta\nx\n", "alpha beta gamma\ny\n", options: options)
        XCTAssertEqual(changed.rows[0].old?.map(\.text).joined(), "Alpha  Beta")
        XCTAssertEqual(changed.rows[0].new?.map(\.text).joined(), "alpha beta gamma")
    }

    func testRowsPairSimilarLinesInChangedBlocks() {
        let old = "Intro\nThe values were averaged.\nThis line was removed.\nAll samples were stored cold.\nEnd"
        let new = "Intro\nThe values were averaged twice.\nAll samples were stored warm.\nA new line.\nEnd"
        let r = TextDiff.compare(old, new)
        let pairs = r.rows.map { [$0.oldLine, $0.newLine] }
        XCTAssertEqual(pairs, [[0, 0], [1, 1], [2, nil], [3, 2], [nil, 3], [4, 4]])
        XCTAssertEqual(r.rows[3].new?.map(\.text).joined(), "All samples were stored warm.")
    }

    func testProseTextIgnoresFormatting() {
        let md = "# Title\n\nSome **bold** and [link](http://x)\nwrapped.\n\n- item *one*\n\n```\ncode line\n```\n"
        XCTAssertEqual(TextStatistics.proseText(of: md), "Title\nSome bold and link wrapped.\nitem one\ncode line\n")
        let r = TextDiff.compare(TextStatistics.proseText(of: "A *quick* fox"), TextStatistics.proseText(of: "A **quick** fox"))
        XCTAssertEqual(r.insertedWords + r.deletedWords, 0)
    }

    func testIdenticalAndEmpty() {
        let ins = TextDiff.compare("", "abc")
        XCTAssertEqual(ins.segments, [DiffSegment(kind: .insert, text: "abc")])
        let same = TextDiff.compare("abc def", "abc def")
        XCTAssertEqual(same.segments, [DiffSegment(kind: .equal, text: "abc def")])
        XCTAssertTrue(TextDiff.compare("", "").segments.isEmpty)
    }

    func testPerformance200k() {
        var seed: UInt64 = 12345
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        var oldWords: [String] = []
        var count = 0
        while count < 200_000 {
            let len = 2 + next() % 7
            let w = String((0..<len).map { _ in Character(UnicodeScalar(UInt8(97 + next() % 26))) })
            oldWords.append(w)
            count += len + 1
        }
        let newWords = oldWords.map { next() % 50 == 0 ? $0 + "x" : $0 }
        let old = oldWords.joined(separator: " ")
        let new = newWords.joined(separator: " ")
        let start = Date()
        let r = TextDiff.compare(old, new)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0)
        XCTAssertGreaterThan(r.insertedWords, 0)
    }

    func testRandomRoundTrip() {
        var seed: UInt64 = 99
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        let vocab = ["a", "b", "c", " ", "\n", ",", "dd"]
        for _ in 0..<200 {
            let o = (0..<(next() % 30)).map { _ in vocab[next() % vocab.count] }.joined()
            let n = (0..<(next() % 30)).map { _ in vocab[next() % vocab.count] }.joined()
            let r = TextDiff.compare(o, n)
            XCTAssertEqual(r.segments.filter { $0.kind != .insert }.map(\.text).joined(), o)
            XCTAssertEqual(r.segments.filter { $0.kind != .delete }.map(\.text).joined(), n)
        }
    }

    func testPerformanceFullyRewrittenMultiline() {
        var seed: UInt64 = 777
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        func make(_ letters: String) -> String {
            let chars = Array(letters)
            var out = ""
            var count = 0
            while count < 200_000 {
                let len = 2 + next() % 7
                out += String((0..<len).map { _ in chars[next() % chars.count] })
                count += len + 1
                out += next() % 10 == 0 ? "\n" : " "
            }
            return out
        }
        let old = make("abcdefghijklm")
        let new = make("nopqrstuvwxyz")
        let start = Date()
        let r = TextDiff.compare(old, new)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        XCTAssertEqual(r.segments.filter { $0.kind != .insert }.map(\.text).joined(), old)
        XCTAssertEqual(r.segments.filter { $0.kind != .delete }.map(\.text).joined(), new)
    }
}
