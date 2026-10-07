import Foundation

/// Edits `~/.codex/config.toml` by TOML structure rather than by substring.
///
/// Two settings are managed: a root-level `notify` and `[features].codex_hooks`.
/// Substring edits used to append `notify` after the last table (so it landed
/// inside that table) and to insert `codex_hooks = true` next to an existing
/// `codex_hooks = false` (a duplicate key, which is invalid TOML).
///
/// This is a line scanner, not a TOML parser. It understands table headers,
/// keys, multi-line arrays and multi-line strings, and refuses a file it
/// cannot follow (an unterminated array or string) instead of guessing.
enum CodexConfigEditor {
    enum EditError: Error, Equatable {
        /// The file uses a construct this editor will not edit around.
        case unsupported(String)
    }

    struct Edit: Equatable {
        var content: String
        /// Human-readable notes about what was (or deliberately was not) done.
        var notes: [String] = []
    }

    static let comment = "# CC Status Bar integration"

    // MARK: - Public edits

    /// Ensure a root-level `notify` pointing at our script.
    /// An existing third-party `notify` is left alone.
    static func ensuringRootNotify(in content: String, scriptPath: String) throws -> Edit {
        var lines = try scannedLines(content)
        let notifyLine = "notify = [\"python3\", \"\(scriptPath)\"]"
        var notes: [String] = []

        // Our own notify written into a table by the old substring edit: move it.
        let misplaced = lines.indices.filter {
            lines[$0].table != nil && lines[$0].key == "notify" && lines[$0].text.contains(scriptPath)
        }
        for index in misplaced.reversed() {
            let end = lines[index].valueEnd
            lines.removeSubrange(index...end)
            if index > 0, lines[index - 1].text.trimmingCharacters(in: .whitespaces) == comment {
                lines.remove(at: index - 1)
            }
            notes.append("moved a notify that had been written inside a table to the root")
        }

        if let existing = lines.first(where: { $0.table == nil && $0.key == "notify" }) {
            let end = lines.firstIndex(where: { $0.number == existing.number }).map { lines[$0].valueEnd } ?? 0
            let start = lines.firstIndex(where: { $0.number == existing.number }) ?? 0
            let value = lines[start...min(end, lines.count - 1)].map(\.text).joined(separator: "\n")
            if value.contains(scriptPath) {
                return Edit(content: render(lines), notes: notes)
            }
            notes.append("left an existing notify setting untouched; CC Status Bar notify not installed")
            return Edit(content: render(lines), notes: notes)
        }

        // Insert at the end of the root section, before the first table.
        let firstTable = lines.firstIndex(where: { $0.isHeader }) ?? lines.count
        var insertAt = firstTable
        while insertAt > 0, lines[insertAt - 1].text.trimmingCharacters(in: .whitespaces).isEmpty {
            insertAt -= 1
        }
        var block: [ScannedLine] = []
        if insertAt > 0 { block.append(ScannedLine(text: "")) }
        block.append(ScannedLine(text: comment))
        block.append(ScannedLine(text: notifyLine))
        if firstTable < lines.count, insertAt == firstTable { block.append(ScannedLine(text: "")) }
        lines.insert(contentsOf: block, at: insertAt)
        notes.append("added root notify")
        return Edit(content: render(lines), notes: notes)
    }

    /// Ensure `[features].codex_hooks = true`, exactly once.
    /// An explicit `codex_hooks = false` is the user's choice and is kept.
    static func ensuringHooksFeatureFlag(in content: String) throws -> Edit {
        var lines = try scannedLines(content)
        var notes: [String] = []

        var flags = lines.indices.filter { lines[$0].table == "features" && lines[$0].key == "codex_hooks" }
        if flags.count > 1 {
            // The old edit put `= true` in front of the user's own line. Keep the last.
            for index in flags.dropLast().reversed() { lines.remove(at: index) }
            notes.append("removed a duplicate codex_hooks key")
            flags = lines.indices.filter { lines[$0].table == "features" && lines[$0].key == "codex_hooks" }
        }

        if let index = flags.first {
            let value = lines[index].text.split(separator: "=", maxSplits: 1).last
                .map { $0.split(separator: "#").first ?? "" }?
                .trimmingCharacters(in: .whitespaces)
            if value != "true" {
                notes.append("codex_hooks is explicitly \(value ?? "set"); left as is, so Codex hooks stay off")
            }
            return Edit(content: render(lines), notes: notes)
        }

        if lines.contains(where: { $0.table != "features" && $0.key == "codex_hooks" }) {
            // Someone put the key outside [features]. Whatever they meant by
            // it, adding a second one elsewhere is not ours to decide.
            notes.append("codex_hooks is set outside [features], where Codex does not read it; left as is")
            return Edit(content: render(lines), notes: notes)
        }

        if let header = lines.firstIndex(where: { $0.isHeader && $0.table == "features" }) {
            lines.insert(ScannedLine(text: "codex_hooks = true"), at: header + 1)
        } else {
            if let last = lines.last, !last.text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(ScannedLine(text: ""))
            }
            lines.append(ScannedLine(text: "[features]"))
            lines.append(ScannedLine(text: "codex_hooks = true"))
            lines.append(ScannedLine(text: ""))
        }
        notes.append("enabled codex_hooks")
        return Edit(content: render(lines), notes: notes)
    }

    /// Structural check run on the result before it replaces the file.
    static func isConsistent(_ content: String) -> Bool {
        guard let lines = try? scannedLines(content) else { return false }
        let rootNotify = lines.filter { $0.table == nil && $0.key == "notify" }.count
        let flags = lines.filter { $0.table == "features" && $0.key == "codex_hooks" }.count
        let featureTables = lines.filter { $0.isHeader && $0.table == "features" }.count
        return rootNotify <= 1 && flags <= 1 && featureTables <= 1
    }

    // MARK: - Scanner

    struct ScannedLine: Equatable {
        var text: String
        var number = -1
        /// Name of the table this line belongs to; nil in the root section.
        var table: String?
        var isHeader = false
        /// Key defined on this line, if it starts a `key = value`.
        var key: String?
        /// Index of the last line of this key's value (multi-line arrays).
        var valueEnd = 0
    }

    static func scannedLines(_ content: String) throws -> [ScannedLine] {
        var result: [ScannedLine] = []
        var table: String?
        var depth = 0
        var openKeyIndex: Int?
        // Delimiter of the multi-line string we are inside, if any. Its body
        // is opaque: a line in it that looks like a table header is not one.
        var openString: String?

        let raw = content.components(separatedBy: "\n")
        for (number, text) in raw.enumerated() {
            var line = ScannedLine(text: text, number: number, table: table)

            if let delimiter = openString {
                if text.components(separatedBy: delimiter).count % 2 == 0 {
                    openString = nil
                    if depth == 0, let open = openKeyIndex {
                        result[open].valueEnd = result.count
                        openKeyIndex = nil
                    }
                }
                result.append(line)
                continue
            }

            // Blank out triple-quoted segments; an unclosed one opens a
            // multi-line string that runs on from this line.
            var visible = text
            for delimiter in ["\"\"\"", "'''"] {
                let parts = visible.components(separatedBy: delimiter)
                guard parts.count > 1 else { continue }
                visible = parts.enumerated().map { $0.offset % 2 == 0 ? $0.element : "" }.joined(separator: " ")
                if parts.count % 2 == 0 {
                    openString = delimiter
                    visible = parts.dropLast().enumerated()
                        .map { $0.offset % 2 == 0 ? $0.element : "" }.joined(separator: " ")
                }
                break
            }
            let code = strippingStringsAndComment(visible)
            let trimmed = code.trimmingCharacters(in: .whitespaces)

            if depth > 0 {
                depth += bracketDelta(code)
                if depth <= 0, let open = openKeyIndex {
                    depth = 0
                    result[open].valueEnd = result.count
                    openKeyIndex = nil
                }
            } else if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.contains("=") {
                let name = text.trimmingCharacters(in: .whitespaces)
                    .split(separator: "#").first.map(String.init)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[] \t")) ?? ""
                table = name
                line.table = name
                line.isHeader = true
            } else if let equals = trimmed.firstIndex(of: "=") {
                line.key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                line.valueEnd = result.count
                depth = max(0, bracketDelta(String(trimmed[trimmed.index(after: equals)...])))
                if depth > 0 || openString != nil { openKeyIndex = result.count }
            }
            result.append(line)
        }
        if depth > 0 { throw EditError.unsupported("an unterminated array") }
        if openString != nil { throw EditError.unsupported("an unterminated multi-line string") }
        return result
    }

    private static func render(_ lines: [ScannedLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// The line with quoted strings blanked and any trailing comment removed,
    /// so brackets and `=` inside strings or comments are not counted.
    private static func strippingStringsAndComment(_ text: String) -> String {
        var output = ""
        var quote: Character?
        var escaped = false
        for character in text {
            if let open = quote {
                if escaped { escaped = false }
                else if character == "\\", open == "\"" { escaped = true }
                else if character == open { quote = nil }
                output.append(" ")
            } else if character == "\"" || character == "'" {
                quote = character
                output.append(" ")
            } else if character == "#" {
                break
            } else {
                output.append(character)
            }
        }
        return output
    }

    private static func bracketDelta(_ code: String) -> Int {
        code.reduce(0) { $0 + ($1 == "[" ? 1 : $1 == "]" ? -1 : 0) }
    }
}
