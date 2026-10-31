import AppKit
import PDFKit
import Vision

/// Text recognition for PDF pages without a text layer (scans), using Vision.
public enum PDFOCR {

    /// Resolution the pages are rendered at before recognition.
    static let dpi: CGFloat = 300
    /// Upper bound of either side of the rendered bitmap, to keep memory in check for huge media boxes.
    private static let maxPixels: CGFloat = 12_000

    /// The user's preferred languages that Vision can recognise, most preferred first; English when none match.
    public static var preferredLanguages: [String] {
        filter(Locale.preferredLanguages, supported: supportedLanguages())
    }

    /// Recognises the text on `page` and returns it as lines in page coordinates (origin bottom left),
    /// top to bottom. The font size is estimated from the height of each line's box.
    public static func recognize(_ page: PDFPage, pageIndex: Int, languages: [String]) -> [PDFLine] {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0, let image = render(page, box: box) else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let usable = filter(languages, supported: supportedLanguages())
        request.recognitionLanguages = usable
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }

        var lines: [PDFLine] = []
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = observation.boundingBox
            let bounds = CGRect(x: box.minX + normalized.minX * box.width,
                                y: box.minY + normalized.minY * box.height,
                                width: normalized.width * box.width,
                                height: normalized.height * box.height)
            lines.append(PDFLine(text: trimmed, bounds: bounds, fontSize: bounds.height * 0.8, isBold: false, page: pageIndex))
        }
        return lines.sorted { $0.bounds.midY != $1.bounds.midY ? $0.bounds.midY > $1.bounds.midY : $0.bounds.minX < $1.bounds.minX }
    }

    // MARK: Helpers

    private static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    /// The `wanted` languages Vision supports (matched by language code, e.g. "hu-HU" → "hu"), else English.
    static func filter(_ wanted: [String], supported: [String]) -> [String] {
        var result: [String] = []
        for language in wanted {
            let code = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language.lowercased()
            let match = supported.first { $0.caseInsensitiveCompare(language) == .orderedSame }
                ?? supported.first { $0.split(separator: "-").first.map { $0.lowercased() } == code }
            if let match, !result.contains(match) { result.append(match) }
        }
        if result.isEmpty { result = supported.contains("en-US") ? ["en-US"] : Array(supported.prefix(1)) }
        return result
    }

    private static func render(_ page: PDFPage, box: CGRect) -> CGImage? {
        let scale = min(dpi / 72, maxPixels / max(box.width, box.height))
        let width = Int((box.width * scale).rounded(.up)), height = Int((box.height * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
