import Foundation

/// The comments imported from a reviewer's PDF for one manuscript, with the user's progress on them.
///
/// Stored in a sidecar next to the main source file. Anchors are not stored: they are recomputed
/// from the current source text (see `SourceTree`).
public struct ReviewSession: Codable, Equatable {
    public var pdfPath: String
    /// The main source file (for LaTeX, the file that includes the others).
    public var mainPath: String
    public var sourceFormat: SourceFormat
    public var comments: [ReviewComment]
    public var createdAt: Date

    public init(pdfPath: String, mainPath: String, sourceFormat: SourceFormat, comments: [ReviewComment], createdAt: Date = Date()) {
        self.pdfPath = pdfPath
        self.mainPath = mainPath
        self.sourceFormat = sourceFormat
        self.comments = comments
        self.createdAt = createdAt
    }
}

/// Why a suggestion could not be applied.
public enum ReviewSessionError: LocalizedError {
    /// The source no longer holds the suggestion's target where the comment is anchored.
    case targetChanged(String)
    case unanchored
    case noSuggestion

    public var errorDescription: String? {
        switch self {
        case .targetChanged(let target):
            return LF("review.error.targetChanged", "The text “%@” is no longer where the comment points. The source may have been edited.", target)
        case .unanchored:
            return L("review.error.unanchored", "The comment could not be found in the source.")
        case .noSuggestion:
            return L("review.error.noSuggestion", "The comment has no suggestion to apply.")
        }
    }
}

extension ReviewSession {

    // MARK: Persistence

    /// `<source file name>.review.json` next to `source`.
    public static func sidecarURL(for source: URL) -> URL {
        source.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent + ".review.json")
    }

    public func save(for source: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.sidecarURL(for: source), options: .atomic)
    }

    /// The session saved for `source`, or nil when there is none or it cannot be read.
    public static func load(for source: URL) -> ReviewSession? {
        guard let data = try? Data(contentsOf: sidecarURL(for: source)) else { return nil }
        return try? JSONDecoder().decode(ReviewSession.self, from: data)
    }

    // MARK: Applying suggestions

    /// `text` with `suggestion` applied at `range`, the comment's anchor. Returns the range of the new
    /// text (empty for a deletion) and the change in length.
    ///
    /// The target is checked first, comparing prose as `format` reads it: for a replacement or deletion
    /// it must be the text at `range` or occur exactly once inside it; for an insertion after (before)
    /// it must end (start) at the corresponding edge of `range`. Otherwise `.targetChanged` is thrown.
    public static func edit(applying suggestion: Suggestion, at range: NSRange, in text: String,
                            format: SourceFormat = .plain) throws -> (text: String, range: NSRange, delta: Int) {
        guard let target = targetRange(for: suggestion, at: range, in: text, format: format) else {
            throw ReviewSessionError.targetChanged(suggestion.target)
        }
        let source = text as NSString
        var replaced = target
        let replacement: String
        switch suggestion {
        case .replace(_, let with): replacement = with
        case .insertAfter(_, let insert), .insertBefore(_, let insert): replacement = insert
        case .delete:
            replacement = ""
            replaced = widenedOverSpace(target, in: source)
        }
        let result = source.replacingCharacters(in: replaced, with: replacement)
        let length = (replacement as NSString).length
        return (result, NSRange(location: replaced.location, length: length), length - replaced.length)
    }

    /// The source range the suggestion edits (empty at the insertion point), or nil when its target is
    /// not where `range` says.
    static func targetRange(for suggestion: Suggestion, at range: NSRange, in text: String, format: SourceFormat) -> NSRange? {
        let source = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= source.length else { return nil }
        let needle = prose(suggestion.target, format: .plain)
        guard !needle.isEmpty else { return nil }
        let reach = (needle as NSString).length * 3 + 64
        switch suggestion {
        case .replace, .delete:
            let normalized = NormalizedText(source: source.substring(with: range), format: format)
            let hay = normalized.text as NSString
            if prose(normalized.text, format: .plain) == needle { return range }
            let found = wordOccurrences(of: needle, in: hay)
            guard found.count == 1 else { return nil }
            let inner = normalized.sourceRange(found[0])
            return NSRange(location: range.location + inner.location, length: inner.length)
        case .insertAfter:
            let end = NSMaxRange(range)
            let start = min(range.location, max(0, end - reach))
            let window = NormalizedText(source: source.substring(with: NSRange(location: start, length: end - start)), format: format).text
            let trimmed = window.trimmingCharacters(in: .whitespaces) as NSString
            let found = wordOccurrences(of: needle, in: trimmed)
            guard let last = found.last, NSMaxRange(last) == trimmed.length else { return nil }
            return NSRange(location: end, length: 0)
        case .insertBefore:
            let end = max(NSMaxRange(range), min(source.length, range.location + reach))
            let window = NormalizedText(source: source.substring(with: NSRange(location: range.location, length: end - range.location)), format: format).text
            let trimmed = window.trimmingCharacters(in: .whitespaces) as NSString
            guard wordOccurrences(of: needle, in: trimmed).first?.location == 0 else { return nil }
            return NSRange(location: range.location, length: 0)
        }
    }

    /// Text reduced to comparable prose: lowercase, typography folded, whitespace collapsed and trimmed.
    private static func prose(_ text: String, format: SourceFormat) -> String {
        NormalizedText(source: text, format: format).text.trimmingCharacters(in: .whitespaces)
    }

    /// The occurrences of `needle` in `hay` that do not start or end inside a word.
    private static func wordOccurrences(of needle: String, in hay: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var search = NSRange(location: 0, length: hay.length)
        while true {
            let found = hay.range(of: needle, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            let before = found.location > 0 ? hay.character(at: found.location - 1) : 0x20
            let after = NSMaxRange(found) < hay.length ? hay.character(at: NSMaxRange(found)) : 0x20
            let first = hay.character(at: found.location), last = hay.character(at: NSMaxRange(found) - 1)
            if !(NormalizedText.isWordUnit(before) && NormalizedText.isWordUnit(first))
                && !(NormalizedText.isWordUnit(after) && NormalizedText.isWordUnit(last)) {
                result.append(found)
            }
            search = NSRange(location: found.location + 1, length: hay.length - found.location - 1)
        }
        return result
    }

    /// `range` plus one neighbouring space, so that deleting it leaves no double space.
    private static func widenedOverSpace(_ range: NSRange, in source: NSString) -> NSRange {
        let before = range.location > 0 ? source.character(at: range.location - 1) : nil
        let after = NSMaxRange(range) < source.length ? source.character(at: NSMaxRange(range)) : nil
        let space: UInt16 = 0x20
        if before == space, after.map({ $0 == space || !NormalizedText.isWordUnit($0) }) ?? true {
            return NSRange(location: range.location - 1, length: range.length + 1)
        }
        if after == space, before.map({ $0 == 0x0A || $0 == 0x0D }) ?? true {
            return NSRange(location: range.location, length: range.length + 1)
        }
        return range
    }

    // MARK: Review marks

    /// The CriticMarkup for a suggestion: `{~~old~>new~~}`, `{++text++}` or `{--old--}`.
    public static func criticMarks(for suggestion: Suggestion) -> String {
        switch suggestion {
        case .replace(let target, let with): return "{~~\(markText(target))~>\(markText(with))~~}"
        case .insertAfter(_, let text), .insertBefore(_, let text): return "{++\(markText(text))++}"
        case .delete(let target): return "{--\(markText(target))--}"
        }
    }

    private static func markText(_ text: String) -> String {
        var result = PDFTextExtractor.singleLine(text)
        for (closer, spaced) in [("~~}", "~~ }"), ("~>", "~ >"), ("++}", "++ }"), ("--}", "-- }")] {
            result = result.replacingOccurrences(of: closer, with: spaced)
        }
        return result
    }

    /// The Markdown `source` with every anchored comment written in as `{==quote==}{>>Author: comment<<}`
    /// and its suggestion as a change mark. A replacement or deletion stands in place of its target
    /// instead of the highlight, so accepting all changes yields the edited text. Only for Markdown
    /// sessions; other formats get `source` back unchanged.
    public func markdownMarks(source: String) -> String {
        guard sourceFormat == .markdown else { return source }
        let normalized = NormalizedText(source: source, format: .markdown)
        var placed: [(range: NSRange, comment: ReviewComment)] = []
        for comment in comments {
            if let range = ReviewAnchor.locate(comment, in: normalized) { placed.append((range, comment)) }
        }
        let ranges = PDFTextExtractor.insertionRanges(for: placed.map(\.range), in: source)
        let items = zip(ranges, placed.map(\.comment)).map { (range: $0, comment: $1) }
            .sorted { $0.range.location < $1.range.location }
        var accepted: [(range: NSRange, comment: ReviewComment)] = []
        var end = 0
        for item in items where item.range.location >= end {
            accepted.append(item)
            end = NSMaxRange(item.range)
        }
        var result = source
        for item in accepted.reversed() {
            let mark = Self.mark(for: item.comment, at: item.range, in: source)
            result = (result as NSString).replacingCharacters(in: item.range, with: mark)
        }
        return result
    }

    private static func mark(for comment: ReviewComment, at range: NSRange, in source: String) -> String {
        let text = source as NSString
        let quote = text.substring(with: range)
        let note = PDFTextExtractor.reviewNote(for: comment)
        let highlighted = quote.isEmpty ? note : "{==\(quote)==}" + note
        guard let suggestion = comment.suggestion,
              let target = targetRange(for: suggestion, at: range, in: source, format: .markdown) else { return highlighted }
        let old = text.substring(with: target)
        let change: Suggestion
        switch suggestion {
        case .insertAfter: return highlighted + criticMarks(for: suggestion)
        case .insertBefore: return criticMarks(for: suggestion) + highlighted
        case .replace(_, let with): change = .replace(target: old, with: with)
        case .delete: change = .delete(target: old)
        }
        let before = text.substring(with: NSRange(location: range.location, length: target.location - range.location))
        let after = text.substring(with: NSRange(location: NSMaxRange(target), length: NSMaxRange(range) - NSMaxRange(target)))
        return before + criticMarks(for: change) + after + note
    }

    // MARK: Response letter

    /// A Markdown response to the reviewers: `title` as heading, then for each comment its number, page
    /// and author, the quoted text, the comment, its status and the user's reply.
    public func responseLetter(title: String) -> String {
        var lines = ["# \(title)", ""]
        for (index, comment) in comments.enumerated() {
            var heading = "### \(index + 1). \(CoreStrings.pdfCommentPage(comment.page + 1))"
            let author = PDFTextExtractor.singleLine(comment.author)
            if !author.isEmpty { heading += " — \(author)" }
            lines += [heading, ""]
            let quote = comment.quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !quote.isEmpty {
                lines += quote.components(separatedBy: .newlines).map { "> " + $0 }
                lines.append("")
            }
            let text = comment.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines += [text, ""] }
            lines += ["**\(L("review.letter.status", "Status")):** \(Self.statusName(comment.status))", ""]
            let reply = comment.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty { lines += ["**\(L("review.letter.reply", "Reply")):** \(reply)", ""] }
        }
        return lines.joined(separator: "\n")
    }

    public static func statusName(_ status: ReviewStatus) -> String {
        switch status {
        case .open: return L("review.status.open", "Open")
        case .applied: return L("review.status.applied", "Applied")
        case .done: return L("review.status.done", "Done")
        case .rejected: return L("review.status.rejected", "Rejected")
        }
    }
}

extension Suggestion {
    /// The source text the suggestion is phrased against.
    public var target: String {
        switch self {
        case .replace(let target, _), .insertAfter(let target, _), .insertBefore(let target, _), .delete(let target):
            return target
        }
    }
}
