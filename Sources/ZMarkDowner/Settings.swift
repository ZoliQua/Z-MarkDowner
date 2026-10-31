import AppKit
import MarkDownerCore

/// User preferences (UserDefaults backed). Posts `Settings.didChange` when a value changes.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("ZMarkDownerSettingsDidChange")

    enum Appearance: String, CaseIterable { case system, light, dark }
    enum Paper: String, CaseIterable { case a4, letter }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "editorFontSize": 14.0,
            "viewMode": ViewMode.split.rawValue,
            "previewTheme": PreviewTheme.github.rawValue,
            "appearance": Appearance.system.rawValue,
            "paper": Paper.a4.rawValue,
            "pageNumbers": true,
            "autoPair": true,
            "spellCheck": true,
            "syncScroll": true,
            "showSidebar": false,
            "sidebarTab": 0,
            "renderMath": true,
            "renderDiagrams": true,
            "readableWidth": 860.0,
            "citationStyle": CitationStyle.vancouver.rawValue,
            "numberSections": false,
            "revisionMode": DocumentImporter.RevisionMode.markup.rawValue,
            "liveFormatting": false,
            "dailyWordGoal": 0,
        ])
        DocumentImporter.revisionMode = revisionMode
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Editor

    var editorFontName: String {
        get { defaults.string(forKey: "editorFontName") ?? "" }
        set { defaults.set(newValue, forKey: "editorFontName"); changed() }
    }

    var editorFontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: "editorFontSize")) }
        set { defaults.set(Double(min(max(newValue, 9), 36)), forKey: "editorFontSize"); changed() }
    }

    var readableWidth: CGFloat {
        get { CGFloat(defaults.double(forKey: "readableWidth")) }
        set { defaults.set(Double(newValue), forKey: "readableWidth"); changed() }
    }

    var autoPair: Bool {
        get { defaults.bool(forKey: "autoPair") }
        set { defaults.set(newValue, forKey: "autoPair"); changed() }
    }

    var spellCheck: Bool {
        get { defaults.bool(forKey: "spellCheck") }
        set { defaults.set(newValue, forKey: "spellCheck"); changed() }
    }

    var focusMode: Bool {
        get { defaults.bool(forKey: "focusMode") }
        set { defaults.set(newValue, forKey: "focusMode"); changed() }
    }

    var typewriterMode: Bool {
        get { defaults.bool(forKey: "typewriterMode") }
        set { defaults.set(newValue, forKey: "typewriterMode"); changed() }
    }

    /// The editor font (monospaced system font unless a family is chosen).
    func editorFont(size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSFont {
        let s = size ?? editorFontSize
        if !editorFontName.isEmpty, let font = NSFont(name: editorFontName, size: s) {
            return weight == .bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
        }
        return .monospacedSystemFont(ofSize: s, weight: weight)
    }

    // MARK: View

    var defaultViewMode: ViewMode {
        get { ViewMode(rawValue: defaults.integer(forKey: "viewMode")) ?? .split }
        set { defaults.set(newValue.rawValue, forKey: "viewMode") }
    }

    var appearance: Appearance {
        get { Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance"); applyAppearance(); changed() }
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var syncScroll: Bool {
        get { defaults.bool(forKey: "syncScroll") }
        set { defaults.set(newValue, forKey: "syncScroll"); changed() }
    }

    var showSidebar: Bool {
        get { defaults.bool(forKey: "showSidebar") }
        set { defaults.set(newValue, forKey: "showSidebar") }
    }

    var sidebarTab: Int {
        get { defaults.integer(forKey: "sidebarTab") }
        set { defaults.set(newValue, forKey: "sidebarTab") }
    }

    var sidebarFolder: URL? {
        get { defaults.string(forKey: "sidebarFolder").map { URL(fileURLWithPath: $0) } }
        set { defaults.set(newValue?.path, forKey: "sidebarFolder") }
    }

    // MARK: Preview & export

    var previewTheme: PreviewTheme {
        get { PreviewTheme(rawValue: defaults.string(forKey: "previewTheme") ?? "") ?? .github }
        set { defaults.set(newValue.rawValue, forKey: "previewTheme"); changed() }
    }

    var customCSSPath: String {
        get { defaults.string(forKey: "customCSSPath") ?? "" }
        set { defaults.set(newValue, forKey: "customCSSPath"); changed() }
    }

    var customCSS: String {
        guard !customCSSPath.isEmpty else { return "" }
        return (try? String(contentsOfFile: customCSSPath, encoding: .utf8)) ?? ""
    }

    var paper: Paper {
        get { Paper(rawValue: defaults.string(forKey: "paper") ?? "") ?? .a4 }
        set { defaults.set(newValue.rawValue, forKey: "paper"); changed() }
    }

    var pageNumbers: Bool {
        get { defaults.bool(forKey: "pageNumbers") }
        set { defaults.set(newValue, forKey: "pageNumbers"); changed() }
    }

    var renderMath: Bool {
        get { defaults.bool(forKey: "renderMath") }
        set { defaults.set(newValue, forKey: "renderMath"); changed() }
    }

    var renderDiagrams: Bool {
        get { defaults.bool(forKey: "renderDiagrams") }
        set { defaults.set(newValue, forKey: "renderDiagrams"); changed() }
    }

    // MARK: Writing (citations, Word)

    var citationStyle: CitationStyle {
        get { CitationStyle(rawValue: defaults.string(forKey: "citationStyle") ?? "") ?? .vancouver }
        set { defaults.set(newValue.rawValue, forKey: "citationStyle"); changed() }
    }

    /// Bibliography (.bib / .json) used when a document does not name one.
    var defaultBibliographyPath: String {
        get { defaults.string(forKey: "defaultBibliographyPath") ?? "" }
        set { defaults.set(newValue, forKey: "defaultBibliographyPath"); changed() }
    }

    var defaultBibliography: URL? {
        defaultBibliographyPath.isEmpty ? nil : URL(fileURLWithPath: defaultBibliographyPath)
    }

    var numberSections: Bool {
        get { defaults.bool(forKey: "numberSections") }
        set { defaults.set(newValue, forKey: "numberSections"); changed() }
    }

    /// Word template (.dotx / .docx) for DOCX export.
    var wordTemplatePath: String {
        get { defaults.string(forKey: "wordTemplatePath") ?? "" }
        set { defaults.set(newValue, forKey: "wordTemplatePath"); changed() }
    }

    var revisionMode: DocumentImporter.RevisionMode {
        get { DocumentImporter.RevisionMode(rawValue: defaults.string(forKey: "revisionMode") ?? "") ?? .markup }
        set {
            defaults.set(newValue.rawValue, forKey: "revisionMode")
            DocumentImporter.revisionMode = newValue
            changed()
        }
    }

    /// Hides Markdown markup outside the line being edited (WYSIWYG-like editing).
    var liveFormatting: Bool {
        get { defaults.bool(forKey: "liveFormatting") }
        set { defaults.set(newValue, forKey: "liveFormatting"); changed() }
    }

    /// Words to write per day (0 = no goal).
    var dailyWordGoal: Int {
        get { defaults.integer(forKey: "dailyWordGoal") }
        set { defaults.set(max(0, newValue), forKey: "dailyWordGoal"); changed() }
    }

    var processingOptions: ProcessingOptions {
        ProcessingOptions(citationStyle: citationStyle, defaultBibliography: defaultBibliography, numberSections: numberSections)
    }

    var pageSetup: PageSetup {
        PageSetup(paperSize: paper == .a4 ? PageSetup.a4 : PageSetup.letter, pageNumbers: pageNumbers)
    }

    /// Export options for a document.
    func exportOptions(title: String, baseURL: URL?) -> ExportOptions {
        var options = ExportOptions(title: title, baseURL: baseURL, theme: previewTheme, customCSS: customCSS,
                                    pageSetup: pageSetup, headHTML: WebAssets.headHTML(for: .export),
                                    assetsDirectory: WebAssets.directory, language: AppLanguage.current)
        options.citationStyle = citationStyle
        options.defaultBibliography = defaultBibliography
        options.numberSections = numberSections
        options.docxTemplate = wordTemplatePath.isEmpty ? nil : URL(fileURLWithPath: wordTemplatePath)
        return options
    }
}
