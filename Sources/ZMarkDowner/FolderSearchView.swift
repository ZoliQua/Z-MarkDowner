import AppKit
import MarkDownerCore

/// Sidebar tab: search (and replace) in all Markdown and text files of the sidebar folder.
final class FolderSearchView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {

    /// Folder to search (the sidebar's file browser folder).
    var folder: () -> URL? = { nil }
    /// Opens a file and selects a range in it.
    var onOpenMatch: ((URL, NSRange) -> Void)?

    private let searchField = NSSearchField()
    private let replaceField = NSTextField()
    private let regexButton = NSButton()
    private let caseButton = NSButton()
    private let wordButton = NSButton()
    private let replaceButton = NSButton()
    private let summary = NSTextField(labelWithString: "")
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let spinner = NSProgressIndicator()

    private var results: [FileItem] = []
    private var generation = 0
    private var searchWork: DispatchWorkItem?

    final class FileItem: NSObject {
        let url: URL
        let matches: [MatchItem]
        init(url: URL, matches: [MatchItem]) { self.url = url; self.matches = matches }
    }

    final class MatchItem: NSObject {
        let url: URL
        let match: FolderSearch.Match
        init(url: URL, match: FolderSearch.Match) { self.url = url; self.match = match }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        searchField.placeholderString = L("search.placeholder", "Search in folder")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchNow)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.setAccessibilityLabel(L("search.placeholder", "Search in folder"))

        replaceField.placeholderString = L("search.replacePlaceholder", "Replace with")
        replaceField.target = self
        replaceField.action = #selector(replaceAll)

        func toggle(_ button: NSButton, _ title: String, _ tip: String) {
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .accessoryBarAction
            button.title = title
            button.toolTip = tip
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(optionsChanged)
        }
        toggle(caseButton, "Aa", L("search.caseSensitive", "Match case"))
        toggle(wordButton, "W", L("search.wholeWord", "Whole words"))
        toggle(regexButton, ".*", L("search.regex", "Regular expression ($1… in the replacement)"))

        replaceButton.title = L("search.replaceAll", "Replace All")
        replaceButton.bezelStyle = .accessoryBarAction
        replaceButton.controlSize = .small
        replaceButton.target = self
        replaceButton.action = #selector(replaceAll)

        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let column = NSTableColumn(identifier: .init("result"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(resultClicked)
        outline.backgroundColor = .clear
        outline.usesAutomaticRowHeights = true
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let options = NSStackView(views: [caseButton, wordButton, regexButton, NSView(), spinner])
        options.spacing = 4
        let replaceRow = NSStackView(views: [replaceField, replaceButton])
        replaceRow.spacing = 4
        for v in [searchField, options, replaceRow, summary, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            options.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            options.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            options.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            replaceRow.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 4),
            replaceRow.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            replaceRow.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            summary.topAnchor.constraint(equalTo: replaceRow.bottomAnchor, constant: 6),
            summary.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: 2),
            summary.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Runs a search programmatically (self test); results arrive asynchronously.
    func search(for query: String) {
        searchField.stringValue = query
        searchNow()
    }

    var resultCount: Int { results.reduce(0) { $0 + $1.matches.count } }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    // MARK: Searching

    private var options: FolderSearch.Options {
        FolderSearch.Options(regularExpression: regexButton.state == .on, caseSensitive: caseButton.state == .on,
                             wholeWord: wordButton.state == .on)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.searchNow() }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    @objc private func optionsChanged() { searchNow() }

    /// Text of documents open in the app, so unsaved edits are searched (and replaced) too.
    static func openDocumentTexts() -> [URL: String] {
        var texts: [URL: String] = [:]
        for case let doc as MarkdownDocument in NSDocumentController.shared.documents {
            guard let url = doc.fileURL else { continue }
            doc.windowController?.commitEditing()
            texts[url.standardizedFileURL] = doc.text
        }
        return texts
    }

    @objc func searchNow() {
        searchWork?.cancel()
        generation += 1
        let current = generation
        let query = searchField.stringValue
        guard !query.isEmpty, let folder = folder() else {
            results = []
            outline.reloadData()
            summary.stringValue = folder() == nil ? L("search.noFolder", "Choose a folder in the Files tab.") : ""
            return
        }
        let regex: NSRegularExpression
        do {
            regex = try FolderSearch.regex(for: query, options: options)
        } catch {
            summary.stringValue = L("search.invalidRegex", "Invalid regular expression")
            return
        }
        let open = Self.openDocumentTexts()
        spinner.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [FileItem] = []
            var total = 0
            for url in FolderSearch.files(in: folder) {
                if self?.generation != current { return }
                let text = open[url.standardizedFileURL]
                    ?? FileManager.default.contents(atPath: url.path).map { DocumentImporter.decodeText($0) } ?? ""
                let matches = FolderSearch.matches(in: text, regex: regex, limit: max(0, 5000 - total))
                if !matches.isEmpty {
                    found.append(FileItem(url: url, matches: matches.map { MatchItem(url: url, match: $0) }))
                    total += matches.count
                }
                if total >= 5000 { break }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.spinner.stopAnimation(nil)
                self.results = found
                self.outline.reloadData()
                found.prefix(20).forEach { self.outline.expandItem($0) }
                self.summary.stringValue = total == 0 ? L("search.none", "No matches")
                    : LF("search.summary", "%d matches in %d files", total, found.count)
            }
        }
    }

    // MARK: Replacing

    @objc private func replaceAll() {
        let query = searchField.stringValue
        guard !query.isEmpty, let folder = folder(), let window,
              let regex = try? FolderSearch.regex(for: query, options: options) else { NSSound.beep(); return }
        let total = results.reduce(0) { $0 + $1.matches.count }
        guard total > 0 else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = LF("search.confirmTitle", "Replace %d matches in %d files?", total, results.count)
        alert.informativeText = L("search.confirmText", "Open documents can be restored with Undo; files that are not open are saved immediately.")
        alert.addButton(withTitle: L("search.replaceAll", "Replace All"))
        alert.addButton(withTitle: L("button.cancel", "Cancel"))
        let replacement = replaceField.stringValue
        let opts = options
        let urls = results.map(\.url)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            var replaced = 0
            var failures: [String] = []
            let openDocs = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
            for url in urls {
                if let doc = openDocs.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }),
                   let wc = doc.windowController {
                    wc.commitEditing()
                    let result = FolderSearch.replace(in: doc.text, regex: regex, with: replacement, options: opts)
                    if result.count > 0 { wc.replaceAllText(with: result.text) }
                    replaced += result.count
                } else {
                    guard let data = FileManager.default.contents(atPath: url.path) else { failures.append(url.lastPathComponent); continue }
                    let result = FolderSearch.replace(in: DocumentImporter.decodeText(data), regex: regex, with: replacement, options: opts)
                    guard result.count > 0 else { continue }
                    do {
                        try result.text.write(to: url, atomically: true, encoding: .utf8)
                        replaced += result.count
                    } catch {
                        failures.append(url.lastPathComponent)
                    }
                }
            }
            _ = folder
            self?.searchNow()
            self?.summary.stringValue = LF("search.replaced", "%d replacements", replaced)
                + (failures.isEmpty ? "" : " · " + LF("search.failed", "Failed: %@", failures.joined(separator: ", ")))
        }
    }

    // MARK: Outline

    @objc private func resultClicked() {
        let item = outline.item(atRow: outline.clickedRow)
        if let match = item as? MatchItem {
            onOpenMatch?(match.url, match.match.range)
        } else if let file = item as? FileItem {
            outline.isItemExpanded(file) ? outline.collapseItem(file) : outline.expandItem(file)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let file = item as? FileItem { return file.matches.count }
        return item == nil ? results.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let file = item as? FileItem { return file.matches[index] }
        return results[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is FileItem }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(wrappingLabelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingTail
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            text.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),
        ])
        if let file = item as? FileItem {
            var relative = file.url.lastPathComponent
            if let base = folder()?.standardizedFileURL.path, file.url.standardizedFileURL.path.hasPrefix(base + "/") {
                relative = String(file.url.standardizedFileURL.path.dropFirst(base.count + 1))
            }
            let title = NSMutableAttributedString(string: relative, attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            title.append(NSAttributedString(string: "  \(file.matches.count)", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            text.attributedStringValue = title
            text.maximumNumberOfLines = 1
        } else if let m = item as? MatchItem {
            let line = m.match.lineText.trimmingCharacters(in: .whitespaces)
            let leading = (m.match.lineText as NSString).length - (line as NSString).length
            let s = NSMutableAttributedString(string: "\(m.match.line + 1): ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor])
            let body = NSMutableAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                          .foregroundColor: NSColor.secondaryLabelColor])
            var hit = m.match.rangeInLine
            hit.location -= leading
            if hit.location >= 0, NSMaxRange(hit) <= body.length {
                body.addAttributes([.foregroundColor: NSColor.labelColor, .font: NSFont.boldSystemFont(ofSize: 11),
                                    .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.5)], range: hit)
            }
            s.append(body)
            text.attributedStringValue = s
        }
        return cell
    }
}

extension DocumentWindowController {

    /// Replaces the whole text as one undoable edit (used by folder-wide replace).
    func replaceAllText(with text: String) {
        let selection = editor.selectedRange()
        editor.replace(NSRange(location: 0, length: (editor.string as NSString).length), with: text,
                       select: NSRange(location: min(selection.location, (text as NSString).length), length: 0))
    }

    /// Selects a range in the editor and shows it (search results, outline).
    func reveal(range: NSRange) {
        if mode == .preview { setMode(.split) }
        window?.makeFirstResponder(editor)
        let length = (editor.string as NSString).length
        let clipped = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
        editor.setSelectedRange(clipped)
        editor.scrollRangeToVisible(clipped)
        editor.showFindIndicator(for: clipped)
    }

    func openSearchResult(_ url: URL, _ range: NSRange) {
        if url.standardizedFileURL == markdownDocument?.fileURL?.standardizedFileURL {
            reveal(range: range)
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, _ in
            DispatchQueue.main.async {
                (document as? MarkdownDocument)?.windowController?.reveal(range: range)
            }
        }
    }

    @objc func showFolderSearch(_ sender: Any?) {
        setSidebarVisible(true)
        sidebar.selectedTab = 2
        sidebar.searchView.focusSearchField()
    }
}
