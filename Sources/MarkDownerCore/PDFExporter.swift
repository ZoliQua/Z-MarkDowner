import AppKit

public enum ExportError: LocalizedError {
    case renderingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .renderingFailed(let reason): return "Az exportálás nem sikerült: \(reason)"
        }
    }
}

/// Renders Markdown into paginated A4 output (PDF data or a print operation).
public enum PDFExporter {

    /// A4 in points.
    public static let pageSize = NSSize(width: 595.28, height: 841.89)
    public static let margin: CGFloat = 56.7 // 2 cm

    /// Builds the styled, print-ready attributed string for a Markdown document.
    @MainActor
    public static func attributedString(markdown: String, title: String, baseURL: URL?) throws -> NSAttributedString {
        var body = HTMLRenderer.render(markdown: markdown)
        // The AppKit HTML importer does not render form controls; use symbols for task lists
        body = body
            .replacingOccurrences(of: "<input type=\"checkbox\" disabled checked> ", with: "☑ ")
            .replacingOccurrences(of: "<input type=\"checkbox\" disabled> ", with: "☐ ")
        let html = HTMLRenderer.page(body: body, title: title, css: Stylesheets.print)
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let baseURL { options[.baseURL] = baseURL }
        do {
            return try NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil)
        } catch {
            throw ExportError.renderingFailed(error.localizedDescription)
        }
    }

    @MainActor
    public static func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo(dictionary: [:])
        info.paperSize = pageSize
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// A text view laid out at printable width containing the rendered document.
    @MainActor
    public static func printableView(markdown: String, title: String, baseURL: URL?,
                                     printInfo: NSPrintInfo? = nil) throws -> NSTextView {
        let info = printInfo ?? self.printInfo()
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let content = try attributedString(markdown: markdown, title: title, baseURL: baseURL)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.appearance = NSAppearance(named: .aqua)
        textView.isEditable = false
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textStorage?.setAttributedString(content)
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            textView.setFrameSize(NSSize(width: width, height: max(ceil(used.height) + 1, 100)))
        }
        return textView
    }

    /// Produces paginated PDF data.
    @MainActor
    public static func pdfData(markdown: String, title: String, baseURL: URL?) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writePDF(markdown: markdown, title: title, baseURL: baseURL, to: tmp)
        return try Data(contentsOf: tmp)
    }

    /// Writes a paginated PDF file using a (panel-less) print operation.
    @MainActor
    public static func writePDF(markdown: String, title: String, baseURL: URL?, to url: URL) throws {
        let info = printInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let view = try printableView(markdown: markdown, title: title, baseURL: baseURL, printInfo: info)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.jobTitle = title
        try? FileManager.default.removeItem(at: url)
        guard op.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw ExportError.renderingFailed("a PDF nem jött létre.")
        }
    }
}
