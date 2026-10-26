import AppKit
import WebKit
import MarkDownerCore

/// End-to-end check of the running app: `ZMD_SELFTEST_IN=<dir> ZMD_SELFTEST_OUT=<dir> Z-MarkDowner`.
/// Opens every file in inputDir through the document controller, exercises editing,
/// view modes, full screen, export and save, then writes `selftest-report.txt` and quits.
@MainActor
final class SelfTest {
    private let input: URL
    private let output: URL
    private var log: [String] = []
    private var failures = 0

    init(input: URL, output: URL) {
        self.input = input
        self.output = output
    }

    static func startIfRequested() {
        // Passed via environment: AppKit would treat extra command line arguments as files to open
        let env = ProcessInfo.processInfo.environment
        guard let inDir = env["ZMD_SELFTEST_IN"], let outDir = env["ZMD_SELFTEST_OUT"] else { return }
        let test = SelfTest(input: URL(fileURLWithPath: inDir), output: URL(fileURLWithPath: outDir))
        Task { @MainActor in await test.run() }
    }

    private func check(_ condition: Bool, _ message: String) {
        log.append((condition ? "OK   " : "FAIL ") + message)
        FileHandle.standardError.write(Data((log.last! + "\n").utf8))
        if !condition { failures += 1 }
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        await wait(1)
        // Close the initial untitled document
        for doc in NSDocumentController.shared.documents { doc.close() }

        let files = (try? FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)) ?? []
        let supported = files.filter { DocumentImporter.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // 1. Import every file
        var opened: [MarkdownDocument] = []
        for url in supported {
            do {
                let (doc, _) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
                guard let md = doc as? MarkdownDocument else {
                    check(false, "\(url.lastPathComponent): nem MarkdownDocument"); continue
                }
                opened.append(md)
                let ext = url.pathExtension.lowercased()
                let imported = !(DocumentImporter.markdownExtensions.contains(ext) || DocumentImporter.plainTextExtensions.contains(ext))
                let headings = md.text.components(separatedBy: "\n").filter { $0.hasPrefix("#") }.count
                check(!md.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "Import \(url.lastPathComponent): \(md.text.count) karakter, \(headings) címsor")
                if imported {
                    check(md.fileURL == nil && md.fileType == DocumentTypes.markdown,
                          "Import \(url.lastPathComponent): új, névtelen Markdown dokumentumként nyílt meg (\(md.displayName ?? ""))")
                }
                let editorText = md.windowController?.editor.string
                check(editorText == md.text, "Import \(url.lastPathComponent): szerkesztő tartalma egyezik"
                      + (editorText == md.text ? "" : " (wc: \(md.windowControllers.count), editor: \(editorText?.count ?? -1), doc: \(md.text.count))"))
                try md.text.write(to: output.appendingPathComponent(url.lastPathComponent + ".md"), atomically: true, encoding: .utf8)
                if url.lastPathComponent.contains("cp1250") {
                    check(md.text.contains("Árvíztűrő tükörfúrógép"), "CP1250 ékezetek helyesek")
                }
            } catch {
                check(false, "Import \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if let first = opened.first, let w = first.windowController, let win = w.window {
            win.makeKeyAndOrderFront(nil)
            w.setMode(.split)
            await wait(1.2)
            await snapshot(win, name: "import-split")
            w.setMode(.preview)
            await wait(0.8)
            await snapshot(win, name: "import-preview")
            w.setMode(.editor)
            await wait(0.5)
            await snapshot(win, name: "import-editor")
        }

        // 2. Editing on a fresh document
        let doc = MarkdownDocument()
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        await wait(0.5)
        guard let wc = doc.windowController, let editor = wc.editor, let window = wc.window else {
            check(false, "Új dokumentum ablaka nem jött létre")
            return finish()
        }
        activeWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        wc.setMode(.split)
        window.makeFirstResponder(editor)
        editor.insertText("Hello world", replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: 6, length: 5))
        perform(#selector(EditorTextView.formatBold(_:)))
        check(editor.string == "Hello **world**", "Félkövér (menüművelet a responder chainen át): \(editor.string)")
        perform(#selector(EditorTextView.formatBold(_:)))
        check(editor.string == "Hello world", "Félkövér visszavonása kapcsolóként: \(editor.string)")
        perform(#selector(EditorTextView.formatItalic(_:)))
        check(editor.string == "Hello *world*", "Dőlt: \(editor.string)")
        perform(#selector(EditorTextView.formatHeading2(_:)))
        check(editor.string == "## Hello *world*", "Címsor 2: \(editor.string)")
        perform(#selector(EditorTextView.formatBulletList(_:)))
        check(editor.string == "- Hello *world*", "Felsorolás: \(editor.string)")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertNewline(nil)
        check(editor.string == "- Hello *world*\n- ", "Lista folytatása Enterrel")
        editor.insertText("második", replacementRange: editor.selectedRange())
        // Toolbar/menu command while the preview has focus is forwarded to the editor
        window.makeFirstResponder(findWebView(in: window.contentView))
        perform(#selector(EditorTextView.insertTable(_:)))
        check(editor.string.contains("| Oszlop 1 | Oszlop 2 | Oszlop 3 |"), "Táblázat beszúrása")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        perform(#selector(EditorTextView.insertCodeBlock(_:)))
        check(editor.string.contains("```\nkód\n```"), "Kódblokk beszúrása")
        await wait(1.0) // undo groups close at the end of the run loop cycle
        check(doc.isDocumentEdited, "Dokumentum módosítottként jelölve")
        let beforeUndo = editor.string
        doc.undoManager?.undo()
        check(editor.string != beforeUndo && !editor.string.contains("```"), "Visszavonás (⌘Z) működik")
        doc.undoManager?.redo()
        check(editor.string == beforeUndo, "Ismét (⇧⌘Z) működik")
        check(doc.text == editor.string, "Dokumentum szövege szinkronban a szerkesztővel")

        // 3. View modes
        wc.setMode(.editor)
        check(!editor.enclosingScrollView!.isHidden, "Szerkesztő nézet: szerkesztő látható")
        wc.setMode(.preview)
        check(editor.enclosingScrollView!.isHidden, "Végleges nézet: szerkesztő rejtve")
        let canFormat = wc.responds(to: #selector(EditorTextView.formatBold(_:)))
            || window.firstResponder is EditorTextView
        check(!canFormat, "Végleges nézetben a formázás le van tiltva")
        wc.setMode(.split)
        await wait(1)
        let previewHTML = await previewContent(window)
        check(previewHTML.contains("<table>") && previewHTML.contains("<li>"), "Előnézet renderelve (HTML: \(previewHTML.count) karakter)")
        await snapshot(window, name: "split")

        // 4. Full screen
        window.toggleFullScreen(nil)
        await wait(2.5)
        check(window.styleMask.contains(.fullScreen), "Teljes képernyő be")
        await snapshot(window, name: "fullscreen")
        window.toggleFullScreen(nil)
        await wait(2.5)
        check(!window.styleMask.contains(.fullScreen), "Teljes képernyő ki")

        // 5. Export from every opened document and the edited one
        for d in opened + [doc] {
            guard let w = d.windowController else { continue }
            let base = (d.displayName ?? "doc").replacingOccurrences(of: "/", with: "-")
            let pdf = output.appendingPathComponent(base + ".pdf")
            let docx = output.appendingPathComponent(base + ".docx")
            do {
                try await w.writePDF(to: pdf)
                let rep = NSPDFImageRep(data: try Data(contentsOf: pdf))
                check(rep != nil && rep!.pageCount >= 1, "PDF export \(base): \(rep?.pageCount ?? 0) oldal")
            } catch { check(false, "PDF export \(base): \(error.localizedDescription)") }
            do {
                try w.writeDOCX(to: docx)
                let back = try DocumentImporter.markdown(fromFileAt: docx)
                check(!back.isEmpty, "DOCX export \(base): \((try? Data(contentsOf: docx).count) ?? 0) bájt, visszaolvasva \(back.count) karakter")
            } catch { check(false, "DOCX export \(base): \(error.localizedDescription)") }
        }

        // 6. Save as Markdown and re-open
        let saveURL = output.appendingPathComponent("mentett.md")
        do {
            try await doc.save(to: saveURL, ofType: DocumentTypes.markdown, for: .saveAsOperation)
            let saved = try String(contentsOf: saveURL, encoding: .utf8)
            check(saved == editor.string, "Mentés .md-be és visszaolvasás")
            check(!doc.isDocumentEdited, "Mentés után nincs függő módosítás")
        } catch { check(false, "Mentés: \(error.localizedDescription)") }

        finish()
    }

    /// Sends an action up the responder chain starting at the window's first responder
    /// (what a menu item / toolbar button does for the key window).
    private var activeWindow: NSWindow?
    private func perform(_ action: Selector) {
        guard let responder = activeWindow?.firstResponder else { return }
        if !responder.tryToPerform(action, with: nil) {
            check(false, "Nincs célpont: \(action)")
        }
    }

    private func previewContent(_ window: NSWindow) async -> String {
        guard let web = findWebView(in: window.contentView) else { return "" }
        let result = try? await web.evaluateJavaScript("document.getElementById('content').innerHTML")
        return result as? String ?? ""
    }

    private func findWebView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let web = view as? WKWebView { return web }
        for sub in view.subviews { if let w = findWebView(in: sub) { return w } }
        return nil
    }

    /// Renders the window (including the web preview, which cacheDisplay cannot capture) to a PNG.
    private func snapshot(_ window: NSWindow, name: String) async {
        guard let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        if let web = findWebView(in: window.contentView), !web.isHidden,
           let shot = try? await web.takeSnapshot(configuration: nil) {
            let rect = web.convert(web.bounds, to: frameView)
            image.lockFocus()
            shot.draw(in: rect)
            image.unlockFocus()
        }
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: output.appendingPathComponent("screenshot-\(name).png"))
        }
    }

    private func finish() {
        log.append(failures == 0 ? "\nEREDMÉNY: MINDEN ELLENŐRZÉS SIKERES" : "\nEREDMÉNY: \(failures) HIBA")
        try? log.joined(separator: "\n").write(to: output.appendingPathComponent("selftest-report.txt"),
                                               atomically: true, encoding: .utf8)
        for d in NSDocumentController.shared.documents {
            d.updateChangeCount(.changeCleared)
            d.close()
        }
        NSApp.terminate(nil)
    }
}
