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
    /// The target runs across markup that cannot be kept intact; the edit must be made by hand.
    case spansMarkup

    public var errorDescription: String? {
        switch self {
        case .targetChanged(let target):
            return LF("review.error.targetChanged", "The text “%@” is no longer where the comment points. The source may have been edited.", target)
        case .unanchored:
            return L("review.error.unanchored", "The comment could not be found in the source.")
        case .noSuggestion:
            return L("review.error.noSuggestion", "The comment has no suggestion to apply.")
        case .spansMarkup:
            return L("review.error.spansMarkup", "The suggested change runs across formatting or a link. Please make it by hand.")
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
        try Self.sidecarEncoder().encode(self).write(to: Self.sidecarURL(for: source), options: .atomic)
    }

    /// Sidecar JSON: sorted keys, dates as ISO 8601 strings (whole seconds, UTC).
    public static func sidecarEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Reads ISO 8601 dates, with or without fractional seconds.
    public static func sidecarDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(string)")
        }
        return decoder
    }

    /// The session saved for `source`, or nil when there is none, it cannot be read, or — when `pdf`
    /// is given — it was made from another PDF. A stored PDF that no longer exists at its path is
    /// matched by file name, so a moved review PDF still finds its session.
    public static func load(for source: URL, pdf: URL? = nil) -> ReviewSession? {
        guard let data = try? Data(contentsOf: sidecarURL(for: source)),
              let session = try? sidecarDecoder().decode(ReviewSession.self, from: data) else { return nil }
        guard let pdf else { return session }
        let stored = URL(fileURLWithPath: session.pdfPath).standardizedFileURL
        if stored.path == pdf.standardizedFileURL.path { return session }
        let moved = !FileManager.default.fileExists(atPath: stored.path)
        return moved && stored.lastPathComponent == pdf.lastPathComponent ? session : nil
    }

    // MARK: Applying suggestions

    /// `text` with `suggestion` applied at `range`, the comment's anchor. Returns the range of the new
    /// text (empty for a deletion) and the change in length.
    ///
    /// The target is checked first, comparing prose as `format` reads it: for a replacement or deletion
    /// it must be the text at `range` or occur exactly once inside it; for an insertion after (before)
    /// it must end (start) at the corresponding edge of `range`. Otherwise `.targetChanged` is thrown.
    ///
    /// Markup is never removed: when the target's words are split by markup (`\textit{rare} birds`,
    /// `*quoted* words`), the replacement takes the place of the words before the first markup
    /// character and the later words are dropped, keeping every brace, emphasis marker and command.
    /// Markup that carries text of its own (a link target, a citation key) throws `.spansMarkup`.
    public static func edit(applying suggestion: Suggestion, at range: NSRange, in text: String,
                            format: SourceFormat = .plain) throws -> (text: String, range: NSRange, delta: Int) {
        let normalized = NormalizedText(source: text, format: format)
        guard let target = target(of: suggestion, at: range, in: text, normalized: normalized) else {
            throw ReviewSessionError.targetChanged(suggestion.target)
        }
        let source = text as NSString
        let insert: String
        switch suggestion {
        case .replace(_, let with): insert = with
        case .insertAfter(_, let text), .insertBefore(_, let text): insert = text
        case .delete: insert = ""
        }
        var replaced = target.range
        var replacement = insert
        if let first = target.markup.first {
            guard target.markup.allSatisfy({ isKeepableMarkup(at: $0, in: source) }) else { throw ReviewSessionError.spansMarkup }
            let words = source.substring(with: NSRange(location: replaced.location, length: first - replaced.location))
            let gap = String(words.reversed().prefix(while: \.isWhitespace).reversed())
            replacement += gap + target.markup.map { source.substring(with: NSRange(location: $0, length: 1)) }.joined()
        } else if case .delete = suggestion {
            replaced = widenedOverSpace(replaced, in: source)
        }
        let result = source.replacingCharacters(in: replaced, with: replacement)
        let length = (replacement as NSString).length
        return (result, NSRange(location: replaced.location, length: (insert as NSString).length), length - replaced.length)
    }

    /// The source range a suggestion edits (empty at an insertion point) with the positions of the
    /// markup characters inside it.
    struct Target {
        let range: NSRange
        let markup: [Int]
    }

    /// Where the suggestion's target lies at `range` in `text`, or nil when it is not there.
    static func target(of suggestion: Suggestion, at range: NSRange, in text: String, normalized: NormalizedText) -> Target? {
        let source = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= source.length else { return nil }
        let needle = NormalizedText(source: suggestion.target, format: .plain).text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        let units = normalized.units
        let count = units.count
        let space: UInt16 = 0x20
        switch suggestion {
        case .replace, .delete:
            var lo = 0
            while lo < count && normalized.map[lo] < range.location { lo += 1 }
            var hi = lo
            while hi < count && normalized.ends[hi] <= NSMaxRange(range) { hi += 1 }
            while lo < hi && units[lo] == space { lo += 1 }
            while hi > lo && units[hi - 1] == space { hi -= 1 }
            guard lo < hi else { return nil }
            let hay = String(decoding: units[lo..<hi], as: UTF16.self) as NSString
            var found = NSRange(location: 0, length: hay.length)
            if hay as String != needle {
                let occurrences = wordOccurrences(of: needle, in: hay)
                guard occurrences.count == 1 else { return nil }
                found = occurrences[0]
            }
            let span = NSRange(location: lo + found.location, length: found.length)
            let target = normalized.sourceRange(span)
            return Target(range: target, markup: markup(in: target, units: span, of: source, normalized: normalized))
        case .insertAfter:
            var k = 0
            while k < count && normalized.ends[k] <= NSMaxRange(range) { k += 1 }
            while k > 0 && units[k - 1] == space { k -= 1 }
            guard hasWord(needle, in: units, from: k - (needle as NSString).length) else { return nil }
            return Target(range: NSRange(location: NSMaxRange(range), length: 0), markup: [])
        case .insertBefore:
            var j = 0
            while j < count && normalized.map[j] < range.location { j += 1 }
            while j < count && units[j] == space { j += 1 }
            guard hasWord(needle, in: units, from: j) else { return nil }
            return Target(range: NSRange(location: range.location, length: 0), markup: [])
        }
    }

    /// The positions in `target` that no normalized unit of `units` came from, whitespace aside: braces,
    /// emphasis markers, commands, link targets. A space unit standing for `~` counts as markup.
    private static func markup(in target: NSRange, units span: NSRange, of source: NSString, normalized: NormalizedText) -> [Int] {
        var covered = IndexSet()
        for i in span.location..<NSMaxRange(span) {
            let start = normalized.map[i], end = max(normalized.ends[i], start + 1)
            if normalized.units[i] == 0x20, let ch = UnicodeScalar(source.character(at: start)),
               !CharacterSet.whitespacesAndNewlines.contains(ch) { continue }
            covered.insert(integersIn: start..<end)
        }
        return (target.location..<NSMaxRange(target)).filter { position in
            guard !covered.contains(position) else { return false }
            guard let ch = UnicodeScalar(source.character(at: position)) else { return true }
            return !CharacterSet.whitespacesAndNewlines.contains(ch)
        }
    }

    /// Whether the markup character at `position` can be kept on its own: a delimiter, or a letter of a
    /// `\command` name.
    private static func isKeepableMarkup(at position: Int, in source: NSString) -> Bool {
        let unit = source.character(at: position)
        if let ch = UnicodeScalar(unit), "{}*_`~$\\".unicodeScalars.contains(ch) { return true }
        guard let ch = UnicodeScalar(unit), CharacterSet.letters.contains(ch) else { return false }
        var i = position - 1
        while i >= 0, let previous = UnicodeScalar(source.character(at: i)), CharacterSet.letters.contains(previous) { i -= 1 }
        return i >= 0 && source.character(at: i) == 0x5C
    }

    /// Whether the normalized `units` hold `needle` as whole words starting at `start`.
    private static func hasWord(_ needle: String, in units: [UInt16], from start: Int) -> Bool {
        let length = (needle as NSString).length
        guard start >= 0, start + length <= units.count else { return false }
        let lo = max(0, start - 1), hi = min(units.count, start + length + 1)
        let hay = String(decoding: units[lo..<hi], as: UTF16.self) as NSString
        return wordOccurrences(of: needle, in: hay).contains { $0.location == start - lo }
    }

    /// The occurrences of `needle` in `hay` that do not start or end inside a word.
    private static func wordOccurrences(of needle: String, in hay: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var search = NSRange(location: 0, length: hay.length)
        let outside: UInt16 = 0x20
        while true {
            let found = hay.range(of: needle, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            let before = found.location > 0 ? hay.character(at: found.location - 1) : outside
            let after = NSMaxRange(found) < hay.length ? hay.character(at: NSMaxRange(found)) : outside
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
            let mark = Self.mark(for: item.comment, at: item.range, in: source, normalized: normalized)
            result = (result as NSString).replacingCharacters(in: item.range, with: mark)
        }
        return result
    }

    /// The marks for one comment at `range`; a suggestion whose target runs across markup is left out,
    /// since a change mark around it would break the formatting.
    private static func mark(for comment: ReviewComment, at range: NSRange, in source: String, normalized: NormalizedText) -> String {
        let text = source as NSString
        let quote = text.substring(with: range)
        let note = PDFTextExtractor.reviewNote(for: comment)
        let highlighted = quote.isEmpty ? note : "{==\(quote)==}" + note
        guard let suggestion = comment.suggestion,
              let found = target(of: suggestion, at: range, in: source, normalized: normalized),
              found.markup.isEmpty else { return highlighted }
        let target = found.range
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
        var lines = ["# " + Self.markdownLine(PDFTextExtractor.singleLine(title)), ""]
        for (index, comment) in comments.enumerated() {
            var heading = "### \(index + 1). \(CoreStrings.pdfCommentPage(comment.page + 1))"
            let author = PDFTextExtractor.singleLine(comment.author).trimmingCharacters(in: .whitespaces)
            if !author.isEmpty { heading += " — " + AttributedToMarkdown.escape(author) }
            lines += [heading, ""]
            let quote = comment.quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !quote.isEmpty {
                lines += Self.markdownLines(quote).map { $0.isEmpty ? ">" : "> " + $0 }
                lines.append("")
            }
            let text = comment.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines += Self.markdownLines(text) + [""] }
            lines += ["**\(L("review.letter.status", "Status")):** \(Self.statusName(comment.status))", ""]
            let reply = comment.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty {
                var replyLines = Self.markdownLines(reply)
                replyLines[0] = "**\(L("review.letter.reply", "Reply")):** " + replyLines[0]
                lines += replyLines + [""]
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `text` as Markdown lines that read literally: inline markup escaped, block markers at line starts
    /// escaped, and leading indentation dropped so no line becomes a code block.
    private static func markdownLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map(markdownLine)
    }

    private static func markdownLine(_ line: String) -> String {
        let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        return AttributedToMarkdown.escapeLineStart(AttributedToMarkdown.escape(trimmed))
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
