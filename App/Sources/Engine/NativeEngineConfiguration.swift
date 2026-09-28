import Foundation

/// Preserve native, non-auth defaults without importing provider routes, hooks, MCP servers or plugins.
/// Original instruction files are linked, never read or rewritten by this adapter.
enum NativeEngineConfiguration {
    static let codexLaunchOverrides = ["-c", "cli_auth_credentials_store=\"file\"", "-c", "model_provider=\"openai\""]

    static func prepareClaude(from source: URL, at runtime: URL) throws {
        try linkIfPresent(source.appendingPathComponent("CLAUDE.md"), at: runtime.appendingPathComponent("CLAUDE.md"))
        try linkIfPresent(source.appendingPathComponent("rules"), at: runtime.appendingPathComponent("rules"))
    }

    static func prepareCodex(from source: URL, at runtime: URL) throws {
        let config = source.appendingPathComponent("config.toml")
        let preferences: String
        if FileManager.default.fileExists(atPath: config.path) {
            preferences = codexPreferenceSnapshot(try String(contentsOf: config, encoding: .utf8))
        } else { preferences = "" }
        let snapshot = "# Native non-auth model preferences, refreshed from the local Codex configuration.\n"
            + "cli_auth_credentials_store = \"file\"\nmodel_provider = \"openai\"\n" + preferences
        try AppAuthPaths.writePrivate(Data(snapshot.utf8), to: runtime.appendingPathComponent("config.toml"))
        for name in ["AGENTS.md", "AGENTS.override.md", "rules"] {
            try linkIfPresent(source.appendingPathComponent(name), at: runtime.appendingPathComponent(name))
        }
    }

    /// Only top-level scalar settings are carried over. Profiles and tables may change credential routing
    /// or activate external integrations, so their interpretation remains in the original native config.
    static func codexPreferenceSnapshot(_ source: String) -> String {
        let strings: Set<String> = ["model", "model_reasoning_effort", "model_reasoning_summary", "model_verbosity", "service_tier"]
        let integers: Set<String> = ["model_context_window", "model_auto_compact_token_limit", "tool_output_token_limit", "project_doc_max_bytes"]
        let booleans: Set<String> = ["model_supports_reasoning_summaries"]
        var lines: [String] = []
        var seen = Set<String>()
        var multiline: String?
        for raw in source.components(separatedBy: .newlines) {
            if let delimiter = multiline {
                if raw.contains(delimiter) { multiline = nil }
                continue
            }
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            // Ignore values spanning multiple lines, including unknown instruction/prompt fields.
            if let delimiter = ["\"\"\"", "'''"].first(where: { line.contains($0) }) {
                if line.components(separatedBy: delimiter).count == 2 { multiline = delimiter }
                continue
            }
            guard let split = line.firstIndex(of: "=") else { continue }
            let key = line[..<split].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            guard !seen.contains(key) else { continue }
            let valid: Bool
            if strings.contains(key) {
                valid = value.range(of: #"^(?:"(?:[^"\\\r\n]|\\["\\btnfr]|\\u[0-9a-fA-F]{4}|\\U[0-9a-fA-F]{8})*"|'[^'\r\n]*')$"#,
                                    options: .regularExpression) != nil
            } else if integers.contains(key) {
                valid = value.range(of: #"^[+]?[0-9]+(?:_[0-9]+)*$"#, options: .regularExpression) != nil
            } else if booleans.contains(key) { valid = value == "true" || value == "false" }
            else { valid = false }
            if valid { lines.append(key + " = " + value); seen.insert(key) }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if quote == "\"", character == "\\" { escaped = true; continue }
            if let current = quote { if character == current { quote = nil }; continue }
            if character == "\"" || character == "'" { quote = character }
            else if character == "#" { return String(line[..<index]) }
        }
        return line
    }

    private static func linkIfPresent(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        let target = source.resolvingSymlinksInPath().standardizedFileURL
        // Do not reconnect explicitly disabled resources through an aliased instruction/rules link.
        let blocked = ["superpowers", "teacher", "chrome"]
        guard !target.pathComponents.contains(where: { component in blocked.contains(where: { component.lowercased().contains($0) }) }) else { return }
        if let existing = try? fm.destinationOfSymbolicLink(atPath: destination.path) {
            let actual = existing.hasPrefix("/") ? URL(fileURLWithPath: existing) : destination.deletingLastPathComponent().appendingPathComponent(existing)
            guard actual.resolvingSymlinksInPath().standardizedFileURL.path == target.path else {
                throw AccountOps.Failure(message: "原生配置链接已指向另一处，未覆盖：\(destination.path)")
            }
            return
        }
        guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) else { return }
        try fm.createSymbolicLink(at: destination, withDestinationURL: target)
    }
}
