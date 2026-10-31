import AppKit
import CoreText
import PDFKit

/// Builds small PDFs with CoreText so the PDF import can be tested without fixture files.
///
/// Each page is a list of lines drawn top-down at the left margin; an entry with empty text leaves a
/// blank line (a paragraph gap). With `lineNumbers` every text line gets a lineno-style number in the
/// right margin (with `twoColumns`: left of each column, the right column's in the gutter), `header` is drawn at the top of every page together with a page number at the bottom,
/// and `twoColumns` puts the first half of a page's lines in the left column and the rest in the right one
/// (its baselines shifted by half a line). Lines are drawn top-down across columns, so the content stream
/// interleaves the columns as typeset papers often do.
enum SyntheticPDF {
    static let pageSize = CGSize(width: 612, height: 792)

    static func make(pages: [[(text: String, fontSize: CGFloat, bold: Bool)]], lineNumbers: Bool = false,
                     header: String? = nil, twoColumns: Bool = false) -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            fatalError("Cannot create PDF context")
        }
        var lineNumber = 0
        for (index, lines) in pages.enumerated() {
            context.beginPDFPage(nil)
            if let header {
                draw(header, size: 9, bold: false, x: 72, y: pageSize.height - 30, in: context)
                draw("\(index + 1)", size: 9, bold: false, x: pageSize.width / 2, y: 30, in: context)
            }
            let columns: [ArraySlice<(text: String, fontSize: CGFloat, bold: Bool)>]
            if twoColumns {
                let half = (lines.count + 1) / 2
                columns = [lines[0..<half], lines[half...]]
            } else {
                columns = [lines[...]]
            }
            var placed: [(line: (text: String, fontSize: CGFloat, bold: Bool), x: CGFloat, y: CGFloat)] = []
            for (column, columnLines) in columns.enumerated() {
                var y = pageSize.height - 72 - CGFloat(column) * 6
                for line in columnLines {
                    y -= line.fontSize * 1.25
                    if !line.text.isEmpty { placed.append((line, column == 0 ? 72 : 330, y)) }
                }
            }
            for item in placed.sorted(by: { $0.y > $1.y }) {
                draw(item.line.text, size: item.line.fontSize, bold: item.line.bold, x: item.x, y: item.y, in: context)
                if lineNumbers {
                    lineNumber += 1
                    let numberX = twoColumns ? item.x - 16 : pageSize.width - 60
                    draw("\(lineNumber)", size: 7, bold: false, x: numberX, y: item.y, in: context)
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else { fatalError("Cannot read synthetic PDF") }
        return document
    }

    private static func draw(_ text: String, size: CGFloat, bold: Bool, x: CGFloat, y: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}
