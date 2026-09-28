import Foundation

/// Resolve the local engines without launching either desktop app. Overrides belong only to this shell.
enum EngineAvailability {
    struct Status: Sendable, Identifiable {
        var engine: ConversationEngine
        var configuredPath: String
        var executablePath: String?
        var id: String { engine.rawValue }
        var isAvailable: Bool { executablePath != nil }
    }

    static func preferenceKey(for engine: ConversationEngine) -> String { "engineExecutable." + engine.rawValue }

    static func configuredPath(for engine: ConversationEngine, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: preferenceKey(for: engine)) ?? ""
    }

    static func executable(for engine: ConversationEngine) -> String? {
        resolve(engine: engine, configuredPath: configuredPath(for: engine), path: ShellEnvironment.loginPATH(), home: NSHomeDirectory())
    }

    static func statuses() -> [Status] {
        [.claude, .codex].map { Status(engine: $0, configuredPath: configuredPath(for: $0), executablePath: executable(for: $0)) }
    }

    /// A configured but invalid executable is an explicit failure, never silently replaced with another account's engine.
    static func resolve(engine: ConversationEngine, configuredPath: String, path: String, home: String,
                        isExecutable: (String) -> Bool = validExecutable) -> String? {
        let custom = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom.hasPrefix("/") && isExecutable(custom) ? custom : nil }
        let name = engine == .claude ? "claude" : "codex"
        var candidates = path.split(separator: ":").map { String($0) + "/" + name }
        candidates += [home + "/.local/bin/" + name, home + "/.npm-global/bin/" + name,
                       "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
        if engine == .codex {
            for root in ["/Applications", home + "/Applications"] {
                for app in ["ChatGPT.app", "Codex.app"] {
                    let resources = root + "/" + app + "/Contents/Resources/"
                    candidates += [resources + "codex-cli/CodexCLI.app/Contents/MacOS/codex",
                                   resources + "codex-cli/bin/codex", resources + "codex"]
                }
            }
        }
        // Relative/empty PATH entries must not resolve a program from the conversation's working directory.
        return candidates.first { $0.hasPrefix("/") && isExecutable($0) }
    }

    static func validExecutable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    static func setConfiguredPath(_ path: String, for engine: ConversationEngine, defaults: UserDefaults = .standard) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.isEmpty || (expanded.hasPrefix("/") && validExecutable(expanded)) else {
            throw AccountOps.Failure(message: "请选择可执行的 \(engine == .claude ? "claude" : "codex") 文件；留空可恢复自动查找。")
        }
        if expanded.isEmpty { defaults.removeObject(forKey: preferenceKey(for: engine)) }
        else { defaults.set(expanded, forKey: preferenceKey(for: engine)) }
    }
}
