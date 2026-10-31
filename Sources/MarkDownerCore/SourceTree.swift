import Foundation

/// A manuscript's source files in document order: a LaTeX main file with the files it pulls in through
/// `\input{…}` / `\include{…}`, or a single Markdown or plain-text file.
///
/// Comments are anchored against one normalized text of the whole tree, so uniqueness and context are
/// judged across all files, and the result is mapped back to the file it lies in.
public struct SourceTree {
    public let files: [URL]
    public let format: SourceFormat
    private let segments: [Segment]
    private let normalized: NormalizedText

    /// A stretch of one file's text placed at `start` in the combined text.
    private struct Segment {
        let file: Int
        let range: NSRange
        let start: Int
    }

    /// Reads `main` and, for LaTeX, every file it includes; included files that cannot be read are skipped.
    public init(main: URL) throws {
        let mainText = DocumentImporter.decodeText(try Data(contentsOf: main))
        self.init(files: [(main, mainText)], format: SourceFormat(fileExtension: main.pathExtension)) { url in
            (try? Data(contentsOf: url)).map(DocumentImporter.decodeText)
        }
    }

    /// A tree from texts already in memory. For LaTeX the first file is the main file and the includes
    /// are resolved among `files`; files no include reaches follow at the end.
    public init(files: [(url: URL, text: String)], format: SourceFormat) {
        let byPath = Dictionary(files.map { (Self.key($0.url), $0.text) }, uniquingKeysWith: { first, _ in first })
        self.init(files: files, format: format) { byPath[Self.key($0)] }
    }

    private init(files given: [(url: URL, text: String)], format: SourceFormat, read: @escaping (URL) -> String?) {
        let folder = given.first?.url.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        var builder = Builder(format: format, folder: folder, read: read)
        for file in given where !builder.visited.contains(Self.key(file.url)) {
            builder.add(file.url, file.text)
        }
        files = builder.files
        self.format = format
        segments = builder.segments
        normalized = NormalizedText(source: builder.combined as String, format: format)
    }

    /// The file and the range in that file's text of the comment's quoted words, or nil when the
    /// comment cannot be placed or its words run across a file boundary.
    public func locate(_ comment: ReviewComment) -> (file: URL, range: NSRange)? {
        guard let range = ReviewAnchor.locate(comment, in: normalized) else { return nil }
        for segment in segments
        where range.location >= segment.start && NSMaxRange(range) <= segment.start + segment.range.length {
            let local = NSRange(location: segment.range.location + range.location - segment.start, length: range.length)
            return (files[segment.file], local)
        }
        return nil
    }

    fileprivate static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private struct Builder {
        let format: SourceFormat
        let folder: URL
        let read: (URL) -> String?
        var files: [URL] = []
        var visited: Set<String> = []
        var segments: [Segment] = []
        let combined = NSMutableString()

        init(format: SourceFormat, folder: URL, read: @escaping (URL) -> String?) {
            self.format = format
            self.folder = folder
            self.read = read
        }

        /// Appends `text`, splicing each included file in at the place of its `\input` / `\include`.
        mutating func add(_ url: URL, _ text: String) {
            visited.insert(SourceTree.key(url))
            let index = files.count
            files.append(url)
            let length = (text as NSString).length
            guard format == .latex else {
                append(index, NSRange(location: 0, length: length), of: text)
                return
            }
            var cursor = 0
            for include in SourceTree.includes(in: text) {
                append(index, NSRange(location: cursor, length: include.range.location - cursor), of: text)
                cursor = NSMaxRange(include.range)
                let child = resolve(include.name)
                guard !visited.contains(SourceTree.key(child)), let childText = read(child) else { continue }
                add(child, childText)
            }
            append(index, NSRange(location: cursor, length: length - cursor), of: text)
        }

        private mutating func append(_ file: Int, _ range: NSRange, of text: String) {
            let piece = (text as NSString).substring(with: range)
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if combined.length > 0 { combined.append("\n\n") }
            segments.append(Segment(file: file, range: range, start: combined.length))
            combined.append(piece)
        }

        /// An include name relative to the main file's folder, with `.tex` added when it has no extension.
        private func resolve(_ name: String) -> URL {
            var url = URL(fileURLWithPath: name, relativeTo: folder)
            if url.pathExtension.isEmpty { url.appendPathExtension("tex") }
            return url.standardizedFileURL
        }
    }

    private static let includePattern = try! NSRegularExpression(pattern: #"\\(?:input|include)\s*\{([^{}]+)\}"#)

    /// The `\input{…}` / `\include{…}` commands of `text` outside `%` comments, in order.
    static func includes(in text: String) -> [(range: NSRange, name: String)] {
        let source = text as NSString
        return includePattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let lineStart = source.lineRange(for: NSRange(location: match.range.location, length: 0)).location
            if isCommented(source, from: lineStart, to: match.range.location) { return nil }
            let name = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (match.range, name)
        }
    }

    /// Whether an unescaped `%` occurs in `source` between `start` and `end`.
    private static func isCommented(_ source: NSString, from start: Int, to end: Int) -> Bool {
        var backslashes = 0
        for i in start..<end {
            let unit = source.character(at: i)
            if unit == 0x25, backslashes % 2 == 0 { return true }
            backslashes = unit == 0x5C ? backslashes + 1 : 0
        }
        return false
    }
}
