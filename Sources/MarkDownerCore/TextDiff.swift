import Foundation

public enum DiffKind: Equatable { case equal, insert, delete }

public struct DiffSegment: Equatable {
    public var kind: DiffKind
    public var text: String
    public init(kind: DiffKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct DiffOptions: Equatable {
    public var ignoreWhitespace = false
    public var ignoreCase = false
    public init(ignoreWhitespace: Bool = false, ignoreCase: Bool = false) {
        self.ignoreWhitespace = ignoreWhitespace
        self.ignoreCase = ignoreCase
    }
}

/// One aligned side-by-side row. A `nil` side is padding; line numbers are zero-based.
public struct DiffRow: Equatable {
    public var old: [DiffSegment]?
    public var new: [DiffSegment]?
    public var oldLine: Int?
    public var newLine: Int?
    public init(old: [DiffSegment]? = nil, new: [DiffSegment]? = nil, oldLine: Int? = nil, newLine: Int? = nil) {
        self.old = old
        self.new = new
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

public struct DiffResult {
    public var segments: [DiffSegment]
    public var rows: [DiffRow]
    public var insertedWords: Int
    public var deletedWords: Int
}

/// Line-then-word diff based on Myers' O(ND) algorithm.
public enum TextDiff {

    public static func compare(_ old: String, _ new: String, options: DiffOptions = DiffOptions()) -> DiffResult {
        let oldLines = lines(old)
        let newLines = lines(new)
        let ops = diffOps(oldLines.map { lineKey($0, options) }, newLines.map { lineKey($0, options) })

        var segments: [DiffSegment] = []
        var rows: [DiffRow] = []
        var oi = 0, ni = 0, i = 0
        while i < ops.count {
            if ops[i] == .equal {
                append(&segments, DiffSegment(kind: .equal, text: newLines[ni]))
                rows.append(DiffRow(old: [DiffSegment(kind: .equal, text: stripNewline(oldLines[oi]))],
                                    new: [DiffSegment(kind: .equal, text: stripNewline(newLines[ni]))],
                                    oldLine: oi, newLine: ni))
                oi += 1; ni += 1; i += 1
                continue
            }
            var dels = 0, inss = 0
            while i < ops.count, ops[i] != .equal {
                if ops[i] == .delete { dels += 1 } else { inss += 1 }
                i += 1
            }
            let oBlock = Array(oldLines[oi..<oi + dels])
            let nBlock = Array(newLines[ni..<ni + inss])
            let blockSegments = wordDiff(oBlock.joined(), nBlock.joined(), options)
            for s in blockSegments { append(&segments, s) }
            appendRows(&rows, oBlock, nBlock, oi, ni, blockSegments, options)
            oi += dels; ni += inss
        }

        var inserted = 0, deleted = 0
        for s in segments where s.kind != .equal {
            let n = tokens(s.text).filter { isWord($0) }.count
            if s.kind == .insert { inserted += n } else { deleted += n }
        }
        return DiffResult(segments: segments, rows: rows, insertedWords: inserted, deletedWords: deleted)
    }

    /// CriticMarkup rendering: deletions as `{--x--}` before insertions as `{++x++}`; nothing is escaped.
    public static func criticMarkup(_ segments: [DiffSegment]) -> String {
        var out = ""
        for s in segments {
            switch s.kind {
            case .equal: out += s.text
            case .delete: out += "{--\(s.text)--}"
            case .insert: out += "{++\(s.text)++}"
            }
        }
        return out
    }

    /// Splits into words (letters, digits, underscore), whitespace runs and single punctuation characters.
    static func tokens(_ s: String) -> [String] {
        var result: [String] = []
        let view = s.unicodeScalars
        var start = view.startIndex
        var currentClass = 0
        var idx = view.startIndex
        while idx != view.endIndex {
            let c = scalarClass(view[idx])
            if idx != start, c != currentClass || c == 3 {
                result.append(String(view[start..<idx]))
                start = idx
            }
            currentClass = c
            idx = view.index(after: idx)
        }
        if start != view.endIndex { result.append(String(view[start..<view.endIndex])) }
        return result
    }

    private static func scalarClass(_ u: Unicode.Scalar) -> Int {
        let v = u.value
        if v < 128 {
            if (v >= 97 && v <= 122) || (v >= 65 && v <= 90) || (v >= 48 && v <= 57) || v == 95 { return 1 }
            if v == 32 || (v >= 9 && v <= 13) { return 2 }
            return 3
        }
        let p = u.properties
        if p.isAlphabetic || p.numericType != nil { return 1 }
        if p.isWhitespace { return 2 }
        return 3
    }

    private static func isWord(_ token: String) -> Bool {
        guard let u = token.unicodeScalars.first else { return false }
        return scalarClass(u) == 1
    }

    private static func lines(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in s {
            current.append(ch)
            if ch == "\n" || ch == "\r\n" {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func stripNewline(_ s: String) -> String {
        if let last = s.last, last == "\n" || last == "\r\n" { return String(s.dropLast()) }
        return s
    }

    private static func lineKey(_ s: String, _ o: DiffOptions) -> String {
        var k = s
        if o.ignoreWhitespace { k = k.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        if o.ignoreCase { k = k.lowercased() }
        return k
    }

    private static func append(_ segments: inout [DiffSegment], _ s: DiffSegment) {
        guard !s.text.isEmpty else { return }
        if let last = segments.last, last.kind == s.kind {
            segments[segments.count - 1].text += s.text
        } else {
            segments.append(s)
        }
    }

    /// Word diff of two texts; equal tokens carry the new text, or the old text when `oldSide` is set.
    private static func wordDiff(_ old: String, _ new: String, _ o: DiffOptions, oldSide: Bool = false) -> [DiffSegment] {
        let ot = tokens(old), nt = tokens(new)
        func key(_ t: String) -> String {
            var k = t
            if o.ignoreWhitespace, let u = t.unicodeScalars.first, scalarClass(u) == 2 { k = " " }
            if o.ignoreCase { k = k.lowercased() }
            return k
        }
        let ops = diffOps(ot.map(key), nt.map(key))
        var segments: [DiffSegment] = []
        var pendingDel = "", pendingIns = ""
        func flush() {
            append(&segments, DiffSegment(kind: .delete, text: pendingDel))
            append(&segments, DiffSegment(kind: .insert, text: pendingIns))
            pendingDel = ""; pendingIns = ""
        }
        var oi = 0, ni = 0
        for op in ops {
            switch op {
            case .equal:
                flush()
                append(&segments, DiffSegment(kind: .equal, text: oldSide ? ot[oi] : nt[ni]))
                oi += 1; ni += 1
            case .delete:
                pendingDel += ot[oi]; oi += 1
            case .insert:
                pendingIns += nt[ni]; ni += 1
            }
        }
        flush()
        return segments
    }

    private static func appendRows(_ rows: inout [DiffRow], _ oBlock: [String], _ nBlock: [String],
                                   _ oStart: Int, _ nStart: Int, _ blockSegments: [DiffSegment], _ o: DiffOptions) {
        let single = oBlock.count == 1 && nBlock.count == 1
        for (ok, nk) in pairLines(oBlock, nBlock, o) {
            let oldText = ok.map { stripNewline(oBlock[$0]) }
            let newText = nk.map { stripNewline(nBlock[$0]) }
            var row = DiffRow(oldLine: ok.map { oStart + $0 }, newLine: nk.map { nStart + $0 })
            if let oldText, let newText {
                let segs = single ? trimTrailingNewline(blockSegments) : wordDiff(oldText, newText, o)
                let ignoring = o.ignoreCase || o.ignoreWhitespace
                let oldSegs = ignoring ? wordDiff(oldText, newText, o, oldSide: true) : segs
                row.old = oldSegs.filter { $0.kind != .insert }
                row.new = segs.filter { $0.kind != .delete }
            } else if let t = oldText {
                row.old = t.isEmpty ? [] : [DiffSegment(kind: .delete, text: t)]
            } else if let t = newText {
                row.new = t.isEmpty ? [] : [DiffSegment(kind: .insert, text: t)]
            }
            rows.append(row)
        }
    }

    /// Side-by-side pairing of the lines of a changed block: similar lines (shared words) are aligned in order,
    /// the lines left between two aligned pairs are paired in order and the rest get padding.
    /// Large blocks are paired in order only.
    private static func pairLines(_ oBlock: [String], _ nBlock: [String], _ o: DiffOptions) -> [(Int?, Int?)] {
        let n = oBlock.count, m = nBlock.count
        func inOrder(_ oRange: Range<Int>, _ nRange: Range<Int>) -> [(Int?, Int?)] {
            (0..<max(oRange.count, nRange.count)).map { k in
                (k < oRange.count ? oRange.lowerBound + k : nil, k < nRange.count ? nRange.lowerBound + k : nil)
            }
        }
        guard n > 1 || m > 1, n > 0, m > 0, n * m <= 40_000 else { return inOrder(0..<n, 0..<m) }

        func words(_ line: String) -> [String: Int] {
            var counts: [String: Int] = [:]
            for t in tokens(o.ignoreCase ? line.lowercased() : line) where isWord(t) { counts[t, default: 0] += 1 }
            return counts
        }
        let ow = oBlock.map(words), nw = nBlock.map(words)
        func similarity(_ i: Int, _ j: Int) -> Double {
            let a = ow[i], b = nw[j]
            if a.isEmpty || b.isEmpty {
                let blankA = oBlock[i].allSatisfy(\.isWhitespace), blankB = nBlock[j].allSatisfy(\.isWhitespace)
                return a.isEmpty && b.isEmpty && blankA == blankB ? 1 : 0
            }
            let common = a.reduce(0) { $0 + min($1.value, b[$1.key] ?? 0) }
            let total = a.values.reduce(0, +) + b.values.reduce(0, +)
            return 2 * Double(common) / Double(total)
        }
        let threshold = 0.3
        var score = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var sims = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for i in 0..<n {
            for j in 0..<m {
                let sim = similarity(i, j)
                sims[i][j] = sim
                var best = max(score[i][j + 1], score[i + 1][j])
                if sim >= threshold { best = max(best, score[i][j] + sim) }
                score[i + 1][j + 1] = best
            }
        }
        var anchors: [(Int, Int)] = []
        var i = n, j = m
        while i > 0, j > 0 {
            if sims[i - 1][j - 1] >= threshold, score[i][j] == score[i - 1][j - 1] + sims[i - 1][j - 1] {
                anchors.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if score[i][j] == score[i - 1][j] {
                i -= 1
            } else {
                j -= 1
            }
        }
        var result: [(Int?, Int?)] = []
        var oi = 0, ni = 0
        for (a, b) in anchors.reversed() {
            result += inOrder(oi..<a, ni..<b)
            result.append((a, b))
            oi = a + 1; ni = b + 1
        }
        result += inOrder(oi..<n, ni..<m)
        return result
    }

    /// Removes one trailing line terminator from each side of a word diff of a single line pair.
    private static func trimTrailingNewline(_ segs: [DiffSegment]) -> [DiffSegment] {
        var result = segs
        for kinds in [[DiffKind.equal, .delete], [.equal, .insert]] {
            if let idx = result.lastIndex(where: { kinds.contains($0.kind) }), let last = result[idx].text.last,
               last == "\n" || last == "\r\n" {
                result[idx].text.removeLast()
            }
        }
        return result.filter { !$0.text.isEmpty }
    }

    // MARK: Myers

    private enum Op { case equal, delete, insert }

    /// Edit script turning `a` into `b`; common prefix and suffix are trimmed before the O(ND) search.
    private static func diffOps(_ a: [String], _ b: [String]) -> [Op] {
        var ids: [String: Int] = [:]
        func id(_ s: String) -> Int {
            if let v = ids[s] { return v }
            let v = ids.count
            ids[s] = v
            return v
        }
        let x = a.map(id), y = b.map(id)
        var prefix = 0
        while prefix < x.count, prefix < y.count, x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < x.count - prefix, suffix < y.count - prefix, x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        let mid = myers(Array(x[prefix..<x.count - suffix]), Array(y[prefix..<y.count - suffix]))
        return Array(repeating: .equal, count: prefix) + mid + Array(repeating: .equal, count: suffix)
    }

    /// Bounds trace memory (about 4 bytes x D^2); beyond it a region is reported as one delete plus one insert.
    private static let maxEditDistance = 2000

    private static func myers(_ a: [Int], _ b: [Int]) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return Array(repeating: .insert, count: m) }
        if m == 0 { return Array(repeating: .delete, count: n) }
        let maxD = min(n + m, maxEditDistance)
        let offset = maxD + 1
        var v = [Int32](repeating: 0, count: 2 * maxD + 3)
        var trace: [Int32] = []
        trace.reserveCapacity(1 << 16)
        var found = -1
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                v.withUnsafeMutableBufferPointer { vp in
                    for d in 0...maxD {
                        var k = -d
                        while k <= d {
                            var xx: Int
                            if k == -d || (k != d && vp[offset + k - 1] < vp[offset + k + 1]) {
                                xx = Int(vp[offset + k + 1])
                            } else {
                                xx = Int(vp[offset + k - 1]) + 1
                            }
                            var yy = xx - k
                            while xx < n, yy < m, ap[xx] == bp[yy] { xx += 1; yy += 1 }
                            vp[offset + k] = Int32(truncatingIfNeeded: xx)
                            if xx >= n && yy >= m { found = d; return }
                            k += 2
                        }
                        trace.append(contentsOf: UnsafeBufferPointer(rebasing: vp[(offset - d)...(offset + d)]))
                    }
                }
            }
        }
        if found < 0 { return Array(repeating: .delete, count: n) + Array(repeating: .insert, count: m) }
        var ops: [Op] = []
        var xx = n, yy = m
        var d = found
        while d > 0 {
            let base = (d - 1) * (d - 1)
            let k = xx - yy
            func at(_ kk: Int) -> Int { Int(trace[base + kk + d - 1]) }
            let prevK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1
            let prevX = at(prevK)
            let prevY = prevX - prevK
            let isInsert = prevK == k + 1
            let midX = isInsert ? prevX : prevX + 1
            while xx > midX { ops.append(.equal); xx -= 1; yy -= 1 }
            ops.append(isInsert ? .insert : .delete)
            xx = prevX; yy = prevY
            d -= 1
        }
        while xx > 0 && yy > 0 { ops.append(.equal); xx -= 1; yy -= 1 }
        return ops.reversed()
    }
}
