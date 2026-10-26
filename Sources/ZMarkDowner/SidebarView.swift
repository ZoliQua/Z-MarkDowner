import AppKit
import MarkDownerCore

/// Left sidebar: document outline (headings) and a folder browser.
final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {

    struct Heading: Equatable {
        var level: Int
        var text: String
        var line: Int
    }

    /// Called when a heading is chosen (source line).
    var onSelectHeading: ((Int) -> Void)?

    private let tabs = NSSegmentedControl()
    private let outlineScroll = NSScrollView()
    private let outlineTable = NSTableView()
    private let filesScroll = NSScrollView()
    private let filesOutline = NSOutlineView()
    private let folderButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")

    private var headings: [Heading] = []
    private var currentHeadingIndex: Int?
    private var rootNode: FileNode?
    var currentFile: URL? { didSet { filesOutline.reloadData() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        tabs.segmentCount = 2
        tabs.setLabel(L("sidebar.outline", "Outline"), forSegment: 0)
        tabs.setLabel(L("sidebar.files", "Files"), forSegment: 1)
        tabs.trackingMode = .selectOne
        tabs.segmentStyle = .automatic
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = Settings.shared.sidebarTab
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Outline
        let col = NSTableColumn(identifier: .init("heading"))
        outlineTable.addTableColumn(col)
        outlineTable.headerView = nil
        outlineTable.style = .sourceList
        outlineTable.rowSizeStyle = .default
        outlineTable.dataSource = self
        outlineTable.delegate = self
        outlineTable.target = self
        outlineTable.action = #selector(headingClicked)
        outlineTable.backgroundColor = .clear
        outlineScroll.documentView = outlineTable
        outlineScroll.drawsBackground = false
        outlineScroll.hasVerticalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false

        // Files
        let fcol = NSTableColumn(identifier: .init("file"))
        filesOutline.addTableColumn(fcol)
        filesOutline.outlineTableColumn = fcol
        filesOutline.headerView = nil
        filesOutline.style = .sourceList
        filesOutline.dataSource = self
        filesOutline.delegate = self
        filesOutline.target = self
        filesOutline.doubleAction = #selector(fileDoubleClicked)
        filesOutline.backgroundColor = .clear
        filesScroll.documentView = filesOutline
        filesScroll.drawsBackground = false
        filesScroll.hasVerticalScroller = true
        filesScroll.autohidesScrollers = true
        filesScroll.translatesAutoresizingMaskIntoConstraints = false

        folderButton.bezelStyle = .accessoryBarAction
        folderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folderButton.imagePosition = .imageLeading
        folderButton.title = L("sidebar.chooseFolder", "Choose Folder…")
        folderButton.lineBreakMode = .byTruncatingMiddle
        folderButton.target = self
        folderButton.action = #selector(chooseFolder)
        folderButton.translatesAutoresizingMaskIntoConstraints = false
        folderButton.toolTip = L("sidebar.chooseFolder", "Choose Folder…")

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.stringValue = L("sidebar.noHeadings", "No headings")

        for v in [tabs, outlineScroll, filesScroll, folderButton, emptyLabel] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            outlineScroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            outlineScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            folderButton.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            folderButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            folderButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            filesScroll.topAnchor.constraint(equalTo: folderButton.bottomAnchor, constant: 4),
            filesScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            filesScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            filesScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: outlineScroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: outlineScroll.topAnchor, constant: 24),
        ])
        updateTab()
    }

    var selectedTab: Int {
        get { tabs.selectedSegment }
        set { tabs.selectedSegment = newValue; updateTab() }
    }

    @objc private func tabChanged() {
        Settings.shared.sidebarTab = tabs.selectedSegment
        updateTab()
    }

    private func updateTab() {
        let files = tabs.selectedSegment == 1
        outlineScroll.isHidden = files
        emptyLabel.isHidden = files || !headings.isEmpty
        filesScroll.isHidden = !files
        folderButton.isHidden = !files
        if files && rootNode == nil, let folder = Settings.shared.sidebarFolder ?? currentFile?.deletingLastPathComponent() {
            setFolder(folder)
        }
    }

    // MARK: Outline

    func setHeadings(_ new: [Heading]) {
        guard new != headings else { return }
        headings = new
        outlineTable.reloadData()
        emptyLabel.isHidden = tabs.selectedSegment == 1 || !headings.isEmpty
    }

    /// Highlights the heading that contains the given source line.
    func highlightHeading(forLine line: Int) {
        let index = headings.lastIndex { $0.line <= line }
        guard index != currentHeadingIndex else { return }
        currentHeadingIndex = index
        if let index {
            outlineTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            outlineTable.scrollRowToVisible(index)
        } else {
            outlineTable.deselectAll(nil)
        }
    }

    @objc private func headingClicked() {
        let row = outlineTable.clickedRow
        guard row >= 0, row < headings.count else { return }
        currentHeadingIndex = row
        onSelectHeading?(headings[row].line)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { headings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let h = headings[row]
        let cell = tableView.makeView(withIdentifier: .init("HeadingCell"), owner: self) as? IndentedCell ?? IndentedCell()
        cell.identifier = .init("HeadingCell")
        cell.label.stringValue = h.text
        cell.label.font = h.level == 1 ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: h.level == 2 ? 13 : 12)
        cell.label.textColor = h.level <= 2 ? .labelColor : .secondaryLabelColor
        cell.indent = CGFloat(h.level - 1) * 12
        return cell
    }

    // MARK: Files

    func setFolder(_ url: URL) {
        rootNode = FileNode(url: url, isDirectory: true)
        folderButton.title = url.lastPathComponent
        folderButton.toolTip = url.path
        filesOutline.reloadData()
        filesOutline.expandItem(nil)
    }

    /// Follows the current document's folder unless the user picked a folder.
    func documentFolderChanged(_ folder: URL?) {
        guard Settings.shared.sidebarFolder == nil, let folder else { return }
        if rootNode?.url.standardizedFileURL != folder.standardizedFileURL { setFolder(folder) }
    }

    func reloadFiles() {
        rootNode?.reset()
        filesOutline.reloadData()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("button.choose", "Choose")
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Settings.shared.sidebarFolder = url
            self?.setFolder(url)
        }
    }

    @objc private func fileDoubleClicked() {
        guard let node = filesOutline.item(atRow: filesOutline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            filesOutline.isItemExpanded(node) ? filesOutline.collapseItem(node) : filesOutline.expandItem(node)
        } else {
            NSDocumentController.shared.openDocument(withContentsOf: node.url, display: true) { _, _, _ in }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FileNode) ?? rootNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? rootNode)!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("FileCell"), owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("FileCell")
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(image); c.addSubview(text)
            c.imageView = image; c.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = node.url.lastPathComponent
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        let isCurrent = currentFile?.standardizedFileURL == node.url.standardizedFileURL
        cell.textField?.font = isCurrent ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        return cell
    }
}

/// Table cell with adjustable leading indentation.
final class IndentedCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    var indent: CGFloat = 0 { didSet { leading.constant = 4 + indent } }

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Lazily loaded file system node (only folders and supported documents are listed).
final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    private var loaded: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    func reset() { loaded = nil }

    var children: [FileNode] {
        if let loaded { return loaded }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        var result: [FileNode] = []
        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let dir = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            if dir || DocumentImporter.supportedExtensions.contains(item.pathExtension.lowercased()) {
                result.append(FileNode(url: item, isDirectory: dir))
            }
        }
        result.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        loaded = result
        return result
    }
}
