import AppKit
import MarkDownerCore

/// Sheet for inserting citations: search the document's bibliography, or add a reference by DOI / PubMed ID.
final class CitationPickerController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private weak var windowController: DocumentWindowController?
    private var entries: [BibEntry] = []
    private var filtered: [BibEntry] = []
    private var bibliographyURLs: [URL] = []

    private let search = NSSearchField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let lookupField = NSTextField()
    private let lookupButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let insertButton = NSButton()
    private let locatorField = NSTextField()

    /// Called with the Markdown to insert.
    var onInsert: ((String) -> Void)?

    init(windowController: DocumentWindowController) {
        self.windowController = windowController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 460))

        let title = NSTextField(labelWithString: L("cite.title", "Insert Citation"))
        title.font = .boldSystemFont(ofSize: 14)

        search.placeholderString = L("cite.search", "Search author, title, year or key")
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)

        for (id, title, width) in [("key", L("cite.key", "Key"), 120.0), ("source", L("cite.source", "Authors, year"), 170.0),
                                   ("title", L("cite.titleColumn", "Title"), 320.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(insert)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        locatorField.placeholderString = L("cite.locator", "Page (optional), e.g. p. 33")

        lookupField.placeholderString = L("cite.lookupPlaceholder", "DOI or PubMed ID, e.g. 10.1056/… or 33301246")
        lookupField.target = self
        lookupField.action = #selector(lookup)
        lookupButton.title = L("cite.lookup", "Fetch and Add")
        lookupButton.bezelStyle = .rounded
        lookupButton.target = self
        lookupButton.action = #selector(lookup)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: L("button.cancel", "Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        insertButton.title = L("cite.insert", "Insert")
        insertButton.bezelStyle = .rounded
        insertButton.keyEquivalent = "\r"
        insertButton.target = self
        insertButton.action = #selector(insert)

        let lookupRow = NSStackView(views: [lookupField, lookupButton, spinner])
        lookupRow.spacing = 8
        let buttons = NSStackView(views: [statusLabel, NSView(), cancel, insertButton])
        buttons.spacing = 8

        for v in [title, search, scroll, emptyLabel, locatorField, lookupRow, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            search.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 40),
            emptyLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -40),
            locatorField.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            locatorField.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            locatorField.widthAnchor.constraint(equalToConstant: 260),
            lookupRow.topAnchor.constraint(equalTo: locatorField.bottomAnchor, constant: 14),
            lookupRow.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            lookupRow.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: lookupRow.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
        ])
        view = root
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(entries.isEmpty ? lookupField : search)
    }

    // MARK: Data

    func reload() {
        guard let wc = windowController else { return }
        let fm = MarkdownParser.frontMatter(of: wc.editor.string)
        bibliographyURLs = DocumentProcessor.bibliographyURLs(frontMatter: fm, options: wc.processingOptions)
        var all: [BibEntry] = []
        var problems: [String] = []
        for url in bibliographyURLs {
            do { all += try Bibliography.load(url) } catch { problems.append(error.localizedDescription) }
        }
        entries = all
        applyFilter()
        if bibliographyURLs.isEmpty {
            emptyLabel.stringValue = L("cite.noBibliography",
                                       "No bibliography yet. Fetch a reference by DOI or PubMed ID below: it is saved to references.bib next to the document. You can also name a .bib or CSL-JSON file in the front matter (bibliography: refs.bib) or in Settings.")
        } else if let problem = problems.first {
            emptyLabel.stringValue = problem
        } else {
            emptyLabel.stringValue = L("cite.empty", "The bibliography is empty.")
        }
        statusLabel.stringValue = bibliographyURLs.map(\.lastPathComponent).joined(separator: ", ")
    }

    private func applyFilter() {
        let terms = search.stringValue.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split(separator: " ").map(String.init)
        filtered = terms.isEmpty ? entries : entries.filter { e in
            let haystack = ([e.id, e.title, e.year, e.container] + e.authors.map { $0.literal ?? "\($0.family) \($0.given)" })
                .joined(separator: " ").lowercased().folding(options: .diacriticInsensitive, locale: nil)
            return terms.allSatisfy { haystack.contains($0) }
        }
        table.reloadData()
        if !filtered.isEmpty, table.selectedRow < 0 { table.selectRowIndexes([0], byExtendingSelection: false) }
        emptyLabel.isHidden = !entries.isEmpty
        insertButton.isEnabled = !filtered.isEmpty
    }

    @objc private func searchChanged() { applyFilter() }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === search { applyFilter() }
    }

    /// Arrow keys in the search field move the table selection.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === search else { return false }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = max(0, min(filtered.count - 1, table.selectedRow + delta))
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) { insert(); return true }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = filtered[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let cell = tableView.makeView(withIdentifier: .init("cite-" + id), owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("cite-" + id)
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingTail
            t.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(t)
            c.textField = t
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        switch id {
        case "key":
            cell.textField?.stringValue = e.id
            cell.textField?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        case "source":
            let names = e.authors.prefix(2).map { $0.literal ?? $0.family }.joined(separator: ", ")
            cell.textField?.stringValue = (e.authors.count > 2 ? names + " et al." : names) + (e.year.isEmpty ? "" : " (\(e.year))")
        default:
            cell.textField?.stringValue = e.title
            cell.textField?.toolTip = [e.title, e.container].filter { !$0.isEmpty }.joined(separator: " — ")
        }
        return cell
    }

    // MARK: Actions

    @objc private func cancel() {
        closeSheet()
    }

    private func closeSheet() {
        guard let sheet = view.window else { return }
        sheet.sheetParent?.endSheet(sheet)
    }

    @objc private func insert() {
        let rows = table.selectedRowIndexes.isEmpty && table.clickedRow >= 0 ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        let keys = rows.compactMap { $0 < filtered.count ? filtered[$0].id : nil }
        guard !keys.isEmpty else { NSSound.beep(); return }
        let locator = locatorField.stringValue.trimmingCharacters(in: .whitespaces)
        var items = keys.map { "@" + $0 }
        if !locator.isEmpty { items[items.count - 1] += ", " + locator }
        closeSheet()
        onInsert?("[" + items.joined(separator: "; ") + "]")
    }

    @objc private func lookup() {
        guard let id = ReferenceLookup.identifier(from: lookupField.stringValue) else {
            statusLabel.stringValue = ReferenceLookup.LookupError.notAnIdentifier.localizedDescription
            NSSound.beep()
            return
        }
        guard let target = targetBibliography() else { return }
        spinner.startAnimation(nil)
        lookupButton.isEnabled = false
        statusLabel.stringValue = L("cite.fetching", "Fetching…")
        Task { @MainActor in
            defer {
                spinner.stopAnimation(nil)
                lookupButton.isEnabled = true
            }
            do {
                var entry = try await ReferenceLookup.fetch(id)
                // Already in the bibliography?
                if let existing = entries.first(where: { e in
                    (!entry.doi.isEmpty && e.doi.lowercased() == entry.doi.lowercased()) || (!entry.pmid.isEmpty && e.pmid == entry.pmid)
                }) {
                    statusLabel.stringValue = LF("cite.exists", "Already in the bibliography as @%@.", existing.id)
                    select(key: existing.id)
                    return
                }
                entry.id = Bibliography.makeKey(for: entry, existing: Set(entries.map(\.id)))
                try ReferenceLookup.append(entry, to: target)
                windowController?.ensureBibliographyInFrontMatter(target)
                reload()
                select(key: entry.id)
                lookupField.stringValue = ""
                statusLabel.stringValue = LF("cite.added", "Added @%@ to %@.", entry.id, target.lastPathComponent)
            } catch {
                statusLabel.stringValue = error.localizedDescription
                NSSound.beep()
            }
        }
    }

    private func select(key: String) {
        search.stringValue = ""
        applyFilter()
        if let row = filtered.firstIndex(where: { $0.id == key }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    /// The file new references are written to; `references.bib` next to the document when none is set.
    private func targetBibliography() -> URL? {
        if let first = bibliographyURLs.first { return first }
        guard let folder = windowController?.markdownDocument?.fileURL?.deletingLastPathComponent() else {
            statusLabel.stringValue = L("cite.saveFirst", "Save the document first, so the bibliography can be stored next to it.")
            NSSound.beep()
            return nil
        }
        return folder.appendingPathComponent("references.bib")
    }
}

extension DocumentWindowController {

    @objc func insertCitation(_ sender: Any?) {
        guard mode != .preview else { setMode(.split); return insertCitation(sender) }
        let picker = CitationPickerController(windowController: self)
        let range = editor.selectedRange()
        let originalLength = (editor.string as NSString).length
        picker.onInsert = { [weak self] markdown in
            guard let self else { return }
            // A bibliography line may have been added to the front matter meanwhile
            let delta = (self.editor.string as NSString).length - originalLength
            let target = NSRange(location: min(range.location + max(0, delta), (self.editor.string as NSString).length), length: range.length)
            self.window?.makeFirstResponder(self.editor)
            self.editor.replace(target, with: markdown)
        }
        presentSheet(picker)
    }

    /// Shows a view controller as a sheet on the document window.
    func presentSheet(_ controller: NSViewController) {
        guard let window else { return }
        let sheet = NSWindow(contentViewController: controller)
        sheet.styleMask = [.titled, .resizable]
        window.beginSheet(sheet, completionHandler: nil)
    }

    /// Adds `bibliography: <file>` to the front matter unless the document already uses that file.
    func ensureBibliographyInFrontMatter(_ url: URL) {
        let text = editor.string
        let fm = MarkdownParser.frontMatter(of: text)
        let current = DocumentProcessor.bibliographyURLs(frontMatter: fm, options: processingOptions)
        if current.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { return }
        let name = url.deletingLastPathComponent().standardizedFileURL == markdownDocument?.baseDirectory?.standardizedFileURL
            ? url.lastPathComponent : url.path
        let line = "bibliography: \(name)"
        let ns = text as NSString
        if text.hasPrefix("---"), !fm.isEmpty {
            let firstLine = ns.lineRange(for: NSRange(location: 0, length: 0))
            editor.replace(NSRange(location: NSMaxRange(firstLine), length: 0), with: line + "\n",
                           select: NSRange(location: 0, length: 0))
        } else {
            editor.replace(NSRange(location: 0, length: 0), with: "---\n\(line)\n---\n\n", select: NSRange(location: 0, length: 0))
        }
    }
}
