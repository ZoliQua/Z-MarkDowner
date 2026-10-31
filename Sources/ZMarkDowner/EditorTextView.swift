import AppKit
import UniformTypeIdentifiers
import MarkDownerCore

/// Markdown source editor with formatting commands.
final class EditorTextView: NSTextView {

    /// Maximum width of a line of text; extra space becomes side margins (nice in full screen).
    var readableWidth: CGFloat = 860 { didSet { updateInsets() } }

    var typewriterMode = false {
        didSet { updateInsets(); if typewriterMode { centerCaret() } }
    }

    var focusMode = false {
        didSet { updateFocusDimming() }
    }

    /// WYSIWYG-like editing (see LiveFormatting.swift).
    var liveFormatting = false {
        didSet {
            guard liveFormatting != oldValue else { return }
            layoutManager?.delegate = liveFormatting ? self : nil
            revealedLines = liveFormatting ? revealedRange(for: selectedRange()) : NSRange(location: NSNotFound, length: 0)
            let full = NSRange(location: 0, length: nsString.length)
            layoutManager?.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            layoutManager?.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            updateDecorations()
            needsDisplay = true
        }
    }

    /// Citation keys and labels offered after `@` (set by the window controller).
    var citationCandidates: (() -> [String])?

    /// Lines where markup is shown in live formatting mode.
    var revealedLines = NSRange(location: NSNotFound, length: 0)

    var markdownDocument: MarkdownDocument? {
        window?.windowController?.document as? MarkdownDocument
    }

    private var isLatex: Bool { markdownDocument?.sourceFormat == .latex }

    /// Markdown formatting, insert and rich copy commands: disabled in LaTeX documents.
    private static let markdownOnlySelectors = DocumentWindowController.formattingSelectors
        .union(DocumentWindowController.readOnlySelectors)

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, isLatex, Self.markdownOnlySelectors.contains(action) { return false }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action, isLatex, Self.markdownOnlySelectors.contains(action) { return false }
        return super.validateMenuItem(menuItem)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    func updateInsets() {
        let horizontal = max(24, (bounds.width - readableWidth) / 2)
        let visibleHeight = enclosingScrollView?.contentView.bounds.height ?? 600
        let vertical: CGFloat = typewriterMode ? max(24, visibleHeight / 2 - 20) : 24
        let inset = NSSize(width: horizontal, height: vertical)
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

    var nsString: NSString { string as NSString }

    // MARK: - Inline formatting

    /// Wraps the selection in `marker` (or removes it if already wrapped).
    func toggleInline(_ marker: String, placeholder: String) {
        let sel = selectedRange()
        let m = (marker as NSString).length
        let text = nsString

        if sel.location >= m, NSMaxRange(sel) + m <= text.length,
           text.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           text.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            replace(outer, with: text.substring(with: sel), select: NSRange(location: 0, length: sel.length))
            return
        }
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
        let selected = text.substring(with: sel)
        let lead = String(selected.prefix(while: { $0 == " " }))
        let trail = String(selected.reversed().prefix(while: { $0 == " " }))
        let core = selected.trimmingCharacters(in: .whitespaces)
        replace(sel, with: lead + marker + core + marker + trail,
                select: NSRange(location: (lead as NSString).length + m, length: (core as NSString).length))
    }

    @objc func formatBold(_ sender: Any?) { toggleInline("**", placeholder: L("placeholder.bold", "bold text")) }
    @objc func formatItalic(_ sender: Any?) { toggleInline("*", placeholder: L("placeholder.italic", "italic text")) }
    @objc func formatStrikethrough(_ sender: Any?) { toggleInline("~~", placeholder: L("placeholder.strike", "struck text")) }
    @objc func formatInlineCode(_ sender: Any?) { toggleInline("`", placeholder: L("placeholder.code", "code")) }
    @objc func insertInlineMath(_ sender: Any?) { toggleInline("$", placeholder: "E = mc^2") }

    @objc func insertLink(_ sender: Any?) {
        let sel = selectedRange()
        let selected = nsString.substring(with: sel)
        let label = L("placeholder.linkText", "link text")
        if selected.hasPrefix("http://") || selected.hasPrefix("https://") {
            replace(sel, with: "[\(label)](\(selected))", select: NSRange(location: 1, length: (label as NSString).length))
        } else {
            let text = selected.isEmpty ? label : selected
            replace(sel, with: "[\(text)](https://)", select: NSRange(location: (text as NSString).length + 3, length: 8))
        }
    }

    @objc func insertImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = L("panel.chooseImage", "Choose images to insert")
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            self.insertImageFiles(panel.urls, at: self.selectedRange())
        }
    }

    @objc func insertFootnote(_ sender: Any?) {
        var n = 1
        while nsString.range(of: "[^\(n)]").location != NSNotFound { n += 1 }
        let insertAt = NSMaxRange(selectedRange())
        let placeholder = L("placeholder.footnote", "Footnote text")
        // One replacement from the caret to the end = a single undo step
        let tail = nsString.substring(from: insertAt)
        let whole = nsString.substring(to: insertAt) + tail
        let separator = whole.hasSuffix("\n\n") ? "" : (whole.hasSuffix("\n") ? "\n" : "\n\n")
        let marker = "[^\(n)]"
        let replacement = marker + tail + separator + "[^\(n)]: " + placeholder
        let placeholderStart = (replacement as NSString).length - (placeholder as NSString).length
        replace(NSRange(location: insertAt, length: nsString.length - insertAt), with: replacement,
                select: NSRange(location: placeholderStart, length: (placeholder as NSString).length))
    }

    // MARK: - Line (block) formatting

    var selectedLinesRange: NSRange {
        nsString.lineRange(for: selectedRange())
    }

    func transformSelectedLines(_ transform: ([String]) -> [String]) {
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
            setSelectedRange(NSRange(location: range.location + max(0, length), length: 0))
        }
    }

    private static let blockPrefix = try! NSRegularExpression(
        pattern: #"^(\s*)(#{1,6}\s+|>\s?|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+)?"#)

    func split(_ line: String) -> (indent: String, prefix: String, body: String) {
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
    func insertBlock(_ block: String, selectInside: NSRange? = nil) {
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
        let code = selected.isEmpty ? L("placeholder.code", "code") : selected
        insertBlock("```\n\(code)\n```", selectInside: NSRange(location: 4, length: (code as NSString).length))
    }

    @objc func insertMathBlock(_ sender: Any?) {
        let selected = nsString.substring(with: selectedRange())
        let tex = selected.isEmpty ? #"\int_0^1 x^2\,dx = \frac{1}{3}"# : selected
        insertBlock("$$\n\(tex)\n$$", selectInside: NSRange(location: 3, length: (tex as NSString).length))
    }

    @objc func insertDiagram(_ sender: Any?) {
        let diagram = "graph TD\n    A[\(L("placeholder.start", "Start"))] --> B{?}\n    B -->|✓| C[OK]\n    B -->|✗| D[…]"
        insertBlock("```mermaid\n\(diagram)\n```", selectInside: NSRange(location: 11, length: (diagram as NSString).length))
    }

    @objc func insertTable(_ sender: Any?) {
        let c = L("placeholder.column", "Column")
        let cell = L("placeholder.cell", "Cell")
        let table = TableModel(rows: [["\(c) 1", "\(c) 2", "\(c) 3"], [cell, cell, cell], [cell, cell, cell]],
                               alignments: [.none, .none, .none]).markdown()
        insertBlock(table, selectInside: NSRange(location: 2, length: ("\(c) 1" as NSString).length))
    }

    @objc func insertHorizontalRule(_ sender: Any?) {
        insertBlock("---")
    }

    // MARK: - Smart editing

    /// Continues lists and quotes when pressing Return; adds a table row at the end of a table row.
    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, !isLatex else { return super.insertNewline(sender) }
        if handleTableNewline() { return }
        let lineRange = nsString.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineToCaret = nsString.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
        let (indent, prefix, body) = split(lineToCaret)

        guard !prefix.isEmpty, !prefix.hasPrefix("#") else { return super.insertNewline(sender) }

        if body.trimmingCharacters(in: .whitespaces).isEmpty {
            replace(NSRange(location: lineRange.location, length: sel.location - lineRange.location), with: "")
            return super.insertNewline(sender)
        }
        var next = prefix
        if let m = prefix.range(of: #"^\d+"#, options: .regularExpression), let n = Int(prefix[m]) {
            next = prefix.replacingCharacters(in: m, with: String(n + 1))
        }
        next = next.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
        replace(sel, with: "\n" + indent + next)
    }

    /// Tab moves between table cells or indents list items.
    override func insertTab(_ sender: Any?) {
        if moveToTableCell(forward: true) { return }
        if isOnListLine || selectedRange().length > 0 && selectionSpansLines {
            transformSelectedLines { $0.map { "    " + $0 } }
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if moveToTableCell(forward: false) { return }
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

    // MARK: - Auto pairing

    private static let pairs: [String: String] = ["(": ")", "[": "]", "{": "}", "`": "`", "\"": "\""]
    private static let wrappers: Set<String> = ["(", "[", "{", "`", "\"", "*", "_", "~"]

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        defer { if let s = insertString as? String { triggerCitationCompletionIfNeeded(after: s) } }
        guard Settings.shared.autoPair, !hasMarkedText(), let s = insertString as? String, (s as NSString).length == 1 else {
            return super.insertText(insertString, replacementRange: replacementRange)
        }
        let sel = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let text = nsString
        let next: unichar? = NSMaxRange(sel) < text.length ? text.character(at: NSMaxRange(sel)) : nil
        let prev: unichar? = sel.location > 0 ? text.character(at: sel.location - 1) : nil
        let nextString = next.map { String(utf16CodeUnits: [$0], count: 1) }

        // Wrap a selection
        if sel.length > 0, Self.wrappers.contains(s) {
            let close = Self.pairs[s] ?? s
            let inner = text.substring(with: sel)
            replace(sel, with: s + inner + close, select: NSRange(location: 1, length: (inner as NSString).length))
            return
        }
        // Type over an existing closing character
        if sel.length == 0, Self.pairs.values.contains(s), nextString == s {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            return
        }
        // Insert a pair when followed by whitespace / end / closing punctuation
        if sel.length == 0, let close = Self.pairs[s] {
            let nextIsFree = nextString.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ")]}.,;:".contains($0) } ?? true
            let prevIsWord = prev.flatMap { Unicode.Scalar($0) }.map { CharacterSet.alphanumerics.contains($0) } ?? false
            if nextIsFree && !(s == "\"" && prevIsWord) && !(s == "`" && prev == 0x60) {
                super.insertText(s + close, replacementRange: sel)
                setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                return
            }
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if Settings.shared.autoPair, sel.length == 0, sel.location > 0, sel.location < nsString.length {
            let prev = nsString.substring(with: NSRange(location: sel.location - 1, length: 1))
            let next = nsString.substring(with: NSRange(location: sel.location, length: 1))
            if let close = Self.pairs[prev], close == next {
                replace(NSRange(location: sel.location - 1, length: 2), with: "")
                return
            }
        }
        super.deleteBackward(sender)
    }

    // MARK: - Focus & typewriter modes

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting {
            if liveFormatting { updateRevealedLines() }
            if focusMode { updateFocusDimming() }
            if typewriterMode { centerCaret() }
        }
    }

    override func didChangeText() {
        super.didChangeText()
        if focusMode || liveFormatting { updateFocusDimming() }
        if typewriterMode { centerCaret() }
    }

    override func mouseDown(with event: NSEvent) {
        if liveFormatting, event.clickCount == 1, toggleCheckbox(at: convert(event.locationInWindow, from: nil)) { return }
        super.mouseDown(with: event)
    }

    /// Dims everything except the paragraph containing the caret (and refreshes live formatting decorations).
    func updateFocusDimming() {
        updateDecorations()
    }

    func applyFocusDimming() {
        guard let lm = layoutManager else { return }
        let full = NSRange(location: 0, length: nsString.length)
        guard focusMode, full.length > 0 else { return }
        let caret = min(selectedRange().location, max(0, nsString.length - 1))
        let current = paragraphRange(around: caret)
        let dim = NSColor.tertiaryLabelColor
        if current.location > 0 {
            lm.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: 0, length: current.location))
        }
        if NSMaxRange(current) < full.length {
            lm.addTemporaryAttribute(.foregroundColor, value: dim,
                                     forCharacterRange: NSRange(location: NSMaxRange(current), length: full.length - NSMaxRange(current)))
        }
    }

    /// Paragraph = run of non-blank lines.
    private func paragraphRange(around index: Int) -> NSRange {
        let text = nsString
        var start = text.lineRange(for: NSRange(location: index, length: 0))
        var end = start
        while start.location > 0 {
            let prev = text.lineRange(for: NSRange(location: start.location - 1, length: 0))
            if text.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            start = prev
        }
        while NSMaxRange(end) < text.length {
            let next = text.lineRange(for: NSRange(location: NSMaxRange(end), length: 0))
            if text.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            end = next
        }
        return NSUnionRange(start, end)
    }

    /// Keeps the caret line vertically centred.
    func centerCaret() {
        guard let lm = layoutManager, let clip = enclosingScrollView?.contentView else { return }
        let location = selectedRange().location
        var rect: NSRect
        if location >= nsString.length, !lm.extraLineFragmentRect.isEmpty {
            rect = lm.extraLineFragmentRect
        } else if lm.numberOfGlyphs > 0 {
            let glyph = min(lm.glyphIndexForCharacter(at: min(location, nsString.length - 1)), lm.numberOfGlyphs - 1)
            rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            return
        }
        let y = rect.midY + textContainerOrigin.y - clip.bounds.height / 2
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, y)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: - Pasting and dropping

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff, .string]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff, .string]
    }

    override func paste(_ sender: Any?) {
        if handleFilesOrImages(from: .general, at: selectedRange()) { return }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        if handleFilesOrImages(from: sender.draggingPasteboard, at: NSRange(location: index, length: 0)) {
            window?.makeFirstResponder(self)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Image files are inserted as images, other documents are opened; raw image data is saved next to the document.
    func handleFilesOrImages(from pb: NSPasteboard, at range: NSRange) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            let documents = urls.filter { DocumentImporter.supportedExtensions.contains($0.pathExtension.lowercased()) }
            if !images.isEmpty {
                insertImageFiles(images, at: range)
                return true
            }
            if !documents.isEmpty {
                for url in documents {
                    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                }
                return true
            }
            return false
        }
        // Image data without text (screenshots, images copied from other apps)
        if pb.string(forType: .string) == nil,
           let data = pb.data(forType: .png)
            ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) {
            if let path = ImageStore.store(data: data, ext: "png", suggestedName: "image",
                                           for: markdownDocument, window: window) {
                replace(range, with: imageMarkup(path, alt: ""))
            }
            return true
        }
        return false
    }

    func insertImageFiles(_ urls: [URL], at range: NSRange) {
        let refs = urls.compactMap { url -> String? in
            guard let path = ImageStore.reference(for: url, document: markdownDocument) else { return nil }
            return imageMarkup(path, alt: url.deletingPathExtension().lastPathComponent)
        }
        guard !refs.isEmpty else { return }
        replace(range, with: refs.joined(separator: "\n"))
    }

    /// Image reference for a stored image (`path` is relative and percent-encoded): Markdown image syntax,
    /// or `\includegraphics` with the plain path in LaTeX documents.
    private func imageMarkup(_ path: String, alt: String) -> String {
        guard isLatex else { return "![\(alt)](\(path))" }
        return "\\includegraphics[width=\\linewidth]{\(path.removingPercentEncoding ?? path)}"
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

    /// Copies the selection (or the whole document) as formatted text for Mail, Word, Pages…
    @objc func copyAsRichText(_ sender: Any?) {
        let sel = selectedRange()
        let source = sel.length > 0 ? nsString.substring(with: sel) : string
        let options = Settings.shared.exportOptions(title: "", baseURL: markdownDocument?.baseDirectory)
        let html = PDFExporter.html(markdown: source, options: options)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let attributed = NSAttributedString(html: Data(html.utf8),
                                               options: [.documentType: NSAttributedString.DocumentType.html,
                                                         .characterEncoding: String.Encoding.utf8.rawValue],
                                               documentAttributes: nil),
           let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) {
            pb.setData(rtf, forType: .rtf)
            pb.setString(attributed.string, forType: .string)
        } else {
            pb.setString(source, forType: .string)
        }
        pb.setString(html, forType: .html)
    }
}
