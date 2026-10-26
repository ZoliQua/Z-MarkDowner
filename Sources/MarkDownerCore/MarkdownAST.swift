import Foundation

/// Block-level Markdown node.
public indirect enum MDBlock: Equatable {
    case heading(level: Int, content: [MDInline])
    case paragraph([MDInline])
    case codeBlock(language: String, code: String)
    case blockquote([MDBlock])
    case list(MDList)
    case table(MDTable)
    case horizontalRule
    /// Display math (`$$ … $$` or a ```math fence), TeX source.
    case mathBlock(String)
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
            if case .heading(let level, let content) = block {
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
            }
        }.joined()
    }
}
