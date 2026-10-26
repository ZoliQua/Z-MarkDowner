import Foundation

/// Lightweight syntax highlighter producing HTML spans (`hl-kw`, `hl-str`, `hl-com`, `hl-num`, `hl-type`, `hl-fn`, `hl-attr`).
public enum CodeHighlighter {

    struct Language {
        var keywords: Set<String>
        var types: Set<String> = []
        var lineComments: [String] = []
        var blockComment: (String, String)?
        var stringDelimiters: [Character] = ["\"", "'"]
        var caseInsensitive = false
        var markup = false
    }

    private static let cFamilyTypes: Set<String> = ["int", "long", "short", "char", "float", "double", "void", "bool", "unsigned", "signed", "size_t", "auto"]

    static let languages: [String: Language] = {
        var l: [String: Language] = [:]
        l["swift"] = Language(keywords: ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "catch", "false", "is", "nil", "rethrows", "super", "self", "Self", "throw", "throws", "true", "try", "async", "await", "actor", "some", "any", "override", "final", "weak", "lazy", "mutating", "convenience", "required", "@MainActor"],
                              types: ["Int", "String", "Double", "Float", "Bool", "Array", "Dictionary", "Set", "Optional", "Data", "URL", "Character", "Void"],
                              lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\""])
        l["python"] = Language(keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield", "self"],
                               types: ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object"],
                               lineComments: ["#"])
        let jsKeywords: Set<String> = ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield", "async", "await", "of", "from", "static", "get", "set"]
        l["javascript"] = Language(keywords: jsKeywords, types: ["Array", "Object", "String", "Number", "Promise", "Map", "Set", "Date", "JSON", "Math", "console"],
                                   lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"])
        l["typescript"] = Language(keywords: jsKeywords.union(["interface", "type", "enum", "implements", "private", "public", "protected", "readonly", "abstract", "declare", "namespace", "as", "keyof"]),
                                   types: ["string", "number", "boolean", "any", "unknown", "never", "void", "Array", "Promise", "Record"],
                                   lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"])
        let cKeywords: Set<String> = ["break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto", "if", "inline", "register", "return", "sizeof", "static", "struct", "switch", "typedef", "union", "volatile", "while", "NULL", "true", "false", "#include", "#define", "#ifdef", "#ifndef", "#endif", "#if", "#else"]
        l["c"] = Language(keywords: cKeywords, types: cFamilyTypes, lineComments: ["//"], blockComment: ("/*", "*/"))
        l["cpp"] = Language(keywords: cKeywords.union(["class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override", "new", "delete", "this", "using", "nullptr", "try", "catch", "throw", "operator", "friend", "constexpr", "noexcept"]),
                            types: cFamilyTypes.union(["std", "string", "vector", "map"]), lineComments: ["//"], blockComment: ("/*", "*/"))
        l["java"] = Language(keywords: ["abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "extends", "final", "finally", "for", "if", "implements", "import", "instanceof", "interface", "native", "new", "package", "private", "protected", "public", "return", "static", "super", "switch", "synchronized", "this", "throw", "throws", "try", "void", "volatile", "while", "true", "false", "null", "var", "record"],
                             types: ["int", "long", "short", "byte", "char", "float", "double", "boolean", "String", "Integer", "List", "Map", "Object"],
                             lineComments: ["//"], blockComment: ("/*", "*/"))
        l["kotlin"] = Language(keywords: ["as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in", "interface", "is", "null", "object", "package", "return", "super", "this", "throw", "true", "try", "typealias", "val", "var", "when", "while", "import", "private", "public", "override", "data", "sealed", "companion", "suspend"],
                               types: ["Int", "String", "Long", "Double", "Boolean", "List", "Map", "Unit", "Any"],
                               lineComments: ["//"], blockComment: ("/*", "*/"))
        l["csharp"] = Language(keywords: ["abstract", "as", "base", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "event", "false", "finally", "for", "foreach", "if", "in", "interface", "internal", "is", "namespace", "new", "null", "override", "private", "protected", "public", "readonly", "return", "sealed", "static", "struct", "switch", "this", "throw", "true", "try", "using", "var", "virtual", "void", "while", "async", "await"],
                               types: ["int", "long", "string", "bool", "double", "float", "decimal", "object", "List", "Task"],
                               lineComments: ["//"], blockComment: ("/*", "*/"))
        l["go"] = Language(keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "nil", "true", "false"],
                           types: ["int", "int64", "string", "bool", "float64", "byte", "rune", "error"],
                           lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "`"])
        l["rust"] = Language(keywords: ["as", "async", "await", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"],
                             types: ["i32", "i64", "u8", "u32", "u64", "usize", "f64", "bool", "String", "Vec", "Option", "Result", "str", "Box"],
                             lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\""])
        l["ruby"] = Language(keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield", "require", "attr_accessor"],
                             lineComments: ["#"])
        l["php"] = Language(keywords: ["abstract", "and", "array", "as", "break", "case", "catch", "class", "const", "continue", "default", "do", "echo", "else", "elseif", "extends", "final", "for", "foreach", "function", "global", "if", "implements", "include", "interface", "namespace", "new", "null", "or", "private", "protected", "public", "require", "return", "static", "switch", "this", "throw", "true", "false", "try", "use", "var", "while"],
                            lineComments: ["//", "#"], blockComment: ("/*", "*/"))
        l["sql"] = Language(keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "join", "left", "right", "inner", "outer", "on", "as", "group", "by", "order", "having", "limit", "offset", "distinct", "union", "all", "null", "is", "in", "like", "between", "primary", "key", "foreign", "references", "index", "view", "case", "when", "then", "else", "end", "asc", "desc", "count", "sum", "avg", "min", "max", "exists"],
                            types: ["int", "integer", "varchar", "text", "date", "datetime", "boolean", "float", "decimal", "char", "timestamp"],
                            lineComments: ["--"], blockComment: ("/*", "*/"), caseInsensitive: true)
        l["bash"] = Language(keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "exit", "local", "export", "echo", "cd", "source", "set", "unset", "sudo", "true", "false"],
                             lineComments: ["#"])
        l["json"] = Language(keywords: ["true", "false", "null"], stringDelimiters: ["\""])
        l["yaml"] = Language(keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComments: ["#"])
        l["css"] = Language(keywords: ["important", "media", "import", "keyframes", "font-face", "supports"], lineComments: [], blockComment: ("/*", "*/"))
        l["html"] = Language(keywords: [], blockComment: ("<!--", "-->"), markup: true)
        return l
    }()

    static let aliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "node": "javascript",
        "ts": "typescript", "tsx": "typescript", "py": "python", "python3": "python",
        "c++": "cpp", "cc": "cpp", "hpp": "cpp", "h": "c", "objc": "c", "objective-c": "c",
        "cs": "csharp", "c#": "csharp", "kt": "kotlin", "golang": "go", "rs": "rust", "rb": "ruby",
        "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash", "yml": "yaml",
        "xml": "html", "xhtml": "html", "svg": "html", "plist": "html", "scss": "css", "less": "css",
        "postgres": "sql", "mysql": "sql", "sqlite": "sql", "jsonc": "json",
    ]

    public static func isSupported(_ language: String) -> Bool {
        let key = language.lowercased()
        return languages[aliases[key] ?? key] != nil
    }

    /// Returns HTML-escaped code with highlight spans (or plain escaped code for unknown languages).
    public static func html(_ code: String, language: String) -> String {
        let key = language.lowercased()
        guard let lang = languages[aliases[key] ?? key] else { return HTMLRenderer.escape(code) }
        return lang.markup ? markupHTML(code) : tokenHTML(code, lang)
    }

    private static func span(_ cls: String, _ text: String) -> String {
        "<span class=\"hl-\(cls)\">\(HTMLRenderer.escape(text))</span>"
    }

    private static func tokenHTML(_ code: String, _ lang: Language) -> String {
        let c = Array(code)
        var out = ""
        var i = 0
        var plain = ""
        func flushPlain() { out += HTMLRenderer.escape(plain); plain = "" }
        func matches(_ s: String, at k: Int) -> Bool {
            let a = Array(s)
            guard k + a.count <= c.count else { return false }
            return Array(c[k..<(k + a.count)]) == a
        }

        while i < c.count {
            let ch = c[i]
            // Comments
            if let lc = lang.lineComments.first(where: { matches($0, at: i) }) {
                _ = lc
                var k = i
                while k < c.count, c[k] != "\n" { k += 1 }
                flushPlain(); out += span("com", String(c[i..<k])); i = k; continue
            }
            if let (open, close) = lang.blockComment, matches(open, at: i) {
                var k = i + open.count
                while k < c.count, !matches(close, at: k) { k += 1 }
                k = min(c.count, k + close.count)
                flushPlain(); out += span("com", String(c[i..<k])); i = k; continue
            }
            // Strings
            if lang.stringDelimiters.contains(ch) {
                var k = i + 1
                let triple = matches(String(repeating: ch, count: 3), at: i)
                if triple { k = i + 3 }
                while k < c.count {
                    if c[k] == "\\" { k += 2; continue }
                    if triple {
                        if matches(String(repeating: ch, count: 3), at: k) { k += 3; break }
                    } else if c[k] == ch { k += 1; break }
                    else if c[k] == "\n" && ch != "`" { break }
                    k += 1
                }
                k = min(k, c.count)
                flushPlain(); out += span("str", String(c[i..<k])); i = k; continue
            }
            // Numbers
            if ch.isNumber, i == 0 || !(c[i - 1].isLetter || c[i - 1] == "_") {
                var k = i
                while k < c.count, c[k].isHexDigit || c[k] == "." || c[k] == "x" || c[k] == "_" || c[k] == "e" { k += 1 }
                flushPlain(); out += span("num", String(c[i..<k])); i = k; continue
            }
            // Words
            if ch.isLetter || ch == "_" || ch == "@" || ch == "#" {
                var k = i + 1
                while k < c.count, c[k].isLetter || c[k].isNumber || c[k] == "_" || c[k] == "?" && ch == "d" { k += 1 }
                let word = String(c[i..<k])
                let lookup = lang.caseInsensitive ? word.lowercased() : word
                if lang.keywords.contains(lookup) {
                    flushPlain(); out += span("kw", word)
                } else if lang.types.contains(lookup) || (word.first?.isUppercase == true && word.count > 1 && !lang.caseInsensitive) {
                    flushPlain(); out += span("type", word)
                } else if k < c.count, c[k] == "(" {
                    flushPlain(); out += span("fn", word)
                } else {
                    plain += word
                }
                i = k
                continue
            }
            plain.append(ch)
            i += 1
        }
        flushPlain()
        return out
    }

    /// HTML/XML: tags, attribute names, attribute values and comments.
    private static func markupHTML(_ code: String) -> String {
        let pattern = #"(<!--[\s\S]*?-->)|(</?[A-Za-z][\w:\-]*)|(\s[\w:\-]+)(=)|("[^"]*"|'[^']*')|(/?>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return HTMLRenderer.escape(code) }
        let ns = code as NSString
        var out = ""
        var last = 0
        var insideTag = false
        for m in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            out += HTMLRenderer.escape(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            if m.range(at: 1).location != NSNotFound {
                out += span("com", ns.substring(with: m.range(at: 1)))
            } else if m.range(at: 2).location != NSNotFound {
                out += span("kw", ns.substring(with: m.range(at: 2))); insideTag = true
            } else if m.range(at: 3).location != NSNotFound, insideTag {
                out += span("attr", ns.substring(with: m.range(at: 3))) + "="
            } else if m.range(at: 5).location != NSNotFound, insideTag {
                out += span("str", ns.substring(with: m.range(at: 5)))
            } else if m.range(at: 6).location != NSNotFound {
                out += span("kw", ns.substring(with: m.range(at: 6))); insideTag = false
            } else {
                out += HTMLRenderer.escape(ns.substring(with: m.range))
            }
            last = NSMaxRange(m.range)
        }
        out += HTMLRenderer.escape(ns.substring(from: last))
        return out
    }
}
