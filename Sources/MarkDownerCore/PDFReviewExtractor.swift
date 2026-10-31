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
            guard let page = document.page(at: index) else { continue }
            result += comments(on: page, index: index, lines: index < lines.count ? lines[index] : [], document: document)
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
    /// to PDFKit's annotations by subtype and order (PDFKit keeps the array's order).
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
            return rank < candidates.count ? candidates[rank] : nil
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
            var text = clean(page.selection(for: band)?.string)
            guard let index = lineIndex(for: rect, in: lines) else {
                if !text.isEmpty { pieces.append(Piece(text: text)) }
                continue
            }
            let lineText = lines[index].text
            if !lineText.contains(text) {
                let stripped = PDFTextExtractor.stripLineNumbers(text)
                if lineText.contains(stripped) { text = stripped }
            }
            let left = textLeft(of: rect.minX + inset, in: lines[index], on: page)
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
