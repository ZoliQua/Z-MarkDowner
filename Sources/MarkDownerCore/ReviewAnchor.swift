import Foundation

/// The markup a review source is written in, which decides how it is reduced to comparable prose.
public enum SourceFormat: String, Codable {
    case markdown, latex, plain

    public init(fileExtension: String) {
        let ext = fileExtension.lowercased()
        if ["tex", "latex", "ltx"].contains(ext) {
            self = .latex
        } else if DocumentImporter.markdownExtensions.contains(ext) {
            self = .markdown
        } else {
            self = .plain
        }
    }
}

/// A source reduced to lowercase prose with its markup removed, typography folded and whitespace
/// collapsed, keeping for every UTF-16 unit the place in the source it came from.
public struct NormalizedText {
    public let text: String
    /// `map[i]` is the UTF-16 offset in the source of normalized unit `i`; the extra last entry is the
    /// source length.
    public let map: [Int]
    /// `ends[i]` is the UTF-16 offset in the source just past the markup that produced unit `i`.
    let ends: [Int]
    let units: [UInt16]
    let tokens: [Token]
    /// Token `i` of `tokens` as an index into `vocabulary`.
    let tokenIDs: [Int]
    let vocabulary: [String: Int]

    /// A word of the normalized text: the units `start..<end`, edge punctuation excluded.
    struct Token {
        let text: String
        let start: Int
        let end: Int
    }

    public init(source: String, format: SourceFormat) {
        var builder = Builder(source: source)
        switch format {
        case .latex: builder.scanLatex()
        case .markdown: builder.scanMarkdown()
        case .plain: builder.scanPlain()
        }
        units = builder.units
        text = String(decoding: units, as: UTF16.self)
        map = builder.map + [source.utf16.count]
        ends = builder.ends
        tokens = NormalizedText.tokenize(units)
        var vocabulary: [String: Int] = [:]
        tokenIDs = tokens.map { token in
            if let id = vocabulary[token.text] { return id }
            vocabulary[token.text] = vocabulary.count
            return vocabulary.count - 1
        }
        self.vocabulary = vocabulary
    }

    /// The source range that produced the normalized units in `range`.
    func sourceRange(_ range: NSRange) -> NSRange {
        let start = map[range.location]
        guard range.length > 0 else { return NSRange(location: start, length: 0) }
        return NSRange(location: start, length: ends[NSMaxRange(range) - 1] - start)
    }

    /// Splits at spaces and trims punctuation from both ends of each word; `!` is kept because PDFs
    /// re-saved by PDFKit write it for lost ligatures ("e!cient").
    static func tokenize(_ units: [UInt16]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < units.count {
            while i < units.count, units[i] == 0x20 { i += 1 }
            var end = i
            while end < units.count, units[end] != 0x20 { end += 1 }
            var s = i, e = end
            while s < e, !isTokenUnit(units[s]) { s += 1 }
            while e > s, !isTokenUnit(units[e - 1]) { e -= 1 }
            if s < e { tokens.append(Token(text: String(decoding: units[s..<e], as: UTF16.self), start: s, end: e)) }
            i = end
        }
        return tokens
    }

    private static func isTokenUnit(_ unit: UInt16) -> Bool {
        unit == 0x21 || isWordUnit(unit)
    }

    static func isWordUnit(_ unit: UInt16) -> Bool {
        if unit < 0x80 {
            return (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
        }
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}

// MARK: - Normalisation

private struct Builder {
    let chars: [Character]
    /// UTF-16 offset of each character, plus the source length.
    let offsets: [Int]
    var units: [UInt16] = []
    var map: [Int] = []
    var ends: [Int] = []

    init(source: String) {
        chars = Array(source)
        var offsets: [Int] = []
        offsets.reserveCapacity(chars.count + 1)
        var offset = 0
        for ch in chars {
            offsets.append(offset)
            offset += ch.utf16.count
        }
        offsets.append(offset)
        self.offsets = offsets
    }

    /// Appends the folded form of `text`, attributed to the source characters `from..<to`.
    mutating func emit(_ text: String, _ from: Int, _ to: Int) {
        for ch in text { emitCharacter(ch, offsets[from], offsets[to]) }
    }

    mutating func emit(_ index: Int) {
        emitCharacter(chars[index], offsets[index], offsets[index + 1])
    }

    private mutating func emitCharacter(_ ch: Character, _ start: Int, _ end: Int) {
        if ch.isWhitespace {
            appendSpace(start, end)
            return
        }
        if let ascii = ch.asciiValue {
            append(ascii >= 0x41 && ascii <= 0x5A ? UInt16(ascii + 0x20) : UInt16(ascii), start, end)
            return
        }
        for folded in Builder.fold(ch) {
            if folded.isWhitespace {
                appendSpace(start, end)
            } else {
                for unit in String(folded).utf16 { append(unit, start, end) }
            }
        }
    }

    private static func fold(_ ch: Character) -> String {
        switch ch {
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}": return "'"
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}": return "\""
        case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}": return "-"
        case "\u{2026}": return "..."
        default:
            return PDFTextExtractor.normalizeCharacters(String(ch)).lowercased().precomposedStringWithCanonicalMapping
        }
    }

    private mutating func append(_ unit: UInt16, _ start: Int, _ end: Int) {
        units.append(unit)
        map.append(start)
        ends.append(end)
    }

    private mutating func appendSpace(_ start: Int, _ end: Int) {
        if units.last != 0x20 { append(0x20, start, end) }
    }

    private func at(_ i: Int) -> Character? { i >= 0 && i < chars.count ? chars[i] : nil }

    // MARK: Plain

    mutating func scanPlain() {
        for i in chars.indices { emit(i) }
    }

    // MARK: LaTeX

    /// Commands whose mandatory arguments are not printed as text, with how many of them to drop.
    private static let droppedArguments: [String: Int] = [
        "ref": 1, "eqref": 1, "autoref": 1, "cref": 1, "Cref": 1, "pageref": 1, "nameref": 1, "vref": 1,
        "label": 1, "href": 1, "includegraphics": 1, "bibliography": 1, "bibliographystyle": 1,
        "usepackage": 1, "documentclass": 1, "input": 1, "include": 1, "vspace": 1, "hspace": 1,
        "begin": 1, "end": 1, "thispagestyle": 1, "pagestyle": 1, "bibitem": 1, "textcolor": 1, "color": 1,
        "hypersetup": 1, "graphicspath": 1, "captionsetup": 1, "newcommand": 2, "renewcommand": 2,
        "setlength": 2, "addtolength": 2, "definecolor": 3, "addcontentsline": 3,
    ]
    /// Environments whose `\begin` also takes a column specification or a width.
    private static let environmentsWithSpec: Set<String> = ["tabular", "tabular*", "tabularx", "array", "longtable", "minipage", "multicols"]
    private static let namedSymbols: [String: String] = [
        "i": "i", "j": "j", "ss": "ß", "o": "ø", "O": "Ø", "aa": "å", "AA": "Å", "ae": "æ", "AE": "Æ",
        "oe": "œ", "OE": "Œ", "l": "ł", "L": "Ł", "LaTeX": "LaTeX", "TeX": "TeX", "ldots": "...",
        "dots": "...", "textendash": "-", "textemdash": "-", "S": "§", "P": "¶", "textasciitilde": "~",
    ]
    private static let accents: [Character: String] = [
        "'": "\u{301}", "`": "\u{300}", "^": "\u{302}", "\"": "\u{308}", "~": "\u{303}", "=": "\u{304}",
        ".": "\u{307}", "H": "\u{30B}", "v": "\u{30C}", "c": "\u{327}", "u": "\u{306}", "r": "\u{30A}", "k": "\u{328}",
    ]

    mutating func scanLatex() {
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "%":
                while i < chars.count, !chars[i].isNewline { i += 1 }
                i += 1
                while let next = at(i), next == " " || next == "\t" { i += 1 }
            case "\\":
                i = latexCommand(at: i)
            case "{", "}", "$":
                i += 1
            case "~":
                emit(" ", i, i + 1)
                i += 1
            case "`", "'":
                if at(i + 1) == c {
                    emit("\"", i, i + 2)
                    i += 2
                } else {
                    emit("'", i, i + 1)
                    i += 1
                }
            case "-":
                var end = i
                while at(end) == "-" { end += 1 }
                emit("-", i, end)
                i = end
            default:
                emit(i)
                i += 1
            }
        }
    }

    /// Handles the command starting with the backslash at `start`; returns where scanning continues.
    private mutating func latexCommand(at start: Int) -> Int {
        guard let next = at(start + 1) else { return start + 1 }
        guard next.isASCII, next.isLetter else { return controlSymbol(next, at: start) }
        var end = start + 1
        while let ch = at(end), ch.isASCII, ch.isLetter { end += 1 }
        let name = String(chars[(start + 1)..<end])
        if at(end) == "*" { end += 1 }
        if name.count == 1, let mark = Builder.accents[Character(name)], let accented = accentGroup(after: end, mark: mark) {
            emit(accented.text, start, accented.end)
            return accented.end
        }
        if let symbol = Builder.namedSymbols[name] {
            emit(symbol, start, end)
            return end
        }
        if name.lowercased().contains("cite") {
            return skipArguments(after: end, count: 1)
        }
        if let count = Builder.droppedArguments[name] {
            var resume = skipArguments(after: end, count: count)
            if name == "begin", let env = groupContent(after: end), Builder.environmentsWithSpec.contains(env) {
                resume = skipArguments(after: resume, count: 1)
            }
            return resume
        }
        return end
    }

    private mutating func controlSymbol(_ symbol: Character, at start: Int) -> Int {
        switch symbol {
        case "%", "&", "$", "#", "_", "{", "}":
            emit(String(symbol), start, start + 2)
            return start + 2
        case "\\", ",", ";", ":", " ", "\n", "\t":
            emit(" ", start, start + 2)
            return start + 2
        default:
            if let mark = Builder.accents[symbol], let accented = accentGroup(after: start + 2, mark: mark) {
                emit(accented.text, start, accented.end)
                return accented.end
            }
            return start + 2
        }
    }

    /// The accented letter of `\'e`, `\'{e}` or `\'{\i}`, and where its markup ends.
    private func accentGroup(after i: Int, mark: String) -> (text: String, end: Int)? {
        if at(i) == "{" {
            if let base = at(i + 1), base.isLetter, at(i + 2) == "}" { return (String(base) + mark, i + 3) }
            if at(i + 1) == "\\", let base = at(i + 2), base == "i" || base == "j", at(i + 3) == "}" {
                return (String(base) + mark, i + 4)
            }
            return nil
        }
        if let base = at(i), base.isLetter { return (String(base) + mark, i + 1) }
        return nil
    }

    /// Skips optional `[...]` arguments and `count` brace groups following a command name.
    private func skipArguments(after i: Int, count: Int) -> Int {
        var i = i
        for _ in 0..<count {
            var j = skipSpaces(i)
            while at(j) == "[", let close = matching(from: j, open: "[", close: "]") { j = skipSpaces(close + 1) }
            guard at(j) == "{", let close = matching(from: j, open: "{", close: "}") else { return i }
            i = close + 1
        }
        return i
    }

    private func skipSpaces(_ i: Int) -> Int {
        var i = i
        while let ch = at(i), ch == " " || ch == "\t" || ch == "\n" { i += 1 }
        return i
    }

    private func groupContent(after i: Int) -> String? {
        let open = skipSpaces(i)
        guard at(open) == "{", let close = matching(from: open, open: "{", close: "}") else { return nil }
        return String(chars[(open + 1)..<close])
    }

    /// Index of the bracket closing the one at `from`, honouring nesting and backslash escapes.
    private func matching(from: Int, open: Character, close: Character) -> Int? {
        var depth = 0
        var i = from
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\" {
                i += 2
                continue
            }
            if ch == open { depth += 1 }
            if ch == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: Markdown

    mutating func scanMarkdown() {
        var i = 0
        /// Index of a link's closing `]` → index just past its `(url)` or `[ref]`.
        var linkEnds: [Int: Int] = [:]
        var lineStart = true
        while i < chars.count {
            if lineStart {
                lineStart = false
                i = skipBlockMarkers(i)
                continue
            }
            let c = chars[i]
            if c.isNewline {
                emit(i)
                i += 1
                lineStart = true
                continue
            }
            if let resume = linkEnds[i] {
                i = resume
                continue
            }
            switch c {
            case "\\":
                if let next = at(i + 1), next.isASCII, next.isPunctuation || next.isSymbol {
                    emit(String(next), i, i + 2)
                    i += 2
                } else {
                    emit(i)
                    i += 1
                }
            case "*", "`":
                i += 1
            case "_":
                let inWord = (at(i - 1)?.isLetter ?? false || at(i - 1)?.isNumber ?? false)
                    && (at(i + 1)?.isLetter ?? false || at(i + 1)?.isNumber ?? false)
                if inWord { emit(i) }
                i += 1
            case "~" where at(i + 1) == "~":
                i += 2
            case "!" where at(i + 1) == "[":
                if let close = matching(from: i + 1, open: "[", close: "]"), at(close + 1) == "(",
                   let paren = matching(from: close + 1, open: "(", close: ")") {
                    i = paren + 1
                } else {
                    emit(i)
                    i += 1
                }
            case "[":
                guard let close = matching(from: i, open: "[", close: "]"), close - i < 500 else {
                    emit(i)
                    i += 1
                    continue
                }
                if at(i + 1) == "^" || at(i + 1) == "@" {
                    i = close + 1
                } else if at(close + 1) == "(", let paren = matching(from: close + 1, open: "(", close: ")") {
                    linkEnds[close] = paren + 1
                    i += 1
                } else if at(close + 1) == "[", let ref = matching(from: close + 1, open: "[", close: "]") {
                    linkEnds[close] = ref + 1
                    i += 1
                } else {
                    emit(i)
                    i += 1
                }
            case "<":
                if let tag = htmlTag(at: i) {
                    if tag.autolink { emit(String(chars[(i + 1)..<(tag.end - 1)]), i + 1, tag.end - 1) }
                    i = tag.end
                } else {
                    emit(i)
                    i += 1
                }
            default:
                emit(i)
                i += 1
            }
        }
    }

    /// Skips indentation, `>` quote markers, heading hashes, list bullets or numbers and task boxes.
    private func skipBlockMarkers(_ start: Int) -> Int {
        var i = start
        while let ch = at(i), ch == " " || ch == "\t" { i += 1 }
        while at(i) == ">" {
            i += 1
            if at(i) == " " { i += 1 }
        }
        var hashes = 0
        while at(i + hashes) == "#" { hashes += 1 }
        if hashes > 0, hashes <= 6, at(i + hashes) == " " || at(i + hashes) == nil || at(i + hashes)?.isNewline == true {
            return i + hashes
        }
        if let ch = at(i), ch == "-" || ch == "*" || ch == "+", at(i + 1) == " " {
            i += 2
            if at(i) == "[", let mark = at(i + 1), mark == " " || mark == "x" || mark == "X", at(i + 2) == "]", at(i + 3) == " " {
                i += 4
            }
            return i
        }
        var digits = 0
        while let ch = at(i + digits), ch.isASCII, ch.isNumber { digits += 1 }
        if digits > 0, let ch = at(i + digits), ch == "." || ch == ")", at(i + digits + 1) == " " {
            return i + digits + 2
        }
        return i
    }

    /// An HTML tag or autolink starting at `i`, and where it ends.
    private func htmlTag(at i: Int) -> (end: Int, autolink: Bool)? {
        guard let first = at(i + 1), first.isLetter || first == "/" else { return nil }
        var j = i + 1
        while let ch = at(j), ch != ">", ch != "<", !ch.isNewline { j += 1 }
        guard at(j) == ">" else { return nil }
        let inner = String(chars[(i + 1)..<j])
        let autolink = !inner.contains(" ") && (inner.contains("://") || inner.contains("@"))
        return (j + 1, autolink)
    }
}

// MARK: - Search

/// Finds where a review comment's quoted words sit in a normalized source.
public enum ReviewAnchor {

    public static func locate(_ comment: ReviewComment, in normalized: NormalizedText) -> NSRange? {
        locate(quote: comment.quotedText, before: comment.contextBefore, after: comment.contextAfter, in: normalized)
    }

    /// The source range of `quote`, or `nil` when it cannot be placed unambiguously. Tries a unique
    /// exact occurrence, then the occurrence whose surroundings best match the context, then the best
    /// window of words by overlap with quote and context (at least 75 %). Quotes shorter than three
    /// characters need context; an empty quote (a caret) yields an empty range between the contexts.
    public static func locate(quote: String, before: String, after: String, in normalized: NormalizedText) -> NSRange? {
        let q = fold(quote), b = fold(before), a = fold(after)
        if q.isEmpty {
            return fuzzy(quote: [], before: b, after: a, in: normalized)
        }
        var variants = [q]
        let uncited = withoutCitations(q)
        if !uncited.isEmpty, uncited != q { variants.append(uncited) }
        for variant in variants {
            let found = occurrences(of: variant, in: normalized)
            if found.isEmpty { continue }
            if found.count == 1, variant.count >= 3 { return normalized.sourceRange(found[0]) }
            return byContext(found, before: b, after: a, in: normalized).map(normalized.sourceRange)
        }
        guard q.count >= 3 else { return nil }
        return fuzzy(quote: NormalizedText.tokenize(Array(variants.last!.utf16)).map(\.text), before: b, after: a, in: normalized)
    }

    private static func fold(_ s: String) -> String {
        NormalizedText(source: s, format: .plain).text.trimmingCharacters(in: .whitespaces)
    }

    /// The quote without bracketed citation numbers ("[12]", "[3, 4]", "[1-5]"), which LaTeX sources
    /// write as `\cite{…}`.
    private static func withoutCitations(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\[\s*\d+(?:\s*[,;-]\s*\d+)*\s*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Exact occurrences in normalized units; those on word boundaries when there are any.
    private static func occurrences(of quote: String, in normalized: NormalizedText) -> [NSRange] {
        let hay = normalized.text as NSString
        var found: [NSRange] = []
        var from = 0
        while from < hay.length {
            let r = hay.range(of: quote, options: .literal, range: NSRange(location: from, length: hay.length - from))
            if r.location == NSNotFound { break }
            found.append(r)
            from = r.location + 1
        }
        let units = normalized.units
        let q = Array(quote.utf16)
        let bounded = found.filter { r in
            let startOK = r.location == 0 || !NormalizedText.isWordUnit(q[0]) || !NormalizedText.isWordUnit(units[r.location - 1])
            let end = NSMaxRange(r)
            let endOK = end == units.count || !NormalizedText.isWordUnit(q[q.count - 1]) || !NormalizedText.isWordUnit(units[end])
            return startOK && endOK
        }
        return bounded.isEmpty ? found : bounded
    }

    /// The occurrence whose neighbouring words (then characters) agree best with the context; `nil` on a tie.
    private static func byContext(_ found: [NSRange], before: String, after: String, in normalized: NormalizedText) -> NSRange? {
        guard !before.isEmpty || !after.isEmpty else { return nil }
        let beforeWords = NormalizedText.tokenize(Array(before.utf16)).map(\.text)
        let afterWords = NormalizedText.tokenize(Array(after.utf16)).map(\.text)
        let beforeUnits = Array(before.utf16), afterUnits = Array(after.utf16)
        let tokens = normalized.tokens
        var best: (words: Int, chars: Int) = (0, 0)
        var winners: [NSRange] = []
        for r in found {
            let firstAfter = partition(tokens) { $0.start >= NSMaxRange(r) }
            let lastBefore = partition(tokens) { $0.end > r.location }
            let preceding = tokens[max(0, lastBefore - beforeWords.count)..<lastBefore].map(\.text)
            let following = tokens[firstAfter..<min(tokens.count, firstAfter + afterWords.count)].map(\.text)
            let words = shared(beforeWords, preceding) + shared(afterWords, following)
            let chars = commonSuffix(beforeUnits, normalized.units[..<r.location])
                + commonPrefix(afterUnits, normalized.units[NSMaxRange(r)...])
            let score = (words, chars)
            if score > best {
                best = score
                winners = [r]
            } else if score == best {
                winners.append(r)
            }
        }
        return best > (0, 0) && winners.count == 1 ? winners[0] : nil
    }

    /// The first index where `isAfter` holds, for a predicate that is false then true along `tokens`.
    private static func partition(_ tokens: [NormalizedText.Token], _ isAfter: (NormalizedText.Token) -> Bool) -> Int {
        var low = 0, high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if isAfter(tokens[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }

    private static func shared(_ a: [String], _ b: [String]) -> Int {
        var counts: [String: Int] = [:]
        for word in a { counts[word, default: 0] += 1 }
        var n = 0
        for word in b where counts[word, default: 0] > 0 {
            counts[word]! -= 1
            n += 1
        }
        return n
    }

    private static func commonSuffix(_ a: [UInt16], _ b: ArraySlice<UInt16>) -> Int {
        let a = a.reversed().drop { $0 == 0x20 }, b = b.reversed().drop { $0 == 0x20 }
        return zip(a, b).prefix { $0 == $1 }.count
    }

    private static func commonPrefix(_ a: [UInt16], _ b: ArraySlice<UInt16>) -> Int {
        zip(a.drop { $0 == 0x20 }, b.drop { $0 == 0x20 }).prefix { $0 == $1 }.count
    }

    /// The window of `quote.count` source words (a gap between words for an empty quote) scoring
    /// highest on words shared with the quote and with the context words beside it. Needs a score of
    /// at least 75 % of all quote and context words, half the quote's words, and a unique best.
    private static func fuzzy(quote: [String], before: String, after: String, in normalized: NormalizedText) -> NSRange? {
        let resolve = { (words: [String]) in words.map { resolveLigatures($0, in: normalized.vocabulary) } }
        let quoteIDs = resolve(quote)
        let beforeIDs = resolve(NormalizedText.tokenize(Array(before.utf16)).map(\.text))
        let afterIDs = resolve(NormalizedText.tokenize(Array(after.utf16)).map(\.text))
        let n = quoteIDs.count, total = n + beforeIDs.count + afterIDs.count
        let ids = normalized.tokenIDs
        guard total > 0, ids.count >= n else { return nil }
        let starts = ids.count - n + 1
        let quoteScores = slidingShared(ids, need: counts(quoteIDs), length: n, offset: 0, starts: starts)
        let beforeScores = slidingShared(ids, need: counts(beforeIDs), length: beforeIDs.count, offset: -beforeIDs.count, starts: starts)
        let afterScores = slidingShared(ids, need: counts(afterIDs), length: afterIDs.count, offset: n, starts: starts)
        var best = -1
        var winners: [Int] = []
        for i in 0..<starts {
            guard quoteScores[i] * 2 >= n else { continue }
            let score = quoteScores[i] + beforeScores[i] + afterScores[i]
            guard score * 4 >= total * 3 else { continue }
            if score > best {
                best = score
                winners = [i]
            } else if score == best {
                winners.append(i)
            }
        }
        let tokens = normalized.tokens
        if n == 0 {
            guard winners.count == 1, let gap = winners.first else { return nil }
            let location = gap > 0 ? normalized.ends[tokens[gap - 1].end - 1] : normalized.map[tokens.first?.start ?? 0]
            return NSRange(location: location, length: 0)
        }
        let wanted = Set(quoteIDs)
        let span: ClosedRange<Int>
        if winners.count == 1 {
            // Drop leading or trailing words the quote does not have only up to the quote's own first
            // or last word, so a replaced word at the edge stays inside the range.
            var first = winners[0], last = winners[0] + n - 1
            if let j = (first...last).first(where: { ids[$0] == quoteIDs[0] }), (first..<j).allSatisfy({ !wanted.contains(ids[$0]) }) {
                first = j
            }
            if let j = (first...last).last(where: { ids[$0] == quoteIDs[n - 1] }), ((j + 1)..<(last + 1)).allSatisfy({ !wanted.contains(ids[$0]) }) {
                last = j
            }
            span = first...last
        } else {
            // Windows shifted over the same matched words (the quote had a word the source lacks) are
            // one passage; distinct passages are a tie.
            let cores = Set(winners.compactMap { start -> ClosedRange<Int>? in
                let window = start...(start + n - 1)
                guard let first = window.first(where: { wanted.contains(ids[$0]) }),
                      let last = window.last(where: { wanted.contains(ids[$0]) }) else { return nil }
                return first...last
            })
            guard cores.count == 1, let core = cores.first else { return nil }
            span = core
        }
        let start = tokens[span.lowerBound].start
        return normalized.sourceRange(NSRange(location: start, length: tokens[span.upperBound].end - start))
    }

    /// The vocabulary id of `word`; a word with `!` where PDFKit dropped a ligature takes the id of the
    /// single source word it can stand for. `-1` when absent.
    private static func resolveLigatures(_ word: String, in vocabulary: [String: Int]) -> Int {
        if let id = vocabulary[word] { return id }
        guard word.contains("!") else { return -1 }
        let pattern = "^" + word.components(separatedBy: "!").map(NSRegularExpression.escapedPattern).joined(separator: "(?:ffi|ffl|ff|fi|fl)") + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return -1 }
        let length = word.utf16.count
        let matches = vocabulary.filter { key, _ in
            let extra = key.utf16.count - length
            return extra >= 1 && extra <= 2 * (word.utf16.count - word.replacingOccurrences(of: "!", with: "").utf16.count)
                && regex.firstMatch(in: key, range: NSRange(location: 0, length: key.utf16.count)) != nil
        }
        return matches.count == 1 ? matches.first!.value : -1
    }

    private static func counts(_ ids: [Int]) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for id in ids where id >= 0 { counts[id, default: 0] += 1 }
        return counts
    }

    /// For each window start `i` in `0..<starts`, how many words of `need` (a multiset) occur among
    /// `ids[i + offset ..< i + offset + length]`, positions outside the text counting as absent.
    private static func slidingShared(_ ids: [Int], need: [Int: Int], length: Int, offset: Int, starts: Int) -> [Int] {
        var result = [Int](repeating: 0, count: starts)
        guard length > 0, !need.isEmpty else { return result }
        var have: [Int: Int] = [:]
        var shared = 0
        func add(_ k: Int) {
            guard k >= 0, k < ids.count, let wanted = need[ids[k]] else { return }
            let count = have[ids[k], default: 0]
            if count < wanted { shared += 1 }
            have[ids[k]] = count + 1
        }
        func remove(_ k: Int) {
            guard k >= 0, k < ids.count, let wanted = need[ids[k]] else { return }
            let count = have[ids[k], default: 0]
            if count <= wanted { shared -= 1 }
            have[ids[k]] = count - 1
        }
        for k in offset..<(offset + length) { add(k) }
        result[0] = shared
        for i in 1..<max(1, starts) {
            remove(i - 1 + offset)
            add(i - 1 + offset + length)
            result[i] = shared
        }
        return result
    }
}
