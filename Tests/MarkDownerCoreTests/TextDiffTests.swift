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
