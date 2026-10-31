import Foundation

/// Counts for the prose of a Markdown document (code, formulas, URLs and front matter are left out).
public struct TextStatistics: Equatable {
    public var words = 0
    public var characters = 0
    public var charactersWithoutSpaces = 0
    public var sentences = 0
    public var paragraphs = 0
    public var headings = 0

    /// Average silent reading speed (words per minute).
    public static let readingSpeed = 230.0
    /// Average speaking speed for presentations (words per minute).
    public static let speakingSpeed = 130.0

    public var readingMinutes: Double { Double(words) / Self.readingSpeed }
    public var speakingMinutes: Double { Double(words) / Self.speakingSpeed }
    public var averageSentenceLength: Double { sentences > 0 ? Double(words) / Double(sentences) : 0 }

    public init() {}

    public init(markdown: String) {
        self.init(document: MDDocument(markdown: markdown))
    }

    public init(document: MDDocument) {
        var texts: [String] = []
        var stats = TextStatistics()
        func visit(_ blocks: [MDBlock]) {
            for block in blocks {
                switch block {
                case .heading(_, let content, _):
                    stats.headings += 1
                    texts.append(Self.prose(content))
                case .paragraph(let content):
                    stats.paragraphs += 1
                    texts.append(Self.prose(content))
                case .blockquote(let inner):
                    visit(inner)
                case .list(let list):
                    list.items.forEach { visit($0.blocks) }
                case .table(let table):
                    for cell in table.header + table.rows.flatMap({ $0 }) { texts.append(Self.prose(cell)) }
                case .figure(let figure):
                    texts.append(Self.prose(figure.caption))
                    if case .table = figure.content { visit([figure.content]) }
                case .codeBlock, .mathBlock, .horizontalRule, .tableOfContents, .bibliography:
                    break
                }
            }
        }
        visit(document.blocks)
        for note in document.footnotes { visit(note.blocks) }
        if let title = document.frontMatter["title"] { texts.append(title) }

        for text in texts where !text.isEmpty {
            text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
                stats.words += 1
            }
            text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
                if !text[range].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { stats.sentences += 1 }
            }
            stats.characters += text.count
            stats.charactersWithoutSpaces += text.filter { !$0.isWhitespace }.count
        }
        self = stats
    }

    /// Visible text of inline content (links count by their text, deletions and comments not at all).
    static func prose(_ inlines: [MDInline]) -> String {
        inlines.map { node -> String in
            switch node {
            case .text(let s): return s
            case .code(let s): return s
            case .emphasis(let c), .strong(let c), .strikethrough(let c), .insertion(let c), .highlight(let c): return prose(c)
            case .link(let t, _, _): return prose(t)
            case .image, .math, .footnoteRef, .deletion, .comment: return ""
            case .citation(let c): return c.inText ? c.items.map(\.key).joined(separator: " ") : ""
            case .lineBreak: return "\n"
            case .softBreak: return " "
            }
        }.joined()
    }
}
