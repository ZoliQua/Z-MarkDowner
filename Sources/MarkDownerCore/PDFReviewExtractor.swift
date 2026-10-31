import AppKit
import PDFKit

/// Reads reviewer comments from a PDF's annotations (spec 3.2).
///
/// Highlight, Underline, Squiggly, StrikeOut, Caret, Text (sticky note) and FreeText annotations become
/// `ReviewComment`s; their Popups are folded into them and replies (`/IRT`) become `replies`. Links,
/// widgets and stand-alone popups are ignored. The quoted text and its context are cleaned like
/// imported PDF text (ligatures, line numbers, hyphenation, whitespace).
public enum PDFReviewExtractor {

    /// Characters of page text kept on each side of a quote.
    static let contextLength = 60

    private static let kinds: [String: AnnotationKind] = [
        "Highlight": .highlight, "Underline": .underline, "Squiggly": .squiggly, "StrikeOut": .strikeOut,
        "Caret": .caret, "Text": .note, "FreeText": .freeText,
    ]

    /// All comments ordered by page, then top to bottom and left to right.
    public static func comments(from document: PDFDocument) -> [ReviewComment] {
        guard !document.isLocked else { return [] }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        guard pages.contains(where: { $0.annotations.contains { kinds[$0.type ?? ""] != nil } }) else { return [] }
        let lines = PDFTextExtractor.readingLines(of: document)
        var result: [ReviewComment] = []
        for index in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                result += comments(on: page, index: index, lines: index < lines.count ? lines[index] : [], document: document)
            }
        }
        return result
    }

    // MARK: Page

    private struct Located {
        var comment: ReviewComment
        var top: CGFloat
        var left: CGFloat
    }

    private static func comments(on page: PDFPage, index: Int, lines: [PDFLine], document: PDFDocument) -> [ReviewComment] {
        let annotations = page.annotations.filter { kinds[$0.type ?? ""] != nil }
        let threads = replyThreads(of: annotations, pageIndex: index, document: document)
        var located: [Located] = []
        for (position, annotation) in annotations.enumerated() where threads.parent[position] == nil {
            guard let kind = kinds[annotation.type ?? ""] else { continue }
            var comment = ReviewComment(id: "", page: index, author: annotation.userName ?? "",
                                        date: date(of: annotation), kind: kind, comment: text(of: annotation))
            comment.replies = threads.replies[position, default: []].map { text(of: annotations[$0]) }.filter { !$0.isEmpty }
            var anchor = annotation.bounds
            switch kind {
            case .highlight, .underline, .squiggly, .strikeOut:
                let rects = lineRects(of: annotation)
                anchor = rects.first ?? anchor
                let quote = self.quote(in: rects, on: page, lines: lines)
                comment.quotedText = quote.text
                comment.contextBefore = quote.before
                comment.contextAfter = quote.after
            case .caret:
                let context = caretContext(annotation.bounds, on: page, lines: lines)
                comment.contextBefore = context.before
                comment.contextAfter = context.after
            case .note, .freeText:
                break
            }
            let sentence = kind == .caret ? comment.contextBefore : comment.contextBefore + comment.quotedText + comment.contextAfter
            comment.suggestion = ReviewInstructionParser.suggestion(kind: kind, quoted: comment.quotedText,
                                                                    comment: comment.comment, sentence: sentence)
            located.append(Located(comment: comment, top: anchor.maxY, left: anchor.minX))
        }
        located.sort { a, b in
            abs(a.top - b.top) > 2 ? a.top > b.top : a.left < b.left
        }
        return located.enumerated().map { offset, item in
            var comment = item.comment
            comment.id = "p\(index)-\(offset)"
            return comment
        }
    }

    /// The annotation's text: its Contents, else its Popup's, with line breaks normalized.
    private static func text(of annotation: PDFAnnotation) -> String {
        var text = annotation.contents ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = annotation.popup?.contents ?? "" }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Replies

    /// Which annotations answer another one (`/IRT`), keyed by position in `annotations`. Replies to
    /// replies join the thread of the comment they finally answer.
    ///
    /// PDFKit does not expose `/IRT`, so the page's `/Annots` array is read with CoreGraphics and matched
    /// to PDFKit's annotations by subtype and order (PDFKit keeps the array's order). Each pair must also
    /// agree on Contents and position; a reply whose pair disagrees stays a comment of its own.
    private static func replyThreads(of annotations: [PDFAnnotation], pageIndex: Int,
                                     document: PDFDocument) -> (parent: [Int: Int], replies: [Int: [Int]]) {
        guard let dictionary = document.documentRef?.page(at: pageIndex + 1)?.dictionary else { return ([:], [:]) }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &array), let array else { return ([:], [:]) }
        var raw: [(subtype: String, dictionary: CGPDFDictionaryRef)] = []
        for i in 0..<CGPDFArrayGetCount(array) {
            var annotation: CGPDFDictionaryRef?
            var name: UnsafePointer<CChar>?
            guard CGPDFArrayGetDictionary(array, i, &annotation), let annotation,
                  CGPDFDictionaryGetName(annotation, "Subtype", &name), let name else { continue }
            raw.append((String(cString: name), annotation))
        }
        func position(ofRaw index: Int) -> Int? {
            let subtype = raw[index].subtype
            let rank = raw[..<index].filter { $0.subtype == subtype }.count
            let candidates = annotations.indices.filter { annotations[$0].type == subtype }
            guard rank < candidates.count, isSame(raw[index].dictionary, annotations[candidates[rank]]) else { return nil }
            return candidates[rank]
        }
        var direct: [Int: Int] = [:]
        for (index, entry) in raw.enumerated() {
            var target: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(entry.dictionary, "IRT", &target), let target,
                  let parentIndex = raw.firstIndex(where: { $0.dictionary == target }),
                  let child = position(ofRaw: index), let parent = position(ofRaw: parentIndex), child != parent else { continue }
            direct[child] = parent
        }
        var parent: [Int: Int] = [:]
        var replies: [Int: [Int]] = [:]
        for child in direct.keys.sorted() {
            var root = direct[child]!
            var seen: Set<Int> = [child]
            while let next = direct[root], seen.insert(root).inserted { root = next }
            guard root != child else { continue }
            parent[child] = root
            replies[root, default: []].append(child)
        }
        return (parent, replies)
    }

    /// Whether a raw annotation dictionary is the PDFKit annotation paired with it: the same Contents and
    /// left edge. PDFKit normalizes some sizes (sticky notes), so only `/Rect`'s left edge is compared.
    private static func isSame(_ dictionary: CGPDFDictionaryRef, _ annotation: PDFAnnotation) -> Bool {
        var rect: CGPDFArrayRef?
        var left: CGPDFReal = 0, right: CGPDFReal = 0
        guard CGPDFDictionaryGetArray(dictionary, "Rect", &rect), let rect,
              CGPDFArrayGetNumber(rect, 0, &left), CGPDFArrayGetNumber(rect, 2, &right),
              abs(min(left, right) - annotation.bounds.minX) <= 1 else { return false }
        var string: CGPDFStringRef?
        var contents = ""
        if CGPDFDictionaryGetString(dictionary, "Contents", &string), let string,
           let text = CGPDFStringCopyTextString(string) {
            contents = text as String
        }
        let trimmed = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trimmed(contents) == trimmed(annotation.contents ?? "")
    }

    // MARK: Dates

    private static func date(of annotation: PDFAnnotation) -> Date? {
        if let modified = annotation.modificationDate { return modified }
        switch annotation.annotationKeyValues[PDFAnnotationKey(rawValue: "/CreationDate")] {
        case let date as Date: return date
        case let string as String: return pdfDate(string)
        default: return nil
        }
    }

    /// Parses a PDF date string (`D:YYYYMMDDHHmmSSOHH'mm'`, every part after the year optional).
    static func pdfDate(_ string: String) -> Date? {
        let pattern = #"^(?:D:)?(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?(?:(Z)|([+-])(\d{2})'?(\d{2})?'?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else { return nil }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: string).map { String(string[$0]) } }
        func number(_ i: Int, _ fallback: Int) -> Int { group(i).flatMap { Int($0) } ?? fallback }
        var components = DateComponents()
        components.year = number(1, 0)
        components.month = number(2, 1)
        components.day = number(3, 1)
        components.hour = number(4, 0)
        components.minute = number(5, 0)
        components.second = number(6, 0)
        if let sign = group(8) {
            let offset = (number(9, 0) * 60 + number(10, 0)) * 60
            components.timeZone = TimeZone(secondsFromGMT: sign == "-" ? -offset : offset)
        } else {
            components.timeZone = TimeZone(identifier: "UTC")
        }
        return Calendar(identifier: .gregorian).date(from: components)
    }

    // MARK: Quotes

    /// The annotation's quad points as one rectangle per text line, top to bottom.
    private static func lineRects(of annotation: PDFAnnotation) -> [CGRect] {
        let points = (annotation.quadrilateralPoints ?? []).map(\.pointValue)
        guard points.count >= 4 else { return [annotation.bounds] }
        let origin = annotation.bounds.origin
        let quads = stride(from: 0, to: points.count - 3, by: 4).map { i -> CGRect in
            let quad = points[i..<i + 4]
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return CGRect(x: xs.min()! + origin.x, y: ys.min()! + origin.y,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        var lines: [CGRect] = []
        for quad in quads.sorted(by: { $0.midY > $1.midY }) {
            if let last = lines.last, verticalOverlap(last, quad) >= min(last.height, quad.height) * 0.5 {
                lines[lines.count - 1] = last.union(quad)
            } else {
                lines.append(quad)
            }
        }
        return lines
    }

    private static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }

    /// The cleaned line holding most of `rect`, by index into the page's lines.
    private static func lineIndex(for rect: CGRect, in lines: [PDFLine], slack: CGFloat = 0) -> Int? {
        var best: (index: Int, overlap: CGFloat)?
        for (index, line) in lines.enumerated() {
            let vertical = verticalOverlap(line.bounds, rect)
            guard vertical >= min(line.bounds.height, rect.height) * 0.5,
                  rect.maxX > line.bounds.minX - slack, rect.minX < line.bounds.maxX + slack else { continue }
            if vertical > best?.overlap ?? 0 { best = (index, vertical) }
        }
        return best?.index
    }

    private static func clean(_ text: String?) -> String {
        PDFTextExtractor.collapseWhitespace(PDFTextExtractor.normalizeCharacters(text ?? ""))
    }

    /// The cleaned page text between the left edge of `line` and `x`.
    private static func textLeft(of x: CGFloat, in line: PDFLine, on page: PDFPage) -> String {
        let start = line.bounds.minX - 1
        guard x > start else { return "" }
        let band = CGRect(x: start, y: line.bounds.midY - line.bounds.height * 0.2, width: x - start, height: line.bounds.height * 0.4)
        return clean(page.selection(for: band)?.string)
    }

    private struct Piece {
        var text: String
        var line: Int?
        var start = 0
        var end = 0
    }

    private static func quote(in rects: [CGRect], on page: PDFPage, lines: [PDFLine]) -> (text: String, before: String, after: String) {
        var pieces: [Piece] = []
        for rect in rects {
            let inset = min(0.5, rect.width / 4)
            let band = CGRect(x: rect.minX + inset, y: rect.midY - rect.height * 0.2,
                              width: rect.width - 2 * inset, height: rect.height * 0.4)
            let snapped = wordRange(under: rect, on: page)
            var text = snapped.map { clean($0.text) } ?? clean(page.selection(for: band)?.string)
            guard let index = lineIndex(for: rect, in: lines) else {
                if !text.isEmpty { pieces.append(Piece(text: text)) }
                continue
            }
            let lineText = lines[index].text
            if !lineText.contains(text) {
                let stripped = PDFTextExtractor.stripLineNumbers(text)
                if lineText.contains(stripped) { text = stripped }
            }
            let left = textLeft(of: snapped.map { $0.minX - 0.5 } ?? rect.minX + inset, in: lines[index], on: page)
            let expected = min(left.isEmpty ? 0 : left.count + 1, lineText.count)
            let starts = text.isEmpty ? [] : lineText.ranges(of: text).map { lineText.distance(from: lineText.startIndex, to: $0.lowerBound) }
            let start = starts.min { abs($0 - expected) < abs($1 - expected) } ?? expected
            pieces.append(Piece(text: text, line: index, start: start, end: min(start + text.count, lineText.count)))
        }
        let text = PDFTextExtractor.joinLines(pieces.map(\.text).filter { !$0.isEmpty })
        let first = pieces.first { $0.line != nil }
        let last = pieces.last { $0.line != nil }
        let before = first.map { context(before: $0.start, inLine: $0.line!, of: lines) } ?? ""
        let after = last.map { context(after: $0.end, inLine: $0.line!, of: lines) } ?? ""
        return (text, before, after)
    }

    /// The page-string range of the whole words under one line's quad.
    ///
    /// A character is under the quad when the centre of its glyph is. Words come from `splitWords`. A word at either end counts when at least half
    /// of its letters are under the quad, and is then taken whole, so quads that stop short of a word's
    /// end or reach into the next word still quote whole words. A number standing more than a line height
    /// apart at either end (a `lineno` number) is left out. `minX` is the left edge of the first glyph, and
    /// `text` the words joined by `joinWords`.
    private static func wordRange(under rect: CGRect, on page: PDFPage) -> (range: NSRange, minX: CGFloat, text: String)? {
        guard let string = page.string as NSString?, string.length > 0, rect.height > 0 else { return nil }
        let em = rect.height
        let search = CGRect(x: rect.minX - em, y: rect.midY - em * 0.2, width: rect.width + 2 * em, height: em * 0.4)
        guard let selection = page.selection(for: search) else { return nil }
        let ranges = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
            .filter { $0.location != NSNotFound && $0.length > 0 }
        guard var lower = ranges.map(\.location).min(), var upper = ranges.map(NSMaxRange).max() else { return nil }
        upper = min(upper, string.length)

        var boxes: [Int: CGRect] = [:]
        func box(_ i: Int) -> CGRect? {
            if let cached = boxes[i] { return cached.isEmpty ? nil : cached }
            let bounds = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) ?? .zero
            boxes[i] = bounds
            return bounds.isEmpty ? nil : bounds
        }
        func isSpace(_ i: Int) -> Bool {
            UnicodeScalar(string.character(at: i)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? true
        }
        func adjacent(_ a: Int, _ b: Int) -> Bool {
            guard !isSpace(a), !isSpace(b), let x = box(a), let y = box(b) else { return false }
            return glyphsAdjacent(x, y, em: em)
        }
        var steps = 0
        while lower > 0, steps < 60, adjacent(lower - 1, lower) { lower -= 1; steps += 1 }
        steps = 0
        while upper < string.length, steps < 60, adjacent(upper - 1, upper) { upper += 1; steps += 1 }

        let words = splitWords((lower..<upper).map { (isSpace($0), box($0)) }, em: em)
            .map { (lower + $0.lowerBound)...(lower + $0.upperBound) }

        func isAlphanumeric(_ i: Int) -> Bool {
            UnicodeScalar(string.character(at: i)).map { CharacterSet.alphanumerics.contains($0) } ?? false
        }
        func isUnder(_ i: Int) -> Bool {
            guard let b = box(i) else { return false }
            return rect.contains(CGPoint(x: b.midX, y: b.midY))
        }
        // Only glyphs with a box can be under the quad, so only they are counted.
        func share(_ word: ClosedRange<Int>) -> (under: Int, total: Int) {
            let boxed = word.filter { box($0) != nil }
            let letters = boxed.filter(isAlphanumeric)
            let counted = letters.isEmpty ? boxed : letters
            return (counted.filter(isUnder).count, counted.count)
        }
        var selected = words.filter { let s = share($0); return s.under > 0 && s.under * 2 >= s.total }
        if selected.isEmpty, let best = words.max(by: { share($0).under < share($1).under }), share(best).under > 0 {
            selected = [best]
        }
        func isNumber(_ word: ClosedRange<Int>) -> Bool {
            word.allSatisfy { (0x30...0x39).contains(string.character(at: $0)) }
        }
        func gap(_ a: ClosedRange<Int>, _ b: ClosedRange<Int>) -> CGFloat {
            guard let x = a.reversed().lazy.compactMap(box).first, let y = b.lazy.compactMap(box).first else { return 0 }
            return y.minX - x.maxX
        }
        while selected.count > 1, isNumber(selected[selected.count - 1]),
              gap(selected[selected.count - 2], selected[selected.count - 1]) > em {
            selected.removeLast()
        }
        while selected.count > 1, isNumber(selected[0]), gap(selected[0], selected[1]) > em {
            selected.removeFirst()
        }
        guard let first = selected.first, let last = selected.last,
              let firstBox = first.lazy.compactMap(box).first else { return nil }
        var glyphWords: [GlyphWord] = []
        for (n, word) in selected.enumerated() {
            let spaceBefore = n > 0 && (selected[n - 1].upperBound + 1..<word.lowerBound).contains(where: isSpace)
            glyphWords.append(GlyphWord(text: string.substring(with: NSRange(location: word.lowerBound, length: word.count)),
                                        minX: box(word.lowerBound)?.minX, maxX: box(word.upperBound)?.maxX,
                                        spaceBefore: spaceBefore))
        }
        return (NSRange(location: first.lowerBound, length: last.upperBound - first.lowerBound + 1), firstBox.minX,
                joinWords(glyphWords, em: em))
    }

    /// Whether two glyph boxes on one line belong to the same word: they stand within a fifth of the line
    /// height (`em`, the quad's height, not the font's em) of each other and on the same baseline.
    static func glyphsAdjacent(_ x: CGRect, _ y: CGRect, em: CGFloat) -> Bool {
        y.minX - x.maxX <= em * 0.2 && x.minX - y.maxX <= em * 0.2 && abs(x.midY - y.midY) < em / 2
    }

    /// Splits a run of characters into words, as index ranges into `glyphs`. Whitespace ends a word, and so
    /// does a gap between two neighbouring boxed glyphs that are not `glyphsAdjacent`. A glyph PDFKit gives
    /// no box has no position, so there is no gap to measure on either side of it: it stays in the word it
    /// falls in and does not split it.
    static func splitWords(_ glyphs: [(isSpace: Bool, box: CGRect?)], em: CGFloat) -> [ClosedRange<Int>] {
        var words: [ClosedRange<Int>] = []
        var start: Int?
        var previousBox: CGRect?
        for (i, glyph) in glyphs.enumerated() {
            if glyph.isSpace {
                if let s = start { words.append(s...(i - 1)) }
                start = nil
                previousBox = nil
                continue
            }
            if let s = start, let previous = previousBox, let current = glyph.box, !glyphsAdjacent(previous, current, em: em) {
                words.append(s...(i - 1))
                start = i
            } else if start == nil {
                start = i
            }
            previousBox = glyph.box
        }
        if let s = start { words.append(s...(glyphs.count - 1)) }
        return words
    }

    /// A run of glyphs on one line without spaces or wide gaps, with its horizontal extent. `minX` and
    /// `maxX` are nil when the glyph at that end has no box.
    struct GlyphWord {
        var text: String
        var minX: CGFloat?
        var maxX: CGFloat?
        /// Whether the page string has whitespace between this word and the previous one.
        var spaceBefore: Bool
    }

    /// Joins the words of one line, putting a single space wherever the page string has whitespace or the
    /// glyphs stand at least a fifth of `em` apart, where `em` is the line height (the quad's height), not
    /// the font's em. pdfTeX's justified text can reach PDFKit without space characters, so the gap alone
    /// must be enough to separate words. When either facing glyph has no box there is no gap to measure,
    /// and only whitespace in the page string adds a space.
    static func joinWords(_ words: [GlyphWord], em: CGFloat) -> String {
        var out = ""
        for (n, word) in words.enumerated() {
            var space = word.spaceBefore
            if n > 0, !space, let left = words[n - 1].maxX, let right = word.minX { space = right - left >= em * 0.2 }
            if n > 0, space { out += " " }
            out += word.text
        }
        return out
    }

    /// Context around a caret: the text before and after its horizontal centre on the line it marks.
    private static func caretContext(_ bounds: CGRect, on page: PDFPage, lines: [PDFLine]) -> (before: String, after: String) {
        guard let index = lineIndex(for: bounds, in: lines, slack: 4) else { return ("", "") }
        let offset = min(textLeft(of: bounds.midX, in: lines[index], on: page).count, lines[index].text.count)
        return (context(before: offset, inLine: index, of: lines), context(after: offset, inLine: index, of: lines))
    }

    /// Up to `contextLength` characters of the page's cleaned text before `offset` in line `index`.
    private static func context(before offset: Int, inLine index: Int, of lines: [PDFLine]) -> String {
        var texts = [String(lines[index].text.prefix(offset))]
        var k = index - 1
        var total = 0
        while k >= 0, total < contextLength * 2 {
            texts.insert(lines[k].text, at: 0)
            total += lines[k].text.count
            k -= 1
        }
        return String(PDFTextExtractor.joinLines(texts).suffix(contextLength))
    }

    /// Up to `contextLength` characters of the page's cleaned text after `offset` in line `index`.
    private static func context(after offset: Int, inLine index: Int, of lines: [PDFLine]) -> String {
        var texts: [String] = []
        var k = index + 1
        var total = 0
        while k < lines.count, total < contextLength * 2 {
            texts.append(lines[k].text)
            total += lines[k].text.count
            k += 1
        }
        let rest = String(lines[index].text.dropFirst(offset))
        let following = PDFTextExtractor.joinLines(texts)
        let text: String
        if rest.isEmpty {
            text = following.isEmpty ? "" : " " + following
        } else {
            text = PDFTextExtractor.joinLines([rest] + texts)
        }
        return String(text.prefix(contextLength))
    }
}
