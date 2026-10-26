import Foundation

/// Creates EPUB 3 books from Markdown (single XHTML content document with a heading-based navigation).
public enum EPUBWriter {

    public static func makeEPUB(markdown: String, options: ExportOptions) -> Data {
        let doc = MDDocument(markdown: markdown)
        let title = doc.title ?? options.title
        let language = doc.frontMatter["lang"] ?? doc.frontMatter["language"]
            ?? (options.language.isEmpty ? "en" : options.language)
        let author = doc.frontMatter["author"] ?? ""

        // Collect local images into the package
        var images: [(name: String, data: Data, mime: String)] = []
        var imageNames: [String: String] = [:]
        let base = options.baseURL
        let imageURL: (String) -> String = { src in
            if let existing = imageNames[src] { return existing }
            guard let image = LocalImage.load(src, base: base) else { return src }
            let name = "images/img\(images.count + 1).\(image.fileExtension)"
            images.append((name, image.data, "image/\(image.fileExtension)"))
            imageNames[src] = name
            return name
        }

        let body = HTMLRenderer.render(document: doc, options: .init(imageURL: imageURL, xhtml: true))
        let css = Stylesheets.css(theme: options.theme, forExport: true, custom: options.customCSS)
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(xml(language))" lang="\(xml(language))">
        <head><meta charset="utf-8" /><title>\(xml(title))</title><link rel="stylesheet" type="text/css" href="style.css" /></head>
        <body><section class="markdown-body" epub:type="bodymatter">\(xhtmlClean(body))</section></body>
        </html>
        """

        let uuid = UUID().uuidString.lowercased()
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        var manifest = """
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
        <item id="css" href="style.css" media-type="text/css"/>
        """
        for (i, img) in images.enumerated() {
            manifest += "\n<item id=\"img\(i + 1)\" href=\"\(img.name)\" media-type=\"\(img.mime)\"/>"
        }
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(xml(language))">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">urn:uuid:\(uuid)</dc:identifier>
        <dc:title>\(xml(title))</dc:title>
        <dc:language>\(xml(language))</dc:language>
        \(author.isEmpty ? "" : "<dc:creator>\(xml(author))</dc:creator>")
        \(doc.frontMatter["date"].map { "<dc:date>\(xml($0))</dc:date>" } ?? "")
        \(doc.frontMatter["keywords"].map { "<dc:subject>\(xml($0))</dc:subject>" } ?? "")
        <meta property="dcterms:modified">\(modified)</meta>
        </metadata>
        <manifest>
        \(manifest)
        </manifest>
        <spine><itemref idref="content"/></spine>
        </package>
        """

        // Navigation from headings (ids generated the same way as by the HTML renderer)
        var used: [String: Int] = [:]
        var navItems: [(Int, String, String)] = []
        for item in doc.outline {
            var id = HTMLRenderer.slug(item.text)
            if let n = used[id] { used[id] = n + 1; id += "-\(n)" } else { used[id] = 1 }
            if item.level <= 3 { navItems.append((item.level, item.text, id)) }
        }
        if navItems.isEmpty { navItems = [(1, title, "")] }
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8" /><title>\(xml(title))</title></head>
        <body><nav epub:type="toc" id="toc"><h1>\(xml(title))</h1>\(navList(navItems))</nav></body>
        </html>
        """

        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """

        var zip = ZipWriter()
        zip.add(path: "mimetype", string: "application/epub+zip") // must be first and uncompressed
        zip.add(path: "META-INF/container.xml", string: container)
        zip.add(path: "OEBPS/content.opf", string: opf)
        zip.add(path: "OEBPS/nav.xhtml", string: nav)
        zip.add(path: "OEBPS/content.xhtml", string: content)
        zip.add(path: "OEBPS/style.css", string: css)
        for img in images { zip.add(path: "OEBPS/" + img.name, data: img.data) }
        return zip.finish()
    }

    /// Nested <ol> lists for the navigation document.
    private static func navList(_ items: [(Int, String, String)]) -> String {
        var index = 0
        func build(_ level: Int) -> String {
            var out = "<ol>"
            while index < items.count {
                let (l, text, id) = items[index]
                if l < level { break }
                index += 1
                out += "<li><a href=\"content.xhtml\(id.isEmpty ? "" : "#" + id)\">\(xml(text))</a>"
                if index < items.count, items[index].0 > l { out += build(items[index].0) }
                out += "</li>"
            }
            return out + "</ol>"
        }
        return build(items.map(\.0).min() ?? 1)
    }

    /// Removes characters that are invalid in XML.
    private static func xhtmlClean(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { v in
            v.value == 0x9 || v.value == 0xA || v.value == 0xD || (v.value >= 0x20 && v.value <= 0xD7FF)
                || (v.value >= 0xE000 && v.value <= 0xFFFD) || v.value >= 0x10000
        }))
    }

    private static func xml(_ s: String) -> String { HTMLRenderer.escape(xhtmlClean(s)) }
}
