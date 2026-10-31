import AppKit
import MarkDownerCore

extension NSAttributedString.Key {
    /// Markdown markup that live formatting hides outside the line being edited.
    static let zmdHidden = NSAttributedString.Key("zmdHidden")
    /// List bullet drawn as "•" (live formatting).
    static let zmdBullet = NSAttributedString.Key("zmdBullet")
    /// Task list box `[ ]` / `[x]` drawn as a checkbox; the value is true when checked.
    static let zmdCheckbox = NSAttributedString.Key("zmdCheckbox")
    /// Horizontal rule drawn as a line.
    static let zmdRule = NSAttributedString.Key("zmdRule")
    /// Block quote line, drawn with a bar on the left.
    static let zmdQuote = NSAttributedString.Key("zmdQuote")
}

/// Applies Markdown (or LaTeX) syntax highlighting to the editor's text storage.
final class MarkdownHighlighter {

    /// Source language: `.latex` uses the LaTeX rules, anything else the Markdown rules.
    var format: SourceFormat = .markdown

    private(set) var baseFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    private var italicFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    /// Font for code, tables and formulas.
    private var monoFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    private var headingFonts: [NSFont] = []
    private(set) var fontSize: CGFloat = 14
    /// WYSIWYG-like mode: proportional text, large headings, markup marked as hidden.
    var liveFormatting = false

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
        if liveFormatting {
            // Proportional text: the chosen font when it is proportional, otherwise the system font
            let chosen = settings.editorFont(size: fontSize + 1)
            baseFont = chosen.isFixedPitch ? .systemFont(ofSize: fontSize + 1) : chosen
            monoFont = .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
            let scales: [CGFloat] = [1.9, 1.55, 1.3, 1.12, 1.0, 0.95]
            headingFonts = scales.map { scale in
                let size = ((fontSize + 1) * scale).rounded()
                return NSFontManager.shared.convert(baseFont.withSize(size), toHaveTrait: .boldFontMask)
            }
        } else {
            baseFont = settings.editorFont()
            monoFont = baseFont
            let scales: [CGFloat] = [1.45, 1.3, 1.15, 1.05, 1.0, 1.0]
            headingFonts = scales.map { settings.editorFont(size: (fontSize * $0).rounded(), weight: .bold) }
        }
        italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = fontSize * (liveFormatting ? 0.45 : 0.35)
        if liveFormatting { para.paragraphSpacing = fontSize * 0.25 }
        return [.font: baseFont, .foregroundColor: NSColor.textColor, .paragraphStyle: para]
    }

    // MARK: Patterns

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let frontMatter = re(#"\A---[ \t]*\n(?:[\s\S]*?\n)?(?:---|\.\.\.)[ \t]*(?=\n|\z)"#, [])
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
    private static let citation = re(#"\[[^\[\]\n]*-?@[A-Za-z0-9_][^\[\]\n]*\](?![(\[])|(?<![\w.@/\\-])@[A-Za-z0-9_][\w:.#$%&\-+?~/]*[\w]"#)
    private static let attributeBlock = re(#"\{[#.-][^{}\n]*\}[ \t]*$"#)
    private static let criticInsert = re(#"\{\+\+([\s\S]+?)\+\+\}"#)
    private static let criticDelete = re(#"\{--([\s\S]+?)--\}"#)
    private static let criticHighlight = re(#"\{==([\s\S]+?)==\}"#)
    private static let criticComment = re(#"\{>>([\s\S]*?)<<\}"#)
    private static let criticSubstitute = re(#"\{~~([\s\S]+?)~>([\s\S]*?)~~\}"#)
    private static let taskBox = re(#"^[ \t]*[-*+][ \t]+(\[[ xX]\])(?=[ \t])"#)
    private static let bulletMarker = re(#"^[ \t]*([-*+])[ \t]+"#)
    private static let quoteMarker = re(#"^ {0,3}(>[ \t]?)+"#)
    private static let headingMarker = re(#"^ {0,3}(#{1,6}[ \t]+)"#)
    private static let footnoteRef = re(#"\[\^([^\]\s]+)\](?!:)"#)
    private static let autolinkBrackets = re(#"<([a-zA-Z][a-zA-Z0-9+.\-]*:[^>\s]+)>"#)

    private static let latexComment = re(#"(?<!\\)%.*$"#)
    private static let latexMath = re(#"\$\$[\s\S]*?\$\$|(?<!\\)\$(?:[^$\\]|\\[\s\S])+?\$|\\\([\s\S]*?\\\)|\\\[[\s\S]*?\\\]"#, [])
    private static let latexCommand = re(#"\\(?:[A-Za-z@]+\*?|.)"#, [])
    private static let latexBrace = re(#"[{}\[\]]"#, [])
    private static let latexHeading = re(#"\\(?:part|chapter|section|subsection|subsubsection)\*?\{[^}\n]*\}"#, [])

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
        guard format != .latex else {
            multilineRanges = []
            return
        }
        let full = NSRange(location: 0, length: (string as NSString).length)
        var ranges: [NSRange] = []
        if let fm = Self.frontMatter.firstMatch(in: string, range: full) { ranges.append(fm.range) }
        ranges += Self.fence.matches(in: string, range: full).map(\.range)
        ranges += Self.mathBlock.matches(in: string, range: full).map(\.range)
        multilineRanges = ranges
    }

    private func apply(_ storage: NSTextStorage, in region: NSRange, partial: Bool = false) {
        guard region.length > 0 else { return }
        if format == .latex {
            applyLatex(storage, in: region, partial: partial)
            return
        }
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
                storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: monoFont], range: clipped)
            } else if isMath {
                storage.addAttributes([.foregroundColor: NSColor.systemPurple, .backgroundColor: codeBackground, .font: monoFont], range: clipped)
            } else {
                storage.addAttributes([.foregroundColor: NSColor.systemBrown, .backgroundColor: codeBackground, .font: monoFont], range: clipped)
            }
            protected.append(r)
            noSpell.append(r)
        }

        func hide(_ range: NSRange) {
            guard liveFormatting, range.location != NSNotFound, range.length > 0 else { return }
            storage.addAttribute(.zmdHidden, value: true, range: range)
        }

        for m in matches(Self.heading) {
            let level = m.range(at: 1).length
            storage.addAttributes([.font: headingFonts[level - 1], .foregroundColor: NSColor.labelColor], range: m.range)
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
            if liveFormatting, let marker = Self.headingMarker.firstMatch(in: string, range: m.range) {
                hide(marker.range(at: 1))
                let para = (baseAttributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                para.paragraphSpacingBefore = fontSize * (level <= 2 ? 0.9 : 0.5)
                storage.addAttribute(.paragraphStyle, value: para, range: m.range)
            }
        }
        for m in matches(Self.setext) {
            let level = text.substring(with: m.range(at: 1)).hasPrefix("=") ? 0 : 1
            storage.addAttribute(.font, value: headingFonts[level], range: m.range)
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
        }
        for m in matches(Self.quote) {
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: italicFont], range: m.range)
            if liveFormatting, let marker = Self.quoteMarker.firstMatch(in: string, range: m.range) {
                hide(marker.range)
                let depth = text.substring(with: marker.range).filter { $0 == ">" }.count
                let para = (baseAttributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                para.firstLineHeadIndent = CGFloat(depth) * 16
                para.headIndent = CGFloat(depth) * 16
                storage.addAttributes([.zmdQuote: depth, .paragraphStyle: para], range: m.range)
            }
        }
        for m in matches(Self.hr) {
            storage.addAttribute(.foregroundColor, value: markupColor, range: m.range)
            if liveFormatting { storage.addAttribute(.zmdRule, value: true, range: m.range) }
        }
        for m in matches(Self.listMarker) {
            storage.addAttribute(.foregroundColor, value: accent, range: m.range)
        }
        if liveFormatting {
            for m in matches(Self.bulletMarker) {
                storage.addAttribute(.zmdBullet, value: true, range: m.range(at: 1))
            }
            for m in matches(Self.taskBox) {
                let box = m.range(at: 1)
                let checked = text.substring(with: box).lowercased() == "[x]"
                storage.addAttribute(.zmdCheckbox, value: checked, range: box)
                // The bullet in front of a checkbox is not drawn
                storage.removeAttribute(.zmdBullet, range: NSRange(location: m.range.location, length: box.location - m.range.location))
                hide(NSRange(location: m.range.location, length: box.location - m.range.location))
            }
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
            if liveFormatting { storage.addAttribute(.font, value: monoFont, range: m.range) }
        }

        // Inline styles
        let fm = NSFontManager.shared
        func applyTrait(_ regex: NSRegularExpression, transform: (NSFont) -> NSFont) {
            for m in matches(regex) {
                storage.enumerateAttribute(.font, in: m.range) { value, range, _ in
                    storage.addAttribute(.font, value: transform((value as? NSFont) ?? baseFont), range: range)
                }
                let marker = m.range(at: 1)
                let open = NSRange(location: m.range.location, length: marker.length)
                let close = NSRange(location: NSMaxRange(m.range) - marker.length, length: marker.length)
                storage.addAttribute(.foregroundColor, value: markupColor, range: open)
                storage.addAttribute(.foregroundColor, value: markupColor, range: close)
                hide(open)
                hide(close)
            }
        }
        applyTrait(Self.boldItalic) { fm.convert(fm.convert($0, toHaveTrait: .boldFontMask), toHaveTrait: .italicFontMask) }
        applyTrait(Self.bold) { fm.convert($0, toHaveTrait: .boldFontMask) }
        applyTrait(Self.italic) { fm.convert($0, toHaveTrait: .italicFontMask) }

        for m in matches(Self.strike) {
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .foregroundColor: NSColor.secondaryLabelColor], range: m.range)
            hide(NSRange(location: m.range.location, length: 2))
            hide(NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        for m in matches(Self.link) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range)
            // Live formatting shows only the link text: "[" and "](url)" are hidden
            let source = text.substring(with: m.range) as NSString
            let close = source.range(of: "](")
            if liveFormatting, !source.hasPrefix("!"), close.location != NSNotFound, close.location > 1 {
                hide(NSRange(location: m.range.location, length: 1))
                hide(NSRange(location: m.range.location + close.location, length: m.range.length - close.location))
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                     range: NSRange(location: m.range.location + 1, length: close.location - 1))
            }
        }
        for m in matches(Self.linkTarget) {
            noSpell.append(m.range(at: 1))
        }
        for m in matches(Self.autolink) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range)
            noSpell.append(m.range)
        }
        if liveFormatting {
            for m in matches(Self.autolinkBrackets) {
                hide(NSRange(location: m.range.location, length: 1))
                hide(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
            }
        }
        for m in matches(Self.footnote) {
            storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: m.range)
            noSpell.append(m.range)
        }
        if liveFormatting {
            for m in matches(Self.footnoteRef) {
                hide(NSRange(location: m.range.location, length: 2))
                hide(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
                storage.addAttributes([.font: baseFont.withSize(fontSize * 0.75), .baselineOffset: fontSize * 0.35],
                                      range: m.range(at: 1))
            }
        }
        for m in matches(Self.citation) {
            storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: m.range)
            noSpell.append(m.range)
        }
        for m in matches(Self.attributeBlock) {
            storage.addAttribute(.foregroundColor, value: markupColor, range: m.range)
            noSpell.append(m.range)
        }

        // CriticMarkup (review marks)
        let insertColor = NSColor.systemGreen
        let deleteColor = NSColor.systemRed
        func critic(_ regex: NSRegularExpression, _ attributes: [NSAttributedString.Key: Any], content: Int = 1) {
            for m in matches(regex) {
                storage.addAttributes(attributes, range: m.range(at: content))
                let open = NSRange(location: m.range.location, length: 3)
                let close = NSRange(location: NSMaxRange(m.range) - 3, length: 3)
                storage.addAttribute(.foregroundColor, value: markupColor, range: open)
                storage.addAttribute(.foregroundColor, value: markupColor, range: close)
                hide(open)
                hide(close)
            }
        }
        critic(Self.criticInsert, [.foregroundColor: insertColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .backgroundColor: insertColor.withAlphaComponent(0.12)])
        critic(Self.criticDelete, [.foregroundColor: deleteColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .backgroundColor: deleteColor.withAlphaComponent(0.1)])
        critic(Self.criticHighlight, [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35)])
        critic(Self.criticComment, [.foregroundColor: NSColor.systemBlue, .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.1),
                                    .font: baseFont.withSize(fontSize * 0.85)])
        for m in matches(Self.criticSubstitute) {
            storage.addAttributes([.foregroundColor: deleteColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: m.range(at: 1))
            storage.addAttributes([.foregroundColor: insertColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: m.range(at: 2))
            hide(NSRange(location: m.range.location, length: 3))
            hide(NSRange(location: NSMaxRange(m.range(at: 1)), length: 2))
            hide(NSRange(location: NSMaxRange(m.range) - 3, length: 3))
        }

        for m in matches(Self.inlineMath) {
            storage.addAttributes([.foregroundColor: NSColor.systemPurple, .font: monoFont], range: m.range)
            noSpell.append(m.range)
        }
        for m in matches(Self.inlineCode) {
            storage.addAttributes([.foregroundColor: NSColor.systemPink, .backgroundColor: codeBackground,
                                   .font: monoFont], range: m.range)
            let ticks = m.range(at: 1).length
            hide(NSRange(location: m.range.location, length: ticks))
            hide(NSRange(location: NSMaxRange(m.range) - ticks, length: ticks))
            noSpell.append(m.range)
        }

        storage.endEditing()
        noSpellRanges = noSpell
    }

    /// LaTeX: `%` comments, math, `\commands`, braces and sectioning headings; commands and math are
    /// not spell checked.
    private func applyLatex(_ storage: NSTextStorage, in region: NSRange, partial: Bool) {
        let string = storage.string
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: region)
        var protected: [NSRange] = []
        var noSpell: [NSRange] = partial ? noSpellRanges : []
        func matches(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
            regex.matches(in: string, range: region).filter { m in
                !protected.contains { NSIntersectionRange($0, m.range).length > 0 }
            }
        }
        let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        for m in matches(Self.latexHeading) {
            storage.addAttribute(.font, value: bold, range: m.range)
        }
        for m in matches(Self.latexComment) {
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: italicFont], range: m.range)
            protected.append(m.range)
        }
        for m in matches(Self.latexMath) {
            storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: m.range)
            protected.append(m.range)
            noSpell.append(m.range)
        }
        for m in matches(Self.latexCommand) {
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: m.range)
            noSpell.append(m.range)
        }
        for m in matches(Self.latexBrace) {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: m.range)
        }
        storage.endEditing()
        noSpellRanges = noSpell
    }
}
