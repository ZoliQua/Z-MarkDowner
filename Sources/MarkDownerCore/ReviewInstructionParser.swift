import Foundation

/// Turns a reviewer's natural-language comment into a `Suggestion` (spec 3.3).
///
/// Rules are tried in the spec's table order and the first match wins. Keywords are matched
/// case-insensitively; quoted strings may use `"…"`, `“…”`, `'…'`, `‘…’` or `„…”`.
public enum ReviewInstructionParser {

    /// The edit a comment asks for, or nil when it is not a recognisable instruction.
    ///
    /// `quoted` is the marked text and `sentence` its surrounding text. For a caret `sentence` is the
    /// text before the caret, whose last word becomes the insertion target.
    public static func suggestion(kind: AnnotationKind, quoted: String, comment: String, sentence: String) -> Suggestion? {
        let quoted = collapse(quoted)
        let comment = collapse(comment)
        switch kind {
        case .strikeOut:
            guard !quoted.isEmpty else { return nil }
            if comment.isEmpty { return .delete(target: quoted) }
            if let parsed = instruction(quoted: quoted, comment: comment, sentence: sentence) { return parsed }
            return .replace(target: quoted, with: unquoted(comment))
        case .caret:
            guard !comment.isEmpty,
                  let word = sentence.split(whereSeparator: \.isWhitespace).last else { return nil }
            return .insertAfter(target: String(word), text: spacedAfter(unquoted(comment)))
        default:
            guard !comment.isEmpty else { return nil }
            return instruction(quoted: quoted, comment: comment, sentence: sentence)
        }
    }

    // MARK: Rules

    private static func instruction(quoted: String, comment: String, sentence: String) -> Suggestion? {
        if let parts = match(#"\b(?:change|replace)\s+%Q\s+(?:to|with|by|into)\s+%Q"#, in: comment), parts.count == 2 {
            let target = parts[0]
            if quoted.range(of: target, options: .caseInsensitive) != nil
                || sentence.range(of: target, options: .caseInsensitive) != nil {
                return .replace(target: target, with: parts[1])
            }
        }
        guard !quoted.isEmpty else { return nil }
        let replacements = [#"\b(?:change|replace)(?:\s+(?:it|this|that))?\s+(?:to|with|by|into)\s*:?\s*%Q"#,
                            #"\bshould\s+(?:be|read)\s*:?\s*%Q"#,
                            #"(?:→|->|=>)\s*%Q"#]
        for pattern in replacements {
            if let text = match(pattern, in: comment)?.first { return .replace(target: quoted, with: text) }
        }
        for pattern in [#"\b(?:add|insert)\s+after(?:\s+(?:this|it|that))?\s*:?\s*%Q"#, #"\b(?:add|insert)\s+%Q\s+after\b"#] {
            if let text = match(pattern, in: comment)?.first { return .insertAfter(target: quoted, text: spacedAfter(text)) }
        }
        for pattern in [#"\b(?:add|insert)\s+before(?:\s+(?:this|it|that))?\s*:?\s*%Q"#, #"\b(?:add|insert)\s+%Q\s+before\b"#] {
            if let text = match(pattern, in: comment)?.first { return .insertBefore(target: quoted, text: spacedBefore(text)) }
        }
        if comment.range(of: #"^(?:delete|remove|omit|cut)(?:\s+this)?[\s.!]*$"#,
                         options: [.regularExpression, .caseInsensitive]) != nil {
            return .delete(target: quoted)
        }
        let strings = quotedStrings(in: comment)
        if strings.count == 1, let candidate = strings.first, candidate != quoted, isSimilar(candidate, quoted) {
            return .replace(target: quoted, with: candidate)
        }
        return nil
    }

    // MARK: Quoted strings

    /// One quoted string; the content is in exactly one of its five groups.
    private static let quote = #"(?:"([^"]+)"|“([^”]+)”|„([^“”]+)[“”]|(?<![\p{L}\p{N}])‘([^’]+)’(?![\p{L}\p{N}])|(?<![\p{L}\p{N}])'([^']+)'(?![\p{L}\p{N}]))"#
    private static let groupsPerQuote = 5

    /// The quoted strings captured by `pattern`, in which each `%Q` stands for one quoted string.
    private static func match(_ pattern: String, in text: String) -> [String]? {
        let full = pattern.replacingOccurrences(of: "%Q", with: quote)
        guard let regex = try? NSRegularExpression(pattern: full, options: [.caseInsensitive]),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return captures(of: result, in: text)
    }

    private static func quotedStrings(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: quote) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { captures(of: $0, in: text) }
    }

    private static func captures(of result: NSTextCheckingResult, in text: String) -> [String] {
        stride(from: 1, to: result.numberOfRanges, by: groupsPerQuote).compactMap { first in
            (first..<min(first + groupsPerQuote, result.numberOfRanges)).lazy
                .compactMap { Range(result.range(at: $0), in: text).map { String(text[$0]) } }
                .first
        }
    }

    /// The text without one pair of quotes around all of it.
    private static func unquoted(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "^" + quote + "$"),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let inner = captures(of: result, in: text).first else { return text }
        return inner
    }

    // MARK: Helpers

    private static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Text inserted after a word gets a leading space unless it starts with punctuation that attaches to the word.
    private static func spacedAfter(_ text: String) -> String {
        guard let first = text.first, !first.isWhitespace, !",.;:!?)]}”’…%".contains(first) else { return text }
        return " " + text
    }

    /// Text inserted before a word gets a trailing space unless it ends with an opening bracket or quote.
    private static func spacedBefore(_ text: String) -> String {
        guard let last = text.last, !last.isWhitespace, !"([{“‘„".contains(last) else { return text }
        return text + " "
    }

    /// Same first four letters, or at most three edits apart (a spelling variant).
    private static func isSimilar(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        if x.count >= 4, y.count >= 4, x.prefix(4) == y.prefix(4), x.prefix(4).allSatisfy(\.isLetter) { return true }
        return editDistance(x, y) <= 3
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
