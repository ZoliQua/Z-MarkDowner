import Foundation

/// Converts files between the supported formats (used by batch conversion and Finder services).
public enum DocumentConverter {

    public enum Format: String, CaseIterable {
        case markdown = "md", html, pdf, docx, epub

        public var fileExtension: String { rawValue }
    }

    /// Converts one file into `directory` and returns the written URL (never overwrites existing files).
    @MainActor
    public static func convert(_ source: URL, to format: Format, into directory: URL,
                               options: ExportOptions) async throws -> URL {
        let markdown = try DocumentImporter.markdown(fromFileAt: source)
        var opts = options
        opts.title = source.deletingPathExtension().lastPathComponent
        opts.baseURL = source.deletingLastPathComponent()
        let target = uniqueURL(in: directory, base: opts.title, ext: format.fileExtension, avoiding: source)

        switch format {
        case .markdown:
            try markdown.write(to: target, atomically: true, encoding: .utf8)
        case .html:
            try PDFExporter.html(markdown: markdown, options: opts, forExport: false)
                .write(to: target, atomically: true, encoding: .utf8)
        case .pdf:
            try await PDFExporter.writePDF(markdown: markdown, options: opts, to: target)
        case .docx:
            try DocxExporter.data(markdown: markdown, options: opts).write(to: target, options: .atomic)
        case .epub:
            try EPUBWriter.makeEPUB(markdown: markdown, options: opts).write(to: target, options: .atomic)
        }
        return target
    }

    /// `name.ext`, or `name 2.ext`, `name 3.ext`… if taken (or identical to the source).
    public static func uniqueURL(in directory: URL, base: String, ext: String, avoiding source: URL? = nil) -> URL {
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) || candidate.standardizedFileURL == source?.standardizedFileURL {
            candidate = directory.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

/// DOCX export with processing (citations, numbering) and the Word template.
public enum DocxExporter {

    public static func data(markdown: String, options: ExportOptions,
                            mathImage: ((String, Bool) -> DocxImage?)? = nil) throws -> Data {
        let doc = options.prepare(markdown)
        let base = options.baseURL
        var writer = DocxWriter(title: doc.title ?? options.title) { LocalImage.load($0, base: base) }
        writer.mathImage = mathImage
        writer.paperSize = options.pageSetup.paperSize
        writer.language = options.language
        if let url = templateURL(frontMatter: doc.frontMatter, options: options) {
            writer.template = try DocxTemplate(url: url)
        }
        return writer.makeDocx(document: doc)
    }

    /// `reference-doc:` / `docx-template:` in the front matter (relative to the document) or the default template.
    public static func templateURL(frontMatter: [String: String], options: ExportOptions) -> URL? {
        if let value = frontMatter["reference-doc"] ?? frontMatter["docx-template"], !value.isEmpty {
            if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
            if value.hasPrefix("~") { return URL(fileURLWithPath: (value as NSString).expandingTildeInPath) }
            if let base = options.baseURL { return base.appendingPathComponent(value) }
        }
        guard let url = options.docxTemplate, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
