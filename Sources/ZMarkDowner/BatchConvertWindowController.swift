import AppKit
import MarkDownerCore

/// Converts many files at once (e.g. a folder of Word documents to Markdown).
final class BatchConvertWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private var files: [URL] = []
    private var results: [URL: String] = [:]
    private let table = NSTableView()
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let destinationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let convertButton = NSButton()
    private var destination: URL?
    private var running = false

    private let formats = DocumentConverter.Format.allCases

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("batch.title", "Batch Convert")
        window.minSize = NSSize(width: 520, height: 340)
        self.init(window: window)
        build()
        window.center()
    }

    private func build() {
        guard let content = window?.contentView else { return }

        let col1 = NSTableColumn(identifier: .init("file"))
        col1.title = L("batch.file", "File")
        col1.width = 340
        let col2 = NSTableColumn(identifier: .init("status"))
        col2.title = L("batch.status", "Status")
        col2.width = 200
        table.addTableColumn(col1)
        table.addTableColumn(col2)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.registerForDraggedTypes([.fileURL])
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let addFiles = NSButton(title: L("batch.addFiles", "Add Files…"), target: self, action: #selector(addFiles))
        let addFolder = NSButton(title: L("batch.addFolder", "Add Folder…"), target: self, action: #selector(addFolder))
        let clear = NSButton(title: L("button.clear", "Clear"), target: self, action: #selector(clearList))

        formatPopup.addItems(withTitles: [
            "Markdown (.md)", "HTML (.html)", "PDF (.pdf)", "Word (.docx)", "EPUB (.epub)",
        ])
        destinationPopup.addItems(withTitles: [L("batch.sameFolder", "Next to the original files"), L("batch.chooseFolder", "Choose Folder…")])
        destinationPopup.target = self
        destinationPopup.action = #selector(destinationChanged)

        convertButton.title = L("batch.convert", "Convert")
        convertButton.bezelStyle = .push
        convertButton.keyEquivalent = "\r"
        convertButton.target = self
        convertButton.action = #selector(convert)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = L("batch.hint", "Add DOCX, DOC, RTF, TXT or MD files (or drop them here).")

        let buttons = NSStackView(views: [addFiles, addFolder, clear])
        let formatRow = NSStackView(views: [NSTextField(labelWithString: L("batch.format", "Convert to:")), formatPopup,
                                            NSTextField(labelWithString: L("batch.destination", "Save:")), destinationPopup])
        let bottom = NSStackView(views: [progress, convertButton])
        let stack = NSStackView(views: [buttons, scroll, formatRow, statusLabel, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: Adding files

    private func add(_ urls: [URL]) {
        files = Self.collect(urls, adding: files)
        table.reloadData()
        statusLabel.stringValue = LF("batch.count", "%d files", files.count)
    }

    /// `existing` followed by the new files: explicitly chosen files of any importable format (PDF too),
    /// and from folders only the formats opened as documents (PDFs inside folders are skipped).
    static func collect(_ urls: [URL], adding existing: [URL]) -> [URL] {
        var files = existing
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let item = enumerator?.nextObject() as? URL {
                    if DocumentImporter.supportedExtensions.contains(item.pathExtension.lowercased()), !files.contains(item) {
                        files.append(item)
                    }
                }
            } else if DocumentImporter.importableExtensions.contains(url.pathExtension.lowercased()), !files.contains(url) {
                files.append(url)
            }
        }
        return files
    }

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = DocumentImporter.importableExtensions.compactMap { .init(filenameExtension: $0) }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] r in if r == .OK { self?.add(panel.urls) } }
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] r in if r == .OK { self?.add(panel.urls) } }
    }

    @objc private func clearList() {
        guard !running else { return }
        files = []
        results = [:]
        table.reloadData()
    }

    @objc private func destinationChanged() {
        guard destinationPopup.indexOfSelectedItem == 1, let window else { destination = nil; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            if r == .OK, let url = panel.url {
                self.destination = url
                self.destinationPopup.item(at: 1)?.title = url.lastPathComponent
            } else {
                self.destination = nil
                self.destinationPopup.selectItem(at: 0)
            }
        }
    }

    // MARK: Converting

    @objc private func convert() {
        guard !running, !files.isEmpty else { NSSound.beep(); return }
        running = true
        convertButton.isEnabled = false
        results = [:]
        progress.maxValue = Double(files.count)
        progress.doubleValue = 0
        let format = formats[formatPopup.indexOfSelectedItem]
        let options = Settings.shared.exportOptions(title: "", baseURL: nil)
        let list = files
        let destination = self.destination
        Task { @MainActor in
            var ok = 0
            for url in list {
                do {
                    let out = try await DocumentConverter.convert(url, to: format, into: destination ?? url.deletingLastPathComponent(), options: options)
                    results[url] = "✓ " + out.lastPathComponent
                    ok += 1
                } catch {
                    results[url] = "✗ " + error.localizedDescription
                }
                progress.doubleValue += 1
                table.reloadData()
            }
            running = false
            convertButton.isEnabled = true
            statusLabel.stringValue = LF("batch.done", "Done: %d of %d files converted.", ok, list.count)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let text = NSTextField(labelWithString: id == "file" ? files[row].lastPathComponent : (results[files[row]] ?? ""))
        text.lineBreakMode = .byTruncatingMiddle
        text.toolTip = id == "file" ? files[row].path : results[files[row]]
        return text
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        add(urls)
        return !urls.isEmpty
    }
}
