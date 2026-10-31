import Foundation

/// Supported citation styles.
public enum CitationStyle: String, CaseIterable {
    /// Numeric, in order of citation (ICMJE / NLM, common in medicine).
    case vancouver
    /// Author–date (APA 7th edition).
    case apa

    /// Recognises names used in front matter (`csl: apa.csl`, `citation-style: Vancouver`).
    public init?(name: String) {
        let lower = name.lowercased()
        if lower.contains("apa") || lower.contains("american-psychological") { self = .apa }
        else if lower.contains("vancouver") || lower.contains("nlm") || lower.contains("icmje")
                    || lower.contains("numeric") || lower.contains("medicine") { self = .vancouver }
        else { return nil }
    }

    public var displayName: String {
        switch self {
        case .vancouver: return "Vancouver"
        case .apa: return "APA 7"
        }
    }
}

/// Formats in-text citations and reference lists for one document.
struct CitationFormatter {
    let style: CitationStyle
    let entries: [String: BibEntry]
    /// Cited keys in order of first appearance.
    private(set) var order: [String] = []
    private var yearSuffix: [String: String] = [:]

    init(style: CitationStyle, entries: [String: BibEntry]) {
        self.style = style
        self.entries = entries
    }

    /// Registers keys in reading order (first pass); call `finishRegistration` afterwards.
    mutating func register(_ key: String) {
        guard entries[key] != nil, !order.contains(key) else { return }
        order.append(key)
    }

    /// APA: "2020a", "2020b" for the same authors and year.
    mutating func finishRegistration() {
        guard style == .apa else { return }
        var groups: [String: [BibEntry]] = [:]
        for key in order {
            guard let e = entries[key] else { continue }
            let authors = e.authors.map { $0.literal ?? $0.family }.joined(separator: "|")
            groups[authors + "#" + e.year, default: []].append(e)
        }
        for (_, list) in groups where list.count > 1 {
            for (i, e) in list.sorted(by: { $0.title.localizedCompare($1.title) == .orderedAscending }).enumerated() {
                yearSuffix[e.id] = String(UnicodeScalar(UInt8(ascii: "a") + UInt8(min(i, 25))))
            }
        }
    }

    func number(_ key: String) -> Int? { order.firstIndex(of: key).map { $0 + 1 } }

    private func year(_ e: BibEntry) -> String {
        (e.year.isEmpty ? "n.d." : e.year) + (yearSuffix[e.id] ?? "")
    }

    // MARK: In-text

    /// Author label for running text: "Kovács", "Kovács & Nagy", "Kovács et al."
    private func authorLabel(_ e: BibEntry, narrative: Bool) -> String {
        let names = e.authors.filter { $0.literal != "et al." }
        guard let first = names.first else {
            return "“" + shortTitle(e.title) + "”"
        }
        let f = first.literal ?? first.family
        switch names.count {
        case 1: return f
        case 2:
            let s = names[1].literal ?? names[1].family
            return style == .apa ? (narrative ? "\(f) and \(s)" : "\(f) & \(s)") : "\(f) and \(s)"
        default: return "\(f) et al."
        }
    }

    private func shortTitle(_ title: String) -> String {
        let words = title.split(separator: " ")
        return words.count > 6 ? words.prefix(6).joined(separator: " ") + "…" : title
    }

    /// Formatted citation; every item must be a known bibliography key.
    func cite(_ items: [MDCitationItem], inText: Bool) -> [MDInline] {
        switch style {
        case .vancouver: return citeNumeric(items, inText: inText)
        case .apa: return citeAuthorDate(items, inText: inText)
        }
    }

    private func link(_ text: String, _ key: String) -> MDInline {
        .link(text: [.text(text)], url: "#ref-" + key, title: nil)
    }

    private func citeNumeric(_ items: [MDCitationItem], inText: Bool) -> [MDInline] {
        var out: [MDInline] = []
        if inText, let first = items.first, let e = entries[first.key] {
            out.append(.text(authorLabel(e, narrative: true) + " "))
        }
        let plain = items.allSatisfy { $0.prefix.isEmpty && $0.locator.isEmpty }
        out.append(.text("["))
        if plain {
            // Compress runs: [1,3–5]
            let numbered = items.compactMap { item in number(item.key).map { ($0, item.key) } }.sorted { $0.0 < $1.0 }
            var i = 0
            var first = true
            while i < numbered.count {
                var j = i
                while j + 1 < numbered.count, numbered[j + 1].0 == numbered[j].0 + 1 { j += 1 }
                if !first { out.append(.text(",")) }
                first = false
                if j - i >= 2 {
                    out.append(link("\(numbered[i].0)", numbered[i].1))
                    out.append(.text("–"))
                    out.append(link("\(numbered[j].0)", numbered[j].1))
                } else {
                    for k in i...j {
                        if k > i { out.append(.text(",")) }
                        out.append(link("\(numbered[k].0)", numbered[k].1))
                    }
                }
                i = j + 1
            }
        } else {
            for (idx, item) in items.enumerated() {
                if idx > 0 { out.append(.text("; ")) }
                if !item.prefix.isEmpty { out.append(.text(item.prefix + " ")) }
                out.append(link("\(number(item.key) ?? 0)", item.key))
                if !item.locator.isEmpty { out.append(.text(", " + item.locator)) }
            }
        }
        out.append(.text("]"))
        return merged(out)
    }

    private func citeAuthorDate(_ items: [MDCitationItem], inText: Bool) -> [MDInline] {
        var out: [MDInline] = []
        if inText {
            for (idx, item) in items.enumerated() {
                guard let e = entries[item.key] else { continue }
                if idx > 0 { out.append(.text("; ")) }
                let loc = item.locator.isEmpty ? "" : ", " + item.locator
                out.append(link(authorLabel(e, narrative: true), item.key))
                out.append(.text(" (\(year(e))\(loc))"))
            }
            return merged(out)
        }
        let sorted = items.count > 1
            ? items.sorted { (entries[$0.key]?.sortKey ?? "") < (entries[$1.key]?.sortKey ?? "") } : items
        out.append(.text("("))
        for (idx, item) in sorted.enumerated() {
            guard let e = entries[item.key] else { continue }
            if idx > 0 { out.append(.text("; ")) }
            if !item.prefix.isEmpty { out.append(.text(item.prefix + " ")) }
            let label = item.suppressAuthor ? year(e) : authorLabel(e, narrative: false) + ", " + year(e)
            out.append(link(label, item.key))
            if !item.locator.isEmpty { out.append(.text(", " + item.locator)) }
        }
        out.append(.text(")"))
        return merged(out)
    }

    /// Joins adjacent text nodes.
    private func merged(_ nodes: [MDInline]) -> [MDInline] {
        var out: [MDInline] = []
        for n in nodes {
            if case .text(let t) = n, case .text(let prev)? = out.last {
                out[out.count - 1] = .text(prev + t)
            } else {
                out.append(n)
            }
        }
        return out
    }

    // MARK: Reference list

    func bibliography() -> [MDBibItem] {
        var keys = order
        if style == .apa {
            keys.sort { a, b in
                let ea = entries[a]!, eb = entries[b]!
                if ea.sortKey != eb.sortKey { return ea.sortKey.localizedCompare(eb.sortKey) == .orderedAscending }
                return (yearSuffix[a] ?? "") < (yearSuffix[b] ?? "")
            }
        }
        return keys.compactMap { key in
            guard let e = entries[key] else { return nil }
            switch style {
            case .vancouver:
                return MDBibItem(anchor: "ref-" + key, label: "\(number(key) ?? 0).", content: vancouver(e))
            case .apa:
                return MDBibItem(anchor: "ref-" + key, label: nil, content: apa(e))
            }
        }
    }

    // MARK: Vancouver (NLM)

    private func vancouverNames(_ names: [BibName]) -> String {
        let real = names.filter { $0.literal != "et al." }
        var list = real.prefix(6).map { n in n.literal ?? (n.initials.isEmpty ? n.family : "\(n.family) \(n.initials)") }
        if real.count > 6 || real.count < names.count { list.append("et al") }
        return list.joined(separator: ", ")
    }

    private func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return "" }
        return ".?!".contains(last) ? t : t + "."
    }

    private func vancouver(_ e: BibEntry) -> [MDInline] {
        var b = InlineBuilder()
        let authors = vancouverNames(e.authors)
        if !authors.isEmpty { b.text(sentence(authors) + " ") }
        switch e.kind {
        case .article:
            b.text(sentence(e.title) + " ")
            let journal = e.containerShort.isEmpty ? e.container : e.containerShort
            if !journal.isEmpty { b.text(sentence(journal) + " ") }
            var tail = e.year
            if !e.volume.isEmpty { tail += ";" + e.volume }
            if !e.issue.isEmpty { tail += "(\(e.issue))" }
            if !e.pages.isEmpty { tail += ":" + e.pages }
            if !tail.isEmpty { b.text(tail + ".") }
        case .book, .thesis, .report, .other:
            var title = e.title
            if e.kind == .thesis { title += " [dissertation]" }
            b.text(sentence(title) + " ")
            if !e.edition.isEmpty { b.text(ordinalEdition(e.edition) + " ed. ") }
            b.text(publication(e) + ".")
        case .chapter, .conference:
            b.text(sentence(e.title) + " ")
            b.text("In: ")
            if !e.editors.isEmpty { b.text(vancouverNames(e.editors) + ", editor" + (e.editors.count > 1 ? "s" : "") + ". ") }
            if !e.container.isEmpty { b.text(sentence(e.container) + " ") }
            b.text(publication(e) + ".")
            if !e.pages.isEmpty { b.text(" p. " + e.pages + ".") }
        case .webpage:
            b.text(e.title + " [Internet]. ")
            if !e.publisher.isEmpty { b.text(e.publisher + "; ") }
            if !e.year.isEmpty { b.text(e.year + ". ") }
            if !e.url.isEmpty { b.text("Available from: "); b.link(e.url, e.url) }
            return b.nodes
        }
        if !e.doi.isEmpty {
            b.text(" doi:")
            b.link(e.doi, "https://doi.org/" + e.doi)
        }
        if !e.pmid.isEmpty { b.text(". PMID: " + e.pmid) }
        if e.doi.isEmpty, e.pmid.isEmpty, !e.url.isEmpty { b.text(" Available from: "); b.link(e.url, e.url) }
        return b.nodes
    }

    private func publication(_ e: BibEntry) -> String {
        var s = ""
        if !e.place.isEmpty { s += e.place + ": " }
        if !e.publisher.isEmpty { s += e.publisher }
        if !e.year.isEmpty { s += (s.isEmpty ? "" : "; ") + e.year }
        return s
    }

    private func ordinalEdition(_ edition: String) -> String {
        guard let n = Int(edition) else { return edition }
        let suffix: String
        switch (n % 10, n % 100) {
        case (1, let h) where h != 11: suffix = "st"
        case (2, let h) where h != 12: suffix = "nd"
        case (3, let h) where h != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    // MARK: APA 7

    private func apaName(_ n: BibName) -> String {
        if let literal = n.literal { return literal }
        return n.dottedInitials.isEmpty ? n.family : "\(n.family), \(n.dottedInitials)"
    }

    private func apaAuthors(_ names: [BibName]) -> String {
        let real = names.filter { $0.literal != "et al." }.map(apaName)
        switch real.count {
        case 0: return ""
        case 1: return real[0]
        case 2: return "\(real[0]), & \(real[1])"
        case 3...20: return real.dropLast().joined(separator: ", ") + ", & " + real.last!
        default: return real.prefix(19).joined(separator: ", ") + ", … " + real.last!
        }
    }

    private func apaEditors(_ names: [BibName]) -> String {
        let list = names.map { n -> String in
            n.literal ?? (n.dottedInitials.isEmpty ? n.family : "\(n.dottedInitials) \(n.family)")
        }
        let joined = list.count <= 2 ? list.joined(separator: " & ") : list.dropLast().joined(separator: ", ") + ", & " + list.last!
        return joined + (names.count > 1 ? " (Eds.)" : " (Ed.)")
    }

    private func apa(_ e: BibEntry) -> [MDInline] {
        var b = InlineBuilder()
        let authors = apaAuthors(e.authors)
        let yearPart = "(\(year(e))). "
        let titleIsItalic = e.kind != .article && e.kind != .chapter && e.kind != .conference
        if authors.isEmpty {
            // No author: the title takes the author position
            if titleIsItalic { b.italic(e.title) } else { b.text(e.title) }
            b.text(" " + yearPart)
        } else {
            b.text(sentence(authors) + " " + yearPart)
            if titleIsItalic {
                b.italic(e.title)
                if !e.edition.isEmpty { b.text(" (\(ordinalEdition(e.edition)) ed.)") }
                b.text(". ")
            } else {
                b.text(sentence(e.title) + " ")
            }
        }
        switch e.kind {
        case .article:
            if !e.container.isEmpty {
                b.italic(e.container)
                if !e.volume.isEmpty { b.text(", "); b.italic(e.volume) }
                if !e.issue.isEmpty { b.text("(\(e.issue))") }
                if !e.pages.isEmpty { b.text(", " + e.pages) }
                b.text(".")
            }
        case .chapter, .conference:
            b.text("In ")
            if !e.editors.isEmpty { b.text(apaEditors(e.editors) + ", ") }
            if !e.container.isEmpty { b.italic(e.container) }
            if !e.pages.isEmpty { b.text(" (pp. \(e.pages))") }
            b.text(".")
            if !e.publisher.isEmpty { b.text(" " + sentence(e.publisher)) }
        default:
            if !e.publisher.isEmpty { b.text(sentence(e.publisher)) }
        }
        if !e.doi.isEmpty {
            b.text(" ")
            b.link("https://doi.org/" + e.doi, "https://doi.org/" + e.doi)
        } else if !e.url.isEmpty {
            b.text(" ")
            b.link(e.url, e.url)
        }
        return b.nodes
    }
}

/// Small helper to assemble inline nodes.
struct InlineBuilder {
    var nodes: [MDInline] = []

    mutating func text(_ s: String) {
        guard !s.isEmpty else { return }
        if case .text(let prev)? = nodes.last { nodes[nodes.count - 1] = .text(prev + s) } else { nodes.append(.text(s)) }
    }

    mutating func italic(_ s: String) {
        guard !s.isEmpty else { return }
        nodes.append(.emphasis([.text(s)]))
    }

    mutating func link(_ text: String, _ url: String) {
        nodes.append(.link(text: [.text(text)], url: url, title: nil))
    }
}
