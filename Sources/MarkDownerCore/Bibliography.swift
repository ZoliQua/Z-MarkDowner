import Foundation

/// A person in a reference (author or editor).
public struct BibName: Equatable {
    public var family: String
    public var given: String
    /// Institutional or otherwise unsplittable name ("World Health Organization").
    public var literal: String?

    public init(family: String, given: String = "", literal: String? = nil) {
        self.family = family
        self.given = given
        self.literal = literal
    }

    /// Initials without punctuation ("JA" for "John Adam").
    var initials: String {
        given.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" })
            .compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    /// Initials with periods ("J. A.").
    var dottedInitials: String {
        let parts = given.split(separator: " ").map { part -> String in
            part.split(separator: "-").compactMap { $0.first.map { "\(String($0).uppercased())." } }.joined(separator: "-")
        }
        return parts.joined(separator: " ")
    }
}

/// One bibliography entry (normalised from BibTeX or CSL-JSON).
public struct BibEntry: Equatable {
    public enum Kind: String { case article, book, chapter, conference, thesis, report, webpage, other }

    public var id: String
    public var kind: Kind
    public var authors: [BibName] = []
    public var editors: [BibName] = []
    public var title = ""
    /// Journal, book or proceedings title.
    public var container = ""
    public var containerShort = ""
    public var publisher = ""
    public var place = ""
    public var year = ""
    public var volume = ""
    public var issue = ""
    public var pages = ""
    public var edition = ""
    public var doi = ""
    public var url = ""
    public var pmid = ""

    public init(id: String, kind: Kind = .article) {
        self.id = id
        self.kind = kind
    }

    /// Family name of the first author, or the title when there is no author (used for sorting and labels).
    var sortKey: String {
        let name = authors.first.map { $0.literal ?? $0.family } ?? title
        return name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) + " " + year + " " + title
    }
}

// MARK: - Loading

public enum BibliographyError: LocalizedError {
    case unreadable(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): return CoreStrings.unreadable(name)
        case .unsupported(let ext): return CoreStrings.unsupportedFormat(ext)
        }
    }
}

public enum Bibliography {

    /// Parses `.bib` (BibTeX / BibLaTeX) or `.json` (CSL-JSON) data.
    public static func parse(_ text: String, fileExtension: String) throws -> [BibEntry] {
        switch fileExtension.lowercased() {
        case "bib", "bibtex", "biblatex": return BibTeX.parse(text)
        case "json", "csljson": return try CSLJSON.parse(Data(text.utf8))
        default: throw BibliographyError.unsupported(fileExtension)
        }
    }

    private static var cache: [String: (Date, [BibEntry])] = [:]
    private static let lock = NSLock()

    /// Loads a bibliography file, cached until the file changes.
    public static func load(_ url: URL) throws -> [BibEntry] {
        let path = url.standardizedFileURL.path
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        lock.lock()
        if let cached = cache[path], cached.0 == modified { lock.unlock(); return cached.1 }
        lock.unlock()
        guard let data = FileManager.default.contents(atPath: path) else {
            throw BibliographyError.unreadable(url.lastPathComponent)
        }
        let entries = try parse(DocumentImporter.decodeText(data), fileExtension: url.pathExtension)
        lock.lock()
        cache[path] = (modified, entries)
        lock.unlock()
        return entries
    }

    /// Generates a citation key such as `kovacs2021` that is not in `existing`.
    public static func makeKey(for entry: BibEntry, existing: Set<String>) -> String {
        let name = entry.authors.first.map { $0.literal ?? $0.family } ?? entry.title.split(separator: " ").first.map(String.init) ?? "ref"
        let ascii = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let base = (ascii.isEmpty ? "ref" : String(ascii.prefix(20))) + entry.year.filter(\.isNumber)
        var key = base
        var suffix = UInt8(ascii: "a")
        while existing.contains(key) {
            key = base + String(UnicodeScalar(suffix))
            suffix += 1
        }
        return key
    }
}

// MARK: - BibTeX

public enum BibTeX {

    public static func parse(_ text: String) -> [BibEntry] {
        var reader = Reader(Array(text))
        var strings: [String: String] = [
            "jan": "1", "feb": "2", "mar": "3", "apr": "4", "may": "5", "jun": "6",
            "jul": "7", "aug": "8", "sep": "9", "oct": "10", "nov": "11", "dec": "12",
        ]
        var entries: [BibEntry] = []
        while reader.skip(to: "@") {
            reader.i += 1
            let type = reader.word().lowercased()
            reader.skipSpace()
            guard reader.i < reader.c.count, reader.c[reader.i] == "{" || reader.c[reader.i] == "(" else { continue }
            let close: Character = reader.c[reader.i] == "{" ? "}" : ")"
            reader.i += 1
            switch type {
            case "comment", "preamble":
                reader.skipBalanced(close)
            case "string":
                for (k, v) in reader.fields(close: close, strings: strings) { strings[k] = v }
            default:
                reader.skipSpace()
                var key = ""
                while reader.i < reader.c.count, reader.c[reader.i] != ",", reader.c[reader.i] != close {
                    key.append(reader.c[reader.i]); reader.i += 1
                }
                if reader.i < reader.c.count, reader.c[reader.i] == "," { reader.i += 1 }
                let fields = reader.fields(close: close, strings: strings)
                entries.append(entry(type: type, key: key.trimmingCharacters(in: .whitespacesAndNewlines), fields: fields))
            }
        }
        return entries
    }

    private static func entry(type: String, key: String, fields: [String: String]) -> BibEntry {
        let kind: BibEntry.Kind
        switch type {
        case "article": kind = .article
        case "book", "booklet", "mvbook": kind = .book
        case "incollection", "inbook", "bookinbook": kind = .chapter
        case "inproceedings", "conference", "proceedings": kind = .conference
        case "phdthesis", "mastersthesis", "thesis": kind = .thesis
        case "techreport", "report": kind = .report
        case "online", "electronic", "www", "webpage": kind = .webpage
        default: kind = .other
        }
        var e = BibEntry(id: key, kind: kind)
        func f(_ name: String) -> String { latexToUnicode(fields[name] ?? "") }
        e.authors = names(fields["author"] ?? "")
        e.editors = names(fields["editor"] ?? "")
        e.title = f("title")
        switch kind {
        case .article: e.container = f("journal").isEmpty ? f("journaltitle") : f("journal")
        case .chapter, .conference: e.container = f("booktitle")
        default: e.container = f("journal")
        }
        e.containerShort = f("shortjournal")
        e.publisher = f("publisher").isEmpty ? (f("school").isEmpty ? f("institution") : f("school")) : f("publisher")
        e.place = f("address").isEmpty ? f("location") : f("address")
        e.year = f("year")
        if e.year.isEmpty, let date = fields["date"] { e.year = String(date.prefix(4)) }
        e.volume = f("volume")
        e.issue = f("number").isEmpty ? f("issue") : f("number")
        e.pages = f("pages").replacingOccurrences(of: "--", with: "–")
        e.edition = f("edition")
        e.doi = (fields["doi"] ?? "").trimmingCharacters(in: .whitespaces)
        e.url = (fields["url"] ?? "").trimmingCharacters(in: .whitespaces)
        e.pmid = (fields["pmid"] ?? "").trimmingCharacters(in: .whitespaces)
        return e
    }

    /// Splits "Last, First and First Last and {Organisation}" into names.
    static func names(_ value: String) -> [BibName] {
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var parts: [String] = []
        var depth = 0
        var current = ""
        let chars = Array(value)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1 }
            if depth == 0, ch.isWhitespace, i + 4 < chars.count,
               String(chars[(i + 1)...(i + 3)]).lowercased() == "and", chars[i + 4].isWhitespace {
                parts.append(current)
                current = ""
                i += 5
                continue
            }
            current.append(ch)
            i += 1
        }
        parts.append(current)
        return parts.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.lowercased() == "others" { return BibName(family: "", literal: "et al.") }
            // A fully braced name is literal
            if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), !trimmed.dropFirst().dropLast().contains("{") {
                return BibName(family: "", literal: latexToUnicode(String(trimmed.dropFirst().dropLast())))
            }
            let commaParts = splitTopLevel(trimmed, on: ",")
            if commaParts.count >= 2 {
                let given = commaParts.count == 3 ? commaParts[2] : commaParts[1]
                return BibName(family: latexToUnicode(commaParts[0]), given: latexToUnicode(given))
            }
            let words = splitTopLevel(trimmed, on: " ").filter { !$0.isEmpty }
            guard words.count > 1 else { return BibName(family: latexToUnicode(trimmed)) }
            // "von" particles (lowercase words) belong to the family name
            var familyStart = words.count - 1
            while familyStart > 1, let first = words[familyStart - 1].first, first.isLowercase { familyStart -= 1 }
            return BibName(family: latexToUnicode(words[familyStart...].joined(separator: " ")),
                           given: latexToUnicode(words[..<familyStart].joined(separator: " ")))
        }
    }

    private static func splitTopLevel(_ s: String, on separator: Character) -> [String] {
        var out: [String] = []
        var depth = 0
        var current = ""
        for ch in s {
            if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 }
            if ch == separator && depth == 0 {
                out.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else {
                current.append(ch)
            }
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }

    private static let accents: [Character: [Character: String]] = [
        "'": ["a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý", "c": "ć", "n": "ń", "s": "ś", "z": "ź",
              "A": "Á", "E": "É", "I": "Í", "O": "Ó", "U": "Ú", "Y": "Ý", "C": "Ć", "N": "Ń", "S": "Ś", "Z": "Ź"],
        "`": ["a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù", "A": "À", "E": "È", "I": "Ì", "O": "Ò", "U": "Ù"],
        "^": ["a": "â", "e": "ê", "i": "î", "o": "ô", "u": "û", "A": "Â", "E": "Ê", "I": "Î", "O": "Ô", "U": "Û"],
        "\"": ["a": "ä", "e": "ë", "i": "ï", "o": "ö", "u": "ü", "y": "ÿ", "A": "Ä", "E": "Ë", "I": "Ï", "O": "Ö", "U": "Ü"],
        "H": ["o": "ő", "u": "ű", "O": "Ő", "U": "Ű"],
        "~": ["a": "ã", "n": "ñ", "o": "õ", "A": "Ã", "N": "Ñ", "O": "Õ"],
        "c": ["c": "ç", "s": "ş", "t": "ţ", "C": "Ç", "S": "Ş", "T": "Ţ"],
        "v": ["c": "č", "d": "ď", "e": "ě", "n": "ň", "r": "ř", "s": "š", "t": "ť", "z": "ž",
              "C": "Č", "D": "Ď", "E": "Ě", "N": "Ň", "R": "Ř", "S": "Š", "T": "Ť", "Z": "Ž"],
        "u": ["a": "ă", "g": "ğ", "A": "Ă", "G": "Ğ"],
        "r": ["u": "ů", "a": "å", "U": "Ů", "A": "Å"],
        "k": ["a": "ą", "e": "ę", "A": "Ą", "E": "Ę"],
        ".": ["z": "ż", "Z": "Ż", "I": "İ"],
        "=": ["a": "ā", "e": "ē", "o": "ō"],
    ]

    private static let symbols: [String: String] = [
        "ss": "ß", "o": "ø", "O": "Ø", "ae": "æ", "AE": "Æ", "oe": "œ", "OE": "Œ", "aa": "å", "AA": "Å",
        "l": "ł", "L": "Ł", "i": "ı", "&": "&", "%": "%", "$": "$", "_": "_", "#": "#",
        "textendash": "–", "textemdash": "—", "ldots": "…", "dots": "…",
    ]

    /// Converts common LaTeX accent commands (`{\'a}`, `\H{o}`, `\ss`) to Unicode and removes braces.
    public static func latexToUnicode(_ input: String) -> String {
        guard input.contains("\\") || input.contains("{") || input.contains("--") || input.contains("~") else {
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let c = Array(input)
        var out = ""
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count {
                let cmd = c[i + 1]
                if let table = accents[cmd], !cmd.isLetter || (i + 2 < c.count && (c[i + 2] == "{" || c[i + 2] == " ")) {
                    // \'a, \'{a}, \H{o}, \c c
                    var j = i + 2
                    while j < c.count, c[j] == " " { j += 1 }
                    var letter: Character?
                    if j < c.count, c[j] == "{" {
                        if j + 1 < c.count, c[j + 1] == "\\", j + 2 < c.count, c[j + 2] == "i" { letter = "i"; j += 3 }
                        else if j + 1 < c.count { letter = c[j + 1]; j += 2 }
                        if j < c.count, c[j] == "}" { j += 1 }
                    } else if j < c.count {
                        letter = c[j]; j += 1
                    }
                    if let letter, let mapped = table[letter] { out += mapped } else if let letter { out.append(letter) }
                    i = j
                    continue
                }
                // \ss, \o, \textendash …
                var j = i + 1
                var name = ""
                if c[j].isLetter {
                    while j < c.count, c[j].isLetter { name.append(c[j]); j += 1 }
                } else {
                    name = String(c[j]); j += 1
                }
                if let symbol = symbols[name] {
                    out += symbol
                    if name.first?.isLetter == true, j < c.count, c[j] == " " { j += 1 }
                } else if name.first?.isLetter == true {
                    // Unknown command such as \emph or \textit: keep its argument
                    while j < c.count, c[j] == " " { j += 1 }
                }
                i = j
                continue
            }
            if ch == "{" || ch == "}" { i += 1; continue }
            if ch == "~" { out.append(" "); i += 1; continue }
            if ch == "-", i + 2 < c.count, c[i + 1] == "-", c[i + 2] == "-" { out += "—"; i += 3; continue }
            if ch == "-", i + 1 < c.count, c[i + 1] == "-" { out += "–"; i += 2; continue }
            out.append(ch)
            i += 1
        }
        return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// BibTeX source for an entry (used when references are added from DOI / PubMed).
    public static func format(_ e: BibEntry) -> String {
        let type: String
        switch e.kind {
        case .article: type = "article"
        case .book: type = "book"
        case .chapter: type = "incollection"
        case .conference: type = "inproceedings"
        case .thesis: type = "phdthesis"
        case .report: type = "techreport"
        case .webpage: type = "online"
        case .other: type = "misc"
        }
        func person(_ n: BibName) -> String {
            if let literal = n.literal { return "{\(literal)}" }
            return n.given.isEmpty ? n.family : "\(n.family), \(n.given)"
        }
        var fields: [(String, String)] = []
        if !e.authors.isEmpty { fields.append(("author", e.authors.map(person).joined(separator: " and "))) }
        if !e.editors.isEmpty { fields.append(("editor", e.editors.map(person).joined(separator: " and "))) }
        fields.append(("title", e.title))
        let containerField = e.kind == .article ? "journal" : (e.kind == .chapter || e.kind == .conference ? "booktitle" : "")
        if !containerField.isEmpty { fields.append((containerField, e.container)) }
        fields += [("shortjournal", e.containerShort), ("publisher", e.publisher), ("address", e.place), ("year", e.year),
                   ("volume", e.volume), ("number", e.issue), ("pages", e.pages.replacingOccurrences(of: "–", with: "--")),
                   ("edition", e.edition), ("doi", e.doi), ("url", e.url), ("pmid", e.pmid)]
        let body = fields.filter { !$0.1.isEmpty }
            .map { "  \($0.0) = {\($0.1.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: ""))}" }
            .joined(separator: ",\n")
        return "@\(type){\(e.id),\n\(body)\n}\n"
    }

    // MARK: Reader

    private struct Reader {
        let c: [Character]
        var i = 0
        init(_ c: [Character]) { self.c = c }

        mutating func skip(to ch: Character) -> Bool {
            while i < c.count, c[i] != ch { i += 1 }
            return i < c.count
        }

        mutating func skipSpace() {
            while i < c.count, c[i].isWhitespace { i += 1 }
            // Comments (% to end of line)
            if i < c.count, c[i] == "%" {
                while i < c.count, c[i] != "\n" { i += 1 }
                skipSpace()
            }
        }

        mutating func word() -> String {
            var w = ""
            while i < c.count, c[i].isLetter || c[i].isNumber || c[i] == "_" || c[i] == "-" || c[i] == ":" { w.append(c[i]); i += 1 }
            return w
        }

        mutating func skipBalanced(_ close: Character) {
            var depth = 0
            while i < c.count {
                if c[i] == "{" { depth += 1 }
                if c[i] == "}" { if depth == 0 && close == "}" { i += 1; return }; depth -= 1 }
                if c[i] == close && depth == 0 { i += 1; return }
                i += 1
            }
        }

        mutating func fields(close: Character, strings: [String: String]) -> [String: String] {
            var result: [String: String] = [:]
            while i < c.count {
                skipSpace()
                if i < c.count, c[i] == close { i += 1; break }
                if i < c.count, c[i] == "," { i += 1; continue }
                let name = word().lowercased()
                guard !name.isEmpty else { i += 1; continue }
                skipSpace()
                guard i < c.count, c[i] == "=" else { continue }
                i += 1
                result[name] = value(close: close, strings: strings)
            }
            return result
        }

        /// A field value: {braced}, "quoted", number or macro, joined with #.
        mutating func value(close: Character, strings: [String: String]) -> String {
            var out = ""
            while i < c.count {
                skipSpace()
                guard i < c.count else { break }
                let ch = c[i]
                if ch == "{" {
                    i += 1
                    var depth = 0
                    var v = ""
                    while i < c.count {
                        if c[i] == "{" { depth += 1 }
                        if c[i] == "}" { if depth == 0 { i += 1; break }; depth -= 1 }
                        v.append(c[i]); i += 1
                    }
                    out += v
                } else if ch == "\"" {
                    i += 1
                    var depth = 0
                    var v = ""
                    while i < c.count {
                        if c[i] == "{" { depth += 1 }
                        if c[i] == "}" { depth -= 1 }
                        if c[i] == "\"" && depth == 0 { i += 1; break }
                        v.append(c[i]); i += 1
                    }
                    out += v
                } else {
                    var v = ""
                    while i < c.count, !c[i].isWhitespace, c[i] != ",", c[i] != "#", c[i] != close { v.append(c[i]); i += 1 }
                    out += strings[v.lowercased()] ?? v
                }
                skipSpace()
                if i < c.count, c[i] == "#" { i += 1; continue }
                break
            }
            return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }
    }
}

// MARK: - CSL-JSON

public enum CSLJSON {

    public static func parse(_ data: Data) throws -> [BibEntry] {
        let json = try JSONSerialization.jsonObject(with: data)
        if let array = json as? [[String: Any]] { return array.map(entry) }
        if let single = json as? [String: Any] {
            if let items = single["items"] as? [[String: Any]] { return items.map(entry) }
            return [entry(single)]
        }
        return []
    }

    public static func entry(_ o: [String: Any]) -> BibEntry {
        func str(_ key: String) -> String {
            if let s = o[key] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let n = o[key] as? NSNumber { return n.stringValue }
            if let a = o[key] as? [String], let first = a.first { return first }
            return ""
        }
        let kind: BibEntry.Kind
        switch str("type") {
        case "article-journal", "article", "article-magazine", "article-newspaper", "review": kind = .article
        case "book": kind = .book
        case "chapter", "entry-encyclopedia", "entry-dictionary": kind = .chapter
        case "paper-conference": kind = .conference
        case "thesis": kind = .thesis
        case "report": kind = .report
        case "webpage", "post-weblog", "post": kind = .webpage
        default: kind = .other
        }
        var id = str("id")
        if id.hasPrefix("pmid:") { id = "pmid" + id.dropFirst(5) }
        var e = BibEntry(id: id, kind: kind)
        e.authors = names(o["author"])
        e.editors = names(o["editor"])
        e.title = stripTags(str("title"))
        e.container = stripTags(str("container-title"))
        e.containerShort = str("container-title-short").isEmpty ? str("journalAbbreviation") : str("container-title-short")
        e.publisher = str("publisher")
        e.place = str("publisher-place")
        e.volume = str("volume")
        e.issue = str("issue")
        e.pages = str("page").replacingOccurrences(of: "-", with: "–")
        e.edition = str("edition")
        e.doi = str("DOI")
        e.url = str("URL")
        e.pmid = str("PMID")
        for key in ["issued", "published-print", "published-online", "created"] {
            if let issued = o[key] as? [String: Any] {
                if let parts = issued["date-parts"] as? [[Any]], let y = parts.first?.first {
                    e.year = (y as? NSNumber)?.stringValue ?? (y as? String) ?? ""
                } else if let raw = issued["raw"] as? String ?? issued["literal"] as? String {
                    e.year = String(raw.prefix(4))
                }
                if !e.year.isEmpty { break }
            }
        }
        return e
    }

    private static func names(_ value: Any?) -> [BibName] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.map { n in
            if let literal = n["literal"] as? String { return BibName(family: "", literal: literal) }
            let particle = (n["non-dropping-particle"] as? String).map { $0 + " " } ?? ""
            return BibName(family: particle + ((n["family"] as? String) ?? ""), given: (n["given"] as? String) ?? "")
        }
    }

    /// Crossref titles may contain HTML/MathML tags.
    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// CSL-JSON object for an entry (used when appending to a `.json` bibliography).
    public static func object(_ e: BibEntry) -> [String: Any] {
        let type: String
        switch e.kind {
        case .article: type = "article-journal"
        case .book: type = "book"
        case .chapter: type = "chapter"
        case .conference: type = "paper-conference"
        case .thesis: type = "thesis"
        case .report: type = "report"
        case .webpage: type = "webpage"
        case .other: type = "document"
        }
        func people(_ list: [BibName]) -> [[String: String]] {
            list.map { $0.literal.map { ["literal": $0] } ?? ["family": $0.family, "given": $0.given] }
        }
        var o: [String: Any] = ["id": e.id, "type": type, "title": e.title]
        if !e.authors.isEmpty { o["author"] = people(e.authors) }
        if !e.editors.isEmpty { o["editor"] = people(e.editors) }
        if let y = Int(e.year) { o["issued"] = ["date-parts": [[y]]] }
        let fields: [(String, String)] = [("container-title", e.container), ("container-title-short", e.containerShort),
                                          ("publisher", e.publisher), ("publisher-place", e.place), ("volume", e.volume),
                                          ("issue", e.issue), ("page", e.pages), ("edition", e.edition), ("DOI", e.doi),
                                          ("URL", e.url), ("PMID", e.pmid)]
        for (k, v) in fields where !v.isEmpty { o[k] = v }
        return o
    }
}
