import AppKit

/// Applies Markdown syntax highlighting to the editor's text storage.
final class MarkdownHighlighter {

    var fontSize: CGFloat {
        didSet { makeFonts() }
    }

    private(set) var baseFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    private var boldFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .bold)
    private var italicFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    private var boldItalicFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .bold)
    private var headingFonts: [NSFont] = []

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        makeFonts()
    }

    private func makeFonts() {
        baseFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = .monospacedSystemFont(ofSize: fontSize, weight: .bold)
        italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        boldItalicFont = NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
        let scales: [CGFloat] = [1.45, 1.3, 1.15, 1.05, 1.0, 1.0]
        headingFonts = scales.map { .monospacedSystemFont(ofSize: (fontSize * $0).rounded(), weight: .bold) }
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

    private static let fence = re(#"^ {0,3}(```|~~~)[^\n]*\n[\s\S]*?(?:^ {0,3}\1[ \t]*$|\z)"#)
    private static let heading = re(#"^ {0,3}(#{1,6})[ \t]+.*$"#)
    private static let setext = re(#"^(?!\s*$)(?![-*+>#]).+\n {0,3}(=+|-+)[ \t]*$"#)
    private static let quote = re(#"^ {0,3}>.*$"#)
    private static let listMarker = re(#"^[ \t]*([-*+]|\d{1,9}[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    private static let hr = re(#"^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let boldItalic = re(#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    private static let bold = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = re(#"(?<![*\w])(\*|_)(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*\w])"#)
    private static let strike = re(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let inlineCode = re(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let link = re(#"!?\[[^\]\n]*\]\([^)\n]*\)"#)
    private static let autolink = re(#"<[a-zA-Z][a-zA-Z0-9+.\-]*:[^>\s]+>|\bhttps?://[^\s<>()]+"#)
    private static let tablePipe = re(#"^\s*\|.*\|\s*$"#)

    // MARK: Highlighting

    func highlight(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        let markupColor = NSColor.tertiaryLabelColor
        let accent = NSColor.controlAccentColor
        let codeBackground = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        var protected: [NSRange] = []

        func isProtected(_ r: NSRange) -> Bool {
            protected.contains { NSIntersectionRange($0, r).length > 0 }
        }

        // Fenced code blocks (nothing else applies inside them)
        for m in Self.fence.matches(in: storage.string, range: full) {
            storage.addAttributes([.foregroundColor: NSColor.systemBrown, .backgroundColor: codeBackground], range: m.range)
            protected.append(m.range)
        }

        for m in Self.heading.matches(in: storage.string, range: full) where !isProtected(m.range) {
            let level = m.range(at: 1).length
            storage.addAttributes([.font: headingFonts[level - 1], .foregroundColor: NSColor.labelColor], range: m.range)
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
        }
        for m in Self.setext.matches(in: storage.string, range: full) where !isProtected(m.range) {
            let level = text.substring(with: m.range(at: 1)).hasPrefix("=") ? 0 : 1
            storage.addAttribute(.font, value: headingFonts[level], range: m.range)
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
        }
        for m in Self.quote.matches(in: storage.string, range: full) where !isProtected(m.range) {
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: italicFont], range: m.range)
        }
        for m in Self.hr.matches(in: storage.string, range: full) where !isProtected(m.range) {
            storage.addAttribute(.foregroundColor, value: markupColor, range: m.range)
        }
        for m in Self.listMarker.matches(in: storage.string, range: full) where !isProtected(m.range) {
            storage.addAttribute(.foregroundColor, value: accent, range: m.range)
        }
        for m in Self.tablePipe.matches(in: storage.string, range: full) where !isProtected(m.range) {
            let line = text.substring(with: m.range) as NSString
            var idx = 0
            while idx < line.length {
                let ch = line.character(at: idx)
                if ch == 0x7C /* | */ || (ch == 0x2D /* - */ && line.range(of: #"^[\s|:\-]+$"#, options: .regularExpression).location != NSNotFound) {
                    storage.addAttribute(.foregroundColor, value: markupColor, range: NSRange(location: m.range.location + idx, length: 1))
                }
                idx += 1
            }
        }

        // Inline styles
        func applyFontTrait(_ regex: NSRegularExpression, markerGroup: Int, transform: (NSFont) -> NSFont) {
            for m in regex.matches(in: storage.string, range: full) where !isProtected(m.range) {
                storage.enumerateAttribute(.font, in: m.range) { value, range, _ in
                    let current = (value as? NSFont) ?? baseFont
                    storage.addAttribute(.font, value: transform(current), range: range)
                }
                let marker = m.range(at: markerGroup)
                storage.addAttribute(.foregroundColor, value: markupColor, range: NSRange(location: m.range.location, length: marker.length))
                storage.addAttribute(.foregroundColor, value: markupColor,
                                     range: NSRange(location: NSMaxRange(m.range) - marker.length, length: marker.length))
            }
        }
        let fm = NSFontManager.shared
        applyFontTrait(Self.boldItalic, markerGroup: 1) { fm.convert(fm.convert($0, toHaveTrait: .boldFontMask), toHaveTrait: .italicFontMask) }
        applyFontTrait(Self.bold, markerGroup: 1) { fm.convert($0, toHaveTrait: .boldFontMask) }
        applyFontTrait(Self.italic, markerGroup: 1) { fm.convert($0, toHaveTrait: .italicFontMask) }

        for m in Self.strike.matches(in: storage.string, range: full) where !isProtected(m.range) {
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .foregroundColor: NSColor.secondaryLabelColor], range: m.range)
        }
        for m in Self.link.matches(in: storage.string, range: full) where !isProtected(m.range) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range)
        }
        for m in Self.autolink.matches(in: storage.string, range: full) where !isProtected(m.range) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range)
        }
        for m in Self.inlineCode.matches(in: storage.string, range: full) where !isProtected(m.range) {
            storage.addAttributes([.foregroundColor: NSColor.systemPink, .backgroundColor: codeBackground,
                                   .font: baseFont], range: m.range)
        }

        storage.endEditing()
    }
}
