import Foundation

/// Authentication alone has launch-level precedence. Project permissions, hooks and other native
/// settings retain their normal precedence; a project's API endpoint cannot receive another account's token.
enum ClaudeAuthOverrides {
    static let routingKeys = ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                              "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_API_KEY"]

    static func settings(environment: [String: String], ultracode: Bool) throws -> [String: Any] {
        let original = try ClaudeSettings.read(env: environment)
        let privateEnv = original["env"] as? [String: String] ?? [:]
        var env = Dictionary(uniqueKeysWithValues: routingKeys.map { ($0, "") })
        env["ANTHROPIC_AUTH_TOKEN"] = ""
        env["ANTHROPIC_API_KEY"] = ""
        env["ANTHROPIC_BASE_URL"] = privateEnv["ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com"
        env["CLAUDE_CONFIG_DIR"] = ClaudeAuth.configDir(env: environment)
        env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = ClaudeAuth.configDir(env: environment)
        // Model aliases belonging to a GLM/API profile must reach its own endpoint coherently.
        for key in APIProvider.modelKeys {
            if let value = privateEnv[key] { env[key] = value }
        }
        var settings: [String: Any] = ["env": env, "apiKeyHelper": original["apiKeyHelper"] as? String ?? ""]
        if ultracode { settings["ultracode"] = true }
        return settings
    }

    static func launchArguments(_ config: LaunchConfig) throws -> [String] {
        guard let environment = config.environment else { return config.arguments }
        let settings = try settings(environment: environment, ultracode: config.effort == EffortOption.ultracode)
        // A unique file keeps simultaneous starts independent and credentials out of process arguments.
        let url = URL(fileURLWithPath: ClaudeAuth.configDir(env: environment))
            .appendingPathComponent("launch-auth-" + UUID().uuidString + ".json")
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        try AppAuthPaths.writePrivate(data, to: url)
        var arguments = config.arguments
        if let index = arguments.firstIndex(of: "--settings"), index + 1 < arguments.count {
            arguments.removeSubrange(index...index + 1)
        }
        arguments += ["--settings", url.path]
        return arguments
    }
}
