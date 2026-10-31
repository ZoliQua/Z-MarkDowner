import AppKit
import UniformTypeIdentifiers
import MarkDownerCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let services = ServiceProvider()
    private var preferences: PreferencesWindowController?
    private var batch: BatchConvertWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        Settings.shared.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        NSApp.activate(ignoringOtherApps: true)
        SelfTest.startIfRequested()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        ProcessInfo.processInfo.environment["ZMD_SELFTEST_IN"] == nil
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Actions

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString()
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: center,
                                                   .foregroundColor: NSColor.labelColor]
        credits.append(NSAttributedString(string: L("about.tagline", "Native Markdown editor for macOS") + "\n\n", attributes: base))
        credits.append(NSAttributedString(string: L("about.author", "Author") + ": ", attributes: base))
        credits.append(NSAttributedString(string: "Dr. Dul Zoltán\n", attributes: base.merging([.font: NSFont.boldSystemFont(ofSize: 11)]) { $1 }))
        credits.append(NSAttributedString(string: "GitHub: ", attributes: base))
        credits.append(NSAttributedString(string: "ZoliQua", attributes: base.merging([.link: URL(string: "https://github.com/ZoliQua")!]) { $1 }))
        credits.append(NSAttributedString(string: "\n", attributes: base))
        credits.append(NSAttributedString(string: "github.com/ZoliQua/Z-MarkDowner",
                                          attributes: base.merging([.link: URL(string: "https://github.com/ZoliQua/Z-MarkDowner")!]) { $1 }))
        credits.append(NSAttributedString(string: "\n\n" + L("about.license", "BSD 3-Clause License"),
                                          attributes: base.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .init(rawValue: "Copyright"): "© 2026 Dr. Dul Zoltán",
        ])
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferences == nil { preferences = PreferencesWindowController() }
        preferences?.showWindow(sender)
        preferences?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func showBatchConvert(_ sender: Any?) {
        if batch == nil { batch = BatchConvertWindowController() }
        batch?.showWindow(sender)
        batch?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func importDocument(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }

    /// Compares two files of any importable type (the older one is the old version).
    @objc func compareDocuments(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = (DocumentImporter.supportedExtensions.union(["tex", "ltx"]))
            .sorted().compactMap { UTType(filenameExtension: $0) }
        panel.message = L("compare.chooseTwo", "Choose two documents to compare (or the old version first).")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var urls = Array(panel.urls.prefix(2))
        if urls.count == 1 {
            panel.allowsMultipleSelection = false
            panel.message = L("compare.chooseNew", "Choose the new version.")
            guard panel.runModal() == .OK, let second = panel.url else { return }
            urls.append(second)
        } else {
            func date(_ url: URL) -> Date {
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            }
            urls.sort { date($0) < date($1) }
        }
        let (oldURL, newURL) = (urls[0], urls[1])
        Task { @MainActor in
            do {
                let old = try await DiffWindowController.text(ofFileAt: oldURL)
                let new = try await DiffWindowController.text(ofFileAt: newURL)
                let latex = [oldURL, newURL].contains { SourceFormat(fileExtension: $0.pathExtension) == .latex }
                DiffWindowController.show(oldTitle: oldURL.lastPathComponent, old: old, newTitle: newURL.lastPathComponent, new: new,
                                          allowsReviewMarks: !latex, baseURL: newURL.deletingLastPathComponent())
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc func showMarkdownHelp(_ sender: Any?) {
        let doc = MarkdownDocument()
        doc.text = MarkdownHelp.text
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        doc.windowController?.setMode(.split, remember: false)
    }

    @objc func openProjectPage(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/ZoliQua/Z-MarkDowner")!)
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = "Z-MarkDowner"
        typealias E = EditorTextView
        typealias W = DocumentWindowController

        // App menu
        let app = submenu(main, appName)
        app.addItem(withTitle: LF("menu.about", "About %@", appName), action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("menu.settings", "Settings…"), action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        let services = NSMenu(title: L("menu.services", "Services"))
        app.addItem(withTitle: L("menu.services", "Services"), action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: LF("menu.hide", "Hide %@", appName), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(item(L("menu.hideOthers", "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(withTitle: L("menu.showAll", "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: LF("menu.quit", "Quit %@", appName), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let file = submenu(main, L("menu.file", "File"))
        file.addItem(withTitle: L("menu.new", "New"), action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: L("menu.open", "Open…"), action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: L("menu.openRecent", "Open Recent"))
        recent.addItem(withTitle: L("menu.clearRecent", "Clear Menu"), action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("menu.openRecent", "Open Recent"), action: nil, keyEquivalent: "").submenu = recent
        file.addItem(item(L("menu.import", "Import (DOCX, DOC, RTF, TXT, MD)…"), #selector(AppDelegate.importDocument(_:)), "i", [.command, .shift]))
        file.addItem(withTitle: L("menu.batch", "Batch Convert…"), action: #selector(AppDelegate.showBatchConvert(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: L("menu.compareDocuments", "Compare Documents…"), action: #selector(AppDelegate.compareDocuments(_:)), keyEquivalent: "")
        let compare = NSMenu(title: L("menu.compareWith", "Compare With"))
        compare.addItem(withTitle: L("menu.lastSaved", "Last Saved Version"), action: #selector(W.compareWithSaved(_:)), keyEquivalent: "")
        compare.addItem(withTitle: L("menu.earlierVersion", "Earlier Version…"), action: #selector(W.compareWithVersion(_:)), keyEquivalent: "")
        compare.addItem(withTitle: L("menu.clipboard", "Clipboard"), action: #selector(W.compareWithClipboard(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("menu.compareWith", "Compare With"), action: nil, keyEquivalent: "").submenu = compare
        file.addItem(.separator())
        file.addItem(withTitle: L("menu.importReview", "Import Review Comments from PDF…"), action: #selector(W.importReviewComments(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("menu.exportResponse", "Export Response to Reviewers…"), action: #selector(W.exportResponseLetter(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: L("menu.close", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: L("menu.save", "Save…"), action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        file.addItem(item(L("menu.duplicate", "Duplicate"), #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        file.addItem(withTitle: L("menu.rename", "Rename…"), action: #selector(NSDocument.rename(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("menu.moveTo", "Move To…"), action: #selector(NSDocument.move(_:)), keyEquivalent: "")
        file.addItem(item(L("menu.saveAs", "Save As…"), #selector(NSDocument.saveAs(_:)), "s", [.command, .shift, .option]))
        let revert = NSMenu(title: L("menu.revertTo", "Revert To"))
        revert.addItem(withTitle: L("menu.lastSaved", "Last Saved Version"), action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        revert.addItem(withTitle: L("menu.browseVersions", "Browse All Versions…"), action: #selector(NSDocument.browseVersions(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("menu.revertTo", "Revert To"), action: nil, keyEquivalent: "").submenu = revert
        file.addItem(.separator())
        let export = NSMenu(title: L("menu.export", "Export"))
        export.addItem(item(L("menu.exportPDF", "Export as PDF…"), #selector(W.exportPDF(_:)), "e", [.command, .shift]))
        export.addItem(item(L("menu.exportDOCX", "Export as Word (DOCX)…"), #selector(W.exportDOCX(_:)), "d", [.command, .shift]))
        export.addItem(withTitle: L("menu.exportHTML", "Export as HTML…"), action: #selector(W.exportHTML(_:)), keyEquivalent: "")
        export.addItem(withTitle: L("menu.exportEPUB", "Export as EPUB…"), action: #selector(W.exportEPUB(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("menu.export", "Export"), action: nil, keyEquivalent: "").submenu = export
        file.addItem(.separator())
        file.addItem(item(L("menu.pageSetup", "Page Setup…"), #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]))
        file.addItem(withTitle: L("menu.print", "Print…"), action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")

        // Edit
        let edit = submenu(main, L("menu.edit", "Edit"))
        edit.addItem(withTitle: L("menu.undo", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(item(L("menu.redo", "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(withTitle: L("menu.cut", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("menu.copy", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(item(L("menu.copyRich", "Copy as Formatted Text"), #selector(E.copyAsRichText(_:)), "c", [.command, .option, .shift]))
        edit.addItem(withTitle: L("menu.paste", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(item(L("menu.pasteMarkdown", "Paste as Markdown (Word, web)"), #selector(E.pasteAsMarkdown(_:)), "v", [.command, .option, .shift]))
        edit.addItem(withTitle: L("menu.delete", "Delete"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: L("menu.selectAll", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: L("menu.find", "Find"))
        find.addItem(findItem(L("menu.findDots", "Find…"), .showFindInterface, "f", [.command]))
        find.addItem(findItem(L("menu.findReplace", "Find and Replace…"), .showReplaceInterface, "f", [.command, .option]))
        find.addItem(findItem(L("menu.findNext", "Find Next"), .nextMatch, "g", [.command]))
        find.addItem(findItem(L("menu.findPrevious", "Find Previous"), .previousMatch, "g", [.command, .shift]))
        find.addItem(findItem(L("menu.useSelection", "Use Selection for Find"), .setSearchString, "e", [.command]))
        find.addItem(.separator())
        find.addItem(item(L("menu.searchFolder", "Search in Folder…"), #selector(W.showFolderSearch(_:)), "f", [.command, .option, .shift]))
        edit.addItem(withTitle: L("menu.find", "Find"), action: nil, keyEquivalent: "").submenu = find
        let review = NSMenu(title: L("menu.review", "Review"))
        review.addItem(item(L("menu.insertComment", "Insert Comment"), #selector(E.insertComment(_:)), "k", [.command, .shift]))
        review.addItem(withTitle: L("menu.markInsertion", "Mark as Insertion"), action: #selector(E.markAsInsertion(_:)), keyEquivalent: "")
        review.addItem(withTitle: L("menu.markDeletion", "Mark as Deletion"), action: #selector(E.markAsDeletion(_:)), keyEquivalent: "")
        review.addItem(.separator())
        review.addItem(withTitle: L("menu.nextChange", "Next Change"), action: #selector(E.selectNextChange(_:)), keyEquivalent: "")
        review.addItem(withTitle: L("menu.previousChange", "Previous Change"), action: #selector(E.selectPreviousChange(_:)), keyEquivalent: "")
        review.addItem(withTitle: L("menu.acceptChange", "Accept Change"), action: #selector(E.acceptChange(_:)), keyEquivalent: "")
        review.addItem(withTitle: L("menu.rejectChange", "Reject Change"), action: #selector(E.rejectChange(_:)), keyEquivalent: "")
        review.addItem(.separator())
        review.addItem(withTitle: L("menu.acceptAll", "Accept All Changes"), action: #selector(E.acceptAllChanges(_:)), keyEquivalent: "")
        review.addItem(withTitle: L("menu.rejectAll", "Reject All Changes"), action: #selector(E.rejectAllChanges(_:)), keyEquivalent: "")
        review.addItem(withTitle: L("menu.removeComments", "Delete All Comments"), action: #selector(E.removeAllComments(_:)), keyEquivalent: "")
        edit.addItem(withTitle: L("menu.review", "Review"), action: nil, keyEquivalent: "").submenu = review
        let spelling = NSMenu(title: L("menu.spelling", "Spelling and Grammar"))
        spelling.addItem(withTitle: L("menu.showSpelling", "Show Spelling and Grammar"), action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        spelling.addItem(withTitle: L("menu.checkNow", "Check Document Now"), action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
        spelling.addItem(withTitle: L("menu.checkWhileTyping", "Check Spelling While Typing"), action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        edit.addItem(withTitle: L("menu.spelling", "Spelling and Grammar"), action: nil, keyEquivalent: "").submenu = spelling
        edit.addItem(.separator())
        edit.addItem(item(L("menu.emoji", "Emoji & Symbols"), #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]))

        // Format
        let format = submenu(main, L("menu.format", "Format"))
        format.addItem(item(L("menu.bold", "Bold"), #selector(E.formatBold(_:)), "b", [.command]))
        format.addItem(item(L("menu.italic", "Italic"), #selector(E.formatItalic(_:)), "i", [.command]))
        format.addItem(item(L("menu.strike", "Strikethrough"), #selector(E.formatStrikethrough(_:)), "x", [.command, .shift]))
        format.addItem(item(L("menu.inlineCode", "Inline Code"), #selector(E.formatInlineCode(_:)), "`", [.command]))
        format.addItem(.separator())
        let headings = NSMenu(title: L("menu.heading", "Heading"))
        headings.addItem(item(L("menu.normalText", "Normal Text"), #selector(E.formatParagraph(_:)), "0", [.command, .option]))
        let headingActions: [Selector] = [
            #selector(E.formatHeading1(_:)), #selector(E.formatHeading2(_:)), #selector(E.formatHeading3(_:)),
            #selector(E.formatHeading4(_:)), #selector(E.formatHeading5(_:)), #selector(E.formatHeading6(_:)),
        ]
        for (i, action) in headingActions.enumerated() {
            headings.addItem(item(LF("menu.headingN", "Heading %d", i + 1), action, "\(i + 1)", [.command, .option]))
        }
        format.addItem(withTitle: L("menu.heading", "Heading"), action: nil, keyEquivalent: "").submenu = headings
        format.addItem(.separator())
        format.addItem(item(L("menu.bulletList", "Bulleted List"), #selector(E.formatBulletList(_:)), "8", [.command, .shift]))
        format.addItem(item(L("menu.numberedList", "Numbered List"), #selector(E.formatNumberedList(_:)), "7", [.command, .shift]))
        format.addItem(item(L("menu.taskList", "Task List"), #selector(E.formatTaskList(_:)), "9", [.command, .shift]))
        format.addItem(item(L("menu.quote", "Quote"), #selector(E.formatQuote(_:)), "'", [.command, .shift]))
        format.addItem(.separator())
        format.addItem(item(L("menu.insertLink", "Insert Link"), #selector(E.insertLink(_:)), "k", [.command]))
        format.addItem(withTitle: L("menu.insertImage", "Insert Image…"), action: #selector(E.insertImage(_:)), keyEquivalent: "")
        format.addItem(item(L("menu.insertCodeBlock", "Insert Code Block"), #selector(E.insertCodeBlock(_:)), "c", [.command, .option]))
        format.addItem(withTitle: L("menu.insertFootnote", "Insert Footnote"), action: #selector(E.insertFootnote(_:)), keyEquivalent: "")
        format.addItem(withTitle: L("menu.insertRule", "Insert Horizontal Rule"), action: #selector(E.insertHorizontalRule(_:)), keyEquivalent: "")
        let table = NSMenu(title: L("menu.table", "Table"))
        table.addItem(item(L("menu.insertTable", "Insert Table"), #selector(E.insertTable(_:)), "t", [.command, .option]))
        table.addItem(item(L("menu.formatTable", "Align Table"), #selector(E.formatTable(_:)), "t", [.command, .option, .shift]))
        table.addItem(.separator())
        table.addItem(withTitle: L("menu.tableRow", "Insert Row Below"), action: #selector(E.tableInsertRow(_:)), keyEquivalent: "")
        table.addItem(withTitle: L("menu.tableColumn", "Insert Column Right"), action: #selector(E.tableInsertColumn(_:)), keyEquivalent: "")
        table.addItem(withTitle: L("menu.tableDeleteRow", "Delete Row"), action: #selector(E.tableDeleteRow(_:)), keyEquivalent: "")
        table.addItem(withTitle: L("menu.tableDeleteColumn", "Delete Column"), action: #selector(E.tableDeleteColumn(_:)), keyEquivalent: "")
        table.addItem(.separator())
        table.addItem(withTitle: L("menu.alignLeft", "Align Column Left"), action: #selector(E.tableAlignLeft(_:)), keyEquivalent: "")
        table.addItem(withTitle: L("menu.alignCenter", "Align Column Center"), action: #selector(E.tableAlignCenter(_:)), keyEquivalent: "")
        table.addItem(withTitle: L("menu.alignRight", "Align Column Right"), action: #selector(E.tableAlignRight(_:)), keyEquivalent: "")
        format.addItem(withTitle: L("menu.table", "Table"), action: nil, keyEquivalent: "").submenu = table
        let math = NSMenu(title: L("menu.mathDiagrams", "Formulas & Diagrams"))
        math.addItem(item(L("menu.inlineMath", "Inline Formula"), #selector(E.insertInlineMath(_:)), "m", [.command, .control]))
        math.addItem(item(L("menu.mathBlock", "Formula Block"), #selector(E.insertMathBlock(_:)), "m", [.command, .control, .shift]))
        math.addItem(withTitle: L("menu.diagram", "Mermaid Diagram"), action: #selector(E.insertDiagram(_:)), keyEquivalent: "")
        format.addItem(withTitle: L("menu.mathDiagrams", "Formulas & Diagrams"), action: nil, keyEquivalent: "").submenu = math
        let scholarly = NSMenu(title: L("menu.references", "Citations & References"))
        scholarly.addItem(item(L("menu.insertCitation", "Insert Citation…"), #selector(W.insertCitation(_:)), "c", [.command, .control]))
        scholarly.addItem(item(L("menu.insertCrossReference", "Insert Cross-Reference"), #selector(E.insertCrossReference(_:)), "r", [.command, .control]))
        scholarly.addItem(.separator())
        scholarly.addItem(withTitle: L("menu.insertFigure", "Figure with Caption"), action: #selector(E.insertFigure(_:)), keyEquivalent: "")
        scholarly.addItem(withTitle: L("menu.insertTableCaption", "Table Caption"), action: #selector(E.insertTableCaption(_:)), keyEquivalent: "")
        scholarly.addItem(withTitle: L("menu.insertTOC", "Table of Contents"), action: #selector(E.insertTableOfContents(_:)), keyEquivalent: "")
        scholarly.addItem(withTitle: L("menu.insertReferenceList", "Reference List Position"), action: #selector(E.insertReferenceList(_:)), keyEquivalent: "")
        scholarly.addItem(.separator())
        scholarly.addItem(withTitle: L("menu.numberSections", "Number Headings"), action: #selector(W.toggleNumberSections(_:)), keyEquivalent: "")
        format.addItem(withTitle: L("menu.references", "Citations & References"), action: nil, keyEquivalent: "").submenu = scholarly
        format.addItem(.separator())
        format.addItem(item(L("menu.biggerFont", "Increase Font Size"), #selector(W.increaseFontSize(_:)), "+", [.command]))
        format.addItem(item(L("menu.smallerFont", "Decrease Font Size"), #selector(W.decreaseFontSize(_:)), "-", [.command]))
        format.addItem(withTitle: L("menu.defaultFont", "Default Font Size"), action: #selector(W.resetFontSize(_:)), keyEquivalent: "")

        // View
        let view = submenu(main, L("menu.view", "View"))
        view.addItem(item(L("view.editor", "Editor"), #selector(W.showEditorOnly(_:)), "1", [.command]))
        view.addItem(item(L("view.split", "Split View"), #selector(W.showSplit(_:)), "2", [.command]))
        view.addItem(item(L("view.preview", "Final View"), #selector(W.showPreviewOnly(_:)), "3", [.command]))
        view.addItem(item(L("menu.toggleEditPreview", "Switch Editor / Final View"), #selector(W.toggleEditPreview(_:)), "r", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(item(L("menu.showSidebar", "Show Sidebar"), #selector(W.toggleDocumentSidebar(_:)), "s", [.command, .control]))
        view.addItem(withTitle: L("menu.outline", "Outline"), action: #selector(W.showOutline(_:)), keyEquivalent: "")
        view.addItem(withTitle: L("menu.files", "Files"), action: #selector(W.showFiles(_:)), keyEquivalent: "")
        view.addItem(withTitle: L("menu.comments", "Comments"), action: #selector(W.showComments(_:)), keyEquivalent: "")
        view.addItem(withTitle: L("sidebar.search", "Search"), action: #selector(W.showFolderSearch(_:)), keyEquivalent: "")
        view.addItem(item(L("menu.statistics", "Document Statistics"), #selector(W.showStatistics(_:)), "s", [.command, .option]))
        view.addItem(.separator())
        view.addItem(withTitle: L("menu.syncScroll", "Synchronized Scrolling"), action: #selector(W.toggleSyncScroll(_:)), keyEquivalent: "")
        view.addItem(item(L("menu.liveFormatting", "Live Formatting"), #selector(W.toggleLiveFormatting(_:)), "l", [.command, .option]))
        view.addItem(item(L("menu.focusMode", "Focus Mode"), #selector(W.toggleFocusMode(_:)), "f", [.command, .shift]))
        view.addItem(item(L("menu.typewriter", "Typewriter Scrolling"), #selector(W.toggleTypewriterMode(_:)), "t", [.command, .control]))
        view.addItem(.separator())
        view.addItem(withTitle: L("menu.toggleToolbar", "Show/Hide Toolbar"), action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "")
        view.addItem(withTitle: L("menu.customizeToolbar", "Customize Toolbar…"), action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(item(L("menu.fullScreen", "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        // Window
        let window = submenu(main, L("menu.window", "Window"))
        window.addItem(withTitle: L("menu.minimize", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L("menu.zoom", "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: L("menu.bringAll", "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        // Help
        let help = submenu(main, L("menu.help", "Help"))
        help.addItem(withTitle: L("menu.markdownGuide", "Markdown Guide"), action: #selector(AppDelegate.showMarkdownHelp(_:)), keyEquivalent: "?")
        help.addItem(withTitle: L("menu.projectPage", "Z-MarkDowner on GitHub"), action: #selector(AppDelegate.openProjectPage(_:)), keyEquivalent: "")
        NSApp.helpMenu = help

        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    static func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = modifiers
        return mi
    }

    private static func findItem(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                                 _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let mi = item(title, #selector(NSTextView.performFindPanelAction(_:)), key, modifiers)
        mi.tag = action.rawValue
        return mi
    }
}
