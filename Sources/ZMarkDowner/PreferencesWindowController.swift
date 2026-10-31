import AppKit
import MarkDownerCore

/// Settings window (General, Editor, Preview & Export).
final class PreferencesWindowController: NSWindowController {

    convenience init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let items: [(String, String, NSViewController)] = [
            (L("prefs.general", "General"), "gearshape", GeneralPane()),
            (L("prefs.editor", "Editor"), "character.cursor.ibeam", EditorPane()),
            (L("prefs.preview", "Preview & Export"), "doc.richtext", PreviewPane()),
            (L("prefs.writing", "Writing"), "text.book.closed", WritingPane()),
        ]
        for (title, symbol, vc) in items {
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = L("prefs.title", "Settings")
        window.setFrameAutosaveName("ZMarkDownerPreferences")
        self.init(window: window)
        window.center()
    }
}

/// Base pane building a two-column form.
class FormPane: NSViewController {
    let grid = NSGridView()

    override func loadView() {
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
        ])
        view = container
        build()
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
    }

    func build() {}

    func row(_ title: String, _ control: NSView) {
        let label = NSTextField(labelWithString: title.isEmpty ? "" : title + ":")
        grid.addRow(with: [label, control])
    }

    func popup(_ titles: [String], selected: Int, action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        p.selectItem(at: max(0, selected))
        p.target = self
        p.action = action
        return p
    }

    func checkbox(_ title: String, _ on: Bool, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = on ? .on : .off
        return b
    }

    func note(_ text: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 360
        return t
    }
}

final class GeneralPane: FormPane {
    private var languageCodes: [String?] = []

    override func build() {
        languageCodes = [nil] + AppLanguage.all.map(\.code)
        let titles = [L("prefs.systemLanguage", "System Default")] + AppLanguage.all.map(\.name)
        let current = languageCodes.firstIndex(where: { $0 == AppLanguage.selected }) ?? 0
        row(L("prefs.language", "Language"), popup(titles, selected: current, action: #selector(languageChanged(_:))))
        row("", note(L("prefs.languageNote", "The new language is applied after restarting the app.")))

        let appearances = [L("prefs.appearanceSystem", "System"), L("prefs.appearanceLight", "Light"), L("prefs.appearanceDark", "Dark")]
        let a = Settings.Appearance.allCases.firstIndex(of: Settings.shared.appearance) ?? 0
        row(L("prefs.appearance", "Appearance"), popup(appearances, selected: a, action: #selector(appearanceChanged(_:))))

        let views = [L("view.editor", "Editor"), L("view.split", "Split View"), L("view.preview", "Final View")]
        row(L("prefs.defaultView", "Default view"), popup(views, selected: Settings.shared.defaultViewMode.rawValue, action: #selector(viewChanged(_:))))
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let code = languageCodes[sender.indexOfSelectedItem]
        guard code != AppLanguage.selected else { return }
        AppLanguage.selected = code
        let alert = NSAlert()
        alert.messageText = L("prefs.restartTitle", "Restart required")
        alert.informativeText = L("prefs.restartText", "Z-MarkDowner needs to restart to use the new language.")
        alert.addButton(withTitle: L("prefs.restartNow", "Restart Now"))
        alert.addButton(withTitle: L("prefs.later", "Later"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { AppRelauncher.relaunch() }
        }
    }

    @objc private func appearanceChanged(_ sender: NSPopUpButton) {
        Settings.shared.appearance = Settings.Appearance.allCases[sender.indexOfSelectedItem]
    }

    @objc private func viewChanged(_ sender: NSPopUpButton) {
        Settings.shared.defaultViewMode = ViewMode(rawValue: sender.indexOfSelectedItem) ?? .split
    }
}

final class EditorPane: FormPane {
    private var fontNames: [String] = []
    private let sizeField = NSTextField()
    private let stepper = NSStepper()
    private let widths: [CGFloat] = [700, 860, 1100, 100_000]

    override func build() {
        let monospaced = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
        let proportional = ["Helvetica Neue", "Avenir Next", "Georgia", "Iowan Old Style", "Palatino", "Charter"]
            .filter { NSFont(name: $0, size: 12) != nil }
        fontNames = [""] + monospaced + proportional
        let titles = [L("prefs.systemMono", "System Monospaced")] + monospaced + proportional
        let selected = fontNames.firstIndex(of: Settings.shared.editorFontName) ?? 0
        row(L("prefs.font", "Font"), popup(titles, selected: selected, action: #selector(fontChanged(_:))))

        sizeField.integerValue = Int(Settings.shared.editorFontSize)
        sizeField.alignment = .right
        sizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        sizeField.target = self
        sizeField.action = #selector(sizeTyped(_:))
        stepper.minValue = 9
        stepper.maxValue = 36
        stepper.integerValue = sizeField.integerValue
        stepper.target = self
        stepper.action = #selector(sizeStepped(_:))
        let sizeRow = NSStackView(views: [sizeField, stepper, NSTextField(labelWithString: "pt")])
        sizeRow.spacing = 6
        row(L("prefs.fontSize", "Font size"), sizeRow)

        let widthTitles = [L("prefs.widthNarrow", "Narrow"), L("prefs.widthMedium", "Medium"),
                           L("prefs.widthWide", "Wide"), L("prefs.widthFull", "Full Width")]
        let w = widths.firstIndex(where: { $0 >= Settings.shared.readableWidth }) ?? 1
        row(L("prefs.lineWidth", "Line width"), popup(widthTitles, selected: w, action: #selector(widthChanged(_:))))

        row(L("prefs.typing", "Typing"), checkbox(L("prefs.autoPair", "Auto-close brackets and quotes"), Settings.shared.autoPair, action: #selector(autoPairChanged(_:))))
        row("", checkbox(L("prefs.spellCheck", "Check spelling while typing"), Settings.shared.spellCheck, action: #selector(spellChanged(_:))))
        row(L("prefs.modes", "Writing modes"), checkbox(L("menu.liveFormatting", "Live Formatting"), Settings.shared.liveFormatting, action: #selector(liveChanged(_:))))
        row("", note(L("prefs.liveNote", "Hides the Markdown markup except on the line you are editing, like a word processor.")))
        row("", checkbox(L("menu.focusMode", "Focus Mode"), Settings.shared.focusMode, action: #selector(focusChanged(_:))))
        row("", checkbox(L("menu.typewriter", "Typewriter Scrolling"), Settings.shared.typewriterMode, action: #selector(typewriterChanged(_:))))
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) { Settings.shared.editorFontName = fontNames[sender.indexOfSelectedItem] }
    @objc private func sizeTyped(_ sender: NSTextField) { setSize(CGFloat(sender.integerValue)) }
    @objc private func sizeStepped(_ sender: NSStepper) { setSize(CGFloat(sender.integerValue)) }
    private func setSize(_ size: CGFloat) {
        Settings.shared.editorFontSize = size
        sizeField.integerValue = Int(Settings.shared.editorFontSize)
        stepper.integerValue = sizeField.integerValue
    }
    @objc private func widthChanged(_ sender: NSPopUpButton) { Settings.shared.readableWidth = widths[sender.indexOfSelectedItem] }
    @objc private func autoPairChanged(_ sender: NSButton) { Settings.shared.autoPair = sender.state == .on }
    @objc private func spellChanged(_ sender: NSButton) { Settings.shared.spellCheck = sender.state == .on }
    @objc private func focusChanged(_ sender: NSButton) { Settings.shared.focusMode = sender.state == .on }
    @objc private func liveChanged(_ sender: NSButton) { Settings.shared.liveFormatting = sender.state == .on }
    @objc private func typewriterChanged(_ sender: NSButton) { Settings.shared.typewriterMode = sender.state == .on }
}

final class PreviewPane: FormPane {
    private let cssLabel = NSTextField(labelWithString: "")

    override func build() {
        let themes = [L("prefs.themeGithub", "GitHub"), L("prefs.themeAcademic", "Academic"), L("prefs.themeMinimal", "Minimal")]
        let t = PreviewTheme.allCases.firstIndex(of: Settings.shared.previewTheme) ?? 0
        row(L("prefs.theme", "Style"), popup(themes, selected: t, action: #selector(themeChanged(_:))))

        cssLabel.lineBreakMode = .byTruncatingMiddle
        cssLabel.textColor = .secondaryLabelColor
        cssLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        updateCSSLabel()
        let choose = NSButton(title: L("button.choose", "Choose…"), target: self, action: #selector(chooseCSS))
        let clear = NSButton(title: L("button.clear", "Clear"), target: self, action: #selector(clearCSS))
        let cssRow = NSStackView(views: [cssLabel, choose, clear])
        cssRow.spacing = 6
        row(L("prefs.customCSS", "Custom CSS"), cssRow)
        row("", note(L("prefs.customCSSNote", "Applied to the preview and to PDF, HTML and EPUB exports.")))

        let papers = ["A4", "US Letter"]
        let p = Settings.Paper.allCases.firstIndex(of: Settings.shared.paper) ?? 0
        row(L("prefs.paper", "Paper size"), popup(papers, selected: p, action: #selector(paperChanged(_:))))
        row(L("prefs.pdf", "PDF"), checkbox(L("prefs.pageNumbers", "Page numbers"), Settings.shared.pageNumbers, action: #selector(pageNumbersChanged(_:))))
        row(L("prefs.rendering", "Rendering"), checkbox(L("prefs.renderMath", "Math formulas (KaTeX)"), Settings.shared.renderMath, action: #selector(mathChanged(_:))))
        row("", checkbox(L("prefs.renderDiagrams", "Diagrams (Mermaid)"), Settings.shared.renderDiagrams, action: #selector(diagramsChanged(_:))))
        row(L("prefs.scrolling", "Scrolling"), checkbox(L("menu.syncScroll", "Synchronized Scrolling"), Settings.shared.syncScroll, action: #selector(syncChanged(_:))))
    }

    private func updateCSSLabel() {
        let path = Settings.shared.customCSSPath
        cssLabel.stringValue = path.isEmpty ? L("prefs.none", "None") : (path as NSString).lastPathComponent
        cssLabel.toolTip = path
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) { Settings.shared.previewTheme = PreviewTheme.allCases[sender.indexOfSelectedItem] }
    @objc private func paperChanged(_ sender: NSPopUpButton) { Settings.shared.paper = Settings.Paper.allCases[sender.indexOfSelectedItem] }
    @objc private func pageNumbersChanged(_ sender: NSButton) { Settings.shared.pageNumbers = sender.state == .on }
    @objc private func mathChanged(_ sender: NSButton) { Settings.shared.renderMath = sender.state == .on }
    @objc private func diagramsChanged(_ sender: NSButton) { Settings.shared.renderDiagrams = sender.state == .on }
    @objc private func syncChanged(_ sender: NSButton) { Settings.shared.syncScroll = sender.state == .on }

    @objc private func chooseCSS() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "css")!]
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Settings.shared.customCSSPath = url.path
            self?.updateCSSLabel()
        }
    }

    @objc private func clearCSS() {
        Settings.shared.customCSSPath = ""
        updateCSSLabel()
    }
}

/// Citations, numbering, Word templates and goals.
final class WritingPane: FormPane {
    private let bibLabel = NSTextField(labelWithString: "")
    private let templateLabel = NSTextField(labelWithString: "")
    private let goalField = NSTextField()

    override func build() {
        let styles = CitationStyle.allCases.map(\.displayName)
        let st = CitationStyle.allCases.firstIndex(of: Settings.shared.citationStyle) ?? 0
        row(L("prefs.citationStyle", "Citation style"), popup(styles, selected: st, action: #selector(styleChanged(_:))))

        row(L("prefs.bibliography", "Default bibliography"), fileRow(bibLabel, choose: #selector(chooseBibliography), clear: #selector(clearBibliography)))
        row("", note(L("prefs.bibliographyNote", "A BibTeX (.bib) or CSL-JSON file, e.g. exported from Zotero. Documents can name their own with “bibliography: refs.bib” in the front matter.")))

        row(L("prefs.numbering", "Numbering"), checkbox(L("prefs.numberSections", "Number headings (1, 1.1, 1.2 …)"), Settings.shared.numberSections, action: #selector(numberingChanged(_:))))

        row(L("prefs.wordTemplate", "Word template"), fileRow(templateLabel, choose: #selector(chooseTemplate), clear: #selector(clearTemplate)))
        row("", note(L("prefs.wordTemplateNote", "A .dotx or .docx file whose styles, page setup, headers and footers are used for Word export (front matter: reference-doc).")))

        let modes = [L("prefs.revisionsMarkup", "Keep as review marks"), L("prefs.revisionsAccept", "Accept all changes, drop comments")]
        let m = DocumentImporter.RevisionMode.allCases.firstIndex(of: Settings.shared.revisionMode) ?? 0
        row(L("prefs.revisions", "Word changes & comments"), popup(modes, selected: m, action: #selector(revisionsChanged(_:))))

        goalField.placeholderString = L("stats.goalPlaceholder", "words")
        goalField.alignment = .right
        goalField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        goalField.target = self
        goalField.action = #selector(goalChanged(_:))
        let goal = Settings.shared.dailyWordGoal
        goalField.stringValue = goal > 0 ? "\(goal)" : ""
        row(L("stats.dailyGoal", "Daily goal"), goalField)
        if AISuggester.isAvailable {
            row(L("prefs.review", "Review"), checkbox(L("prefs.aiSuggestions", "Use Apple Intelligence for review suggestions"),
                                                      Settings.shared.aiSuggestions, action: #selector(aiChanged(_:))))
        }
        updateLabels()
    }

    private func fileRow(_ label: NSTextField, choose: Selector, clear: Selector) -> NSView {
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        let chooseButton = NSButton(title: L("button.choose", "Choose…"), target: self, action: choose)
        let clearButton = NSButton(title: L("button.clear", "Clear"), target: self, action: clear)
        let stack = NSStackView(views: [label, chooseButton, clearButton])
        stack.spacing = 6
        return stack
    }

    private func updateLabels() {
        for (label, path) in [(bibLabel, Settings.shared.defaultBibliographyPath), (templateLabel, Settings.shared.wordTemplatePath)] {
            label.stringValue = path.isEmpty ? L("prefs.none", "None") : (path as NSString).lastPathComponent
            label.toolTip = path
        }
    }

    private func choose(_ extensions: [String], _ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = extensions.compactMap { .init(filenameExtension: $0) }
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            done(url)
        }
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) { Settings.shared.citationStyle = CitationStyle.allCases[sender.indexOfSelectedItem] }
    @objc private func numberingChanged(_ sender: NSButton) { Settings.shared.numberSections = sender.state == .on }
    @objc private func revisionsChanged(_ sender: NSPopUpButton) {
        Settings.shared.revisionMode = DocumentImporter.RevisionMode.allCases[sender.indexOfSelectedItem]
    }
    @objc private func aiChanged(_ sender: NSButton) { Settings.shared.aiSuggestions = sender.state == .on }
    @objc private func goalChanged(_ sender: NSTextField) {
        Settings.shared.dailyWordGoal = Int(sender.stringValue.filter(\.isNumber)) ?? 0
    }
    @objc private func chooseBibliography() {
        choose(["bib", "json"]) { [weak self] url in Settings.shared.defaultBibliographyPath = url.path; self?.updateLabels() }
    }
    @objc private func clearBibliography() { Settings.shared.defaultBibliographyPath = ""; updateLabels() }
    @objc private func chooseTemplate() {
        choose(["dotx", "docx"]) { [weak self] url in Settings.shared.wordTemplatePath = url.path; self?.updateLabels() }
    }
    @objc private func clearTemplate() { Settings.shared.wordTemplatePath = ""; updateLabels() }
}

/// Restarts the application (used after changing the language).
enum AppRelauncher {
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
