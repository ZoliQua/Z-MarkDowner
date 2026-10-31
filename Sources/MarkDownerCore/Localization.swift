import Foundation

/// Localized string lookup. `english` is the development-language text used when no translation exists.
/// Translations live in `<lang>.lproj/Localizable.strings` inside the app bundle.
public func L(_ key: String, _ english: String) -> String {
    Bundle.main.localizedString(forKey: key, value: english, table: nil)
}

/// Localized string in a specific language (e.g. the document's `lang`), falling back to the UI language.
public func L(_ key: String, _ english: String, language: String?) -> String {
    guard let language, let bundle = AppLanguage.bundle(for: language) else { return L(key, english) }
    return bundle.localizedString(forKey: key, value: english, table: nil)
}

/// Localized string with `%@` / `%d` placeholders.
public func LF(_ key: String, _ english: String, _ args: CVarArg...) -> String {
    String(format: L(key, english), locale: Locale.current, arguments: args)
}

/// Languages offered in the app (ISO code, native name).
public enum AppLanguage {
    public static let all: [(code: String, name: String)] = [
        ("en", "English"), ("hu", "Magyar"), ("de", "Deutsch"), ("es", "Español"), ("it", "Italiano"),
        ("fr", "Français"), ("pt", "Português"), ("ru", "Русский"), ("sk", "Slovenčina"), ("cs", "Čeština"),
        ("ro", "Română"), ("tr", "Türkçe"),
    ]

    /// The language chosen in the app (`nil` = follow the system).
    public static var selected: String? {
        get { UserDefaults.standard.string(forKey: "appLanguage") }
        set {
            UserDefaults.standard.set(newValue, forKey: "appLanguage")
            if let code = newValue {
                UserDefaults.standard.set([code], forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }
    }

    private static var bundles: [String: Bundle] = [:]
    private static let bundleLock = NSLock()

    /// The `.lproj` bundle for a language code such as "hu" or "en-US".
    static func bundle(for language: String) -> Bundle? {
        let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        bundleLock.lock()
        defer { bundleLock.unlock() }
        if let cached = bundles[code] { return cached }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
        bundles[code] = bundle
        return bundle
    }

    /// Language currently used for the UI.
    public static var current: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }
}

enum CoreStrings {
    static func exportFailed(_ what: String) -> String {
        LF("error.exportFailed", "Export failed: %@", what)
    }
    static func unsupportedFormat(_ ext: String) -> String {
        LF("error.unsupportedFormat", "The “.%@” format is not supported.", ext)
    }
    static func unreadable(_ name: String) -> String {
        LF("error.unreadable", "The file “%@” could not be read.", name)
    }
    static let notAZip = L("error.notZip", "The file is not a valid ZIP/DOCX package.")
    static func corruptZip(_ what: String) -> String { LF("error.corruptZip", "Damaged ZIP package (%@).", what) }
    static func unsupportedZipMethod(_ m: Int) -> String { LF("error.zipMethod", "Unsupported compression method: %d.", m) }
    static let pdfLocked = L("pdf.locked", "The PDF is password-protected, so its text could not be read.")
    static func pdfNoTextOnPage(_ page: Int) -> String { LF("pdf.noTextOnPage", "No text could be recognised on page %d.", page) }
    static func pdfOCRPages(_ n: Int) -> String { LF("pdf.ocrPages", "Text recognised with OCR on %d pages.", n) }
    static let pdfNoText = L("pdf.noText", "The PDF contains no extractable text.")
}
