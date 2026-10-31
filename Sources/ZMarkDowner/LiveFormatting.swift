import AppKit

/// Live formatting: Markdown markup is hidden except on the lines being edited, bullets,
/// checkboxes, rules and quote bars are drawn (a WYSIWYG-like way of editing the same Markdown text).
extension EditorTextView: NSLayoutManagerDelegate {

    /// Lines of the current selection, where markup stays visible.
    func revealedRange(for selection: NSRange) -> NSRange {
        let text = nsString
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let clipped = NSRange(location: min(selection.location, text.length), length: min(selection.length, text.length - min(selection.location, text.length)))
        return text.lineRange(for: clipped)
    }

    /// Re-generates glyphs where hidden markup must appear or disappear after the caret moved.
    func updateRevealedLines() {
        guard liveFormatting, let lm = layoutManager else { return }
        let new = revealedRange(for: selectedRange())
        guard new != revealedLines else { return }
        let old = revealedLines
        revealedLines = new
        for r in [old, new] {
            let clipped = NSIntersectionRange(r, NSRange(location: 0, length: nsString.length))
            guard clipped.length > 0 else { continue }
            lm.invalidateGlyphs(forCharacterRange: clipped, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: clipped, actualCharacterRange: nil)
        }
        updateDecorations()
        needsDisplay = true
    }

    /// Hidden markup becomes null glyphs (no ink, no width).
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard liveFormatting, let storage = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
        var modified: [NSLayoutManager.GlyphProperty]?
        var cached = NSRange(location: NSNotFound, length: 0)
        var cachedHidden = false
        for i in 0..<glyphRange.length {
            let ci = charIndexes[i]
            guard ci < storage.length else { continue }
            if !NSLocationInRange(ci, cached) {
                cachedHidden = storage.attribute(.zmdHidden, at: ci, effectiveRange: &cached) != nil
            }
            guard cachedHidden, !NSLocationInRange(ci, revealedLines) else { continue }
            if modified == nil { modified = Array(UnsafeBufferPointer(start: props, count: glyphRange.length)) }
            modified![i] = .null
        }
        guard let modified else { return 0 }
        modified.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: charIndexes,
                                    font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    /// Bullets, checkboxes and rules are drawn by the view; their characters are made transparent.
    func updateDecorations() {
        guard let lm = layoutManager, let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        if focusMode { applyFocusDimming() }
        guard liveFormatting else { return }
        for key in [NSAttributedString.Key.zmdBullet, .zmdCheckbox, .zmdRule] {
            storage.enumerateAttribute(key, in: full) { value, range, _ in
                guard value != nil, NSIntersectionRange(range, revealedLines).length == 0 else { return }
                lm.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: range)
            }
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard liveFormatting, let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return }
        let origin = textContainerOrigin
        let visibleGlyphs = lm.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let visible = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        guard visible.length > 0 else { return }

        func rect(for range: NSRange) -> NSRect {
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: origin.x, dy: origin.y)
        }

        // Quote bars
        NSColor.separatorColor.setFill()
        storage.enumerateAttribute(.zmdQuote, in: visible) { value, range, _ in
            guard let depth = value as? Int else { return }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
                for d in 0..<depth {
                    NSBezierPath(rect: NSRect(x: origin.x + fragment.minX + CGFloat(d) * 16 + 2,
                                              y: origin.y + fragment.minY, width: 3, height: fragment.height)).fill()
                }
            }
        }

        // Horizontal rules
        storage.enumerateAttribute(.zmdRule, in: visible) { value, range, _ in
            guard value != nil, NSIntersectionRange(range, revealedLines).length == 0 else { return }
            let r = rect(for: range)
            let width = tc.size.width - 2 * tc.lineFragmentPadding
            NSColor.separatorColor.setFill()
            NSBezierPath(rect: NSRect(x: origin.x + tc.lineFragmentPadding, y: r.midY, width: width, height: 1.5)).fill()
        }

        // Bullets
        storage.enumerateAttribute(.zmdBullet, in: visible) { value, range, _ in
            guard value != nil, NSIntersectionRange(range, revealedLines).length == 0 else { return }
            let r = rect(for: range)
            let size = max(5, r.height * 0.28)
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.midX - size / 2, y: r.midY - size / 2 - r.height * 0.06, width: size, height: size)).fill()
        }

        // Checkboxes
        storage.enumerateAttribute(.zmdCheckbox, in: visible) { value, range, _ in
            guard let checked = value as? Bool, NSIntersectionRange(range, revealedLines).length == 0 else { return }
            let r = rect(for: range)
            let side = min(r.height * 0.8, 16)
            let box = NSRect(x: r.minX + 1, y: r.midY - side / 2, width: side, height: side)
            let symbol = NSImage(systemSymbolName: checked ? "checkmark.square.fill" : "square", accessibilityDescription: nil)
            let config = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
                .applying(.init(paletteColors: [checked ? .controlAccentColor : .secondaryLabelColor]))
            symbol?.withSymbolConfiguration(config)?.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                                                           respectFlipped: true, hints: nil)
        }
    }

    /// Clicking a drawn checkbox toggles the task.
    func toggleCheckbox(at point: NSPoint) -> Bool {
        guard liveFormatting, let storage = textStorage, let lm = layoutManager, let tc = textContainer else { return false }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: local, in: tc)
        let index = lm.characterIndexForGlyph(at: glyph)
        for candidate in [index, index - 1, index - 2] where candidate >= 0 && candidate < storage.length {
            var range = NSRange()
            guard storage.attribute(.zmdCheckbox, at: candidate, effectiveRange: &range) != nil,
                  NSIntersectionRange(range, revealedLines).length == 0, range.length == 3 else { continue }
            let boxRect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc)
            guard boxRect.insetBy(dx: -3, dy: -3).contains(local) else { return false }
            let state = NSRange(location: range.location + 1, length: 1)
            let checked = nsString.substring(with: state).lowercased() == "x"
            replace(state, with: checked ? " " : "x", select: NSRange(location: 0, length: 0))
            setSelectedRange(selectedRange())
            return true
        }
        return false
    }
}
