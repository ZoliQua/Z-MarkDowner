import Foundation

/// Fetches bibliographic data for a DOI (doi.org content negotiation) or a PubMed ID (NCBI Citation Exporter).
public enum ReferenceLookup {

    public enum Identifier: Equatable {
        case doi(String)
        case pmid(String)
    }

    public enum LookupError: LocalizedError {
        case notAnIdentifier
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .notAnIdentifier:
                return L("lookup.invalid", "Enter a DOI (10.xxxx/…) or a PubMed ID.")
            case .notFound(let id):
                return LF("lookup.notFound", "No reference found for “%@”.", id)
            }
        }
    }

    /// Recognises DOIs (also as doi.org links or "doi:" prefixed) and PubMed IDs (digits, "PMID:", pubmed links).
    public static func identifier(from input: String) -> Identifier? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"10\.\d{4,9}/\S+"#, options: .regularExpression) {
            var doi = String(s[r])
            while let last = doi.last, ".,;)]>\"'".contains(last) { doi.removeLast() }
            return .doi(doi.removingPercentEncoding ?? doi)
        }
        s = s.lowercased()
        for prefix in ["https://pubmed.ncbi.nlm.nih.gov/", "http://pubmed.ncbi.nlm.nih.gov/", "pmid:", "pmid"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        }
        if !s.isEmpty, s.count <= 10, s.allSatisfy(\.isNumber) { return .pmid(s) }
        return nil
    }

    public static func fetch(_ id: Identifier, session: URLSession = .shared) async throws -> BibEntry {
        var request: URLRequest
        switch id {
        case .doi(let doi):
            let path = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
            request = URLRequest(url: URL(string: "https://doi.org/" + path)!)
            request.setValue("application/vnd.citationstyles.csl+json", forHTTPHeaderField: "Accept")
        case .pmid(let pmid):
            request = URLRequest(url: URL(string: "https://api.ncbi.nlm.nih.gov/lit/ctxp/v1/pubmed/?format=csl&id=\(pmid)")!)
            request.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        request.timeoutInterval = 20
        request.setValue("Z-MarkDowner (https://github.com/ZoliQua/Z-MarkDowner)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let label: String
        switch id { case .doi(let d): label = d; case .pmid(let p): label = p }
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              var entry = try CSLJSON.parse(data).first, !entry.title.isEmpty else {
            throw LookupError.notFound(label)
        }
        switch id {
        case .doi(let doi): if entry.doi.isEmpty { entry.doi = doi }
        case .pmid(let pmid): if entry.pmid.isEmpty { entry.pmid = pmid }
        }
        return entry
    }

    /// Adds an entry to a bibliography file (BibTeX or CSL-JSON), creating the file when needed.
    public static func append(_ entry: BibEntry, to url: URL) throws {
        let fm = FileManager.default
        if url.pathExtension.lowercased() == "json" {
            var list: [Any] = []
            if let data = fm.contents(atPath: url.path), !data.isEmpty {
                list = (try JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
            }
            list.append(CSLJSON.object(entry))
            let data = try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } else {
            var text = fm.contents(atPath: url.path).map { DocumentImporter.decodeText($0) } ?? ""
            if !text.isEmpty && !text.hasSuffix("\n\n") { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
            text += BibTeX.format(entry)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
