import Foundation

@MainActor
enum AuthFileRegression {
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("claudex-auth-files-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let env = ["CLAUDE_CONFIG_DIR": root.path]
        let target = root.appendingPathComponent("profile.json")
        let link = root.appendingPathComponent(".claude.json")
        let original = Data(#"{"unrelated":{"keep":true},"oauthAccount":{"accountUuid":"old"}}"#.utf8)
        try original.write(to: target)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        try ClaudeAuth.writeOAuthAccount(.object(["accountUuid": .string("fixture-new")]), env: env)
        let value = JSONValue.parse(try Data(contentsOf: target))!
        precondition(value["unrelated"]?["keep"]?.bool == true, "OAuth write must preserve unrelated settings")
        precondition(value["oauthAccount"]?["accountUuid"]?.string == "fixture-new")
        let destination = try fm.destinationOfSymbolicLink(atPath: link.path)
        precondition(destination == target.path, "OAuth write must preserve dotfile symlink")
        let mode = (try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue
        precondition(mode == 0o600, "OAuth file must stay private")
        try ClaudeAuth.writeOAuthAccount(nil, env: env)
        let cleared = JSONValue.parse(try Data(contentsOf: target))!
        precondition(cleared["oauthAccount"] == nil && cleared["unrelated"]?["keep"]?.bool == true)
        let malformed = Data("not-json fixture".utf8)
        try malformed.write(to: target)
        do {
            try ClaudeAuth.writeOAuthAccount(.object([:]), env: env)
            preconditionFailure("Malformed existing config must reject mutation")
        } catch {}
        let preserved = try Data(contentsOf: target)
        precondition(preserved == malformed)
        let fresh = root.appendingPathComponent("fresh")
        try ClaudeAuth.writeOAuthAccount(.object(["accountUuid": .string("first")]), env: ["CLAUDE_CONFIG_DIR": fresh.path])
        precondition(ClaudeAuth.readOAuthAccount(env: ["CLAUDE_CONFIG_DIR": fresh.path])?["accountUuid"]?.string == "first")
        for invalid in ["secret\ncommand", "service\rcommand", "secret\0value"] {
            do { try KeychainCLI.validate(invalid); preconditionFailure("Control character must reject") } catch {}
        }
        try KeychainCLI.validate("normal-'quoted'-value")
        let authEnv = ["CLAUDE_CONFIG_DIR": fresh.path]
        try ClaudeSettings.write(["env": ["ANTHROPIC_BASE_URL": "https://glm.example.invalid", "ANTHROPIC_MODEL": "glm-fixture"], "apiKeyHelper": "fixture-helper", "permissions": ["defaultMode": "plan"]], env: authEnv)
        let overlay = try ClaudeAuthOverrides.settings(environment: authEnv, ultracode: true)
        let overlayEnv = overlay["env"] as! [String: String]
        precondition(overlayEnv["ANTHROPIC_BASE_URL"] == "https://glm.example.invalid")
        precondition(overlayEnv["ANTHROPIC_AUTH_TOKEN"] == "" && overlayEnv["CLAUDE_CODE_USE_BEDROCK"] == "")
        precondition(overlay["apiKeyHelper"] as? String == "fixture-helper" && overlay["permissions"] == nil)
        precondition(overlay["ultracode"] as? Bool == true)
        let launch = LaunchConfig(executable: "/fixture/claude", cwd: root.path, sessionId: UUID().uuidString,
                                  resume: false, model: nil, permissionMode: "manual", effort: "ultracode", environment: authEnv)
        let launchArgs = try ClaudeAuthOverrides.launchArguments(launch)
        precondition(launchArgs.filter { $0 == "--settings" }.count == 1)
        precondition(launchArgs.contains("--no-chrome"))
        precondition(!launchArgs.contains(where: { $0.contains("fixture-helper") }))
        print("PASS auth files: unrelated keys, symlinks, private permissions, malformed-file refusal, first login, credential validation")
    }
}
