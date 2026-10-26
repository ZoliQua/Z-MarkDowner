import AppKit

/// Applies Markdown syntax highlighting to the editor's text storage.
final class MarkdownHighlighter {

    private(set) var baseFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    private var italicFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    private var headingFonts: [NSFont] = []
    private(set) var fontSize: CGFloat = 14

    /// Ranges that must not be spell checked (code, URLs, math, front matter).
    private(set) var noSpellRanges: [NSRange] = []
    /// Fenced code / math blocks and front matter: edits touching them need a full re-highlight.
    private(set) var multilineRanges: [NSRange] = []

    init() {
        updateFonts()
    }

    func updateFonts() {
        let settings = Settings.shared
        fontSize = settings.editorFontSize
        baseFont = settings.editorFont()
        italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        let scales: [CGFloat] = [1.45, 1.3, 1.15, 1.05, 1.0, 1.0]
        headingFonts = scales.map { settings.editorFont(size: (fontSize * $0).rounded(), weight: .bold) }
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = fontSize * 0.35
        return [.font: baseFont, .foregroundColor: NSColor.textColor, .paragraphStyle: para]
    }

    // MARK: Patterns

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let frontMatter = re(#"\A---[ \t]*\n(?:[\s\S]*?\n)?(?:---|\.\.\.)[ \t]*$"#, [])
    private static let fence = re(#"^ {0,3}(```|~~~)[^\n]*\n[\s\S]*?(?:^ {0,3}\1[ \t]*$|\z)"#)
    private static let mathBlock = re(#"^ {0,3}\$\$[\s\S]*?\$\$[ \t]*$"#)
    private static let heading = re(#"^ {0,3}(#{1,6})[ \t]+.*$"#)
    private static let setext = re(#"^(?!\s*$)(?![-*+>#|]).+\n {0,3}(=+|-+)[ \t]*$"#)
    private static let quote = re(#"^ {0,3}>.*$"#)
    private static let listMarker = re(#"^[ \t]*([-*+]|\d{1,9}[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    private static let hr = re(#"^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let boldItalic = re(#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    private static let bold = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = re(#"(?<![*\w])(\*|_)(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*\w])"#)
    private static let strike = re(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let inlineCode = re(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let inlineMath = re(#"(?<![\\$])\$(?=\S)[^$\n]+?(?<=\S)\$(?!\d)"#)
    private static let link = re(#"!?\[[^\]\n]*\]\([^)\n]*\)"#)
    private static let linkTarget = re(#"\]\(([^)\n]*)\)"#)
    private static let footnote = re(#"\[\^[^\]\s]+\]:?"#)
    private static let autolink = re(#"<[a-zA-Z][a-zA-Z0-9+.\-]*:[^>\s]+>|\bhttps?://[^\s<>()]+|\bwww\.[^\s<>()]+"#)
    private static let tablePipe = re(#"^\s*\|.*\|\s*$"#)

    // MARK: Highlighting

    /// Highlights the whole document.
    func highlight(_ storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        computeMultilineRanges(storage.string)
        apply(storage, in: full)
    }

    /// Highlights only the lines around an edit when possible; falls back to a full pass.
    func highlight(_ storage: NSTextStorage, editedRange: NSRange, replacement: String, replaced: String) {
        let text = storage.string as NSString
        let special = CharacterSet(charactersIn: "`~$")
        let touchesSpecial = replacement.rangeOfCharacter(from: special) != nil
            || replaced.rangeOfCharacter(from: special) != nil
            || replaced.contains("---") || replacement.contains("---")
        let oldMultiline = multilineRanges
        if storage.length < 30_000 || touchesSpecial {
            highlight(storage)
            return
        }
        // Edit inside or next to a fenced block: full pass
        let probe = NSRange(location: max(0, editedRange.location - 1), length: editedRange.length + 2)
        if oldMultiline.contains(where: { NSIntersectionRange($0, probe).length > 0 || NSLocationInRange(editedRange.location, $0) }) {
            highlight(storage)
            return
        }
        // Lines of the edit plus one line before and after (setext headings, tables)
        var region = text.lineRange(for: NSRange(location: min(editedRange.location, text.length), length: editedRange.length))
        if region.location > 0 {
            region = NSUnionRange(region, text.lineRange(for: NSRange(location: region.location - 1, length: 0)))
        }
        if NSMaxRange(region) < text.length {
            region = NSUnionRange(region, text.lineRange(for: NSRange(location: NSMaxRange(region), length: 0)))
        }
        // Shift stored ranges after the edit
        let delta = (replacement as NSString).length - (replaced as NSString).length
        multilineRanges = oldMultiline.map { r in
            r.location >= editedRange.location ? NSRange(location: r.location + delta, length: r.length) : r
        }
        noSpellRanges = noSpellRanges.compactMap { r in
            if NSIntersectionRange(r, region).length > 0 { return nil }
            return r.location >= editedRange.location ? NSRange(location: r.location + delta, length: r.length) : r
        }
        apply(storage, in: region, partial: true)
    }

    private func computeMultilineRanges(_ string: String) {
        let full = NSRange(location: 0, length: (string as NSString).length)
        var ranges: [NSRange] = []
        if let fm = Self.frontMatter.firstMatch(in: string, range: full) { ranges.append(fm.range) }
        ranges += Self.fence.matches(in: string, range: full).map(\.range)
        ranges += Self.mathBlock.matches(in: string, range: full).map(\.range)
        multilineRanges = ranges
    }

    private func apply(_ storage: NSTextStorage, in region: NSRange, partial: Bool = false) {
        guard region.length > 0 else { return }
        let string = storage.string
        let text = string as NSString

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: region)

        let markupColor = NSColor.tertiaryLabelColor
        let accent = NSColor.controlAccentColor
        let codeBackground = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        var protected: [NSRange] = []
        var noSpell: [NSRange] = partial ? noSpellRanges : []

        func isProtected(_ r: NSRange) -> Bool {
            protected.contains { NSIntersectionRange($0, r).length > 0 }
        }
        func matches(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
            regex.matches(in: string, range: region).filter { !isProtected($0.range) }
        }

        // Multi-line constructs (computed over the whole text, applied where they intersect the region)
        for r in multilineRanges where NSIntersectionRange(r, region).length > 0 || (r.location == region.location) {
            let clipped = NSIntersectionRange(r, region)
            guard clipped.length > 0 else { continue }
            let isFrontMatter = r.location == 0 && text.substring(with: NSRange(location: 0, length: min(3, text.length))) == "---"
            let isMath = text.substring(with: NSRange(location: r.location, length: min(r.length, 8)))
                .trimmingCharacters(in: .whitespaces).hasPrefix("$$")
            if isFrontMatter {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: clipped)
            } else if isMath {
                storage.addAttributes([.foregroundColor: NSColor.systemPurple, .backgroundColor: codeBackground], range: clipped)
            } else {
                storage.addAttributes([.foregroundColor: NSColor.systemBrown, .backgroundColor: codeBackground], range: clipped)
            }
            protected.append(r)
            noSpell.append(r)
        }

        for m in matches(Self.heading) {
            let level = m.range(at: 1).length
            storage.addAttributes([.font: headingFonts[level - 1], .foregroundColor: NSColor.labelColor], range: m.range)
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
        }
        for m in matches(Self.setext) {
            let level = text.substring(with: m.range(at: 1)).hasPrefix("=") ? 0 : 1
            storage.addAttribute(.font, value: headingFonts[level], range: m.range)
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
        }
        for m in matches(Self.quote) {
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: italicFont], range: m.range)
        }
        for m in matches(Self.hr) {
            storage.addAttribute(.foregroundColor, value: markupColor, range: m.range)
        }
        for m in matches(Self.listMarker) {
            storage.addAttribute(.foregroundColor, value: accent, range: m.range)
        }
        for m in matches(Self.tablePipe) {
            let line = text.substring(with: m.range) as NSString
            let isDelimiter = line.range(of: #"^[\s|:\-]+$"#, options: .regularExpression).location != NSNotFound
            for idx in 0..<line.length {
                let ch = line.character(at: idx)
                if ch == 0x7C || (isDelimiter && (ch == 0x2D || ch == 0x3A)) {
                    storage.addAttribute(.foregroundColor, value: markupColor, range: NSRange(location: m.range.location + idx, length: 1))
                }
            }
        }

        // Inline styles
        let fm = NSFontManager.shared
        func applyTrait(_ regex: NSRegularExpression, transform: (NSFont) -> NSFont) {
            for m in matches(regex) {
                storage.enumerateAttribute(.font, in: m.range) { value, range, _ in
                    storage.addAttribute(.font, value: transform((value as? NSFont) ?? baseFont), range: range)
                }
                let marker = m.range(at: 1)
                storage.addAttribute(.foregroundColor, value: markupColor, range: NSRange(location: m.range.location, length: marker.length))
                storage.addAttribute(.foregroundColor, value: markupColor,
                                     range: NSRange(location: NSMaxRange(m.range) - marker.length, length: marker.length))
            }
        }
        applyTrait(Self.boldItalic) { fm.convert(fm.convert($0, toHaveTrait: .boldFontMask), toHaveTrait: .italicFontMask) }
        applyTrait(Self.bold) { fm.convert($0, toHaveTrait: .boldFontMask) }
        applyTrait(Self.italic) { fm.convert($0, toHaveTrait: .italicFontMask) }

        for m in matches(Self.strike) {
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .foregroundColor: NSColor.secondaryLabelColor], range: m.range)
        }
        for m in matches(Self.link) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range)
        }
        for m in matches(Self.linkTarget) {
            noSpell.append(m.range(at: 1))
        }
        for m in matches(Self.autolink) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range)
            noSpell.append(m.range)
        }
        for m in matches(Self.footnote) {
            storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: m.range)
            noSpell.append(m.range)
        }
        for m in matches(Self.inlineMath) {
            storage.addAttributes([.foregroundColor: NSColor.systemPurple, .font: baseFont], range: m.range)
            noSpell.append(m.range)
        }
        for m in matches(Self.inlineCode) {
            storage.addAttributes([.foregroundColor: NSColor.systemPink, .backgroundColor: codeBackground,
                                   .font: baseFont], range: m.range)
            noSpell.append(m.range)
        }

        storage.endEditing()
        noSpellRanges = noSpell
    }
}
