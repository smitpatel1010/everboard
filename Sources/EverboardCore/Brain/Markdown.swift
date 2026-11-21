import Foundation

/// Minimal YAML frontmatter: flat `key: value` pairs between `---` lines. Enough for Obsidian properties.
public enum Frontmatter {
    /// Splits a note into its frontmatter fields and body. Lists (`- x` lines, `[a, b]`) are joined with ", ".
    public static func parse(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else {
            return ([:], text)
        }
        let header = lines[1..<close]
        let body = lines[(close + 1)...].joined(separator: "\n")
        var fields: [String: String] = [:]
        var listKey: String?
        for line in header {
            if let key = listKey, line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                let item = unquote(String(line.trimmingCharacters(in: .whitespaces).dropFirst(2)))
                fields[key] = (fields[key].map { $0.isEmpty ? "" : $0 + ", " } ?? "") + item
                continue
            }
            listKey = nil
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("#") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if value.isEmpty { listKey = key; fields[key] = ""; continue }
            if value.hasPrefix("["), value.hasSuffix("]") {
                value = value.dropFirst().dropLast().split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .joined(separator: ", ")
            } else {
                value = unquote(value)
            }
            fields[key] = value
        }
        return (fields, body)
    }

    /// Renders fields in the given order as YAML, quoting every value.
    public static func render(_ fields: [(String, String)]) -> String {
        guard !fields.isEmpty else { return "" }
        // `tags` and `aliases` are lists in Obsidian; everything else is a quoted string.
        let lines = fields.map { key, value in
            ["tags", "aliases"].contains(key)
                ? "\(key): [" + value.split(separator: ",").map { quote($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: ", ") + "]"
                : "\(key): \(scalar(value))"
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n"
    }

    /// `note` with frontmatter field `key` set to `value`, only if the note already has that field. The rest of the
    /// note, including how its other fields are written, is left exactly as it was.
    public static func setting(_ key: String, to value: String, in note: String) -> String {
        var lines = note.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }),
              let i = lines[1..<close].firstIndex(where: { $0.hasPrefix(key + ":") }) else { return note }
        lines[i] = "\(key): \(scalar(value))"
        return lines.joined(separator: "\n")
    }

    /// Dates stay bare (`2026-11-18`) so Obsidian reads them as dates; everything else is quoted.
    static func scalar(_ s: String) -> String {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? s : quote(s)
    }

    public static func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") { return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return s
    }
}

/// Everboard-owned sections inside notes you may also edit. Only the text between the markers is ever replaced.
public enum ManagedBlock {
    public static func start(_ id: String) -> String { "<!-- everboard:\(id) -->" }
    public static func end(_ id: String) -> String { "<!-- /everboard:\(id) -->" }

    /// `note` with block `id` set to `content`: replaced in place if present, else appended.
    public static func upsert(_ note: String, id: String, content: String) -> String {
        let block = start(id) + "\n" + content.trimmingCharacters(in: .newlines) + "\n" + end(id)
        if let s = note.range(of: start(id)), let e = note.range(of: end(id), range: s.upperBound..<note.endIndex) {
            return note.replacingCharacters(in: s.lowerBound..<e.upperBound, with: block)
        }
        let trimmed = note.trimmingCharacters(in: .newlines)
        return (trimmed.isEmpty ? "" : note.hasSuffix("\n\n") ? note : trimmed + "\n\n") + block + "\n"
    }

    /// Content of block `id`, if present.
    public static func content(_ note: String, id: String) -> String? {
        guard let s = note.range(of: start(id)), let e = note.range(of: end(id), range: s.upperBound..<note.endIndex) else { return nil }
        return note[s.upperBound..<e.lowerBound].trimmingCharacters(in: .newlines)
    }

    /// The note without any Everboard blocks: what *you* wrote (used as AI context, so we don't feed our own output back).
    public static func stripAll(_ note: String) -> String {
        var out = note
        while let s = out.range(of: "<!-- everboard:"), let close = out.range(of: "-->", range: s.upperBound..<out.endIndex) {
            let id = out[s.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let e = out.range(of: end(id), range: close.upperBound..<out.endIndex) else { break }
            out.removeSubrange(s.lowerBound..<e.upperBound)
        }
        return out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
}

public enum NoteName {
    /// A file-name-safe version of `s` (no path separators, no characters Obsidian rejects in links).
    public static func safe(_ s: String, maxLength: Int = 90) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]\n\r\t")
        var out = String(s.unicodeScalars.map { banned.contains($0) ? " " : Character($0) })
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if out.count > maxLength { out = String(out.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return out.isEmpty ? "Untitled" : out
    }

    /// `[[Name]]` link to a note.
    public static func link(_ name: String) -> String { "[[\(safe(name))]]" }
}
