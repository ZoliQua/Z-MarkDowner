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
}

public struct MDDocument: Equatable {
    public var blocks: [MDBlock]

    public init(blocks: [MDBlock]) {
        self.blocks = blocks
    }

    public init(markdown: String) {
        self.blocks = MarkdownParser.parseBlocks(markdown)
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
            }
        }.joined()
    }
}
