import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        SelfTest.startIfRequested()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func importDocument(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }

    @objc func showMarkdownHelp(_ sender: Any?) {
        let doc = MarkdownDocument()
        doc.text = MarkdownHelp.text
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = "Z-MarkDowner"

        // App menu
        let app = submenu(main, appName)
        app.addItem(withTitle: "A(z) \(appName) névjegye", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu(title: "Szolgáltatások")
        app.addItem(withTitle: "Szolgáltatások", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "\(appName) elrejtése", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(item("Egyebek elrejtése", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(withTitle: "Összes megjelenítése", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Kilépés: \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let file = submenu(main, "Fájl")
        file.addItem(withTitle: "Új", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Megnyitás…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: "Legutóbbiak megnyitása")
        recent.addItem(withTitle: "Lista törlése", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Legutóbbiak megnyitása", action: nil, keyEquivalent: "").submenu = recent
        file.addItem(item("Importálás (DOCX, DOC, RTF, TXT, MD)…", #selector(AppDelegate.importDocument(_:)), "i", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(withTitle: "Bezárás", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Mentés", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        file.addItem(item("Mentés másként…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]))
        file.addItem(withTitle: "Visszaállítás a mentett változatra", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(item("Exportálás PDF-be…", #selector(DocumentWindowController.exportPDF(_:)), "e", [.command, .shift]))
        file.addItem(item("Exportálás Word (DOCX) formátumba…", #selector(DocumentWindowController.exportDOCX(_:)), "d", [.command, .shift]))
        file.addItem(withTitle: "Exportálás HTML-be…", action: #selector(DocumentWindowController.exportHTML(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(item("Oldalbeállítás…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]))
        file.addItem(withTitle: "Nyomtatás…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")

        // Edit
        let edit = submenu(main, "Szerkesztés")
        edit.addItem(withTitle: "Visszavonás", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(item("Ismét", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(withTitle: "Kivágás", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Másolás", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Beillesztés", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(item("Beillesztés Markdownként (Word, web)", #selector(EditorTextView.pasteAsMarkdown(_:)), "v", [.command, .option, .shift]))
        edit.addItem(withTitle: "Törlés", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Összes kijelölése", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Keresés")
        find.addItem(findItem("Keresés…", .showFindInterface, "f", [.command]))
        find.addItem(findItem("Keresés és csere…", .showReplaceInterface, "f", [.command, .option]))
        find.addItem(findItem("Következő találat", .nextMatch, "g", [.command]))
        find.addItem(findItem("Előző találat", .previousMatch, "g", [.command, .shift]))
        find.addItem(findItem("Kijelölés használata a kereséshez", .setSearchString, "e", [.command]))
        edit.addItem(withTitle: "Keresés", action: nil, keyEquivalent: "").submenu = find
        let spelling = NSMenu(title: "Helyesírás")
        spelling.addItem(withTitle: "Helyesírás és nyelvtan megjelenítése", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        spelling.addItem(withTitle: "Dokumentum ellenőrzése most", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
        spelling.addItem(withTitle: "Helyesírás ellenőrzése gépelés közben", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Helyesírás", action: nil, keyEquivalent: "").submenu = spelling
        edit.addItem(.separator())
        edit.addItem(item("Emoji és szimbólumok", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]))

        // Format
        let format = submenu(main, "Formátum")
        format.addItem(item("Félkövér", #selector(EditorTextView.formatBold(_:)), "b", [.command]))
        format.addItem(item("Dőlt", #selector(EditorTextView.formatItalic(_:)), "i", [.command]))
        format.addItem(item("Áthúzott", #selector(EditorTextView.formatStrikethrough(_:)), "x", [.command, .shift]))
        format.addItem(item("Kód (soron belül)", #selector(EditorTextView.formatInlineCode(_:)), "`", [.command]))
        format.addItem(.separator())
        let headings = NSMenu(title: "Címsor")
        headings.addItem(item("Normál szöveg", #selector(EditorTextView.formatParagraph(_:)), "0", [.command, .option]))
        let headingActions: [Selector] = [
            #selector(EditorTextView.formatHeading1(_:)), #selector(EditorTextView.formatHeading2(_:)),
            #selector(EditorTextView.formatHeading3(_:)), #selector(EditorTextView.formatHeading4(_:)),
            #selector(EditorTextView.formatHeading5(_:)), #selector(EditorTextView.formatHeading6(_:)),
        ]
        for (i, action) in headingActions.enumerated() {
            headings.addItem(item("Címsor \(i + 1)", action, "\(i + 1)", [.command, .option]))
        }
        format.addItem(withTitle: "Címsor", action: nil, keyEquivalent: "").submenu = headings
        format.addItem(.separator())
        format.addItem(item("Felsorolás", #selector(EditorTextView.formatBulletList(_:)), "8", [.command, .shift]))
        format.addItem(item("Számozott lista", #selector(EditorTextView.formatNumberedList(_:)), "7", [.command, .shift]))
        format.addItem(item("Feladatlista", #selector(EditorTextView.formatTaskList(_:)), "9", [.command, .shift]))
        format.addItem(item("Idézet", #selector(EditorTextView.formatQuote(_:)), "'", [.command, .shift]))
        format.addItem(.separator())
        format.addItem(item("Link beszúrása", #selector(EditorTextView.insertLink(_:)), "k", [.command]))
        format.addItem(withTitle: "Kép beszúrása…", action: #selector(EditorTextView.insertImage(_:)), keyEquivalent: "")
        format.addItem(item("Kódblokk beszúrása", #selector(EditorTextView.insertCodeBlock(_:)), "c", [.command, .option]))
        format.addItem(item("Táblázat beszúrása", #selector(EditorTextView.insertTable(_:)), "t", [.command, .option]))
        format.addItem(withTitle: "Vízszintes vonal beszúrása", action: #selector(EditorTextView.insertHorizontalRule(_:)), keyEquivalent: "")
        format.addItem(.separator())
        format.addItem(item("Betűméret növelése", #selector(DocumentWindowController.increaseFontSize(_:)), "+", [.command]))
        format.addItem(item("Betűméret csökkentése", #selector(DocumentWindowController.decreaseFontSize(_:)), "-", [.command]))
        format.addItem(withTitle: "Alapértelmezett betűméret", action: #selector(DocumentWindowController.resetFontSize(_:)), keyEquivalent: "")

        // View
        let view = submenu(main, "Nézet")
        view.addItem(item("Szerkesztő", #selector(DocumentWindowController.showEditorOnly(_:)), "1", [.command]))
        view.addItem(item("Osztott nézet", #selector(DocumentWindowController.showSplit(_:)), "2", [.command]))
        view.addItem(item("Végleges nézet (előnézet)", #selector(DocumentWindowController.showPreviewOnly(_:)), "3", [.command]))
        view.addItem(item("Váltás szerkesztő és végleges nézet között", #selector(DocumentWindowController.toggleEditPreview(_:)), "r", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(item("Eszköztár elrejtése/megjelenítése", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .control]))
        view.addItem(withTitle: "Eszköztár testreszabása…", action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(item("Teljes képernyő", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        // Window
        let window = submenu(main, "Ablak")
        window.addItem(withTitle: "Kis méret", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Nagyítás", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Összes előtérbe hozása", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        // Help
        let help = submenu(main, "Súgó")
        help.addItem(withTitle: "Markdown gyorstalpaló", action: #selector(AppDelegate.showMarkdownHelp(_:)), keyEquivalent: "?")
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

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
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
