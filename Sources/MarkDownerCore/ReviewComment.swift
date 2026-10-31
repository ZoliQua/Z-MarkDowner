import Foundation

/// An edit proposed by a review comment, phrased against text that must be found in the source.
public enum Suggestion: Codable, Equatable {
    case replace(target: String, with: String)
    /// `text` already carries the space that separates it from `target`.
    case insertAfter(target: String, text: String)
    /// `text` already carries the space that separates it from `target`.
    case insertBefore(target: String, text: String)
    case delete(target: String)
}

/// Where a review comment stands in the user's work on it.
public enum ReviewStatus: String, Codable {
    case open, applied, done, rejected
}

/// The PDF annotation subtype a review comment came from.
public enum AnnotationKind: String, Codable {
    case highlight, underline, squiggly, strikeOut, caret, note, freeText
}

/// One reviewer comment read from a PDF annotation, with the text it marks and the edit it asks for.
public struct ReviewComment: Codable, Equatable, Identifiable {
    /// `"p<page>-<index>"`, the index counting the page's comments in reading order from 0.
    public var id: String
    /// Zero-based page index.
    public var page: Int
    public var author: String
    public var date: Date?
    public var kind: AnnotationKind
    /// The words under the annotation, cleaned like imported PDF text; empty for notes and carets.
    public var quotedText: String
    /// Up to 60 characters of page text before the quote (or the caret).
    public var contextBefore: String
    /// Up to 60 characters of page text after the quote (or the caret).
    public var contextAfter: String
    public var comment: String
    public var replies: [String]
    public var suggestion: Suggestion?
    public var suggestionIsAI: Bool
    public var status: ReviewStatus
    /// The user's answer to the reviewer.
    public var reply: String

    public init(id: String, page: Int, author: String = "", date: Date? = nil, kind: AnnotationKind,
                quotedText: String = "", contextBefore: String = "", contextAfter: String = "", comment: String = "",
                replies: [String] = [], suggestion: Suggestion? = nil, suggestionIsAI: Bool = false,
                status: ReviewStatus = .open, reply: String = "") {
        self.id = id
        self.page = page
        self.author = author
        self.date = date
        self.kind = kind
        self.quotedText = quotedText
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.comment = comment
        self.replies = replies
        self.suggestion = suggestion
        self.suggestionIsAI = suggestionIsAI
        self.status = status
        self.reply = reply
    }
}

extension ReviewComment {
    private enum CodingKeys: String, CodingKey {
        case id, page, author, date, kind, quotedText, contextBefore, contextAfter, comment, replies
        case suggestion, suggestionIsAI, status, reply
    }

    /// Decodes tolerantly: only `id` is required, so sidecars written by older or newer versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  page: try c.decodeIfPresent(Int.self, forKey: .page) ?? 0,
                  author: try c.decodeIfPresent(String.self, forKey: .author) ?? "",
                  date: try c.decodeIfPresent(Date.self, forKey: .date),
                  kind: try c.decodeIfPresent(AnnotationKind.self, forKey: .kind) ?? .highlight,
                  quotedText: try c.decodeIfPresent(String.self, forKey: .quotedText) ?? "",
                  contextBefore: try c.decodeIfPresent(String.self, forKey: .contextBefore) ?? "",
                  contextAfter: try c.decodeIfPresent(String.self, forKey: .contextAfter) ?? "",
                  comment: try c.decodeIfPresent(String.self, forKey: .comment) ?? "",
                  replies: try c.decodeIfPresent([String].self, forKey: .replies) ?? [],
                  suggestion: try c.decodeIfPresent(Suggestion.self, forKey: .suggestion),
                  suggestionIsAI: try c.decodeIfPresent(Bool.self, forKey: .suggestionIsAI) ?? false,
                  status: try c.decodeIfPresent(ReviewStatus.self, forKey: .status) ?? .open,
                  reply: try c.decodeIfPresent(String.self, forKey: .reply) ?? "")
    }
}
