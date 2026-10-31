import AppKit
import MarkDownerCore

/// Completion of citation keys and cross-reference labels after `@`.
extension EditorTextView {

    /// The partial key after an `@` at the caret, if any.
    var citationKeyRange: NSRange? {
        let caret = selectedRange().location
        let text = nsString
        var start = caret
        while start > 0 {
            guard let scalar = Unicode.Scalar(text.character(at: start - 1)) else { return nil }
            let ch = Character(scalar)
            if ch == "@" {
                // "@" must start a citation, not be part of an e-mail address
                if start - 1 > 0, let prev = Unicode.Scalar(text.character(at: start - 2)),
                   CharacterSet.alphanumerics.contains(prev) { return nil }
                return NSRange(location: start, length: caret - start)
            }
            guard MarkdownParser.isCitationKeyCharacter(ch), caret - start < 80 else { return nil }
            start -= 1
        }
        return nil
    }

    override var rangeForUserCompletion: NSRange {
        citationKeyRange ?? super.rangeForUserCompletion
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard let keyRange = citationKeyRange, NSEqualRanges(keyRange, charRange) || keyRange.location == charRange.location else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
        let partial = nsString.substring(with: charRange).lowercased()
        let candidates = citationCandidates?() ?? []
        let matches = candidates.filter { partial.isEmpty || $0.lowercased().hasPrefix(partial) }
            + candidates.filter { !partial.isEmpty && !$0.lowercased().hasPrefix(partial) && $0.lowercased().contains(partial) }
        index.pointee = matches.isEmpty ? -1 : 0
        return matches
    }

    /// Opens the completion list right after an `@` is typed at the start of a citation.
    func triggerCitationCompletionIfNeeded(after typed: String) {
        guard typed == "@", citationKeyRange != nil, !(citationCandidates?() ?? []).isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.complete(nil) }
    }
}

extension DocumentWindowController {

    /// Bibliography keys and the document's cross-reference labels.
    func citationCandidates() -> [String] {
        guard !isLatex else { return [] }
        let text = editor.string
        var labels: [String] = []
        if let re = try? NSRegularExpression(pattern: #"\{#((?:fig|tbl|eq|sec):[^\s}]+)"#) {
            let ns = text as NSString
            labels = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        }
        let fm = MarkdownParser.frontMatter(of: text)
        var keys: [String] = []
        for url in DocumentProcessor.bibliographyURLs(frontMatter: fm, options: processingOptions) {
            keys += ((try? Bibliography.load(url)) ?? []).map(\.id)
        }
        return labels + keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
