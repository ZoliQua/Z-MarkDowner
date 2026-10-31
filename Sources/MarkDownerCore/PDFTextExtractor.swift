import AppKit
import PDFKit

/// One line of text read from a PDF page, in page coordinates (origin bottom left).
public struct PDFLine: Equatable {
    public var text: String
    public var bounds: CGRect
    public var fontSize: CGFloat
    public var isBold: Bool
    /// Zero-based page index.
    public var page: Int

    public init(text: String, bounds: CGRect, fontSize: CGFloat, isBold: Bool, page: Int) {
        self.text = text
        self.bounds = bounds
        self.fontSize = fontSize
        self.isBold = isBold
        self.page = page
    }
}

/// The result of turning a PDF into Markdown.
public struct PDFExtraction {
    public var markdown: String
    /// The cleaned lines in reading order.
    public var lines: [PDFLine]
    /// Zero-based indexes of the pages whose text was recognised with OCR.
    public var ocrPages: [Int]
    /// Localized, user-visible notes about problems met during the extraction.
    public var warnings: [String]

    public init(markdown: String, lines: [PDFLine], ocrPages: [Int], warnings: [String]) {
        self.markdown = markdown
        self.lines = lines
        self.ocrPages = ocrPages
        self.warnings = warnings
    }
}

/// Recovers structured Markdown (front matter, headings, paragraphs, lists) from the text layer of a PDF.
///
/// Typesetting artefacts are removed first: `lineno` line numbers, running headers and footers, page
/// numbers, ligatures and end-of-line hyphenation. Two-column pages are read column by column.
public enum PDFTextExtractor {

    /// Pages with fewer extractable characters than this are candidates for OCR.
    static let ocrCharacterThreshold = 20

    public static func extract(_ document: PDFDocument, ocr: Bool = true) -> PDFExtraction {
        extract(document, ocr: ocr, includeAnnotations: DocumentImporter.revisionMode == .markup)
    }

    /// With `includeAnnotations`, the reviewers' annotations are written into the Markdown as CriticMarkup.
    public static func extract(_ document: PDFDocument, ocr: Bool = true, includeAnnotations: Bool) -> PDFExtraction {
        if document.isLocked {
            return PDFExtraction(markdown: "", lines: [], ocrPages: [], warnings: [CoreStrings.pdfLocked])
        }
        var pages: [[PDFLine]] = []
        var pageBounds: [CGRect] = []
        var ocrPages: [Int] = []
        var warnings: [String] = []
        let languages = ocr ? PDFOCR.preferredLanguages : []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                pages.append([])
                pageBounds.append(.zero)
                continue
            }
            var lines = readLines(of: page, index: index)
            if ocr, lines.reduce(0, { $0 + $1.text.count }) < ocrCharacterThreshold {
                let recognized = PDFOCR.recognize(page, pageIndex: index, languages: languages)
                if recognized.isEmpty {
                    warnings.append(CoreStrings.pdfNoTextOnPage(index + 1))
                } else {
                    lines = recognized
                    ocrPages.append(index)
                }
            }
            pages.append(lines)
            pageBounds.append(page.bounds(for: .mediaBox))
        }

        let ordered = cleanLines(pages, pageBounds: pageBounds).flatMap(readingOrder)
        if document.pageCount > 0 && ordered.isEmpty { warnings.append(CoreStrings.pdfNoText) }
        var markdown = frontMatter(of: document) + render(ordered)
        if includeAnnotations {
            markdown = addingReviewMarks(from: PDFReviewExtractor.comments(from: document), to: markdown)
        }
        return PDFExtraction(markdown: markdown, lines: ordered, ocrPages: ocrPages, warnings: warnings)
    }

    /// Each page's cleaned lines in reading order, without OCR (the text layer the annotations sit on).
    static func readingLines(of document: PDFDocument) -> [[PDFLine]] {
        var pages: [[PDFLine]] = []
        var pageBounds: [CGRect] = []
        for index in 0..<document.pageCount {
            let page = document.page(at: index)
            pages.append(page.map { readLines(of: $0, index: index) } ?? [])
            pageBounds.append(page?.bounds(for: .mediaBox) ?? .zero)
        }
        return cleanLines(pages, pageBounds: pageBounds).map(readingOrder)
    }

    // MARK: Reading lines

    private static func readLines(of page: PDFPage, index: Int) -> [PDFLine] {
        guard let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        var lines: [PDFLine] = []
        for lineSelection in selection.selectionsByLine() {
            let text = collapseWhitespace(lineSelection.string ?? "")
            guard !text.isEmpty else { continue }
            var fontSize: CGFloat = 0
            var isBold = false
            if let attributed = lineSelection.attributedString {
                let ns = attributed.string as NSString
                var location = 0
                while location < ns.length,
                      let scalar = UnicodeScalar(ns.character(at: location)),
                      CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    location += 1
                }
                if location < ns.length, let font = attributed.attribute(.font, at: location, effectiveRange: nil) as? NSFont {
                    fontSize = font.pointSize
                    isBold = isBoldFont(font)
                }
            }
            let fullBounds = lineSelection.bounds(for: page)
            if fontSize <= 0 { fontSize = fullBounds.height }
            let bounds = textBounds(of: lineSelection, on: page, fontSize: fontSize) ?? fullBounds
            lines.append(PDFLine(text: text, bounds: bounds, fontSize: fontSize, isBold: isBold, page: index))
        }
        return lines
    }

    private static func isBoldFont(_ font: NSFont) -> Bool {
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let name = font.fontName
        return ["Bold", "Black", "Semibold", "SemiBold", "Heavy", "CMBX"].contains { name.contains($0) }
    }

    /// The bounds of a line without a number standing apart in the margin (a line number), so that
    /// widths and left edges describe the text itself.
    private static func textBounds(of selection: PDFSelection, on page: PDFPage, fontSize: CGFloat) -> CGRect? {
        let count = selection.numberOfTextRanges(on: page)
        guard count > 0, let pageString = page.string as NSString? else { return nil }
        let first = selection.range(at: 0, on: page)
        let last = selection.range(at: count - 1, on: page)
        guard first.location != NSNotFound, last.location != NSNotFound else { return nil }
        let upper = min(NSMaxRange(last), pageString.length)
        func isSpace(_ i: Int) -> Bool {
            UnicodeScalar(pageString.character(at: i)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        func isDigit(_ i: Int) -> Bool { (0x30...0x39).contains(pageString.character(at: i)) }
        func bounds(_ lower: Int, _ upper: Int) -> CGRect? {
            guard upper > lower, let part = page.selection(for: NSRange(location: lower, length: upper - lower)) else { return nil }
            let rect = part.bounds(for: page)
            return rect.isEmpty ? nil : rect
        }
        var start = first.location
        var end = upper
        while start < end && isSpace(start) { start += 1 }
        while end > start && isSpace(end - 1) { end -= 1 }
        guard end > start else { return nil }

        /// Whether the digits in `digits` stand apart from the text in `text` by more than one em.
        func apart(_ digits: (Int, Int), _ text: (Int, Int)) -> Bool {
            guard let d = bounds(digits.0, digits.1), let t = bounds(text.0, text.1) else { return false }
            return d.minX - t.maxX > fontSize || t.minX - d.maxX > fontSize
        }
        var k = end
        while k > start && isDigit(k - 1) { k -= 1 }
        var textEnd = k
        while textEnd > start && isSpace(textEnd - 1) { textEnd -= 1 }
        if k < end, textEnd > start, apart((k, end), (textEnd - 1, textEnd)) { end = textEnd }
        var j = start
        while j < end && isDigit(j) { j += 1 }
        var textStart = j
        while textStart < end && isSpace(textStart) { textStart += 1 }
        if j > start, textStart < end, apart((start, j), (textStart, textStart + 1)) { start = textStart }

        guard let text = bounds(start, end) else { return nil }
        let full = selection.bounds(for: page)
        return CGRect(x: text.minX, y: full.minY, width: text.width, height: full.height)
    }

    // MARK: Cleaning

    /// Normalizes characters and removes line numbers, running headers/footers and page numbers.
    ///
    /// `pageBounds` gives each page's media box; when missing, the area covered by all lines is used.
    public static func cleanLines(_ pages: [[PDFLine]], pageBounds: [CGRect] = []) -> [[PDFLine]] {
        var pages = pages.map { lines in
            lines.compactMap { line -> PDFLine? in
                var line = line
                line.text = collapseWhitespace(normalizeCharacters(line.text))
                return line.text.isEmpty ? nil : line
            }
        }
        let fallback = pages.joined().map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        let boxes = pages.indices.map { i -> CGRect in
            i < pageBounds.count && !pageBounds[i].isEmpty ? pageBounds[i] : fallback
        }
        let contentBoxes = pages.map { $0.map(\.bounds).reduce(CGRect.null) { $0.union($1) } }

        func inBand(_ line: PDFLine, _ box: CGRect) -> Bool {
            guard !box.isNull, box.height > 0 else { return false }
            let band = box.height * 0.08
            return line.bounds.midY >= box.maxY - band || line.bounds.midY <= box.minY + band
        }
        /// Top or bottom 8 % of the page, or of the area its text covers (LaTeX's default margins put
        /// running heads well inside the page).
        func inMargin(_ line: PDFLine, _ page: Int) -> Bool {
            inBand(line, boxes[page]) || inBand(line, contentBoxes[page])
        }
        func key(_ text: String) -> String {
            text.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression).lowercased()
        }
        var repeated: Set<String> = []
        if pages.count >= 3 {
            var counts: [String: Int] = [:]
            for (i, lines) in pages.enumerated() {
                for k in Set(lines.filter { inMargin($0, i) }.map { key($0.text) }) { counts[k, default: 0] += 1 }
            }
            let needed = max(3, Int((Double(pages.count) * 0.5).rounded(.up)))
            repeated = Set(counts.filter { $0.value >= needed }.keys)
        }
        for i in pages.indices {
            pages[i].removeAll { line in
                inMargin(line, i) && (repeated.contains(key(line.text)) || isPageNumber(line.text))
            }
            pages[i] = removeLineNumbers(pages[i])
        }
        return pages
    }

    private static func isPageNumber(_ text: String) -> Bool {
        text.range(of: #"^(?i)(page\s+|p\.\s*)?(\d+|[ivxlc]+)(\s*(of|/)\s*\d+)?$"#, options: .regularExpression) != nil
    }

    /// Replaces ligatures (ﬀ ﬁ ﬂ ﬃ ﬄ) by their letters, removes soft hyphens and turns no-break spaces into spaces.
    public static func normalizeCharacters(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\u{FB00}": out += "ff"
            case "\u{FB01}": out += "fi"
            case "\u{FB02}": out += "fl"
            case "\u{FB03}": out += "ffi"
            case "\u{FB04}": out += "ffl"
            case "\u{00AD}": continue
            case "\u{00A0}", "\u{202F}": out += " "
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Line numbers

    private enum Side { case leading, trailing }

    /// Removes a `lineno`-style integer glued to the start or end of one line ("platform for1" → "platform for").
    ///
    /// A trailing number is preferred; a string that is only a number is returned unchanged.
    public static func stripLineNumbers(_ s: String) -> String {
        let text = s.trimmingCharacters(in: .whitespaces)
        if let stripped = stripNumber(text, side: .trailing, after: nil) { return stripped.text }
        if let stripped = stripNumber(text, side: .leading, after: nil) { return stripped.text }
        return s
    }

    /// The digit run at one end of `text`, when other text remains besides it. A leading run must be
    /// followed by a space or a letter, so section numbers such as "1.2 Methods" are not taken.
    private static func digitRun(_ text: String, side: Side) -> Substring? {
        let digits = side == .trailing
            ? text.reversed().prefix { $0.isASCII && $0.isNumber }.count
            : text.prefix { $0.isASCII && $0.isNumber }.count
        guard digits > 0, digits < text.count else { return nil }
        if side == .leading {
            let next = text[text.index(text.startIndex, offsetBy: digits)]
            guard next.isWhitespace || next.isLetter else { return nil }
            return text.prefix(digits)
        }
        return text.suffix(digits)
    }

    /// Removes the line number at one end of `text`. With `last` (the previous line number on the page)
    /// only the shortest run of edge digits that continues the sequence (`last` < n ≤ `last` + 20) is
    /// taken, so a number in the text glued to the line number ("in 202017") keeps its own digits, and
    /// nothing is removed when no run continues it.
    private static func stripNumber(_ text: String, side: Side, after last: Int?) -> (text: String, value: Int)? {
        guard let run = digitRun(text, side: side) else { return nil }
        var take = run.count
        if let last {
            let candidates = (1...run.count).filter { length in
                let part = side == .trailing ? run.suffix(length) : run.prefix(length)
                guard let value = Int(part) else { return false }
                return value > last && value <= last + 20
            }
            guard let shortest = candidates.first else { return nil }
            take = shortest
        }
        let digits = side == .trailing ? run.suffix(take) : run.prefix(take)
        guard let value = Int(digits) else { return nil }
        let rest = side == .trailing ? String(text.dropLast(take)) : String(text.dropFirst(take))
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed, value)
    }

    /// Applies the `lineno` rule to one page: when at least half of the lines start or end with an
    /// integer that increases down the page, those numbers are removed and number-only lines dropped.
    /// Both ends are checked, as two-column layouts number the left column on the left and the right one on the right.
    /// PDFKit often returns the numbers as separate number-only lines, so the share is taken against the
    /// lines that hold text.
    private static func removeLineNumbers(_ lines: [PDFLine]) -> [PDFLine] {
        guard lines.count >= 2 else { return lines }
        var lines = lines
        func isNumberOnly(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber } }
        for side in [Side.trailing, .leading] {
            var last: Int?
            var values: [Int] = []
            let parsed = lines.map { line -> String? in
                if isNumberOnly(line.text) {
                    last = Int(line.text) ?? last
                    values.append(last ?? 0)
                    return nil
                }
                guard let stripped = stripNumber(line.text, side: side, after: last) else { return line.text }
                last = stripped.value
                values.append(stripped.value)
                return stripped.text
            }
            let textLines = lines.filter { !isNumberOnly($0.text) }.count
            guard values.count >= 2, Double(values.count) >= Double(max(textLines, 1)) * 0.5 else { continue }
            let rising = zip(values, values.dropFirst()).filter { $0 < $1 }.count
            guard Double(rising) >= Double(values.count - 1) * 0.8 else { continue }
            lines = zip(lines, parsed).compactMap { line, text in
                guard let text else { return nil }
                var line = line
                line.text = text
                return line
            }
        }
        return lines
    }

    // MARK: Reading order

    /// Reads a two-column page column by column: the lines' left edges must form two groups each holding
    /// at least 30 % of the lines, with most of the left group's lines ending before the right column
    /// (its median left edge) starts.
    private static func readingOrder(_ lines: [PDFLine]) -> [PDFLine] {
        guard lines.count >= 4 else { return lines }
        let xs = lines.map(\.bounds.minX).sorted()
        guard let minX = xs.first, let maxX = lines.map(\.bounds.maxX).max(), maxX > minX else { return lines }
        var bestGap: CGFloat = 0
        var split: CGFloat = 0
        for (a, b) in zip(xs, xs.dropFirst()) where b - a > bestGap {
            bestGap = b - a
            split = (a + b) / 2
        }
        guard bestGap >= (maxX - minX) * 0.15 else { return lines }
        let left = lines.filter { $0.bounds.minX < split }
        let right = lines.filter { $0.bounds.minX >= split }
        let minimum = Double(lines.count) * 0.3
        guard Double(left.count) >= minimum, Double(right.count) >= minimum else { return lines }
        let rightStart = median(right.map(\.bounds.minX))
        let leftEndsBeforeRight = left.filter { $0.bounds.maxX <= rightStart + 2 }.count
        guard Double(leftEndsBeforeRight) >= Double(left.count) * 0.5 else { return lines }
        return left + right
    }

    // MARK: Structure

    private enum ListMarker: Equatable {
        case bullet
        case ordered(String)
    }

    private struct Block {
        var lines: [PDFLine]
        var list: ListMarker?
        /// The list marker as printed ("•", "2.", "a)").
        var marker = ""
        var text = ""
        var fontSize: CGFloat { lines.first?.fontSize ?? 0 }
        var isBold: Bool { lines.allSatisfy(\.isBold) }
    }

    private struct PageMetrics {
        var lineGap: CGFloat
        var lineWidth: CGFloat
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    private static func rounded(_ size: CGFloat) -> CGFloat { (size * 2).rounded() / 2 }

    /// The most frequent font size weighted by character count.
    private static func bodySize(_ lines: [PDFLine]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for line in lines { weights[rounded(line.fontSize), default: 0] += line.text.count }
        return weights.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key ?? 0
    }

    private static func listMarker(_ text: String) -> (list: ListMarker, marker: String, rest: String)? {
        let patterns: [(String, Bool)] = [(#"^[•–▪]\s*"#, false), (#"^-\s+"#, false),
                                          (#"^\d{1,3}[.)]\s+"#, true), (#"^[a-zA-Z]\)\s+"#, true)]
        for (pattern, ordered) in patterns {
            guard let range = text.range(of: pattern, options: .regularExpression) else { continue }
            let rest = String(text[range.upperBound...])
            guard !rest.isEmpty else { return nil }
            let marker = text[range].trimmingCharacters(in: .whitespaces)
            return (ordered ? .ordered(marker) : .bullet, marker, rest)
        }
        return nil
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".:?!".contains(last)
    }

    /// Joins the lines of a block, undoing end-of-line hyphenation.
    static func joinLines(_ texts: [String]) -> String {
        var out = ""
        for text in texts {
            if out.isEmpty {
                out = text
            } else if out.hasSuffix("-"), out.dropLast().last?.isLetter == true, text.first?.isLowercase == true {
                out.removeLast()
                out += text
            } else {
                out += " " + text
            }
        }
        return out
    }

    private static func render(_ lines: [PDFLine]) -> String {
        guard !lines.isEmpty else { return "" }
        let body = bodySize(lines)
        var metrics: [Int: PageMetrics] = [:]
        for page in Set(lines.map(\.page)) {
            let pageLines = lines.filter { $0.page == page }
            let gaps = zip(pageLines, pageLines.dropFirst())
                .map { $0.bounds.minY - $1.bounds.minY }
                .filter { $0 > 0 }
            metrics[page] = PageMetrics(lineGap: median(gaps), lineWidth: median(pageLines.map(\.bounds.width)))
        }

        /// Spec rules (gap > 1.5 × median gap, short line ending a sentence, font size change > 10 %), plus a
        /// break after a short bold line and before a first-line indent following a sentence end (LaTeX style).
        func startsNewBlock(_ previous: PDFLine, _ line: PDFLine) -> Bool {
            if abs(line.fontSize - previous.fontSize) > previous.fontSize * 0.1 { return true }
            let m = metrics[previous.page] ?? PageMetrics(lineGap: 0, lineWidth: 0)
            if line.page == previous.page, m.lineGap > 0 {
                let gap = previous.bounds.minY - line.bounds.minY
                if gap > m.lineGap * 1.5 { return true }
            }
            let short = previous.bounds.width < m.lineWidth * 0.8
            if endsSentence(previous.text) && short { return true }
            if previous.isBold && !line.isBold && short { return true }
            if endsSentence(previous.text), line.page == previous.page {
                let indent = line.bounds.minX - previous.bounds.minX
                if indent >= line.fontSize * 0.8 && indent <= line.fontSize * 6 { return true }
            }
            return false
        }

        var blocks: [Block] = []
        // A marker starts a list item only where a new block may begin ("•" and "▪" always do), so a
        // wrapped line that happens to start with "5. " stays in its paragraph.
        for line in lines {
            let previous = blocks.last?.lines.last
            var item = line.fontSize < body * 1.15 ? listMarker(line.text) : nil
            if let found = item, let previous,
               !(found.marker == "•" || found.marker == "▪" || blocks.last?.list != nil
                 || endsSentence(previous.text) || startsNewBlock(previous, line)) {
                item = nil
            }
            if item == nil, let previous, !startsNewBlock(previous, line) {
                blocks[blocks.count - 1].lines.append(line)
            } else {
                var block = Block(lines: [line], list: item?.list)
                if let item {
                    block.marker = item.marker
                    block.lines[0].text = item.rest
                }
                blocks.append(block)
            }
        }
        for i in blocks.indices { blocks[i].text = joinLines(blocks[i].lines.map(\.text)) }

        /// Short blocks not ending with "."; numbered lines ("2. Methods") qualify and keep their number.
        func isHeadingCandidate(_ block: Block) -> Bool {
            if block.list == .bullet { return false }
            return block.lines.count <= 2 && block.text.count <= 150 && !block.text.hasSuffix(".")
        }
        let headingSizes = blocks.filter { isHeadingCandidate($0) && $0.fontSize >= body * 1.15 }.map { rounded($0.fontSize) }
        let levels = Array(Set(headingSizes)).sorted(by: >)

        var out: [(text: String, isItem: Bool)] = []
        for (i, block) in blocks.enumerated() {
            let text = AttributedToMarkdown.escape(block.text)
            let headingText = block.marker.isEmpty ? text : AttributedToMarkdown.escape(block.marker) + " " + text
            if isHeadingCandidate(block), block.fontSize >= body * 1.15, let rank = levels.firstIndex(of: rounded(block.fontSize)) {
                out.append((String(repeating: "#", count: min(rank + 1, 3)) + " " + headingText, false))
                continue
            }
            if isHeadingCandidate(block), block.isBold, abs(block.fontSize - body) <= body * 0.1, i + 1 < blocks.count {
                let next = blocks[i + 1]
                if next.list == nil, !isHeadingCandidate(next) || next.text.hasSuffix("."), !next.isBold,
                   next.fontSize < body * 1.15 {
                    out.append(("### " + headingText, false))
                    continue
                }
            }
            switch block.list {
            case .bullet:
                out.append(("- " + text, true))
            case .ordered(let marker):
                if marker.first?.isNumber == true {
                    let number = marker.prefix { $0.isNumber }
                    out.append(("\(number). " + text, true))
                } else {
                    out.append(("- " + marker + " " + text, true))
                }
            case nil:
                out.append((AttributedToMarkdown.escapeLineStart(text), false))
            }
        }

        var markdown = ""
        for (i, chunk) in out.enumerated() {
            if i > 0 {
                markdown += out[i - 1].isItem && chunk.isItem ? "\n" : "\n\n"
            }
            markdown += chunk.text
        }
        return markdown + "\n"
    }

    // MARK: Metadata

    private static func frontMatter(of document: PDFDocument) -> String {
        let attributes = document.documentAttributes ?? [:]
        func value(_ key: PDFDocumentAttribute) -> String? {
            let raw = attributes[key] ?? attributes[key.rawValue]
            let text: String?
            if let list = raw as? [Any] {
                text = list.map { "\($0)" }.joined(separator: ", ")
            } else if let string = raw as? String {
                text = string
            } else {
                text = nil
            }
            let cleaned = text.map { collapseWhitespace(normalizeCharacters($0)) }
            return cleaned?.isEmpty == false ? cleaned : nil
        }
        var fields: [(String, String)] = []
        if let title = value(.titleAttribute) {
            let fileName = document.documentURL?.lastPathComponent ?? ""
            let baseName = document.documentURL?.deletingPathExtension().lastPathComponent ?? ""
            if fileName.isEmpty || (title.caseInsensitiveCompare(fileName) != .orderedSame
                                    && title.caseInsensitiveCompare(baseName) != .orderedSame) {
                fields.append(("title", title))
            }
        }
        if let author = value(.authorAttribute) { fields.append(("author", author)) }
        if let subject = value(.subjectAttribute) { fields.append(("subtitle", subject)) }
        if let keywords = value(.keywordsAttribute) { fields.append(("keywords", keywords)) }
        guard !fields.isEmpty else { return "" }
        return "---\n" + fields.map { "\($0.0): \(yamlScalar($0.1))" }.joined(separator: "\n") + "\n---\n\n"
    }

    /// Quotes a YAML value when it would otherwise be read as something other than a plain string.
    private static func yamlScalar(_ value: String) -> String {
        let special = value.contains(": ") || value.contains(" #") || value.hasSuffix(":")
            || "!&*[]{}|>'\"%@`#,?-".contains(value.first ?? " ")
        guard special else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: Review marks

extension PDFTextExtractor {

    private static let linePrefix = try! NSRegularExpression(pattern: #"^[ \t]*(?:#{1,6}[ \t]+|>[ \t]*|[-*+][ \t]+|\d+[.)][ \t]+)+"#)

    /// `markdown` with every comment that can be placed written in as CriticMarkup; the others are
    /// listed in a final "Comments" section.
    static func addingReviewMarks(from comments: [ReviewComment], to markdown: String) -> String {
        guard !comments.isEmpty else { return markdown }
        let normalized = NormalizedText(source: markdown, format: .markdown)
        let source = markdown as NSString
        var placed: [(range: NSRange, comment: ReviewComment)] = []
        var unplaced: [ReviewComment] = []
        for comment in comments {
            if let range = ReviewAnchor.locate(comment, in: normalized) {
                placed.append((range, comment))
            } else {
                unplaced.append(comment)
            }
        }
        let adjusted = insertionRanges(for: placed.map(\.range), in: markdown)
        var items = zip(adjusted, placed.map(\.comment)).map { (range: $0, comment: $1) }
        items.sort { $0.range.location < $1.range.location }

        var accepted: [(range: NSRange, comment: ReviewComment)] = []
        var end = 0
        for item in items {
            if item.range.location < end {
                unplaced.append(item.comment)
                continue
            }
            accepted.append(item)
            end = NSMaxRange(item.range)
        }

        var result = markdown
        for item in accepted.reversed() {
            let quote = source.substring(with: item.range)
            let mark = reviewMark(for: item.comment, quote: quote)
            guard !mark.isEmpty else { continue }
            result = (result as NSString).replacingCharacters(in: item.range, with: mark)
        }
        let listed = unplaced.sorted { ($0.page, $0.id) < ($1.page, $1.id) }.compactMap(commentLine)
        if !listed.isEmpty {
            result = result.trimmingCharacters(in: .newlines) + "\n\n## \(CoreStrings.pdfCommentsSection)\n\n" + listed.joined(separator: "\n") + "\n"
        }
        return result
    }

    /// The CriticMarkup for one comment around the text it marks (`quote`, empty at an insertion point).
    static func reviewMark(for comment: ReviewComment, quote: String) -> String {
        let escaped = singleLine(comment.comment).replacingOccurrences(of: "<<}", with: "<< }")
        let note = escaped.isEmpty ? "" : "{>>\(comment.author.isEmpty ? "" : comment.author + ": ")\(escaped)<<}"
        guard !quote.isEmpty else { return note }
        var mark: String
        switch comment.kind {
        case .strikeOut: mark = "{--\(quote)--}" + note
        case .caret, .note, .freeText: return quote + note
        case .highlight, .underline, .squiggly:
            mark = "{==\(quote)==}" + note
            if case .insertAfter(_, let text)? = comment.suggestion, comment.kind == .highlight, !text.isEmpty {
                mark += "{++\(singleLine(text))++}"
            }
        }
        return mark
    }

    /// Narrows source ranges so that a mark never starts inside a Markdown line prefix ("# ", "- ", "1. ", "> ")
    /// or runs across a paragraph break.
    static func insertionRanges(for ranges: [NSRange], in markdown: String) -> [NSRange] {
        let source = markdown as NSString
        return ranges.map { original in
            var range = original
            guard range.location <= source.length else { return NSRange(location: source.length, length: 0) }
            range.length = min(range.length, source.length - range.location)
            let lineStart = source.lineRange(for: NSRange(location: range.location, length: 0)).location
            let lineLength = source.lineRange(for: NSRange(location: lineStart, length: 0)).length
            if let match = linePrefix.firstMatch(in: markdown, range: NSRange(location: lineStart, length: lineLength)) {
                let prefixEnd = NSMaxRange(match.range)
                if range.location < prefixEnd {
                    let cut = min(prefixEnd - range.location, range.length)
                    range.location += cut
                    range.length -= cut
                    if range.length == 0 && original.length > 0 { range.location = prefixEnd }
                }
            }
            if range.length > 0 {
                let lineBreak = source.rangeOfCharacter(from: .newlines, range: range)
                if lineBreak.location != NSNotFound { range.length = lineBreak.location - range.location }
            }
            return snappedToSpans(range, in: markdown)
        }
    }

    private static let inlineSpan = try! NSRegularExpression(pattern: #"\*\*[^*\n]+\*\*|__[^_\n]+__|\*[^*\n]+\*|`[^`\n]+`|~~[^~\n]+~~"#)

    /// Widens `range` so that neither edge falls inside an emphasis, strike-through or code span.
    private static func snappedToSpans(_ range: NSRange, in markdown: String) -> NSRange {
        let source = markdown as NSString
        let line = source.lineRange(for: NSRange(location: range.location, length: 0))
        let spans = inlineSpan.matches(in: markdown, range: line).map(\.range)
        var start = range.location, end = NSMaxRange(range)
        var changed = true
        while changed {
            changed = false
            for span in spans {
                if start > span.location && start < NSMaxRange(span) {
                    if range.length == 0 { start = NSMaxRange(span); end = start } else { start = span.location }
                    changed = true
                }
                if end > span.location && end < NSMaxRange(span) && end > start {
                    end = NSMaxRange(span)
                    changed = true
                }
            }
        }
        return NSRange(location: start, length: end - start)
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*[\r\n]+\s*"#, with: " ", options: .regularExpression)
    }

    private static func commentLine(_ comment: ReviewComment) -> String? {
        let text = comment.comment.isEmpty ? comment.quotedText : comment.comment
        guard !text.isEmpty else { return nil }
        let page = CoreStrings.pdfCommentPage(comment.page + 1)
        let lead = comment.author.isEmpty ? "\(page): " : "\(page), \(comment.author): "
        return "- " + lead + text.replacingOccurrences(of: "\n", with: " ")
    }
}
