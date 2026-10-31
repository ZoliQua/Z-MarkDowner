import Foundation

/// Block-level Markdown node.
public indirect enum MDBlock: Equatable {
    /// `id` is an explicit anchor (`# Title {#sec:intro}`) or one assigned by `DocumentProcessor`.
    case heading(level: Int, content: [MDInline], id: String? = nil)
    case paragraph([MDInline])
    case codeBlock(language: String, code: String)
    case blockquote([MDBlock])
    case list(MDList)
    case table(MDTable)
    case horizontalRule
    /// Display math (`$$ … $$` or a ```math fence), TeX source.
    case mathBlock(String)
    /// A captioned figure, table or equation (`{#fig:…}`, `{#tbl:…}`, `{#eq:…}`).
    case figure(MDFigure)
    /// Table of contents (`[TOC]` or `toc: true`); entries are filled in by `DocumentProcessor`.
    case tableOfContents(title: String, entries: [MDTocEntry])
    /// Formatted reference list, produced by `DocumentProcessor` from citations.
    case bibliography([MDBibItem])
}

public struct MDFigure: Equatable {
    public enum Kind: String, Equatable { case figure, table, equation }
    public var kind: Kind
    /// Label without `#`, e.g. `fig:overview`.
    public var id: String?
    public var caption: [MDInline]
    /// The image paragraph, table or math block.
    public var content: MDBlock
    /// Number assigned by `DocumentProcessor` ("1", "2"…).
    public var number: String?
    /// Localized caption prefix such as "Figure 1" (set by `DocumentProcessor`).
    public var label: String?

    public init(kind: Kind, id: String?, caption: [MDInline], content: MDBlock, number: String? = nil, label: String? = nil) {
        self.kind = kind
        self.id = id
        self.caption = caption
        self.content = content
        self.number = number
        self.label = label
    }
}

public struct MDTocEntry: Equatable {
    public var level: Int
    public var text: String
    public var anchor: String

    public init(level: Int, text: String, anchor: String) {
        self.level = level
        self.text = text
        self.anchor = anchor
    }
}

public struct MDBibItem: Equatable {
    /// Anchor of the entry (`ref-<key>`).
    public var anchor: String
    /// "[1]" / "1." for numeric styles, nil for author–date styles.
    public var label: String?
    public var content: [MDInline]

    public init(anchor: String, label: String?, content: [MDInline]) {
        self.anchor = anchor
        self.label = label
        self.content = content
    }
}

/// One cited source inside `[see @key, p. 3; @other]`.
public struct MDCitationItem: Equatable {
    public var key: String
    public var prefix: String
    /// Text after the key, e.g. "p. 33".
    public var locator: String
    /// `[-@key]`: only the year (author–date styles).
    public var suppressAuthor: Bool

    public init(key: String, prefix: String = "", locator: String = "", suppressAuthor: Bool = false) {
        self.key = key
        self.prefix = prefix
        self.locator = locator
        self.suppressAuthor = suppressAuthor
    }

    /// Cross-reference labels (`@fig:x`, `@tbl:x`, `@eq:x`, `@sec:x`) rather than bibliography keys.
    public var isCrossReference: Bool {
        ["fig:", "tbl:", "eq:", "sec:"].contains { key.hasPrefix($0) }
    }
}

public struct MDCitation: Equatable {
    public var items: [MDCitationItem]
    /// `@key` written in running text (author-in-text form) instead of `[@key]`.
    public var inText: Bool
    /// The original source text, shown when nothing can be resolved.
    public var raw: String

    public init(items: [MDCitationItem], inText: Bool, raw: String) {
        self.items = items
        self.inText = inText
        self.raw = raw
    }
}

public struct MDList: Equatable {
    public var ordered: Bool
    public var start: Int
    public var tight: Bool
    public var items: [MDListItem]
}

public struct MDListItem: Equatable {
    /// nil for normal items, true/false for task list items.
    public var checked: Bool?
    public var blocks: [MDBlock]
}

public enum MDAlignment: Equatable {
    case none, left, center, right
}

public struct MDTable: Equatable {
    public var header: [[MDInline]]
    public var alignments: [MDAlignment]
    public var rows: [[[MDInline]]]
}

/// Inline-level Markdown node.
public indirect enum MDInline: Equatable {
    case text(String)
    case emphasis([MDInline])
    case strong([MDInline])
    case strikethrough([MDInline])
    case code(String)
    case link(text: [MDInline], url: String, title: String?)
    case image(alt: String, url: String, title: String?)
    case lineBreak
    case softBreak
    /// Reference to a footnote (`[^id]`).
    case footnoteRef(String)
    /// Inline math (`$ … $`), TeX source.
    case math(String)
    /// Citation or cross-reference (`[@key]`, `@key`, `@fig:x`).
    case citation(MDCitation)
    /// CriticMarkup review marks: `{++ … ++}`, `{-- … --}`, `{== … ==}`, `{>> … <<}`.
    case insertion([MDInline])
    case deletion([MDInline])
    case highlight([MDInline])
    case comment(String)
}

public struct MDFootnote: Equatable {
    public var id: String
    public var blocks: [MDBlock]
}

public struct MDDocument: Equatable {
    public var blocks: [MDBlock]
    /// 0-based source line of each top-level block (parallel to `blocks`).
    public var blockLines: [Int]
    public var footnotes: [MDFootnote]
    /// Simple `key: value` pairs from a YAML front matter block.
    public var frontMatter: [String: String]

    public init(blocks: [MDBlock], blockLines: [Int] = [], footnotes: [MDFootnote] = [], frontMatter: [String: String] = [:]) {
        self.blocks = blocks
        self.blockLines = blockLines
        self.footnotes = footnotes
        self.frontMatter = frontMatter
    }

    public init(markdown: String) {
        self = MarkdownParser.parseDocument(markdown)
    }

    public var title: String? { frontMatter["title"].flatMap { $0.isEmpty ? nil : $0 } }

    /// Headings of the document with their source lines (for outlines).
    public var outline: [(level: Int, text: String, line: Int)] {
        var result: [(Int, String, Int)] = []
        for (index, block) in blocks.enumerated() {
            if case .heading(let level, let content, _) = block {
                result.append((level, content.plainText, index < blockLines.count ? blockLines[index] : 0))
            }
        }
        return result
    }
}

extension Array where Element == MDInline {
    /// Plain text content without formatting.
    public var plainText: String {
        map { node -> String in
            switch node {
            case .text(let s), .code(let s): return s
            case .emphasis(let c), .strong(let c), .strikethrough(let c): return c.plainText
            case .link(let t, _, _): return t.plainText
            case .image(let alt, _, _): return alt
            case .lineBreak: return "\n"
            case .softBreak: return " "
            case .footnoteRef: return ""
            case .math(let tex): return tex
            case .citation(let c): return c.raw
            case .insertion(let c), .highlight(let c): return c.plainText
            case .deletion, .comment: return ""
            }
        }.joined()
    }
}
