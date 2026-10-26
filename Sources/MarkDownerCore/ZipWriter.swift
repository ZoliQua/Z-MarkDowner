import Foundation

/// Minimal ZIP archive writer (stored entries, no compression). Sufficient for OOXML packages.
public struct ZipWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []

    public init() {}

    public mutating func add(path: String, data content: Data) {
        let name = Array(path.utf8)
        let crc = ZipWriter.crc32(content)
        let offset = UInt32(data.count)

        append32(0x04034b50)          // local file header signature
        append16(20)                  // version needed
        append16(0x0800)              // flags: UTF-8 names
        append16(0)                   // method: stored
        append16(0)                   // mod time
        append16(0x21)                // mod date (1980-01-01)
        append32(crc)
        append32(UInt32(content.count))
        append32(UInt32(content.count))
        append16(UInt16(name.count))
        append16(0)                   // extra length
        data.append(contentsOf: name)
        data.append(content)

        entries.append(Entry(name: name, crc: crc, size: UInt32(content.count), offset: offset))
    }

    public mutating func add(path: String, string: String) {
        add(path: path, data: Data(string.utf8))
    }

    public mutating func finish() -> Data {
        let cdOffset = UInt32(data.count)
        for e in entries {
            append32(0x02014b50)      // central directory signature
            append16(20)              // version made by
            append16(20)              // version needed
            append16(0x0800)
            append16(0)
            append16(0)
            append16(0x21)
            append32(e.crc)
            append32(e.size)
            append32(e.size)
            append16(UInt16(e.name.count))
            append16(0)               // extra
            append16(0)               // comment
            append16(0)               // disk number
            append16(0)               // internal attributes
            append32(0)               // external attributes
            append32(e.offset)
            data.append(contentsOf: e.name)
        }
        let cdSize = UInt32(data.count) - cdOffset
        append32(0x06054b50)          // end of central directory
        append16(0)
        append16(0)
        append16(UInt16(entries.count))
        append16(UInt16(entries.count))
        append32(cdSize)
        append32(cdOffset)
        append16(0)
        return data
    }

    private mutating func append16(_ v: UInt16) {
        data.append(UInt8(v & 0xff))
        data.append(UInt8(v >> 8))
    }

    private mutating func append32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8((v >> UInt32(shift)) & 0xff))
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for byte in buf {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xffffffff
    }
}
