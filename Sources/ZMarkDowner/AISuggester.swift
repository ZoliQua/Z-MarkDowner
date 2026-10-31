import Foundation
import MarkDownerCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Why the on-device model gave no proposal for a comment.
enum AISuggesterError: LocalizedError {
    case unavailable
    case guardrail
    case contextTooLong
    case unsupportedLanguage
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return L("ai.error.unavailable", "Apple Intelligence is not available.")
        case .guardrail:
            return L("ai.error.guardrail", "Apple Intelligence declined to process this comment.")
        case .contextTooLong:
            return L("ai.error.tooLong", "The comment and its sentence are too long for the on-device model.")
        case .unsupportedLanguage:
            return L("ai.error.language", "The on-device model does not support the language of this comment.")
        case .failed(let message):
            return message
        }
    }
}

/// Edit proposals for free-form review comments from Apple's on-device language model
/// (FoundationModels, macOS 26 with Apple Intelligence). Proposals are validated against the sentence
/// (`ReviewInstructionParser.validateAI`) and only ever shown as suggestions; nothing is applied here.
/// On systems without the framework or the model the feature does not exist.
enum AISuggester {
    static let instructions = "You edit scientific manuscripts. Return the smallest edit that implements the reviewer comment, or action none."

    /// Whether the on-device model can be used now.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Whether the AI commands are offered: the model is available and the user has not turned them off.
    static var isEnabled: Bool { isAvailable && Settings.shared.aiSuggestions }

    /// The edit the model proposes for `comment` in `sentence` (the source sentence around its anchor),
    /// or nil when it proposes none or an invalid one.
    static func suggest(for comment: ReviewComment, sentence: String) async throws -> Suggestion? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), SystemLanguageModel.default.availability == .available {
            let proposal = try await ModelProposer.propose(comment: comment.comment, quoted: comment.quotedText, sentence: sentence)
            return ReviewInstructionParser.validateAI(action: proposal.action, target: proposal.target,
                                                      text: proposal.text, sentence: sentence)
        }
        #endif
        throw AISuggesterError.unavailable
    }
}

#if canImport(FoundationModels)
/// The structured answer the model generates.
@available(macOS 26, *)
@Generable
struct EditProposal {
    @Guide(description: "The kind of edit; none when the comment asks for no concrete change of the text.",
           .anyOf(["replace", "insertAfter", "insertBefore", "delete", "none"]))
    var action: String
    @Guide(description: "Words copied exactly, with the same letters and case, from the marked text (or else the sentence); the text to replace, delete, or insert next to.")
    var target: String
    @Guide(description: "The new text: the replacement, or the words to insert. Empty for delete and none.")
    var text: String
}

/// One request to the on-device model, in a fresh session so earlier comments never fill its context.
@available(macOS 26, *)
private enum ModelProposer {
    static func propose(comment: String, quoted: String, sentence: String) async throws -> EditProposal {
        let session = LanguageModelSession(instructions: AISuggester.instructions)
        let prompt = """
        Reviewer comment: \(comment)
        Marked text: "\(quoted)"
        Sentence: "\(sentence)"
        """
        do {
            return try await session.respond(to: prompt, generating: EditProposal.self,
                                             options: GenerationOptions(sampling: .greedy)).content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: throw AISuggesterError.guardrail
            case .exceededContextWindowSize: throw AISuggesterError.contextTooLong
            case .unsupportedLanguageOrLocale: throw AISuggesterError.unsupportedLanguage
            case .assetsUnavailable: throw AISuggesterError.unavailable
            default: throw AISuggesterError.failed(error.localizedDescription)
            }
        }
    }
}
#endif
