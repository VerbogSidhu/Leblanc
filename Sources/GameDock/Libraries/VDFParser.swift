import Foundation

/// A parsed VDF value: either a quoted string or a nested key/value dict.
enum VDFValue {
    case string(String)
    case dict([String: VDFValue])

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var dict: [String: VDFValue]? {
        if case .dict(let d) = self { return d }
        return nil
    }

    subscript(_ key: String) -> VDFValue? {
        dict?[key]
    }
}

/// Minimal, dependency-free VDF/ACF parser (the format Steam uses for
/// libraryfolders.vdf and appmanifest_*.acf).
///
/// Grammar: `key value` pairs where key is a quoted string and value is either
/// a quoted string or a `{ ... }` block. `//` and `/* */` comments are ignored.
/// When a key repeats inside a dict, the last value wins (acceptable for our
/// use — Steam's library VDFs have unique keys per dict).
enum VDFParser {
    static func parse(_ text: String) -> VDFValue? {
        // Skip UTF-8 BOM if present.
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }

        let scanner = Scanner(Array(body))
        scanner.skipTrivia()
        guard !scanner.isAtEnd else { return nil }

        // Root can be either a bare `{ ... }` block or a sequence of
        // `"key" value` pairs (ACF files are `"AppState" { ... }`).
        if scanner.peek() == "{" {
            return .dict(scanner.readDictBody() ?? [:])
        }

        var root: [String: VDFValue] = [:]
        while !scanner.isAtEnd {
            scanner.skipTrivia()
            guard !scanner.isAtEnd else { break }
            guard let key = scanner.readQuotedString(),
                  let value = scanner.readValue() else { return nil }
            root[key] = value
        }
        return .dict(root)
    }

    private final class Scanner {
        private let chars: [Character]
        private var i = 0

        init(_ chars: [Character]) {
            self.chars = chars
        }

        var isAtEnd: Bool { i >= chars.count }

        fileprivate func peek(_ offset: Int = 0) -> Character? {
            let idx = i + offset
            guard idx < chars.count else { return nil }
            return chars[idx]
        }

        /// Advances past whitespace, // line comments and /* block comments */.
        func skipTrivia() {
            while !isAtEnd {
                let c = chars[i]
                if c.isWhitespace {
                    i += 1
                } else if c == "/" && peek(1) == "/" {
                    while !isAtEnd, chars[i] != "\n" { i += 1 }
                } else if c == "/" && peek(1) == "*" {
                    i += 2
                    while !isAtEnd, !(chars[i] == "*" && peek(1) == "/") { i += 1 }
                    i = min(i + 2, chars.count)
                } else {
                    break
                }
            }
        }

        /// Reads the next value (string or dict). Returns nil on syntax error.
        func readValue() -> VDFValue? {
            skipTrivia()
            guard !isAtEnd else { return nil }

            if chars[i] == "{" {
                guard let dict = readDictBody() else { return nil }
                return .dict(dict)
            }
            guard let str = readQuotedString() else { return nil }
            return .string(str)
        }

        /// Assumes current char is `{`; reads until matching `}`.
        fileprivate func readDictBody() -> [String: VDFValue]? {
            i += 1 // consume '{'
            var result: [String: VDFValue] = [:]

            while true {
                skipTrivia()
                if isAtEnd { return nil } // unbalanced
                if chars[i] == "}" {
                    i += 1
                    return result
                }
                guard let key = readQuotedString() else { return nil }
                guard let value = readValue() else { return nil }
                result[key] = value
            }
        }

        /// Reads a quoted string starting at current char (must be `"`).
        fileprivate func readQuotedString() -> String? {
            skipTrivia()
            guard !isAtEnd, chars[i] == "\"" else { return nil }
            i += 1

            var out: [Character] = []
            while !isAtEnd {
                let c = chars[i]
                if c == "\\" {
                    // Only treat known escapes specially (\", \\, \n, \t, \r); any other
                    // backslash (e.g. Windows paths like D:\Games) stays literal — the
                    // scout report (§6.1) confirmed the old code corrupted such values.
                    guard let next = peek(1) else {
                        out.append(c)
                        i += 1
                        return String(out)
                    }
                    switch next {
                    case "\"": out.append("\""); i += 2
                    case "\\": out.append("\\"); i += 2
                    case "n": out.append("\n"); i += 2
                    case "t": out.append("\t"); i += 2
                    case "r": out.append("\r"); i += 2
                    default:
                        out.append(c) // keep the backslash literally
                        i += 1
                    }
                } else if c == "\"" {
                    i += 1
                    return String(out)
                } else {
                    out.append(c)
                    i += 1
                }
            }
            return nil // unterminated string
        }
    }
}
