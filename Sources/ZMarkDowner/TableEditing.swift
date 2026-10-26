import AppKit
import MarkDownerCore

/// A Markdown table parsed from source lines.
struct TableModel {
    var rows: [[String]]          // first row is the header
    var alignments: [MDAlignment]

    var columnCount: Int { max(alignments.count, rows.map(\.count).max() ?? 0) }

    init(rows: [[String]], alignments: [MDAlignment]) {
        self.rows = rows
        self.alignments = alignments
    }

    /// Parses table lines (header, delimiter, body rows).
    init?(lines: [String]) {
        guard lines.count >= 2, MarkdownParser.isTableDelimiterRow(lines[1]) else { return nil }
        alignments = MarkdownParser.splitTableRow(lines[1]).map(MarkdownParser.parseAlignment)
        rows = [MarkdownParser.splitTableRow(lines[0])] + lines.dropFirst(2).map { MarkdownParser.splitTableRow($0) }
        normalize()
    }

    mutating func normalize() {
        let n = columnCount
        rows = rows.map { $0.count < n ? $0 + Array(repeating: "", count: n - $0.count) : $0 }
        if alignments.count < n { alignments += Array(repeating: .none, count: n - alignments.count) }
    }

    /// Display width (wide characters count as two columns).
    static func width(_ s: String) -> Int {
        var w = 0
        for scalar in s.unicodeScalars where scalar.properties.generalCategory != .nonspacingMark {
            w += scalar.properties.isEmojiPresentation || scalar.properties.isIdeographic ? 2 : 1
        }
        return w
    }

    /// Aligned Markdown source.
    func markdown() -> String {
        var model = self
        model.normalize()
        let n = model.columnCount
        var widths = Array(repeating: 3, count: n)
        for row in model.rows {
            for (i, cell) in row.enumerated() where i < n { widths[i] = max(widths[i], Self.width(cell)) }
        }
        func pad(_ s: String, _ w: Int, _ a: MDAlignment) -> String {
            let space = max(0, w - Self.width(s))
            switch a {
            case .right: return String(repeating: " ", count: space) + s
            case .center:
                let left = space / 2
                return String(repeating: " ", count: left) + s + String(repeating: " ", count: space - left)
            default: return s + String(repeating: " ", count: space)
            }
        }
        func line(_ cells: [String]) -> String {
            "| " + (0..<n).map { pad(cells[$0], widths[$0], model.alignments[$0]) }.joined(separator: " | ") + " |"
        }
        let delimiter = "|" + (0..<n).map { i -> String in
            let w = widths[i]
            switch model.alignments[i] {
            case .left: return ":" + String(repeating: "-", count: w + 1)
            case .right: return String(repeating: "-", count: w + 1) + ":"
            case .center: return ":" + String(repeating: "-", count: w) + ":"
            case .none: return String(repeating: "-", count: w + 2)
            }
        }.joined(separator: "|") + "|"
        var out = [line(model.rows[0]), delimiter]
        out += model.rows.dropFirst().map(line)
        return out.joined(separator: "\n")
    }
}

extension EditorTextView {

    private func isTableLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") || (t.contains("|") && !t.isEmpty)
    }

    /// The table around the caret: character range of its lines and the lines themselves.
    func tableAtCaret() -> (range: NSRange, lines: [String], caretLine: Int)? {
        let text = nsString
        let caret = selectedRange().location
        let current = text.lineRange(for: NSRange(location: caret, length: 0))
        guard isTableLine(text.substring(with: current).trimmingCharacters(in: .newlines)) else { return nil }
        var start = current
        while start.location > 0 {
            let prev = text.lineRange(for: NSRange(location: start.location - 1, length: 0))
            guard isTableLine(text.substring(with: prev).trimmingCharacters(in: .newlines)) else { break }
            start = prev
        }
        var end = current
        while NSMaxRange(end) < text.length {
            let next = text.lineRange(for: NSRange(location: NSMaxRange(end), length: 0))
            guard isTableLine(text.substring(with: next).trimmingCharacters(in: .newlines)) else { break }
            end = next
        }
        var range = NSUnionRange(start, end)
        var block = text.substring(with: range)
        if block.hasSuffix("\n") { block.removeLast(); range.length -= 1 }
        let lines = block.components(separatedBy: "\n")
        guard lines.count >= 2, MarkdownParser.isTableDelimiterRow(lines[1]) else { return nil }
        let caretLine = text.substring(with: NSRange(location: range.location, length: caret - range.location))
            .filter { $0 == "\n" }.count
        return (range, lines, caretLine)
    }

    /// Cell index of the caret within a table line.
    private func cellIndex(in line: String, offset: Int) -> Int {
        let prefix = (line as NSString).substring(to: min(offset, (line as NSString).length))
        let pipes = prefix.filter { $0 == "|" }.count
        let leading = line.trimmingCharacters(in: .whitespaces).hasPrefix("|") ? 1 : 0
        return max(0, pipes - leading)
    }

    /// Replaces the table with `model` (aligned) and selects cell (row, col); row 0 = header, rows ≥ 1 = body.
    private func apply(_ model: TableModel, range: NSRange, selectRow row: Int, column col: Int) {
        let source = model.markdown()
        let lines = source.components(separatedBy: "\n")
        let lineIndex = row == 0 ? 0 : row + 1
        var offset = 0
        for i in 0..<lineIndex { offset += (lines[i] as NSString).length + 1 }
        let line = lines[lineIndex] as NSString
        // Find the col-th cell between pipes
        var pipeCount = 0
        var cellStart = 0
        var cellEnd = line.length
        for i in 0..<line.length where line.character(at: i) == 0x7C {
            if pipeCount == col { cellStart = i + 1 }
            if pipeCount == col + 1 { cellEnd = i; break }
            pipeCount += 1
        }
        let cell = line.substring(with: NSRange(location: cellStart, length: max(0, cellEnd - cellStart)))
        let trimmedStart = cellStart + (cell.count - cell.drop(while: { $0 == " " }).count)
        let content = cell.trimmingCharacters(in: .whitespaces)
        replace(range, with: source, select: NSRange(location: offset + trimmedStart, length: (content as NSString).length))
    }

    /// Tab / Shift-Tab inside a table: re-align and move to the next / previous cell.
    func moveToTableCell(forward: Bool) -> Bool {
        guard let table = tableAtCaret(), var model = TableModel(lines: table.lines) else { return false }
        guard table.caretLine != 1 else { return false }
        let lineStart = table.lines.prefix(table.caretLine).reduce(table.range.location) { $0 + ($1 as NSString).length + 1 }
        let col = cellIndex(in: table.lines[table.caretLine], offset: selectedRange().location - lineStart)
        var row = table.caretLine == 0 ? 0 : table.caretLine - 1
        var newCol = col + (forward ? 1 : -1)
        let n = model.columnCount
        if newCol >= n {
            newCol = 0; row += 1
            if row >= model.rows.count { model.rows.append(Array(repeating: "", count: n)) }
        } else if newCol < 0 {
            guard row > 0 else { return true }
            newCol = n - 1; row -= 1
        }
        apply(model, range: table.range, selectRow: row, column: newCol)
        return true
    }

    /// Return at the end of a table row inserts a new empty row.
    func handleTableNewline() -> Bool {
        guard let table = tableAtCaret(), var model = TableModel(lines: table.lines), table.caretLine != 1 else { return false }
        let lineStart = table.lines.prefix(table.caretLine).reduce(table.range.location) { $0 + ($1 as NSString).length + 1 }
        let lineEnd = lineStart + (table.lines[table.caretLine] as NSString).length
        guard selectedRange().location == lineEnd else { return false }
        let row = table.caretLine == 0 ? 0 : table.caretLine - 1
        // An empty last row ends the table
        if row == model.rows.count - 1, row > 0, model.rows[row].allSatisfy({ $0.isEmpty }) {
            model.rows.removeLast()
            replace(table.range, with: model.markdown() + "\n")
            return true
        }
        model.rows.insert(Array(repeating: "", count: model.columnCount), at: row + 1)
        apply(model, range: table.range, selectRow: row + 1, column: 0)
        return true
    }

    private func currentCell() -> (table: (range: NSRange, lines: [String], caretLine: Int), model: TableModel, row: Int, col: Int)? {
        guard let table = tableAtCaret(), let model = TableModel(lines: table.lines) else { return nil }
        let lineStart = table.lines.prefix(table.caretLine).reduce(table.range.location) { $0 + ($1 as NSString).length + 1 }
        let col = min(cellIndex(in: table.lines[table.caretLine], offset: selectedRange().location - lineStart), model.columnCount - 1)
        let row = table.caretLine <= 1 ? 0 : table.caretLine - 1
        return (table, model, row, col)
    }

    @objc func formatTable(_ sender: Any?) {
        guard let c = currentCell() else { NSSound.beep(); return }
        apply(c.model, range: c.table.range, selectRow: c.row, column: c.col)
    }

    @objc func tableInsertRow(_ sender: Any?) {
        guard var c = currentCell() else { NSSound.beep(); return }
        c.model.rows.insert(Array(repeating: "", count: c.model.columnCount), at: c.row + 1)
        apply(c.model, range: c.table.range, selectRow: c.row + 1, column: c.col)
    }

    @objc func tableInsertColumn(_ sender: Any?) {
        guard var c = currentCell() else { NSSound.beep(); return }
        for i in c.model.rows.indices { c.model.rows[i].insert(i == 0 ? L("placeholder.column", "Column") : "", at: c.col + 1) }
        c.model.alignments.insert(.none, at: c.col + 1)
        apply(c.model, range: c.table.range, selectRow: 0, column: c.col + 1)
    }

    @objc func tableDeleteRow(_ sender: Any?) {
        guard var c = currentCell(), c.row > 0 else { NSSound.beep(); return }
        c.model.rows.remove(at: c.row)
        if c.model.rows.count == 1 { c.model.rows.append(Array(repeating: "", count: c.model.columnCount)) }
        apply(c.model, range: c.table.range, selectRow: min(c.row, c.model.rows.count - 1), column: c.col)
    }

    @objc func tableDeleteColumn(_ sender: Any?) {
        guard var c = currentCell(), c.model.columnCount > 1 else { NSSound.beep(); return }
        for i in c.model.rows.indices where c.col < c.model.rows[i].count { c.model.rows[i].remove(at: c.col) }
        c.model.alignments.remove(at: c.col)
        apply(c.model, range: c.table.range, selectRow: c.row, column: max(0, c.col - 1))
    }

    @objc func tableAlignLeft(_ sender: Any?) { setColumnAlignment(.left) }
    @objc func tableAlignCenter(_ sender: Any?) { setColumnAlignment(.center) }
    @objc func tableAlignRight(_ sender: Any?) { setColumnAlignment(.right) }

    private func setColumnAlignment(_ a: MDAlignment) {
        guard var c = currentCell() else { NSSound.beep(); return }
        c.model.alignments[c.col] = a
        apply(c.model, range: c.table.range, selectRow: c.row, column: c.col)
    }
}
