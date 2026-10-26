import AppKit
import WebKit
import PDFKit
import MarkDownerCore

/// End-to-end check of the running app: `ZMD_SELFTEST_IN=<dir> ZMD_SELFTEST_OUT=<dir> Z-MarkDowner`.
/// Opens every file in the input folder through the document controller, exercises editing,
/// view modes, sidebar, scroll sync, images, tables, full screen, all exports, batch conversion,
/// services and saving, then writes `selftest-report.txt` and quits.
@MainActor
final class SelfTest {
    private let input: URL
    private let output: URL
    private var log: [String] = []
    private var failures = 0
    private var activeWindow: NSWindow?

    init(input: URL, output: URL) {
        self.input = input
        self.output = output
    }

    static func startIfRequested() {
        // Passed via environment: AppKit would treat extra command line arguments as files to open
        let env = ProcessInfo.processInfo.environment
        guard let inDir = env["ZMD_SELFTEST_IN"], let outDir = env["ZMD_SELFTEST_OUT"] else { return }
        ServiceProvider.revealResults = false
        let test = SelfTest(input: URL(fileURLWithPath: inDir).absoluteURL.standardizedFileURL,
                            output: URL(fileURLWithPath: outDir).absoluteURL.standardizedFileURL)
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

    /// Waits until `condition` holds (or the timeout expires).
    private func waitFor(_ timeout: Double, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return true }
            await wait(0.1)
        }
        return await condition()
    }

    private func perform(_ action: Selector) {
        guard let responder = activeWindow?.firstResponder else { return }
        if !responder.tryToPerform(action, with: nil) { check(false, "No target for \(action)") }
    }

    private func js(_ window: NSWindow, _ script: String) async -> Any? {
        guard let web = findWebView(in: window.contentView) else { return nil }
        return try? await web.evaluateJavaScript(script)
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        await wait(1)
        for doc in NSDocumentController.shared.documents { doc.close() }
        check(Bundle.main.localizations.count >= 12, "Localizations in bundle: \(Bundle.main.localizations.sorted().joined(separator: ", "))")
        check(WebAssets.hasKaTeX && WebAssets.hasMermaid, "KaTeX and Mermaid bundled")

        await importAll()
        await editingAndViews()
        await finish()
    }

    // MARK: 1. Import

    private var opened: [MarkdownDocument] = []

    private func importAll() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)) ?? []
        let supported = files.filter { DocumentImporter.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in supported {
            do {
                let (doc, _) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
                guard let md = doc as? MarkdownDocument else { check(false, "\(url.lastPathComponent): not a MarkdownDocument"); continue }
                opened.append(md)
                let ext = url.pathExtension.lowercased()
                let imported = !(DocumentImporter.markdownExtensions.contains(ext) || DocumentImporter.plainTextExtensions.contains(ext))
                let headings = md.text.components(separatedBy: "\n").filter { $0.hasPrefix("#") }.count
                check(!md.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "Import \(url.lastPathComponent): \(md.text.count) chars, \(headings) headings")
                if imported {
                    check(md.fileURL == nil && md.fileType == DocumentTypes.markdown, "Import \(url.lastPathComponent): opened as new untitled Markdown")
                }
                check(md.windowController?.editor.string == md.text, "Import \(url.lastPathComponent): editor shows the text")
                try md.text.write(to: output.appendingPathComponent(url.lastPathComponent + ".md"), atomically: true, encoding: .utf8)
                if url.lastPathComponent.contains("cp1250") {
                    check(md.text.contains("Árvíztűrő tükörfúrógép"), "CP1250 accents decoded")
                }
            } catch {
                check(false, "Import \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // MARK: 2. Editing, views, features

    private func editingAndViews() async {
        // A saved document so images can be stored next to it
        let doc = MarkdownDocument()
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        await wait(0.5)
        guard let wc = doc.windowController, let editor = wc.editor, let window = wc.window else {
            check(false, "New document window was not created")
            return
        }
        activeWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        wc.setMode(.split)
        window.makeFirstResponder(editor)

        // Formatting through the responder chain
        editor.insertText("Hello world", replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: 6, length: 5))
        perform(#selector(EditorTextView.formatBold(_:)))
        check(editor.string == "Hello **world**", "Bold: \(editor.string)")
        perform(#selector(EditorTextView.formatBold(_:)))
        check(editor.string == "Hello world", "Bold toggles off")
        perform(#selector(EditorTextView.formatItalic(_:)))
        check(editor.string == "Hello *world*", "Italic: \(editor.string)")
        perform(#selector(EditorTextView.formatHeading2(_:)))
        check(editor.string == "## Hello *world*", "Heading 2: \(editor.string)")
        perform(#selector(EditorTextView.formatBulletList(_:)))
        check(editor.string == "- Hello *world*", "Bulleted list: \(editor.string)")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertNewline(nil)
        check(editor.string == "- Hello *world*\n- ", "List continues on Return")
        editor.insertText("második", replacementRange: editor.selectedRange())

        // Auto pairing
        editor.insertText(" (", replacementRange: editor.selectedRange())
        editor.insertText("(", replacementRange: editor.selectedRange())
        let caret = editor.selectedRange().location
        check(editor.string.hasSuffix("(()") && caret == (editor.string as NSString).length - 1, "Auto-pair inserts () with caret inside")
        editor.insertText(")", replacementRange: editor.selectedRange())
        check(editor.string.hasSuffix("(()") && editor.selectedRange().location == (editor.string as NSString).length, "Typing ) skips over the closing bracket")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        // Commands with the preview focused are forwarded to the editor
        window.makeFirstResponder(findWebView(in: window.contentView))
        perform(#selector(EditorTextView.insertTable(_:)))
        check(editor.string.contains("| Column 1 |") || editor.string.contains("| ") , "Insert table (forwarded from preview focus)")

        // Table: Tab moves to the next cell and aligns the table
        let selectedCell = (editor.string as NSString).substring(with: editor.selectedRange())
        editor.insertText("Name", replacementRange: editor.selectedRange())
        editor.insertTab(nil)
        let afterTab = (editor.string as NSString).substring(with: editor.selectedRange())
        check(!selectedCell.isEmpty && afterTab.contains("2"), "Tab jumps to the next table cell (\(afterTab))")
        let tableLines = editor.string.components(separatedBy: "\n").filter { $0.hasPrefix("|") }
        check(Set(tableLines.map { ($0 as NSString).length }).count == 1, "Table columns aligned")

        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        perform(#selector(EditorTextView.insertCodeBlock(_:)))
        check(editor.string.contains("```\n"), "Insert code block")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        perform(#selector(EditorTextView.insertFootnote(_:)))
        check(editor.string.contains("[^1]") && editor.string.contains("[^1]: "), "Insert footnote")

        // Undo groups (groupsByEvent) close when the app finishes handling an event; post one,
        // as a key press would, since a locked screen delivers no events of its own
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        await wait(1.0)
        check(doc.isDocumentEdited, "Document marked as edited (grouping \(doc.undoManager?.groupingLevel ?? -1), canUndo \(doc.undoManager?.canUndo ?? false), same UM \(editor.undoManager === doc.undoManager))")
        let beforeUndo = editor.string
        doc.undoManager?.undo()
        check(editor.string != beforeUndo, "Undo works")
        doc.undoManager?.redo()
        check(editor.string == beforeUndo, "Redo works")
        check(doc.text == editor.string, "Document text in sync with editor")

        // Save so relative images can be stored
        let saveURL = output.appendingPathComponent("saved.md")
        do {
            try await doc.save(to: saveURL, ofType: DocumentTypes.markdown, for: .saveAsOperation)
            check(doc.fileURL == saveURL && (try? String(contentsOf: saveURL, encoding: .utf8)) == editor.string, "Save as .md")
            check(!doc.isDocumentEdited, "No pending changes after saving")
        } catch { check(false, "Save: \(error.localizedDescription)") }

        // Image paste (raw PNG data) and image file drop
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pngData = png.representation(using: .png, properties: [:])!
        let pb = NSPasteboard(name: .init("zmd-selftest"))
        pb.clearContents()
        pb.setData(pngData, forType: .png)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("\n\n", replacementRange: editor.selectedRange())
        _ = editor.handleFilesOrImages(from: pb, at: editor.selectedRange())
        let pastedPath = editor.string.range(of: #"!\[\]\(images/[^)]+\.png\)"#, options: .regularExpression).map { String(editor.string[$0]) }
        let pastedFile = pastedPath.map { output.appendingPathComponent(String($0.dropFirst(4).dropLast())) }
        check(pastedFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false, "Pasted image saved to images/ and inserted: \(pastedPath ?? "-")")
        let outsideImage = FileManager.default.temporaryDirectory.appendingPathComponent("zmd-drop.png")
        try? pngData.write(to: outsideImage)
        pb.clearContents()
        pb.writeObjects([outsideImage as NSURL])
        editor.insertText("\n\n", replacementRange: editor.selectedRange())
        _ = editor.handleFilesOrImages(from: pb, at: editor.selectedRange())
        check(editor.string.contains("](images/zmd-drop.png)") &&
              FileManager.default.fileExists(atPath: output.appendingPathComponent("images/zmd-drop.png").path),
              "Dropped image file copied into images/")

        // Rich content for rendering checks + long text for scroll sync
        var rich = (try? String(contentsOf: input.appendingPathComponent("features.md"), encoding: .utf8)) ?? "# Features"
        rich = "---\ntitle: Self test\nauthor: Z-MarkDowner\n---\n\n" + rich + """

        ## Math and diagrams

        Inline $a^2 + b^2 = c^2$ and a footnote[^x].

        $$
        \\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}
        $$

        ```mermaid
        graph LR
            A --> B
        ```

        [^x]: Footnote text.

        """
        for i in 1...40 { rich += "\n## Section \(i)\n\nParagraph \(i) with some text to make the document long enough to scroll.\n" }
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText(rich, replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        await wait(0.5)

        let rendered = await waitFor(8) {
            let html = await js(window, "document.getElementById('content').innerHTML") as? String ?? ""
            return html.contains("katex") && html.contains("<svg")
        }
        let html = await js(window, "document.getElementById('content').innerHTML") as? String ?? ""
        check(rendered, "Preview renders math (KaTeX) and diagrams (Mermaid)")
        check(html.contains("hl-kw"), "Preview highlights code")
        check(html.contains("class=\"footnotes\"") && html.contains("doc-title"), "Preview shows footnotes and front matter title")
        await snapshot(window, name: "split-rich")

        // Outline sidebar
        wc.setSidebarVisible(true)
        await wait(0.4)
        check(wc.sidebar.headings.count >= 42, "Outline lists headings (\(wc.sidebar.headings.count))")
        let target = wc.sidebar.headings.first { $0.text == "Section 30" }
        if let target {
            wc.reveal(line: target.line)
            await wait(0.6)
            let y = await js(window, "window.scrollY") as? Double ?? 0
            check(y > 500, "Outline click scrolls the preview (scrollY \(Int(y)))")
        }
        await snapshot(window, name: "sidebar")

        // Scroll sync editor -> preview
        wc.scrollEditor(toLine: 0)
        await wait(0.6)
        let top = await js(window, "window.scrollY") as? Double ?? -1
        if let line = wc.sidebar.headings.first(where: { $0.text == "Section 20" })?.line {
            wc.scrollEditor(toLine: Double(line))
            await wait(0.8)
        }
        let afterScroll = await js(window, "window.scrollY") as? Double ?? 0
        check(top < 50 && afterScroll > 400, "Editor scroll syncs the preview (\(Int(top)) → \(Int(afterScroll)))")
        // preview -> editor
        await wait(0.4)
        let before = wc.preview.scrollMessageCount
        // Native scroll events need a rendering display; dispatch the event explicitly so the
        // page script -> app -> editor path is exercised even with a locked / sleeping screen
        _ = await js(window, "window.scrollTo(0, 0); window.dispatchEvent(new Event('scroll'));")
        await wait(0.8)
        let editorTop = wc.editorTopLine()
        check(editorTop >= 0 && editorTop < 5, "Preview scroll syncs the editor (line \(String(format: "%.1f", editorTop)), messages \(wc.preview.scrollMessageCount - before))")

        // Focus and typewriter modes
        Settings.shared.focusMode = true
        Settings.shared.typewriterMode = true
        editor.setSelectedRange(NSRange(location: 200, length: 0))
        await wait(0.3)
        check(editor.focusMode && editor.typewriterMode, "Focus and typewriter modes on")
        Settings.shared.focusMode = false
        Settings.shared.typewriterMode = false

        // View modes
        wc.setMode(.editor)
        check(!wc.editorScroll.isHidden && wc.preview.isHidden, "Editor view")
        wc.setMode(.preview)
        check(wc.editorScroll.isHidden, "Final view hides the editor")
        check(!wc.responds(to: #selector(EditorTextView.formatBold(_:))), "Formatting disabled in final view")
        await snapshot(window, name: "final-view")
        wc.setMode(.split)
        wc.setSidebarVisible(false)

        // Full screen
        if Self.screenUnavailable {
            log.append("SKIP Full screen (display asleep or screen locked)")
        } else {
            window.toggleFullScreen(nil)
            await wait(2.5)
            check(window.styleMask.contains(.fullScreen), "Full screen on")
            await snapshot(window, name: "fullscreen")
            window.toggleFullScreen(nil)
            await wait(2.5)
            check(!window.styleMask.contains(.fullScreen), "Full screen off")
        }

        // Exports of the rich document
        await exports(wc, name: "rich")
        // Exports of every imported document
        for d in opened {
            guard let w = d.windowController else { continue }
            await exports(w, name: (d.displayName ?? "doc").replacingOccurrences(of: "/", with: "-"))
        }

        // Batch conversion and Finder service
        let batchDir = output.appendingPathComponent("batch")
        try? FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
        for name in ["apple.docx", "sample.rtf"] {
            let src = input.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            do {
                let out = try await DocumentConverter.convert(src, to: .markdown, into: batchDir,
                                                              options: Settings.shared.exportOptions(title: "", baseURL: nil))
                check(((try? String(contentsOf: out, encoding: .utf8)) ?? "").count > 20, "Batch convert \(name) → \(out.lastPathComponent)")
            } catch { check(false, "Batch convert \(name): \(error.localizedDescription)") }
        }
        let serviceSource = batchDir.appendingPathComponent("service.md")
        try? "# Service\n\nConverted by the Finder service.".write(to: serviceSource, atomically: true, encoding: .utf8)
        let spb = NSPasteboard(name: .init("zmd-selftest-service"))
        spb.clearContents()
        spb.writeObjects([serviceSource as NSURL])
        var errorString: NSString?
        ServiceProvider().convertToPDF(spb, userData: nil, error: &errorString)
        let serviceOK = await waitFor(15) { ServiceProvider.lastResults.first?.pathExtension == "pdf" }
        check(serviceOK, "Finder service “Convert to PDF” wrote \(ServiceProvider.lastResults.first?.lastPathComponent ?? "-")")

        // Preferences window and settings
        (NSApp.delegate as? AppDelegate)?.showPreferences(nil)
        await wait(0.5)
        let prefsVisible = NSApp.windows.contains { $0.isVisible && $0.contentViewController is NSTabViewController }
        check(prefsVisible, "Settings window opens")
        let previousTheme = Settings.shared.previewTheme
        Settings.shared.previewTheme = .academic
        await wait(1.0)
        let font = await js(window, "getComputedStyle(document.body).fontFamily") as? String ?? ""
        check(font.lowercased().contains("palatino") || font.lowercased().contains("iowan") || font.lowercased().contains("georgia"),
              "Preview theme switches (Academic: \(font.prefix(40)))")
        Settings.shared.previewTheme = previousTheme
        NSApp.windows.filter { $0.contentViewController is NSTabViewController }.forEach { $0.close() }
    }

    private func exports(_ w: DocumentWindowController, name: String) async {
        let pdf = output.appendingPathComponent(name + ".pdf")
        let docx = output.appendingPathComponent(name + ".docx")
        let epub = output.appendingPathComponent(name + ".epub")
        let html = output.appendingPathComponent(name + ".html")
        do {
            try await w.writePDF(to: pdf)
            let doc = PDFDocument(url: pdf)
            check((doc?.pageCount ?? 0) >= 1, "PDF \(name): \(doc?.pageCount ?? 0) pages")
        } catch { check(false, "PDF \(name): \(error.localizedDescription)") }
        do {
            try w.writeDOCX(to: docx)
            let back = try DocumentImporter.markdown(fromFileAt: docx)
            check(!back.isEmpty, "DOCX \(name): \((try? Data(contentsOf: docx).count) ?? 0) bytes, read back \(back.count) chars")
        } catch { check(false, "DOCX \(name): \(error.localizedDescription)") }
        do {
            try w.writeEPUB(to: epub)
            let zip = try ZipReader(data: Data(contentsOf: epub))
            let content = try zip.contents(of: "OEBPS/content.xhtml")
            check(content.map { (try? XMLDocument(data: $0)) != nil } ?? false, "EPUB \(name): valid package")
        } catch { check(false, "EPUB \(name): \(error.localizedDescription)") }
        do {
            try w.writeHTML(to: html)
            check(((try? String(contentsOf: html, encoding: .utf8)) ?? "").contains("<article"), "HTML \(name)")
        } catch { check(false, "HTML \(name): \(error.localizedDescription)") }
    }

    // MARK: Helpers

    /// Full screen needs an awake, unlocked display.
    static var screenUnavailable: Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
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
        if let web = findWebView(in: window.contentView), !web.isHidden, web.window != nil,
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

    private func finish() async {
        log.append(failures == 0 ? "\nRESULT: ALL CHECKS PASSED" : "\nRESULT: \(failures) FAILURE(S)")
        try? log.joined(separator: "\n").write(to: output.appendingPathComponent("selftest-report.txt"),
                                               atomically: true, encoding: .utf8)
        for d in NSDocumentController.shared.documents {
            d.updateChangeCount(.changeCleared)
            d.close()
        }
        NSApp.terminate(nil)
    }
}
