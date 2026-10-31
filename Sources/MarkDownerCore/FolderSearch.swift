import Foundation

/// Search and replace across the text files of a folder.
public enum FolderSearch {

    public struct Options: Equatable {
        public var regularExpression = false
        public var caseSensitive = false
        public var wholeWord = false

        public init(regularExpression: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false) {
            self.regularExpression = regularExpression
            self.caseSensitive = caseSensitive
            self.wholeWord = wholeWord
        }
    }

    public struct Match: Equatable {
        /// Range in the whole file (UTF-16).
        public var range: NSRange
        /// 0-based line number.
        public var line: Int
        /// The line (shortened around the match for very long lines) and the match inside it.
        public var lineText: String
        public var rangeInLine: NSRange
    }

    public struct FileResult {
        public var url: URL
        public var matches: [Match]
    }

    /// File types that can be searched and edited as text.
    public static let textExtensions: Set<String> = DocumentImporter.markdownExtensions.union(DocumentImporter.plainTextExtensions)

    public static func regex(for query: String, options: Options) throws -> NSRegularExpression {
        var pattern = options.regularExpression ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: flags)
    }

    /// Text files below `folder` (hidden files, packages and files over 5 MB are skipped).
    public static func files(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker {
            guard textExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  (values.fileSize ?? 0) < 5_000_000 else { continue }
            result.append(url)
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public static func matches(in text: String, regex: NSRegularExpression, limit: Int = 10_000) -> [Match] {
        let ns = text as NSString
        var out: [Match] = []
        var lineStarts: [Int] = [0]
        var lineIndex = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { result, _, stop in
            guard let r = result?.range, r.length > 0 else { return }
            // Advance the line counter up to the match
            while true {
                let from = lineStarts[lineStarts.count - 1]
                let nl = ns.range(of: "\n", options: [], range: NSRange(location: from, length: ns.length - from))
                guard nl.location != NSNotFound, nl.location < r.location else { break }
                lineStarts.append(NSMaxRange(nl))
                lineIndex += 1
            }
            let lineRange = ns.lineRange(for: NSRange(location: r.location, length: 0))
            var line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            var inLine = NSRange(location: r.location - lineRange.location, length: min(r.length, (line as NSString).length - (r.location - lineRange.location)))
            // Keep long lines readable: about 60 characters of context before the match
            if inLine.location > 80 {
                let cut = inLine.location - 60
                line = "…" + (line as NSString).substring(from: cut)
                inLine.location = inLine.location - cut + 1
            }
            if (line as NSString).length > 300 { line = (line as NSString).substring(to: 300) + "…" }
            inLine.length = max(0, min(inLine.length, (line as NSString).length - inLine.location))
            out.append(Match(range: r, line: lineIndex, lineText: line, rangeInLine: inLine))
            if out.count >= limit { stop.pointee = true }
        }
        return out
    }

    /// Searches all text files of a folder; `isCancelled` is polled between files.
    public static func search(folder: URL, regex: NSRegularExpression, limit: Int = 5_000,
                              isCancelled: () -> Bool = { false }) -> [FileResult] {
        var results: [FileResult] = []
        var total = 0
        for url in files(in: folder) {
            if isCancelled() || total >= limit { break }
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            let text = DocumentImporter.decodeText(data)
            let found = matches(in: text, regex: regex, limit: limit - total)
            if !found.isEmpty {
                results.append(FileResult(url: url, matches: found))
                total += found.count
            }
        }
        return results
    }

    /// Replaces every match; `template` uses `$1`… for groups in regular expression mode.
    public static func replace(in text: String, regex: NSRegularExpression, with replacement: String,
                               options: Options) -> (text: String, count: Int) {
        let template = options.regularExpression ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        let range = NSRange(location: 0, length: (text as NSString).length)
        let count = regex.numberOfMatches(in: text, range: range)
        guard count > 0 else { return (text, 0) }
        return (regex.stringByReplacingMatches(in: text, range: range, withTemplate: template), count)
    }
}
