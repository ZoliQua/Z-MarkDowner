import Foundation

/// Settings for scholarly processing (citations, numbering, cross-references, table of contents).
public struct ProcessingOptions {
    /// Folder of the document; relative bibliography paths are resolved against it.
    public var baseURL: URL?
    /// Style used when the front matter does not name one.
    public var citationStyle: CitationStyle
    /// Bibliography used when the front matter has no `bibliography:` entry.
    public var defaultBibliography: URL?
    /// Number headings (1, 1.1 …) unless the front matter says otherwise.
    public var numberSections: Bool

    public init(baseURL: URL? = nil, citationStyle: CitationStyle = .vancouver,
                defaultBibliography: URL? = nil, numberSections: Bool = false) {
        self.baseURL = baseURL
        self.citationStyle = citationStyle
        self.defaultBibliography = defaultBibliography
        self.numberSections = numberSections
    }
}

public struct ProcessingResult {
    public var document: MDDocument
    /// Citation keys and cross-reference labels that could not be resolved.
    public var unresolved: [String]
    /// Problems such as an unreadable bibliography file.
    public var warnings: [String]
    /// All entries of the loaded bibliographies (for citation pickers).
    public var entries: [BibEntry]
}

/// Resolves citations against a bibliography, numbers headings, figures, tables and equations,
/// resolves cross-references and fills in the table of contents and reference list.
/// All exporters render the processed document, so the output is identical everywhere.
public enum DocumentProcessor {

    public static func process(markdown: String, options: ProcessingOptions) -> ProcessingResult {
        process(MDDocument(markdown: markdown), options: options)
    }

    public static func process(_ doc: MDDocument, options: ProcessingOptions) -> ProcessingResult {
        var run = Run(doc: doc, options: options)
        return run.execute()
    }

    /// Bibliography files named in the front matter (or the default one).
    public static func bibliographyURLs(frontMatter: [String: String], options: ProcessingOptions) -> [URL] {
        if let value = frontMatter["bibliography"], !value.isEmpty {
            return value.split(separator: ",").map { item -> URL in
                let path = item.trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
                if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
                return (options.baseURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appendingPathComponent(path)
            }
        }
        return options.defaultBibliography.map { [$0] } ?? []
    }

    static func isTrue(_ value: String?) -> Bool {
        guard let v = value?.lowercased() else { return false }
        return ["true", "yes", "on", "1"].contains(v)
    }

    // MARK: - Run

    private struct Run {
        let doc: MDDocument
        let options: ProcessingOptions
        let fm: [String: String]
        let language: String?

        var entries: [String: BibEntry] = [:]
        var allEntries: [BibEntry] = []
        var formatter: CitationFormatter
        var warnings: [String] = []
        var unresolved: [String] = []

        // Numbering state
        var numberSections: Bool
        var minLevel = 1
        var sectionCounters = [Int](repeating: 0, count: 7)
        var counters: [MDFigure.Kind: Int] = [:]
        var usedIDs: [String: Int] = [:]
        /// Cross-reference label → (kind, number or title)
        var labels: [String: (kind: String, number: String)] = [:]
        var headings: [(level: Int, text: String, anchor: String)] = []
        var needsWork = false

        init(doc: MDDocument, options: ProcessingOptions) {
            self.doc = doc
            self.options = options
            self.fm = doc.frontMatter
            self.language = doc.frontMatter["lang"] ?? doc.frontMatter["language"]
            let styleName = fm["citation-style"] ?? fm["csl"] ?? ""
            let style = CitationStyle(name: styleName) ?? options.citationStyle
            self.formatter = CitationFormatter(style: style, entries: [:])
            if let explicit = fm["numbersections"] ?? fm["number-sections"] {
                numberSections = DocumentProcessor.isTrue(explicit)
            } else {
                numberSections = options.numberSections
            }
        }

        // MARK: Labels

        func text(_ key: String, _ english: String) -> String { L(key, english, language: language) }

        func prefix(for kind: String, plural: Bool) -> String {
            // pandoc-crossref style overrides: figPrefix, tblPrefix, eqnPrefix, secPrefix
            let fmKey = ["fig": "figprefix", "tbl": "tblprefix", "eq": "eqnprefix", "sec": "secprefix"][kind] ?? ""
            if let custom = fm[fmKey], !custom.isEmpty { return custom + " %@" }
            switch (kind, plural) {
            case ("fig", false): return L("label.figure", "Figure %@", language: language)
            case ("fig", true): return L("label.figures", "Figures %@", language: language)
            case ("tbl", false): return L("label.table", "Table %@", language: language)
            case ("tbl", true): return L("label.tables", "Tables %@", language: language)
            case ("eq", false): return L("label.equation", "Equation (%@)", language: language)
            case ("eq", true): return L("label.equations", "Equations %@", language: language)
            case ("sec", false): return L("label.section", "Section %@", language: language)
            default: return L("label.sections", "Sections %@", language: language)
            }
        }

        func captionLabel(_ kind: MDFigure.Kind, _ number: String) -> String {
            let custom = kind == .figure ? fm["figuretitle"] : kind == .table ? fm["tabletitle"] : nil
            if let custom, !custom.isEmpty { return "\(custom) \(number)" }
            switch kind {
            case .figure: return L("label.figure", "Figure %@", language: language).replacingOccurrences(of: "%@", with: number)
            case .table: return L("label.table", "Table %@", language: language).replacingOccurrences(of: "%@", with: number)
            case .equation: return "(\(number))"
            }
        }

        // MARK: Execute

        mutating func execute() -> ProcessingResult {
            loadBibliography()
            minLevel = doc.blocks.compactMap { b -> Int? in
                if case .heading(let level, _, _) = b { return level }
                return nil
            }.min() ?? 1

            // Pass 1: numbers, anchors and citation order
            var numbered: [MDBlock] = []
            for block in doc.blocks { numbered.append(collect(block, topLevel: true)) }
            var footnotes = doc.footnotes
            for i in footnotes.indices { footnotes[i].blocks = footnotes[i].blocks.map { collect($0, topLevel: false) } }
            formatter.finishRegistration()

            guard needsWork || numberSections || DocumentProcessor.isTrue(fm["toc"]) else {
                return ProcessingResult(document: doc, unresolved: unresolved, warnings: warnings, entries: allEntries)
            }

            // Pass 2: resolve citations / references, fill TOC and bibliography
            var blocks: [MDBlock] = []
            var lines: [Int] = []
            var placedBibliography = false
            for (index, block) in numbered.enumerated() {
                let line = index < doc.blockLines.count ? doc.blockLines[index] : (lines.last ?? 0)
                if isReferencesPlaceholder(block) {
                    if !formatter.order.isEmpty { blocks.append(.bibliography(formatter.bibliography())); lines.append(line) }
                    placedBibliography = true
                    continue
                }
                blocks.append(resolve(block))
                lines.append(line)
            }
            footnotes = footnotes.map { MDFootnote(id: $0.id, blocks: $0.blocks.map { resolve($0) }) }

            if !placedBibliography, !formatter.order.isEmpty {
                let title = fm["reference-section-title"] ?? L("label.references", "References", language: language)
                let last = lines.last ?? 0
                if !title.isEmpty {
                    let anchor = uniqueID("references")
                    blocks.append(.heading(level: minLevel, content: [.text(title)], id: anchor))
                    lines.append(last)
                }
                blocks.append(.bibliography(formatter.bibliography()))
                lines.append(last)
            }

            if DocumentProcessor.isTrue(fm["toc"]), !blocks.contains(where: { if case .tableOfContents = $0 { return true }; return false }) {
                blocks.insert(.tableOfContents(title: tocTitle, entries: tocEntries()), at: 0)
                lines.insert(doc.blockLines.first ?? 0, at: 0)
            }

            var result = MDDocument(blocks: blocks, blockLines: lines, footnotes: footnotes, frontMatter: doc.frontMatter)
            if result.blockLines.count != result.blocks.count { result.blockLines = [] }
            return ProcessingResult(document: result, unresolved: unresolved, warnings: warnings, entries: allEntries)
        }

        mutating func loadBibliography() {
            for url in DocumentProcessor.bibliographyURLs(frontMatter: fm, options: options) {
                do {
                    for e in try Bibliography.load(url) where entries[e.id] == nil {
                        entries[e.id] = e
                        allEntries.append(e)
                    }
                } catch {
                    warnings.append(error.localizedDescription)
                }
            }
            formatter = CitationFormatter(style: formatter.style, entries: entries)
        }

        mutating func uniqueID(_ base: String) -> String {
            var id = base
            if let n = usedIDs[id] { usedIDs[id] = n + 1; id += "-\(n)" } else { usedIDs[id] = 1 }
            return id
        }

        func isReferencesPlaceholder(_ block: MDBlock) -> Bool {
            guard case .paragraph(let content) = block else { return false }
            let t = content.plainText.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "").lowercased()
            return t == ":::{#refs}:::" || t == "<divid=\"refs\"></div>" || t == "[[references]]"
        }

        // MARK: Pass 1

        mutating func collect(_ block: MDBlock, topLevel: Bool) -> MDBlock {
            switch block {
            case .heading(let level, var content, let id):
                var number: String?
                if numberSections && topLevel {
                    let depth = max(1, level - minLevel + 1)
                    sectionCounters[depth] += 1
                    for d in (depth + 1)..<sectionCounters.count { sectionCounters[d] = 0 }
                    number = (1...depth).map { String(sectionCounters[$0]) }.joined(separator: ".")
                }
                collectInlines(content)
                let plain = content.plainText
                let anchor = id.map { uniqueID($0) } ?? uniqueID(HTMLRenderer.slug(plain))
                if let id { labels[id] = ("sec", number ?? plain) }
                if let number { content.insert(.text(number + " "), at: 0) }
                if topLevel { headings.append((level, (number.map { $0 + " " } ?? "") + plain, anchor)) }
                return .heading(level: level, content: content, id: anchor)

            case .paragraph(let content):
                collectInlines(content)
            case .blockquote(let blocks):
                return .blockquote(blocks.map { collect($0, topLevel: false) })
            case .list(var list):
                for i in list.items.indices { list.items[i].blocks = list.items[i].blocks.map { collect($0, topLevel: false) } }
                return .list(list)
            case .table(let table):
                table.header.forEach { collectInlines($0) }
                table.rows.forEach { $0.forEach { collectInlines($0) } }
            case .figure(var figure):
                needsWork = true
                collectInlines(figure.caption)
                figure.content = collect(figure.content, topLevel: false)
                if figure.id != nil || figure.kind != .table {
                    let n = (counters[figure.kind] ?? 0) + 1
                    counters[figure.kind] = n
                    figure.number = "\(n)"
                    figure.label = captionLabel(figure.kind, "\(n)")
                    if let id = figure.id {
                        let kind = figure.kind == .figure ? "fig" : figure.kind == .table ? "tbl" : "eq"
                        labels[id] = (kind, "\(n)")
                    }
                }
                return .figure(figure)
            case .tableOfContents:
                needsWork = true
            default:
                break
            }
            return block
        }

        mutating func collectInlines(_ inlines: [MDInline]) {
            for node in inlines {
                switch node {
                case .citation(let c):
                    needsWork = true
                    for item in c.items where !item.isCrossReference { formatter.register(item.key) }
                case .emphasis(let n), .strong(let n), .strikethrough(let n), .insertion(let n), .deletion(let n), .highlight(let n):
                    collectInlines(n)
                case .link(let text, _, _):
                    collectInlines(text)
                default:
                    break
                }
            }
        }

        // MARK: Pass 2

        mutating func resolve(_ block: MDBlock) -> MDBlock {
            switch block {
            case .heading(let level, let content, let id):
                return .heading(level: level, content: resolveInlines(content), id: id)
            case .paragraph(let content):
                return .paragraph(resolveInlines(content))
            case .blockquote(let blocks):
                return .blockquote(blocks.map { resolve($0) })
            case .list(var list):
                for i in list.items.indices { list.items[i].blocks = list.items[i].blocks.map { resolve($0) } }
                return .list(list)
            case .table(var table):
                table.header = table.header.map { resolveInlines($0) }
                table.rows = table.rows.map { $0.map { resolveInlines($0) } }
                return .table(table)
            case .figure(var figure):
                figure.caption = resolveInlines(figure.caption)
                figure.content = resolve(figure.content)
                return .figure(figure)
            case .tableOfContents:
                return .tableOfContents(title: tocTitle, entries: tocEntries())
            default:
                return block
            }
        }

        var tocTitle: String { fm["toc-title"] ?? L("label.contents", "Contents", language: language) }

        func tocEntries() -> [MDTocEntry] {
            let depth = Int(fm["toc-depth"] ?? "") ?? 3
            return headings.filter { $0.level - minLevel < depth }
                .map { MDTocEntry(level: $0.level - minLevel + 1, text: $0.text, anchor: $0.anchor) }
        }

        mutating func resolveInlines(_ inlines: [MDInline]) -> [MDInline] {
            var out: [MDInline] = []
            for node in inlines {
                switch node {
                case .citation(let c): out += resolveCitation(c)
                case .emphasis(let n): out.append(.emphasis(resolveInlines(n)))
                case .strong(let n): out.append(.strong(resolveInlines(n)))
                case .strikethrough(let n): out.append(.strikethrough(resolveInlines(n)))
                case .insertion(let n): out.append(.insertion(resolveInlines(n)))
                case .deletion(let n): out.append(.deletion(resolveInlines(n)))
                case .highlight(let n): out.append(.highlight(resolveInlines(n)))
                default: out.append(node)
                }
            }
            return out
        }

        mutating func resolveCitation(_ c: MDCitation) -> [MDInline] {
            let crossRefs = c.items.filter(\.isCrossReference)
            if crossRefs.isEmpty {
                let known = c.items.filter { entries[$0.key] != nil }
                guard known.count == c.items.count else {
                    unresolved += c.items.filter { entries[$0.key] == nil }.map(\.key)
                    // Without any bibliography a bare @word is ordinary text (e.g. a social media handle)
                    return [.text(c.raw)]
                }
                return formatter.cite(c.items, inText: c.inText)
            }
            // Cross-references: "Figure 2", "Figures 1, 3"
            guard crossRefs.count == c.items.count else {
                unresolved.append(c.raw)
                return [.text(c.raw)]
            }
            var resolved: [(kind: String, number: String, id: String)] = []
            for item in crossRefs {
                guard let label = labels[item.key] else {
                    unresolved.append(item.key)
                    return [.text(c.raw)]
                }
                resolved.append((label.kind, label.number, item.key))
            }
            let kinds = Set(resolved.map(\.kind))
            var out: [MDInline] = []
            if let first = c.items.first, !first.prefix.isEmpty { out.append(.text(first.prefix + " ")) }
            if kinds.count == 1, resolved.count > 1 {
                let template = prefix(for: resolved[0].kind, plural: true)
                let parts = template.components(separatedBy: "%@")
                out.append(.text(parts.first ?? ""))
                for (i, r) in resolved.enumerated() {
                    if i > 0 { out.append(.text(", ")) }
                    out.append(.link(text: [.text(r.number)], url: "#" + r.id, title: nil))
                }
                out.append(.text(parts.count > 1 ? parts[1] : ""))
            } else {
                for (i, r) in resolved.enumerated() {
                    if i > 0 { out.append(.text(", ")) }
                    let label: String
                    if r.kind == "sec", !numberSections {
                        label = r.number   // the heading's title
                    } else {
                        label = prefix(for: r.kind, plural: false).replacingOccurrences(of: "%@", with: r.number)
                    }
                    out.append(.link(text: [.text(label)], url: "#" + r.id, title: nil))
                }
            }
            if let last = c.items.last, !last.locator.isEmpty { out.append(.text(", " + last.locator)) }
            return out.filter { if case .text(let t) = $0 { return !t.isEmpty }; return true }
        }
    }
}
