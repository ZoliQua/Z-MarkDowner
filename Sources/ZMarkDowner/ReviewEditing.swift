import AppKit
import MarkDownerCore

/// Review commands for CriticMarkup marks (tracked changes and comments imported from Word or typed by hand).
extension EditorTextView {

    private static let criticPattern = try! NSRegularExpression(pattern:
        #"\{\+\+([\s\S]*?)\+\+\}|\{--([\s\S]*?)--\}|\{~~([\s\S]*?)~>([\s\S]*?)~~\}|\{==([\s\S]*?)==\}|\{>>([\s\S]*?)<<\}"#)

    private enum Mark { case insertion, deletion, substitution, highlight, comment }

    private func kind(_ m: NSTextCheckingResult) -> Mark {
        if m.range(at: 1).location != NSNotFound { return .insertion }
        if m.range(at: 2).location != NSNotFound { return .deletion }
        if m.range(at: 3).location != NSNotFound { return .substitution }
        if m.range(at: 5).location != NSNotFound { return .highlight }
        return .comment
    }

    private func group(_ m: NSTextCheckingResult, _ i: Int) -> String {
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : nsString.substring(with: r)
    }

    /// Text replacing a mark: `accept` = keep insertions, drop deletions; `nil` = remove comments only.
    private func resolution(_ m: NSTextCheckingResult, accept: Bool?) -> String? {
        switch (kind(m), accept) {
        case (.insertion, .some(let a)): return a ? group(m, 1) : ""
        case (.deletion, .some(let a)): return a ? "" : group(m, 2)
        case (.substitution, .some(let a)): return a ? group(m, 4) : group(m, 3)
        case (.highlight, nil): return group(m, 5)
        case (.comment, nil): return ""
        default: return nil
        }
    }

    private var criticMatches: [NSTextCheckingResult] {
        Self.criticPattern.matches(in: string, range: NSRange(location: 0, length: nsString.length))
    }

    /// Applies a resolution to all marks as one undoable edit.
    private func resolveAll(accept: Bool?) {
        let matches = criticMatches.filter { resolution($0, accept: accept) != nil }
        guard let first = matches.first, let last = matches.last else { NSSound.beep(); return }
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var out = ""
        var cursor = span.location
        for m in matches {
            out += nsString.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += resolution(m, accept: accept) ?? ""
            cursor = NSMaxRange(m.range)
        }
        replace(span, with: out, select: NSRange(location: 0, length: 0))
    }

    @objc func acceptAllChanges(_ sender: Any?) { resolveAll(accept: true) }
    @objc func rejectAllChanges(_ sender: Any?) { resolveAll(accept: false) }
    @objc func removeAllComments(_ sender: Any?) { resolveAll(accept: nil) }

    /// The change at (or right after) the caret.
    private func changeAtCaret() -> NSTextCheckingResult? {
        let caret = selectedRange().location
        let changes = criticMatches.filter { [.insertion, .deletion, .substitution].contains(kind($0)) }
        return changes.first { NSLocationInRange(caret, $0.range) || NSMaxRange($0.range) == caret }
            ?? changes.first { $0.range.location >= caret }
    }

    private func resolveAtCaret(accept: Bool) {
        guard let m = changeAtCaret(), let text = resolution(m, accept: accept) else { NSSound.beep(); return }
        replace(m.range, with: text)
        selectNextChange(nil)
    }

    @objc func acceptChange(_ sender: Any?) { resolveAtCaret(accept: true) }
    @objc func rejectChange(_ sender: Any?) { resolveAtCaret(accept: false) }

    @objc func selectNextChange(_ sender: Any?) {
        let caret = NSMaxRange(selectedRange())
        let all = criticMatches
        guard let next = all.first(where: { $0.range.location >= caret }) ?? all.first else {
            if sender != nil { NSSound.beep() }
            return
        }
        setSelectedRange(next.range)
        scrollRangeToVisible(next.range)
    }

    @objc func selectPreviousChange(_ sender: Any?) {
        let caret = selectedRange().location
        let all = criticMatches
        guard let previous = all.last(where: { NSMaxRange($0.range) <= caret }) ?? all.last else { NSSound.beep(); return }
        setSelectedRange(previous.range)
        scrollRangeToVisible(previous.range)
    }

    /// Comments the selection (`{==text==}{>>comment<<}`) or inserts a comment at the caret.
    @objc func insertComment(_ sender: Any?) {
        let sel = selectedRange()
        let placeholder = L("placeholder.comment", "Comment")
        if sel.length > 0 {
            let selected = nsString.substring(with: sel)
            let text = "{==\(selected)==}{>>\(placeholder)<<}"
            let start = (selected as NSString).length + 9
            replace(sel, with: text, select: NSRange(location: start, length: (placeholder as NSString).length))
        } else {
            replace(sel, with: "{>>\(placeholder)<<}", select: NSRange(location: 3, length: (placeholder as NSString).length))
        }
    }

    /// Marks the selection as deleted / the typed text as inserted (manual change tracking).
    @objc func markAsDeletion(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0 else { NSSound.beep(); return }
        let selected = nsString.substring(with: sel)
        replace(sel, with: "{--\(selected)--}")
    }

    @objc func markAsInsertion(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0 else { NSSound.beep(); return }
        let selected = nsString.substring(with: sel)
        replace(sel, with: "{++\(selected)++}")
    }

    // MARK: Scholarly inserts

    @objc func insertTableOfContents(_ sender: Any?) {
        insertBlock("[TOC]")
    }

    @objc func insertReferenceList(_ sender: Any?) {
        insertBlock("::: {#refs}\n:::")
    }

    /// Figure with a numbered caption: `![Caption](image){#fig:label}`.
    @objc func insertFigure(_ sender: Any?) {
        let caption = L("placeholder.caption", "Caption")
        let text = "![\(caption)](images/figure.png){#fig:label}"
        insertBlock(text, selectInside: NSRange(location: 2, length: (caption as NSString).length))
    }

    /// Caption line for the table at the caret: `Table: Caption {#tbl:label}`.
    @objc func insertTableCaption(_ sender: Any?) {
        let caption = L("placeholder.caption", "Caption")
        let text = "Table: \(caption) {#tbl:label}"
        insertBlock(text, selectInside: NSRange(location: 7, length: (caption as NSString).length))
    }

    /// Opens the completion list for cross-references and citations.
    @objc func insertCrossReference(_ sender: Any?) {
        replace(selectedRange(), with: "@")
        if citationKeyRange != nil { complete(nil) }
    }
}
