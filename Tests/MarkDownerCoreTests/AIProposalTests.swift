import XCTest
@testable import MarkDownerCore

/// Validation of on-device model proposals and the sentence they are asked about.
final class AIProposalTests: XCTestCase {
    private let sentence = "The color scale is fixed."

    func testValidProposals() {
        XCTAssertEqual(ReviewInstructionParser.validateAI(action: "replace", target: "color", text: "colour", sentence: sentence),
                       .replace(target: "color", with: "colour"))
        XCTAssertEqual(ReviewInstructionParser.validateAI(action: "insertAfter", target: "scale", text: "bar", sentence: sentence),
                       .insertAfter(target: "scale", text: " bar"))
        XCTAssertEqual(ReviewInstructionParser.validateAI(action: "insertAfter", target: "fixed", text: ", however", sentence: sentence),
                       .insertAfter(target: "fixed", text: ", however"))
        XCTAssertEqual(ReviewInstructionParser.validateAI(action: "insertBefore", target: "scale", text: "logarithmic", sentence: sentence),
                       .insertBefore(target: "scale", text: "logarithmic "))
        XCTAssertEqual(ReviewInstructionParser.validateAI(action: "delete", target: " color ", text: "", sentence: sentence),
                       .delete(target: "color"))
        XCTAssertEqual(ReviewInstructionParser.validateAI(action: "Replace", target: "is fixed", text: "is fixed at 0–1", sentence: sentence),
                       .replace(target: "is fixed", with: "is fixed at 0–1"))
    }

    func testRejectedProposals() {
        let cases: [(String, String, String)] = [
            ("none", "color", "colour"),
            ("replace", "Color", "colour"),          // case-sensitive
            ("replace", "colors", "colours"),        // not in the sentence
            ("replace", "", "colour"),
            ("replace", "color", ""),
            ("replace", "color", "color"),
            ("replace", "color", "colour scale ..."),
            ("insertAfter", "scale", "bar…"),
            ("insertBefore", "scale", "  "),
            ("rewrite", "color", "colour"),
        ]
        for (action, target, text) in cases {
            XCTAssertNil(ReviewInstructionParser.validateAI(action: action, target: target, text: text, sentence: sentence),
                         "\(action) \(target) \(text)")
        }
    }

    func testSentenceAroundRange() {
        let text = "# Title\n\nFirst sentence here. The color scale is fixed. Last one!\nNext line."
        let range = (text as NSString).range(of: "color")
        XCTAssertEqual(ReviewInstructionParser.sentence(around: range, in: text), "The color scale is fixed.")
        let last = (text as NSString).range(of: "one")
        XCTAssertEqual(ReviewInstructionParser.sentence(around: last, in: text), "Last one!")
        let first = (text as NSString).range(of: "First")
        XCTAssertEqual(ReviewInstructionParser.sentence(around: first, in: text), "First sentence here.")
        let decimal = "The value was 3.5 per \\cite{x} cent. Next."
        let r = (decimal as NSString).range(of: "cent")
        XCTAssertEqual(ReviewInstructionParser.sentence(around: r, in: decimal), "The value was 3.5 per \\cite{x} cent.")
    }

    func testLongSentenceIsCutAroundTheRange() {
        let words = (1...200).map { "word\($0)" }.joined(separator: " ")
        let text = words + "."
        let range = (text as NSString).range(of: "word100 ")
        let sentence = ReviewInstructionParser.sentence(around: range, in: text, limit: 120)
        XCTAssertLessThanOrEqual(sentence.count, 120)
        XCTAssertTrue(sentence.contains("word100"))
        XCTAssertTrue(sentence.hasPrefix("word"), sentence)
        XCTAssertFalse(sentence.hasSuffix("wor"), sentence)
        let wide = NSRange(location: 0, length: (text as NSString).length)
        XCTAssertEqual(ReviewInstructionParser.sentence(around: wide, in: text, limit: 50), text)
    }
}
