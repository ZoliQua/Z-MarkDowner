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
        await scholarlyAndWriting()
        await latexSources()
        await reviewFromPDF()
        await diffWindow()
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

    // MARK: 3. Citations, cross-references, review, live formatting, search, statistics

    private func scholarlyAndWriting() async {
        let dir = output.appendingPathComponent("scholarly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bib = #"""
        @article{kovacs2020,
          author = {Kov{\'a}cs, J{\'a}nos and Nagy, Erzs{\'e}bet and Sz{\H{o}}ke, P{\'e}ter},
          title = {A randomized trial of something}, journal = {N Engl J Med}, year = 2020,
          volume = {382}, number = {5}, pages = {401--410}, doi = {10.1056/NEJMoa1234567}
        }
        @book{who2019, author = {{World Health Organization}}, title = {Global report}, publisher = {WHO Press}, address = {Geneva}, year = {2019}}
        """#
        try? bib.write(to: dir.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
        var md = """
        ---
        title: Scholarly test
        author: Self Test
        lang: en
        bibliography: refs.bib
        toc: true
        numbersections: true
        ---

        # Introduction {#sec:intro}

        Earlier work [@kovacs2020, p. 5; @who2019] and @kovacs2020 show it. See @fig:plot, @tbl:data and @eq:main; details in @sec:methods.
        The {--old--}{++new++} wording was {==discussed==}{>>Check this<<}. Visit https://example.com for more.

        # Methods {#sec:methods}

        - [ ] open task
        - [x] done task

        > A quoted line

        ![A small plot](plot.png){#fig:plot}

        | Group | n |
        |-------|---|
        | A     | 1 |

        Table: Participants {#tbl:data}

        $$ E = mc^2 $$ {#eq:main}

        """
        for i in 1...25 { md += "\n## Part \(i)\n\nFiller paragraph \(i) so the document spans several PDF pages and the table of contents gets page numbers.\n" }
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try? png.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("plot.png"))
        let mdURL = dir.appendingPathComponent("paper.md")
        try? md.write(to: mdURL, atomically: true, encoding: .utf8)

        guard let (document, _) = try? await NSDocumentController.shared.openDocument(withContentsOf: mdURL, display: true),
              let doc = document as? MarkdownDocument, let wc = doc.windowController, let window = wc.window,
              let editor = wc.editor else {
            check(false, "Scholarly document did not open")
            return
        }
        activeWindow = window
        window.makeKeyAndOrderFront(nil)
        wc.setMode(.split)
        await wait(0.6)

        // Preview: citations, reference list, numbering, cross-references, table of contents, review marks
        let ready = await waitFor(8) {
            let html = await js(window, "document.getElementById('content').innerHTML") as? String ?? ""
            return html.contains("csl-entry") && html.contains("katex")
        }
        let html = await js(window, "document.getElementById('content').innerHTML") as? String ?? ""
        check(ready && html.contains(">1</a>,<a") || html.contains(">1</a>, p. 5"), "Preview: numbered citations")
        check(html.contains("Kovács J, Nagy E, Szőke P. A randomized trial of something."), "Preview: Vancouver reference list")
        check(html.contains(">Figure 1</a>") && html.contains(">Table 1</a>") && html.contains(">Equation (1)</a>") && html.contains(">Section 2</a>"),
              "Preview: cross-references resolved")
        check(html.contains("class=\"toc\"") && html.contains("1 Introduction") && html.contains("2.25 Part 25"), "Preview: table of contents with numbered headings")
        check(html.contains("<ins class=\"critic\">") && html.contains("critic-comment"), "Preview: review marks")
        check((wc.lastProcessing?.unresolved ?? ["?"]).isEmpty, "No unresolved citations (\(wc.lastProcessing?.unresolved ?? []))")
        await snapshot(window, name: "scholarly-preview")

        // APA through the settings
        Settings.shared.citationStyle = .apa
        let apa = await waitFor(4) {
            (await js(window, "document.getElementById('content').innerHTML") as? String ?? "").contains("World Health Organization, 2019")
        }
        check(apa, "Citation style switches to APA in the preview")
        Settings.shared.citationStyle = .vancouver

        // Statistics and goals
        check(wc.statistics.words > 300, "Statistics: \(wc.statistics.words) words, \(wc.statistics.sentences) sentences")
        wc.showStatistics(nil)
        await wait(0.4)
        check(wc.statsPopover?.isShown ?? false, "Statistics popover opens")
        wc.statsPopover?.close()
        wc.documentGoal = 2000
        check(wc.documentGoal == 2000, "Document goal stored")
        wc.documentGoal = nil
        let before = WritingGoals.shared.wordsToday
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("\n\nThree more words.", replacementRange: editor.selectedRange())
        await wait(0.5)
        check(WritingGoals.shared.wordsToday >= before + 3, "Words written today counted (\(before) → \(WritingGoals.shared.wordsToday))")

        // Citation completion and picker
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" [@kov", replacementRange: editor.selectedRange())
        let keyRange = editor.rangeForUserCompletion
        var index = 0
        let completions = editor.completions(forPartialWordRange: keyRange, indexOfSelectedItem: &index) ?? []
        check(completions.first == "kovacs2020", "Citation key completion (\(completions.prefix(3)))")
        let crossRefs = wc.citationCandidates().filter { $0.hasPrefix("fig:") || $0.hasPrefix("sec:") }
        check(crossRefs.contains("fig:plot") && crossRefs.contains("sec:methods"), "Cross-reference labels offered")
        editor.undoManager?.undo()
        wc.insertCitation(nil)
        await wait(0.6)
        check(window.attachedSheet?.contentViewController is CitationPickerController, "Insert Citation sheet opens")
        if let sheet = window.attachedSheet { window.endSheet(sheet) }

        if ProcessInfo.processInfo.environment["ZMD_SELFTEST_NETWORK"] == "1" {
            do {
                let entry = try await ReferenceLookup.fetch(.pmid("33301246"))
                check(entry.authors.first?.family == "Polack" && entry.year == "2020", "PubMed lookup: \(entry.title.prefix(50))")
                let doi = try await ReferenceLookup.fetch(.doi("10.1056/NEJMoa2034577"))
                check(doi.container.contains("New England") || doi.containerShort.contains("N Engl"), "DOI lookup: \(doi.container)")
            } catch { check(false, "Online lookup: \(error.localizedDescription)") }
        }

        // Exports: PDF with TOC page numbers and links, DOCX with a Word template
        let pdfURL = dir.appendingPathComponent("paper.pdf")
        do {
            try await wc.writePDF(to: pdfURL)
            let pdf = PDFDocument(url: pdfURL)
            let pages = pdf?.pageCount ?? 0
            let first = pdf?.page(at: 0)?.string ?? ""
            let links = (0..<pages).flatMap { pdf?.page(at: $0)?.annotations ?? [] }.filter { $0.type == "Link" }
            let internalLinks = links.filter { $0.destination != nil }.count
            let external = links.filter { $0.url != nil }.count
            check(pages >= 3, "Scholarly PDF: \(pages) pages")
            check(first.range(of: #"Introduction\s*1"#, options: .regularExpression) != nil
                  && first.range(of: #"Part 25\s*\d+"#, options: .regularExpression) != nil,
                  "PDF table of contents shows page numbers")
            check(internalLinks >= 10 && external >= 1, "PDF links: \(internalLinks) internal, \(external) external")
        } catch { check(false, "Scholarly PDF: \(error.localizedDescription)") }

        let templateURL = dir.appendingPathComponent("template.dotx")
        try? Self.sampleTemplate().write(to: templateURL)
        Settings.shared.wordTemplatePath = templateURL.path
        let docxURL = dir.appendingPathComponent("paper.docx")
        do {
            try wc.writeDOCX(to: docxURL)
            let zip = try ZipReader(data: Data(contentsOf: docxURL))
            let xml = String(decoding: try zip.contents(of: "word/document.xml") ?? Data(), as: UTF8.self)
            let header = try zip.contents(of: "word/header1.xml")
            check(xml.contains("w:val=\"Cmsor1\"") && header != nil, "DOCX uses the Word template styles and header")
            check(xml.contains("TOC \\o") && xml.contains("<w:ins ") && xml.contains("commentRangeStart"), "DOCX: TOC field, tracked change and comment")
            check(xml.contains("Kovács J, Nagy E"), "DOCX: reference list")
            for part in ["word/document.xml", "word/styles.xml", "word/numbering.xml", "word/comments.xml", "[Content_Types].xml"] {
                check((try? XMLDocument(data: try zip.contents(of: part) ?? Data())) != nil, "DOCX part is well-formed: \(part)")
            }
            let back = try DocumentImporter.markdown(fromFileAt: docxURL)
            check(back.contains("{--old--}{++new++}") && back.contains("{>>"), "DOCX review marks read back")
        } catch { check(false, "Scholarly DOCX: \(error.localizedDescription)") }
        Settings.shared.wordTemplatePath = ""

        // Review commands
        let reviewDoc = "A {--old--}{++new++} and {~~x~>y~~} text {==here==}{>>note<<}."
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText(reviewDoc, replacementRange: editor.selectedRange())
        await endUndoGroup()
        perform(#selector(EditorTextView.acceptAllChanges(_:)))
        await endUndoGroup()
        check(editor.string == "A new and y text {==here==}{>>note<<}.", "Accept all changes: \(editor.string)")
        perform(#selector(EditorTextView.removeAllComments(_:)))
        await endUndoGroup()
        check(editor.string == "A new and y text here.", "Delete all comments: \(editor.string)")
        editor.undoManager?.undo()
        editor.undoManager?.undo()
        check(editor.string == reviewDoc, "Review commands are undoable")
        perform(#selector(EditorTextView.rejectAllChanges(_:)))
        check(editor.string.hasPrefix("A old and x text"), "Reject all changes: \(editor.string)")
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        perform(#selector(EditorTextView.insertComment(_:)))
        check(editor.string.hasPrefix("A {==old==}{>>"), "Insert comment on the selection")

        // Live formatting
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText("# Heading\n\nSome **bold** and [a link](https://example.com).\n\n- [ ] task\n- item\n\n---\n\nLast line", replacementRange: editor.selectedRange())
        Settings.shared.liveFormatting = true
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        await wait(0.4)
        if let lm = editor.layoutManager {
            lm.ensureLayout(for: editor.textContainer!)
            let hash = lm.glyphIndexForCharacter(at: 0)
            let star = lm.glyphIndexForCharacter(at: (editor.string as NSString).range(of: "**").location)
            check(lm.propertyForGlyph(at: hash) == .null && lm.propertyForGlyph(at: star) == .null, "Live formatting hides markup")
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            await wait(0.3)
            check(lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: 0)) != .null, "Markup reappears on the caret line")
            // Click the checkbox
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            await wait(0.2)
            let box = (editor.string as NSString).range(of: "[ ]")
            let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: box, actualCharacterRange: nil), in: editor.textContainer!)
            let point = NSPoint(x: rect.midX + editor.textContainerOrigin.x, y: rect.midY + editor.textContainerOrigin.y)
            check(editor.toggleCheckbox(at: point) && editor.string.contains("- [x] task"), "Clicking a checkbox toggles the task")
        }
        await snapshot(window, name: "live-formatting")
        Settings.shared.liveFormatting = false
        await wait(0.2)
        check(editor.layoutManager.map { $0.propertyForGlyph(at: 0) != .null } ?? false, "Live formatting off shows all markup")

        // Folder search and replace
        try? "Searchable needle here\nanother needle".write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        wc.setSidebarVisible(true)
        wc.showFolderSearch(nil)
        wc.sidebar.searchView.search(for: "needle")
        let found = await waitFor(5) { wc.sidebar.searchView.resultCount >= 2 }
        check(found, "Folder search finds matches (\(wc.sidebar.searchView.resultCount))")
        let notes = dir.appendingPathComponent("notes.md")
        wc.openSearchResult(notes, NSRange(location: 11, length: 6))
        let openedNotes = await waitFor(5) {
            (NSDocumentController.shared.document(for: notes) as? MarkdownDocument)?.windowController?.editor.selectedRange()
                == NSRange(location: 11, length: 6)
        }
        check(openedNotes, "Search result opens the file and selects the match")
        if let notesDoc = NSDocumentController.shared.document(for: notes) as? MarkdownDocument, let nwc = notesDoc.windowController {
            let regex = try? FolderSearch.regex(for: "needle", options: .init())
            let result = FolderSearch.replace(in: notesDoc.text, regex: regex!, with: "pin", options: .init())
            nwc.replaceAllText(with: result.text)
            check(nwc.editor.string == "Searchable pin here\nanother pin" && result.count == 2, "Replace in an open document")
            nwc.editor.undoManager?.undo()
            check(nwc.editor.string.contains("needle"), "Replace is undoable")
            notesDoc.updateChangeCount(.changeCleared)
            notesDoc.close()
        }
        wc.setSidebarVisible(false)

        // Word document with tracked changes and comments
        let reviewDocx = dir.appendingPathComponent("review.docx")
        var w = DocxWriter(title: "Review")
        try? w.makeDocx(markdown: "The {--old--}{++new++} {==result==}{>>Check this<<}.").write(to: reviewDocx)
        if let (opened, _) = try? await NSDocumentController.shared.openDocument(withContentsOf: reviewDocx, display: true),
           let reviewed = opened as? MarkdownDocument {
            check(reviewed.text.contains("{--old--}{++new++}") && reviewed.text.contains("{==result==}{>>"), "Word changes and comments import as review marks")
            reviewed.updateChangeCount(.changeCleared)
            reviewed.close()
        } else {
            check(false, "Open Word document with changes")
        }
        doc.updateChangeCount(.changeCleared)
    }

    // MARK: 4. LaTeX sources

    /// `.tex` files open as text documents with LaTeX highlighting and are saved back unchanged.
    private func latexSources() async {
        let dir = output.appendingPathComponent("latex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sample.tex")
        let source = "\\section{Intro}\nText with \\textit{italic} % comment\n"
        let liveBefore = Settings.shared.liveFormatting
        Settings.shared.liveFormatting = true
        defer { Settings.shared.liveFormatting = liveBefore }
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            let (opened, _) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
            guard let doc = opened as? MarkdownDocument, let wc = doc.windowController, let editor = wc.editor,
                  let storage = editor.textStorage, let window = wc.window else {
                check(false, "LaTeX: sample.tex did not open as a text document")
                return
            }
            activeWindow = window
            check(doc.sourceFormat == .latex && doc.fileURL == url, "LaTeX: sample.tex opens in place as LaTeX (type \(doc.fileType ?? "-"))")
            check(doc.text == source && editor.string == source, "LaTeX: text read unchanged")
            check(wc.mode == .editor, "LaTeX: window starts in editor view")
            let text = source as NSString
            let comment = storage.attribute(.foregroundColor, at: text.range(of: "% comment").location + 2, effectiveRange: nil) as? NSColor
            check(comment != nil && comment != NSColor.textColor, "LaTeX: % comment highlighted")
            let command = storage.attribute(.foregroundColor, at: text.range(of: "\\textit").location + 1, effectiveRange: nil) as? NSColor
            check(command != nil && command != NSColor.textColor, "LaTeX: \\commands highlighted")
            check(!editor.liveFormatting, "LaTeX: live formatting stays off")
            let bold = NSMenuItem(title: "Bold", action: #selector(EditorTextView.formatBold(_:)), keyEquivalent: "")
            check(!editor.validateUserInterfaceItem(bold), "LaTeX: Markdown formatting commands disabled")
            check(wc.sidebar.headings.map(\.text) == ["Intro"], "LaTeX: outline lists \\section headings (\(wc.sidebar.headings.map(\.text)))")
            check(doc.writableTypes(for: .saveAsOperation).allSatisfy { doc.fileNameExtension(forType: $0, saveOperation: .saveAsOperation) == "tex" },
                  "LaTeX: Save As keeps the .tex extension")

            wc.setMode(.split)
            let previewed = await waitFor(5) {
                let html = await js(window, "document.getElementById('content').innerHTML") as? String ?? ""
                return html.contains("<pre") && html.contains("\\section{Intro}")
            }
            check(previewed, "LaTeX: preview shows the source as plain text")

            editor.setSelectedRange(NSRange(location: text.length, length: 0))
            editor.insertText("More $x^2$ text.\n", replacementRange: editor.selectedRange())
            try await doc.save(to: url, ofType: doc.fileType ?? DocumentTypes.latex, for: .saveOperation)
            let saved = try String(contentsOf: url, encoding: .utf8)
            check(doc.fileURL == url && saved == source + "More $x^2$ text.\n", "LaTeX: edit and save keep .tex and the exact content")

            // Markdown-only features stay out of LaTeX windows
            func enabled(_ action: Selector) -> Bool {
                let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
                // The window's responder chain from the editor, then the window delegate and the document (as AppKit searches)
                var chain: [AnyObject] = []
                var responder: NSResponder? = editor
                while let r = responder { chain.append(r); responder = r.nextResponder }
                chain += [window.delegate, doc].compactMap { $0 as AnyObject? }
                guard let target = chain.first(where: { $0.responds(to: action) }) else { return false }
                if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
                return (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? true
            }
            let markdownOnly: [Selector] = [
                #selector(DocumentWindowController.exportPDF(_:)), #selector(DocumentWindowController.exportDOCX(_:)),
                #selector(DocumentWindowController.exportHTML(_:)), #selector(DocumentWindowController.exportEPUB(_:)),
                #selector(EditorTextView.copyAsRichText(_:)), #selector(NSDocument.printDocument(_:)),
                #selector(EditorTextView.formatBold(_:)),
            ]
            check(enabled(#selector(NSText.selectAll(_:))) && !markdownOnly.contains(where: enabled),
                  "LaTeX: export, Copy as Formatted Text, Print and formatting menu items disabled (still enabled: \(markdownOnly.filter(enabled).map(NSStringFromSelector)))")
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.insertText("- item", replacementRange: editor.selectedRange())
            editor.insertNewline(nil)
            check(editor.string.hasSuffix("- item\n"), "LaTeX: Return inserts a plain newline (no list continuation)")
            editor.insertText("See {#fig:one} @", replacementRange: editor.selectedRange())
            check(wc.citationCandidates().isEmpty, "LaTeX: no @ citation completion")
            let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let pb = NSPasteboard(name: .init("zmd-selftest-latex"))
            pb.clearContents()
            pb.setData(image.representation(using: .png, properties: [:])!, forType: .png)
            editor.insertText("\n", replacementRange: editor.selectedRange())
            _ = editor.handleFilesOrImages(from: pb, at: editor.selectedRange())
            let graphic = editor.string.range(of: #"\\includegraphics\[width=\\linewidth\]\{images/[^}]+\.png\}"#,
                                              options: .regularExpression).map { String(editor.string[$0]) }
            let graphicFile = graphic.map { dir.appendingPathComponent(String($0.split(separator: "{").last!.dropLast())) }
            check(graphicFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                  "LaTeX: pasted image stored and inserted as \\includegraphics: \(graphic ?? "-")")
            check(enabled(#selector(DocumentWindowController.compareWithSaved(_:))), "LaTeX: Compare With ▸ Last Saved Version enabled")
            wc.compareWithSaved(nil)
            if let diff = DiffWindowController.openControllers.last {
                _ = await waitFor(5) { diff.result != nil }
                check(diff.oldTitle.contains("Last Saved") && (diff.result?.insertedWords ?? 0) > 0,
                      "LaTeX: compares with the last explicitly saved text (\(diff.oldTitle))")
                check(!diff.allowsReviewMarks && diff.result != nil,
                      "LaTeX: compare with saved works (\(diff.result?.insertedWords ?? -1) words inserted), Open as Review Marks disabled (\(diff.allowsReviewMarks))")
                diff.close()
            } else {
                check(false, "LaTeX: compare with saved opened no window")
            }
            doc.updateChangeCount(.changeCleared)
            doc.close()
        } catch {
            check(false, "LaTeX: \(error.localizedDescription)")
        }
    }

    // MARK: 5. Review comments from a PDF

    /// Imports the comments of an annotated PDF into the Comments panel of a Markdown and of a two-file
    /// LaTeX manuscript: anchoring, applying suggestions (undoable, re-verified after edits), statuses,
    /// replies, the sidecar, the response letter and review marks.
    private func reviewFromPDF() async {
        let dir = output.appendingPathComponent("review", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sentence = "Results show bugs in current tools for visualization."
        let pdfURL = dir.appendingPathComponent("reviewed.pdf")
        guard let pdf = Self.annotatedPDF(text: sentence), pdf.write(to: pdfURL) else {
            check(false, "Review: synthetic annotated PDF could not be made")
            return
        }
        let mdURL = dir.appendingPathComponent("paper.md")
        let filler = (1...40).map { "## Part \($0)\n\nFiller paragraph \($0) about other matters.\n\n" }.joined()
        let source = "# Paper\n\n" + filler + "\(sentence)\n"
        try? source.write(to: mdURL, atomically: true, encoding: .utf8)
        guard let (opened, _) = try? await NSDocumentController.shared.openDocument(withContentsOf: mdURL, display: true),
              let doc = opened as? MarkdownDocument, let wc = doc.windowController, let window = wc.window,
              let editor = wc.editor else {
            check(false, "Review: paper.md did not open")
            return
        }
        activeWindow = window
        let review = wc.review
        do {
            try review.importPDF(pdfURL)
        } catch {
            check(false, "Review: import failed: \(error.localizedDescription)")
            return
        }
        let comments = review.session?.comments ?? []
        check(comments.count == 3, "Review: 3 comments imported (\(comments.count))")
        check(review.anchors.count == 2, "Review: 2 comments anchored in the source (\(review.anchors.count))")
        wc.showComments(nil)
        await wait(0.4)
        check(wc.sidebar.selectedTab == SidebarView.commentsTab && wc.sidebar.reviewView.displayedCount == 3,
              "Review: Comments tab lists the open comments (\(wc.sidebar.reviewView.displayedCount))")
        let sidebarWidth = wc.sidebar.frame.width
        check(wc.sidebar.reviewView.columnWidth > sidebarWidth - 50, "Review: comment rows span the sidebar (\(Int(wc.sidebar.reviewView.columnWidth)) of \(Int(sidebarWidth)))")
        await snapshot(window, name: "review-panel")
        await aiSuggestions(review: review, panel: wc.sidebar.reviewView, window: window)
        func first(_ test: (Suggestion?) -> Bool) -> ReviewComment? { comments.first { test($0.suggestion) } }
        guard let replace = first({ if case .replace = $0 { return true }; return false }),
              let delete = first({ if case .delete = $0 { return true }; return false }),
              let note = first({ $0 == nil }) else {
            check(false, "Review: expected a replacement, a deletion and a note (\(comments.map(\.suggestion)))")
            return
        }

        await endUndoGroup()
        do {
            try review.apply(replace.id)
            check(editor.string.contains("Results show regressions in current tools"), "Review: applying the suggestion edits the source: \(editor.string)")
            check(review.comment(replace.id)?.status == .applied && wc.sidebar.reviewView.displayedCount == 2,
                  "Review: the applied comment leaves the Open filter")
        } catch {
            check(false, "Review: apply: \(error.localizedDescription)")
        }
        await endUndoGroup()
        check(doc.isDocumentEdited, "Review: applying marks the document edited")
        doc.undoManager?.undo()
        check(editor.string == source, "Review: applying is undoable")
        let stored = { ReviewSession.load(for: mdURL)?.comments.first { $0.id == replace.id }?.status }
        check(review.comment(replace.id)?.status == .open && stored() == .open && wc.sidebar.reviewView.displayedCount == 3,
              "Review: undo reopens the comment (sidecar: \(stored().map { "\($0)" } ?? "-"))")
        doc.undoManager?.redo()
        check(editor.string.contains("Results show regressions in current") && review.comment(replace.id)?.status == .applied && stored() == .applied,
              "Review: redo applies it again")
        doc.undoManager?.undo()
        check(editor.string == source && review.comment(replace.id)?.status == .open, "Review: undone again")

        // Selecting a comment scrolls the preview to its passage
        wc.setMode(.split)
        _ = await js(window, "window.scrollTo(0, 0)")
        await wait(0.5)
        review.select(replace.id)
        let scrolled = await waitFor(4) { (await js(window, "window.scrollY") as? Double ?? 0) > 300 }
        check(scrolled && (editor.string as NSString).substring(with: editor.selectedRange()) == "bugs",
              "Review: selecting a comment selects it in the editor and scrolls the preview")

        // Text typed before the passage: the anchors are recomputed before the edit
        editor.replace(NSRange(location: (editor.string as NSString).range(of: "Results show").location, length: 0), with: "In short: ")
        do {
            try review.apply(delete.id)
            check(editor.string.contains("In short: Results show bugs in tools for"), "Review: apply after an edit re-anchors first: \(editor.string)")
        } catch {
            check(false, "Review: apply after an edit: \(error.localizedDescription)")
        }
        let afterDelete = editor.string
        do {
            try review.apply(delete.id)
            check(false, "Review: a suggestion whose target is gone is refused")
        } catch {
            check(editor.string == afterDelete, "Review: a suggestion whose target is gone is refused (\(error.localizedDescription))")
        }

        // Statuses, replies and the sidecar
        review.setStatus(note.id, .done)
        review.setReply(note.id, "The original study is now cited.")
        check(FileManager.default.fileExists(atPath: ReviewSession.sidecarURL(for: mdURL).path), "Review: sidecar saved next to the source")
        let reloaded = ReviewController()
        reloaded.windowController = wc
        reloaded.loadSidecar()
        check(reloaded.comment(note.id)?.status == .done && reloaded.comment(note.id)?.reply == "The original study is now cited."
              && reloaded.comment(delete.id)?.status == .applied && reloaded.anchors.count >= 1,
              "Review: reloading the sidecar restores statuses and replies")
        check(review.hasReview(from: pdfURL), "Review: a second import of the same PDF is recognised")
        try? review.importPDF(pdfURL, continueExisting: true)
        check(review.comment(note.id)?.status == .done && review.comment(delete.id)?.status == .applied,
              "Review: continuing the review keeps the progress")

        // Response letter
        let letterDOCX = dir.appendingPathComponent("response.docx")
        let letterMD = dir.appendingPathComponent("response.md")
        do {
            try review.exportResponse(to: letterDOCX, asDOCX: true)
            try review.exportResponse(to: letterMD, asDOCX: false)
            let back = try DocumentImporter.markdown(fromFileAt: letterDOCX)
            check(back.contains("Please cite the original study.") && back.contains("The original study is now cited."),
                  "Review: DOCX response letter reads back with the comment and the reply")
            let markdown = (try? String(contentsOf: letterMD, encoding: .utf8)) ?? ""
            check(markdown.hasPrefix("# Response to Reviewers") && markdown.contains("### 3."), "Review: Markdown response letter")
        } catch {
            check(false, "Review: response letter: \(error.localizedDescription)")
        }

        // Review marks (single-file Markdown only)
        check(review.canInsertMarks, "Review: review marks offered for Markdown")
        review.insertMarks()
        check(editor.string.contains("{~~bugs~>regressions~~}") && editor.string.contains("{>>Reviewer:"),
              "Review: comments inserted as review marks: \(editor.string)")
        doc.updateChangeCount(.changeCleared)
        doc.close()

        await latexReview(pdfURL: pdfURL, sentence: sentence, in: dir)
    }

    /// On-device AI proposals: a spelling comment yields a replacement with the British spelling, and a run
    /// over all comments leaves the instruction parser's suggestions alone. Without the model the AI
    /// commands are hidden.
    private func aiSuggestions(review: ReviewController, panel: ReviewPanelView, window: NSWindow) async {
        guard AISuggester.isAvailable else {
            log.append("SKIP AI suggestions (model unavailable)")
            check(!panel.showsAIControls, "Review: AI commands hidden without the on-device model")
            return
        }
        let wasOn = Settings.shared.aiSuggestions
        Settings.shared.aiSuggestions = true
        check(panel.showsAIControls, "Review: AI commands shown when the on-device model is available")
        let comment = ReviewComment(id: "ai-test", page: 0, kind: .highlight, quotedText: "color", comment: "Use the British spelling.")
        do {
            let started = Date()
            let suggestion = try await AISuggester.suggest(for: comment, sentence: "The color scale is fixed.")
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            if case .replace(_, let with)? = suggestion {
                check(with.contains("colour"), "Review AI: British spelling proposed as a replacement (\(String(describing: suggestion)), \(seconds) s)")
            } else {
                check(false, "Review AI: expected a replacement with “colour” (\(String(describing: suggestion)))")
            }
        } catch {
            check(false, "Review AI: \(error.localizedDescription)")
        }
        let before = review.session?.comments ?? []
        defer {
            // The review checks that follow see the comments exactly as imported
            for comment in before { review.update(comment) }
            check(review.session?.comments == before, "Review AI: the comments are restored after the AI checks")
        }
        await review.suggestAllWithAI()
        let after = review.session?.comments ?? []
        let parsed = before.filter { $0.suggestion != nil }
        check(!parsed.isEmpty && parsed.allSatisfy { old in after.first { $0.id == old.id }.map { $0.suggestion == old.suggestion && !$0.suggestionIsAI } ?? false },
              "Review AI: suggestions from the comments' instructions are never replaced (\(review.aiStatus))")
        check(!review.isSuggesting && !review.aiStatus.isEmpty, "Review AI: the run reports in the status line")
        // A free-form remark on an anchored comment goes through the controller: sentence, validation, applicability
        if let original = after.first(where: { $0.suggestion != nil && review.anchors[$0.id] != nil }) {
            var remark = original
            remark.comment = "This word is too strong; use “shortcomings” instead."
            remark.suggestion = nil
            review.update(remark)
            await review.suggestWithAI(remark.id)
            let result = review.comment(remark.id)
            check(result?.suggestion == nil || result?.suggestionIsAI == true,
                  "Review AI: a free-form remark gets an AI suggestion or none (\(result?.suggestion.map { String(describing: $0) } ?? "none"); \(review.aiStatus))")
            await wait(0.3)
            await snapshot(window, name: "review-panel-ai")
            // A started batch is marked running at once, and Cancel stops it before the next comment
            review.update(remark)
            review.startSuggesting(nil)
            let marked = review.isSuggesting
            review.startSuggesting(nil)
            review.cancelAI()
            let stopped = await waitFor(10) { !review.isSuggesting }
            check(marked && stopped && review.comment(remark.id)?.suggestion == nil,
                  "Review AI: a batch is marked running at once and Cancel stops it (\(review.aiStatus))")
            // Turning the setting off stops a running batch too
            review.startSuggesting(nil)
            Settings.shared.aiSuggestions = false
            let ended = await waitFor(10) { !review.isSuggesting }
            check(ended && review.comment(remark.id)?.suggestion == nil,
                  "Review AI: turning the setting off stops the batch (\(review.aiStatus))")
            Settings.shared.aiSuggestions = true
            review.update(original)
        }
        Settings.shared.aiSuggestions = false
        check(!panel.showsAIControls, "Review AI: the setting turns the AI commands off")
        Settings.shared.aiSuggestions = wasOn
    }

    /// A LaTeX main file that pulls its text in with `\input`: suggestions are applied in the section
    /// file's own document, opened for it, and the main file stays untouched.
    private func latexReview(pdfURL: URL, sentence: String, in folder: URL) async {
        let dir = folder.appendingPathComponent("latex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mainURL = dir.appendingPathComponent("main.tex")
        let secURL = dir.appendingPathComponent("sec.tex")
        let mainSource = "\\documentclass{article}\n\\begin{document}\n\\section{Introduction}\n\\input{sec}\n\\end{document}\n"
        let secSource = sentence + "\n"
        try? mainSource.write(to: mainURL, atomically: true, encoding: .utf8)
        try? secSource.write(to: secURL, atomically: true, encoding: .utf8)
        guard let (opened, _) = try? await NSDocumentController.shared.openDocument(withContentsOf: mainURL, display: true),
              let doc = opened as? MarkdownDocument, let wc = doc.windowController, let window = wc.window else {
            check(false, "Review LaTeX: main.tex did not open")
            return
        }
        activeWindow = window
        let review = wc.review
        do {
            try review.importPDF(pdfURL)
        } catch {
            check(false, "Review LaTeX: import failed: \(error.localizedDescription)")
            return
        }
        let comments = review.session?.comments ?? []
        let inSection = review.anchorFiles.values.filter { $0.standardizedFileURL.path == secURL.standardizedFileURL.path }.count
        check(review.anchors.count == 2 && inSection == 2, "Review LaTeX: comments anchored in the \\input file (\(inSection) of \(review.anchors.count))")
        check(!review.canInsertMarks, "Review LaTeX: no review marks for LaTeX")
        guard let replace = comments.first(where: { if case .replace = $0.suggestion { return true }; return false }),
              let delete = comments.first(where: { if case .delete = $0.suggestion { return true }; return false }) else {
            check(false, "Review LaTeX: suggestions missing")
            return
        }
        do {
            try review.apply(replace.id)
        } catch {
            check(false, "Review LaTeX: apply: \(error.localizedDescription)")
        }
        let secDoc = NSDocumentController.shared.document(for: secURL) as? MarkdownDocument
        let secEditor = secDoc?.windowController?.editor
        check(secEditor?.string == "Results show regressions in current tools for visualization.\n",
              "Review LaTeX: the suggestion is applied in sec.tex's document: \(secEditor?.string ?? "not open")")
        check(wc.editor.string == mainSource && doc.text == mainSource, "Review LaTeX: main.tex stays untouched")
        check((try? String(contentsOf: secURL, encoding: .utf8)) == secSource, "Review LaTeX: sec.tex is not written behind the user's back")
        await endUndoGroup()
        check(secDoc?.isDocumentEdited == true && !doc.isDocumentEdited, "Review LaTeX: sec.tex marked edited, main.tex not")
        review.select(delete.id)
        let selected = await waitFor(3) {
            guard let editor = secEditor else { return false }
            let range = editor.selectedRange()
            return range.length > 0 && (editor.string as NSString).substring(with: range) == "current"
        }
        check(selected, "Review LaTeX: selecting a comment selects its passage in sec.tex")
        check(FileManager.default.fileExists(atPath: ReviewSession.sidecarURL(for: mainURL).path)
              && !FileManager.default.fileExists(atPath: ReviewSession.sidecarURL(for: secURL).path),
              "Review LaTeX: the review is stored next to main.tex")
        secDoc?.updateChangeCount(.changeCleared)
        secDoc?.close()
        doc.updateChangeCount(.changeCleared)
        doc.close()
    }

    /// A one-page PDF with `text` (which must contain “bugs” and “current”) and three review annotations,
    /// as the reviewer's PDF reader writes them: a highlight over “bugs” asking for “regressions”, a
    /// strike-out over “current” and a sticky note.
    static func annotatedPDF(text: String) -> PDFDocument? {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), let page = document.page(at: 0) else { return nil }
        func bounds(_ word: String) -> CGRect? {
            document.findString(word, withOptions: []).first?.bounds(for: page)
        }
        func markup(_ type: PDFAnnotationSubtype, over rect: CGRect, contents: String?) -> PDFAnnotation {
            let annotation = PDFAnnotation(bounds: rect, forType: type, withProperties: nil)
            annotation.quadrilateralPoints = [NSPoint(x: 0, y: rect.height), NSPoint(x: rect.width, y: rect.height),
                                              NSPoint(x: 0, y: 0), NSPoint(x: rect.width, y: 0)].map { NSValue(point: $0) }
            annotation.contents = contents
            annotation.userName = "Reviewer"
            return annotation
        }
        guard let bugs = bounds("bugs"), let current = bounds("current") else { return nil }
        page.addAnnotation(markup(.highlight, over: bugs, contents: #"Change "bugs" to "regressions"."#))
        page.addAnnotation(markup(.strikeOut, over: current, contents: nil))
        let note = PDFAnnotation(bounds: CGRect(x: 72, y: 400, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Please cite the original study."
        note.userName = "Reviewer"
        page.addAnnotation(note)
        guard let saved = document.dataRepresentation() else { return nil }
        return PDFDocument(data: saved)
    }

    /// Closes the current undo group the way the end of a key event would.
    private func endUndoGroup() async {
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        await wait(0.3)
    }

    /// A Word template with Hungarian style ids and a page header.
    static func sampleTemplate() -> Data {
        let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        var zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", string: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/word/header1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml\"/></Types>")
        zip.add(path: "word/styles.xml", string: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:styles \(w)><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Norml\"><w:name w:val=\"Normal\"/><w:rPr><w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\"/></w:rPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"Cmsor1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Norml\"/><w:rPr><w:color w:val=\"C00000\"/><w:sz w:val=\"36\"/></w:rPr></w:style></w:styles>")
        zip.add(path: "word/document.xml", string: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document \(w)><w:body><w:p/><w:sectPr><w:headerReference w:type=\"default\" r:id=\"rId7\"/><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1418\" w:right=\"1418\" w:bottom=\"1418\" w:left=\"1418\" w:header=\"709\" w:footer=\"709\"/></w:sectPr></w:body></w:document>")
        zip.add(path: "word/_rels/document.xml.rels", string: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId7\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/></Relationships>")
        zip.add(path: "word/header1.xml", string: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:hdr \(w)><w:p><w:pPr><w:jc w:val=\"right\"/></w:pPr><w:r><w:t>Semmelweis University</w:t></w:r></w:p></w:hdr>")
        return zip.finish()
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
    // MARK: 6. Diff window

    /// Compares texts side by side and inline, navigates changes, writes review marks and a tracked-changes
    /// Word file, compares a DOCX with a PDF of the same Markdown, and diffs 200 000 characters off the main thread.
    private func diffWindow() async {
        let dir = output.appendingPathComponent("diff", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let diff = DiffWindowController(oldTitle: "A", old: "The quick brown fox", newTitle: "B", new: "The slow brown dog")
        diff.ignoreWhitespace = false; diff.ignoreCase = false; diff.ignoreFormatting = false
        diff.layout = .sideBySide
        diff.showWindow(nil)
        await diff.recompute()
        guard let window = diff.window, let result = diff.result else { check(false, "Diff: no result"); return }
        activeWindow = window
        check(window.title == "Compare: A ↔ B", "Diff: window title \(window.title)")
        check(result.insertedWords == 2 && result.deletedWords == 2, "Diff: 2 words inserted, 2 deleted (\(result.insertedWords), \(result.deletedWords))")
        check(diff.oldTextView.string.contains("The quick brown fox") && diff.newTextView.string.contains("The slow brown dog")
              && diff.oldTextView.enclosingScrollView?.isHidden == false,
              "Diff: side by side shows both versions")
        diff.layout = .inline
        let inline = diff.inlineTextView.string as NSString
        let quick = inline.range(of: "quick")
        let strike = quick.location == NSNotFound ? nil
            : diff.inlineTextView.textStorage?.attribute(.strikethroughStyle, at: quick.location, effectiveRange: nil) as? Int
        check(strike == NSUnderlineStyle.single.rawValue && diff.inlineTextView.enclosingScrollView?.isHidden == false,
              "Diff: inline view strikes through \"quick\"")
        let reviewDoc = await diff.openAsReviewMarks()
        check(reviewDoc.text == "The {--quick--}{++slow++} brown {--fox--}{++dog++}", "Diff: review marks: \(reviewDoc.text)")
        reviewDoc.updateChangeCount(.changeCleared)
        reviewDoc.close()
        let wordURL = dir.appendingPathComponent("changes.docx")
        do {
            try await diff.exportWord(to: wordURL)
            let back = try DocumentImporter.markdown(fromFileAt: wordURL)
            check(back.contains("{--quick--}") && back.contains("{++slow++}"), "Diff: Word export has tracked changes: \(back.prefix(80))")
        } catch {
            check(false, "Diff: Word export: \(error.localizedDescription)")
        }
        window.makeKeyAndOrderFront(nil)
        let down = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
        let up = String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!))
        func key(_ chars: String) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .numericPad, .function], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: chars == down ? 125 : 126)
        }
        _ = key(down).map(window.performKeyEquivalent)
        _ = key(down).map(window.performKeyEquivalent)
        let afterDown = diff.currentChange
        _ = key(up).map(window.performKeyEquivalent)
        check(afterDown == 1 && diff.currentChange == 0 && diff.inlineTextView.selectedRange().length > 0,
              "Diff: ⌘↓ / ⌘↑ move between changes (\(String(describing: afterDown)), \(String(describing: diff.currentChange)))")
        diff.close()

        // Outputs come from the source text even when the window ignores formatting
        let formatted = DiffWindowController(oldTitle: "F1", old: "**bold** old", newTitle: "F2", new: "**bold** new")
        formatted.ignoreWhitespace = false; formatted.ignoreCase = false; formatted.ignoreFormatting = true
        await formatted.recompute()
        let formattedDoc = await formatted.openAsReviewMarks()
        check(formattedDoc.text == "**bold** {--old--}{++new++}", "Diff: ignoring formatting, review marks keep the Markdown: \(formattedDoc.text)")
        formattedDoc.updateChangeCount(.changeCleared)
        formattedDoc.close()
        formatted.close()

        // Screenshots with wrapped, inserted and deleted lines
        let oldSample = "# Results\n\nThe experiment was repeated three times with the same settings, and the values were averaged before the statistical analysis was performed on the whole data set.\n\nThis paragraph was removed.\n\nAll samples were stored at room temperature.\nThe end."
        let newSample = "# Results\n\nThe experiment was repeated five times with identical settings, and the values were averaged before the analysis.\n\nAll samples were stored at 4 °C.\nA new line was added here.\nThe end."
        let sample = DiffWindowController(oldTitle: "draft-v1.md", old: oldSample, newTitle: "draft-v2.md", new: newSample)
        sample.ignoreWhitespace = false; sample.ignoreCase = false; sample.ignoreFormatting = false
        sample.layout = .sideBySide
        sample.showWindow(nil)
        sample.window?.setContentSize(NSSize(width: 1000, height: 460))
        await sample.recompute()
        sample.selectNextChange()
        let summaryCount = { (c: DiffWindowController) in c.summary().components(separatedBy: "\n").first { $0.hasPrefix("Changes:") } ?? "" }
        let sideSummary = summaryCount(sample)
        if let w = sample.window {
            await wait(0.4)
            await snapshot(w, name: "diff-side-by-side")
            let oldRows = (sample.oldTextView.layoutManager?.usedRect(for: sample.oldTextView.textContainer!).height ?? 0)
            let newRows = (sample.newTextView.layoutManager?.usedRect(for: sample.newTextView.textContainer!).height ?? 0)
            check(abs(oldRows - newRows) < 2, "Diff: side-by-side texts stay line-aligned (\(Int(oldRows)) / \(Int(newRows)) pt)")
            sample.layout = .inline
            await wait(0.3)
            await snapshot(w, name: "diff-inline")
            check(sideSummary == "Changes: 2" && summaryCount(sample) == "Changes: 8",
                  "Diff: change counts follow the layout's navigation (\(sideSummary), \(summaryCount(sample)))")
        }
        sample.close()

        // DOCX and PDF of the same Markdown differ by at most a few words when formatting is ignored
        let markdown = "# Annual Report\n\nThe first paragraph describes the **main** results of the year in plain words.\n\nA second paragraph with *emphasis* and a list:\n\n- first item\n- second item\n\nThe final sentence closes the report.\n"
        let docxURL = dir.appendingPathComponent("same.docx"), pdfURL = dir.appendingPathComponent("same.pdf")
        do {
            let options = Settings.shared.exportOptions(title: "Annual Report", baseURL: nil)
            try DocxExporter.data(markdown: markdown, options: options).write(to: docxURL)
            try await PDFExporter.writePDF(markdown: markdown, options: options, to: pdfURL)
            let docxText = try await DiffWindowController.text(ofFileAt: docxURL)
            let pdfText = try await DiffWindowController.text(ofFileAt: pdfURL)
            let formats = DiffWindowController(oldTitle: "same.docx", old: docxText, newTitle: "same.pdf", new: pdfText)
            formats.ignoreWhitespace = true; formats.ignoreCase = false; formats.ignoreFormatting = true
            await formats.recompute()
            let changed = (formats.result?.insertedWords ?? 99) + (formats.result?.deletedWords ?? 99)
            check(changed <= 3, "Diff: DOCX vs PDF of the same Markdown, ignoring formatting: \(changed) changed words")
            if changed > 3, let r = formats.result { log.append("     " + TextDiff.criticMarkup(r.segments).replacingOccurrences(of: "\n", with: "⏎")) }
            formats.close()
        } catch {
            check(false, "Diff: DOCX vs PDF: \(error.localizedDescription)")
        }

        // 200 000 characters per side: the diff runs in the background
        var rng = SystemRandomNumberGenerator()
        let words = ["alpha", "beta", "gamma", "delta", "review", "paper", "result", "method", "sample", "data"]
        var oldLines: [String] = [], newLines: [String] = []
        var size = 0
        while size < 200_000 {
            let line = (0..<12).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
            oldLines.append(line)
            newLines.append(Int.random(in: 0..<20, using: &rng) == 0 ? line.replacingOccurrences(of: "data", with: "evidence") : line)
            size += line.count + 1
        }
        let big = DiffWindowController(oldTitle: "big-old", old: oldLines.joined(separator: "\n"), newTitle: "big-new", new: newLines.joined(separator: "\n"))
        big.ignoreWhitespace = false; big.ignoreCase = false; big.ignoreFormatting = false
        big.layout = .sideBySide
        big.showWindow(nil)
        var ticks = 0
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in ticks += 1 }
        RunLoop.main.add(timer, forMode: .common)
        let start = Date()
        await big.recompute()
        let elapsed = Date().timeIntervalSince(start)
        timer.invalidate()
        check(ticks > 0 && (big.result?.insertedWords ?? 0) > 0,
              "Diff: 200 000 characters compared in \(String(format: "%.2f", elapsed)) s while the main thread kept running (\(ticks) timer ticks)")
        big.close()
    }

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
