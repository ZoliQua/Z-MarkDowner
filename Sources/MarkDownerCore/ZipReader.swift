import Foundation
import Compression

public enum ZipError: LocalizedError {
    case notAZip
    case corrupt(String)
    case unsupportedMethod(UInt16)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "A fájl nem érvényes ZIP/DOCX csomag."
        case .corrupt(let what): return "Sérült ZIP csomag (\(what))."
        case .unsupportedMethod(let m): return "Nem támogatott tömörítési mód: \(m)."
        }
    }
}

/// Minimal ZIP reader supporting stored and deflated entries.
public struct ZipReader {
    public struct Entry {
        public let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    public private(set) var entries: [String: Entry] = [:]

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw ZipError.notAZip }

        // Locate end of central directory record
        let minPos = max(0, data.count - 65_557)
        var eocd = -1
        var p = data.count - 22
        while p >= minPos {
            if u32(p) == 0x06054b50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        let count = Int(u16(eocd + 10))
        var offset = Int(u32(eocd + 16))
        for _ in 0..<count {
            guard offset + 46 <= data.count, u32(offset) == 0x02014b50 else {
                throw ZipError.corrupt("central directory")
            }
            let method = u16(offset + 10)
            let compSize = Int(u32(offset + 20))
            let uncompSize = Int(u32(offset + 24))
            let nameLen = Int(u16(offset + 28))
            let extraLen = Int(u16(offset + 30))
            let commentLen = Int(u16(offset + 32))
            let localOffset = Int(u32(offset + 42))
            guard offset + 46 + nameLen <= data.count else { throw ZipError.corrupt("entry name") }
            let nameData = data.subdata(in: (data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLen))
            let name = String(decoding: nameData, as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: compSize,
                                  uncompressedSize: uncompSize, localHeaderOffset: localOffset)
            offset += 46 + nameLen + extraLen + commentLen
        }
    }

    public func contents(of name: String) throws -> Data? {
        guard let e = entries[name] else { return nil }
        let h = e.localHeaderOffset
        guard h + 30 <= data.count, u32(h) == 0x04034b50 else { throw ZipError.corrupt("local header") }
        let start = h + 30 + Int(u16(h + 26)) + Int(u16(h + 28))
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt("entry data") }
        let compressed = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))

        switch e.method {
        case 0:
            return compressed
        case 8:
            if e.uncompressedSize == 0 { return Data() }
            var output = Data(count: e.uncompressedSize)
            let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.uncompressedSize,
                                              src.bindMemory(to: UInt8.self).baseAddress!, e.compressedSize,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written == e.uncompressedSize else { throw ZipError.corrupt("deflate stream") }
            return output
        default:
            throw ZipError.unsupportedMethod(e.method)
        }
    }

    private func u16(_ o: Int) -> UInt16 {
        let i = data.startIndex + o
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private func u32(_ o: Int) -> UInt32 {
        let i = data.startIndex + o
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }
}
