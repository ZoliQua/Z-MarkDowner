// Renders the app icon into an .iconset directory: swift make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.03
    shadow.set()
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.96, alpha: 1),
               ending: NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.82, alpha: 1))!
        .draw(in: path, angle: -60)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Page
    let page = NSRect(x: s * 0.27, y: s * 0.2, width: s * 0.46, height: s * 0.6)
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect: page, xRadius: s * 0.035, yRadius: s * 0.035).fill()

    // "M↓" mark
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.2, weight: .heavy),
        .foregroundColor: NSColor(calibratedRed: 0.24, green: 0.33, blue: 0.86, alpha: 1),
    ]
    let mark = NSAttributedString(string: "M↓", attributes: attrs)
    let size = mark.size()
    mark.draw(at: NSPoint(x: page.midX - size.width / 2, y: page.maxY - size.height - s * 0.05))

    // Text lines
    NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
    for i in 0..<4 {
        let w = page.width * (i == 3 ? 0.45 : 0.72)
        let line = NSRect(x: page.minX + page.width * 0.14, y: page.minY + s * 0.07 + CGFloat(i) * s * 0.055,
                          width: w, height: s * 0.022)
        NSBezierPath(roundedRect: line, xRadius: s * 0.011, yRadius: s * 0.011).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
