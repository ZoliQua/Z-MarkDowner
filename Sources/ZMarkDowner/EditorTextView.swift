import AppKit
import MarkDownerCore

/// Markdown source editor with formatting commands.
final class EditorTextView: NSTextView {

    /// Maximum width of a line of text; extra space becomes side margins (nice in full screen).
    var readableWidth: CGFloat = 860 { didSet { updateInsets() } }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    private func updateInsets() {
        let horizontal = max(24, (bounds.width - readableWidth) / 2)
        let inset = NSSize(width: horizontal, height: 24)
        if textContainerInset != inset { textContainerInset = inset }
    }

    // MARK: - Editing primitives

    /// Replaces a range with undo support and selects `selection` (relative to the range start) afterwards.
    func replace(_ range: NSRange, with string: String, select selection: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
        if let selection {
            setSelectedRange(NSRange(location: range.location + selection.location, length: selection.length))
        } else {
            setSelectedRange(NSRange(location: range.location + (string as NSString).length, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    private var nsString: NSString { string as NSString }

    // MARK: - Inline formatting

    /// Wraps the selection in `marker` (or removes it if already wrapped).
    func toggleInline(_ marker: String, placeholder: String) {
        let sel = selectedRange()
        let m = (marker as NSString).length
        let text = nsString

        // Already wrapped: markers just outside the selection
        if sel.location >= m, NSMaxRange(sel) + m <= text.length,
           text.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           text.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            replace(outer, with: text.substring(with: sel), select: NSRange(location: 0, length: sel.length))
            return
        }
        // Selection includes the markers
        if sel.length >= 2 * m {
            let selected = text.substring(with: sel)
            if selected.hasPrefix(marker), selected.hasSuffix(marker) {
                let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
                replace(sel, with: inner, select: NSRange(location: 0, length: (inner as NSString).length))
                return
            }
        }

        if sel.length == 0 {
            replace(sel, with: marker + placeholder + marker,
                    select: NSRange(location: m, length: (placeholder as NSString).length))
            return
        }
        // Keep surrounding whitespace outside the markers
        let selected = text.substring(with: sel)
        let lead = String(selected.prefix(while: { $0 == " " }))
        let trail = String(selected.reversed().prefix(while: { $0 == " " }))
        let core = selected.trimmingCharacters(in: .whitespaces)
        let replacement = lead + marker + core + marker + trail
        replace(sel, with: replacement,
                select: NSRange(location: (lead as NSString).length + m, length: (core as NSString).length))
    }

    @objc func formatBold(_ sender: Any?) { toggleInline("**", placeholder: "félkövér szöveg") }
    @objc func formatItalic(_ sender: Any?) { toggleInline("*", placeholder: "dőlt szöveg") }
    @objc func formatStrikethrough(_ sender: Any?) { toggleInline("~~", placeholder: "áthúzott szöveg") }
    @objc func formatInlineCode(_ sender: Any?) { toggleInline("`", placeholder: "kód") }

    @objc func insertLink(_ sender: Any?) {
        let sel = selectedRange()
        let selected = nsString.substring(with: sel)
        if selected.hasPrefix("http://") || selected.hasPrefix("https://") {
            replace(sel, with: "[link szövege](\(selected))", select: NSRange(location: 1, length: 12))
        } else {
            let label = selected.isEmpty ? "link szövege" : selected
            let s = "[\(label)](https://)"
            let urlStart = (label as NSString).length + 3
            replace(sel, with: s, select: NSRange(location: urlStart, length: 8))
        }
    }

    @objc func insertImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Válassz képet a beszúráshoz"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let sel = self.selectedRange()
            if response == .OK, let url = panel.url {
                var path = url.path
                if let base = (self.window?.windowController?.document as? MarkdownDocument)?.fileURL?.deletingLastPathComponent(),
                   url.path.hasPrefix(base.path + "/") {
                    path = String(url.path.dropFirst(base.path.count + 1))
                }
                let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                let alt = url.deletingPathExtension().lastPathComponent
                self.replace(sel, with: "![\(alt)](\(encoded))")
            }
        }
    }

    // MARK: - Line (block) formatting

    /// Ranges of the full lines touched by the selection.
    private var selectedLinesRange: NSRange {
        nsString.lineRange(for: selectedRange())
    }

    private func transformSelectedLines(_ transform: ([String]) -> [String]) {
        let range = selectedLinesRange
        var block = nsString.substring(with: range)
        let hadNewline = block.hasSuffix("\n")
        if hadNewline { block.removeLast() }
        let lines = block.components(separatedBy: "\n")
        var result = transform(lines).joined(separator: "\n")
        if hadNewline { result += "\n" }
        let length = (result as NSString).length - (hadNewline ? 1 : 0)
        replace(range, with: result, select: NSRange(location: 0, length: max(0, length)))
        if lines.count == 1 {
            // Single line: put the caret at the end of the line instead of selecting it
            setSelectedRange(NSRange(location: range.location + max(0, length), length: 0))
        }
    }

    private static let blockPrefix = try! NSRegularExpression(
        pattern: #"^(\s*)(#{1,6}\s+|>\s?|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+)?"#)

    private func split(_ line: String) -> (indent: String, prefix: String, body: String) {
        let ns = line as NSString
        guard let m = Self.blockPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return ("", "", line)
        }
        let indent = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
        let prefix = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
        return (indent, prefix, ns.substring(from: m.range.length))
    }

    func setHeading(_ level: Int) {
        transformSelectedLines { lines in
            lines.map { line in
                let (indent, prefix, body) = split(line)
                let currentLevel = prefix.hasPrefix("#") ? prefix.filter { $0 == "#" }.count : 0
                let keepPrefix = prefix.hasPrefix("#") ? "" : prefix
                if level == 0 || currentLevel == level { return indent + keepPrefix + body }
                return String(repeating: "#", count: level) + " " + body
            }
        }
    }

    @objc func formatHeading1(_ sender: Any?) { setHeading(1) }
    @objc func formatHeading2(_ sender: Any?) { setHeading(2) }
    @objc func formatHeading3(_ sender: Any?) { setHeading(3) }
    @objc func formatHeading4(_ sender: Any?) { setHeading(4) }
    @objc func formatHeading5(_ sender: Any?) { setHeading(5) }
    @objc func formatHeading6(_ sender: Any?) { setHeading(6) }
    @objc func formatParagraph(_ sender: Any?) {
        transformSelectedLines { lines in lines.map { let s = split($0); return s.indent + s.body } }
    }

    enum ListKind { case bullet, numbered, task, quote }

    func toggleList(_ kind: ListKind) {
        transformSelectedLines { lines in
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let matches: (String) -> Bool = { line in
                let p = self.split(line).prefix
                switch kind {
                case .bullet: return p.range(of: #"^[-*+]\s+$"#, options: .regularExpression) != nil
                case .numbered: return p.range(of: #"^\d+[.)]\s+$"#, options: .regularExpression) != nil
                case .task: return p.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil
                case .quote: return p.hasPrefix(">")
                }
            }
            let allHave = !nonEmpty.isEmpty && nonEmpty.allSatisfy(matches)
            var number = 0
            return lines.map { line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty && lines.count > 1 { return line }
                let (indent, _, body) = split(line)
                if allHave { return indent + body }
                switch kind {
                case .bullet: return indent + "- " + body
                case .numbered: number += 1; return indent + "\(number). " + body
                case .task: return indent + "- [ ] " + body
                case .quote: return indent + "> " + body
                }
            }
        }
    }

    @objc func formatBulletList(_ sender: Any?) { toggleList(.bullet) }
    @objc func formatNumberedList(_ sender: Any?) { toggleList(.numbered) }
    @objc func formatTaskList(_ sender: Any?) { toggleList(.task) }
    @objc func formatQuote(_ sender: Any?) { toggleList(.quote) }

    // MARK: - Block insertion

    /// Inserts a block on its own lines (adds blank lines around it when needed).
    private func insertBlock(_ block: String, selectInside: NSRange? = nil) {
        let sel = selectedRange()
        let text = nsString
        var before = ""
        if sel.location > 0 {
            let prevLine = text.lineRange(for: NSRange(location: sel.location - 1, length: 0))
            let prev = text.substring(with: prevLine)
            if !prev.hasSuffix("\n") || sel.location != NSMaxRange(prevLine) { before = "\n\n" }
            else if !prev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { before = "\n" }
        }
        var after = "\n"
        if NSMaxRange(sel) < text.length {
            after = text.character(at: NSMaxRange(sel)) == 0x0A ? "\n" : "\n\n"
        }
        let insertion = before + block + after
        let selection = selectInside.map {
            NSRange(location: (before as NSString).length + $0.location, length: $0.length)
        }
        replace(sel, with: insertion, select: selection)
    }

    @objc func insertCodeBlock(_ sender: Any?) {
        let selected = nsString.substring(with: selectedRange())
        let code = selected.isEmpty ? "kód" : selected
        insertBlock("```\n\(code)\n```", selectInside: NSRange(location: 4, length: (code as NSString).length))
    }

    @objc func insertTable(_ sender: Any?) {
        let table = """
        | Oszlop 1 | Oszlop 2 | Oszlop 3 |
        |----------|----------|----------|
        | Cella    | Cella    | Cella    |
        | Cella    | Cella    | Cella    |
        """
        insertBlock(table, selectInside: NSRange(location: 2, length: 8))
    }

    @objc func insertHorizontalRule(_ sender: Any?) {
        insertBlock("---")
    }

    // MARK: - Smart editing

    /// Continues lists and quotes when pressing Return.
    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0 else { return super.insertNewline(sender) }
        let lineRange = nsString.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineToCaret = nsString.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
        let (indent, prefix, body) = split(lineToCaret)

        guard !prefix.isEmpty, !prefix.hasPrefix("#") else { return super.insertNewline(sender) }

        if body.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item: end the list
            replace(NSRange(location: lineRange.location, length: sel.location - lineRange.location), with: "")
            return super.insertNewline(sender)
        }
        var next = prefix
        if let m = prefix.range(of: #"^\d+"#, options: .regularExpression), let n = Int(prefix[m]) {
            next = prefix.replacingCharacters(in: m, with: String(n + 1))
        }
        next = next.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
        insertText("\n" + indent + next, replacementRange: sel)
    }

    /// Tab / Shift-Tab indent list items.
    override func insertTab(_ sender: Any?) {
        if isOnListLine || selectedRange().length > 0 && selectionSpansLines {
            transformSelectedLines { $0.map { "    " + $0 } }
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        transformSelectedLines { lines in
            lines.map { line in
                var l = line
                var removed = 0
                while removed < 4, l.hasPrefix(" ") { l.removeFirst(); removed += 1 }
                if removed == 0, l.hasPrefix("\t") { l.removeFirst() }
                return l
            }
        }
    }

    private var isOnListLine: Bool {
        let line = nsString.substring(with: nsString.lineRange(for: NSRange(location: selectedRange().location, length: 0)))
        let p = split(line).prefix
        return !p.isEmpty && !p.hasPrefix("#") && !p.hasPrefix(">")
    }

    private var selectionSpansLines: Bool {
        nsString.substring(with: selectedRange()).contains("\n")
    }

    /// Pastes rich text (e.g. copied from Word or a web page) converted to Markdown.
    @objc func pasteAsMarkdown(_ sender: Any?) {
        let pb = NSPasteboard.general
        var attributed: NSAttributedString?
        if let data = pb.data(forType: .rtf) {
            attributed = NSAttributedString(rtf: data, documentAttributes: nil)
        } else if let data = pb.data(forType: .html) {
            attributed = NSAttributedString(html: data, documentAttributes: nil)
        }
        let markdown: String
        if let attributed {
            markdown = AttributedToMarkdown.convert(attributed).trimmingCharacters(in: .newlines)
        } else if let plain = pb.string(forType: .string) {
            markdown = plain
        } else {
            NSSound.beep()
            return
        }
        replace(selectedRange(), with: markdown)
    }

    // Paste plain text only (rich text would be meaningless in Markdown source)
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }
}
