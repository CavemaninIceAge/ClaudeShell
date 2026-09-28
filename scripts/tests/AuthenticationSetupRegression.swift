import Foundation

enum AuthenticationSetupRegression {
    struct Failure: Error, CustomStringConvertible { var description: String }
    private final class Vault: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
        var adapter: CredentialVault {
            CredentialVault(read: { key in self.lock.lock(); defer { self.lock.unlock() }; return self.values[key] },
                            write: { key, value in self.lock.lock(); defer { self.lock.unlock() }; self.values[key] = value },
                            delete: { key in self.lock.lock(); defer { self.lock.unlock() }; self.values.removeValue(forKey: key) })
        }
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudex-auth-setup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try discovery()
        try plansAndParsing(root: root)
        try await nativeLoginFixture(root: root)
        print("PASS — executable discovery, isolated native login plan, fake CLI authentication and cancellation")
    }

    private static func discovery() throws {
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let resolved = EngineAvailability.resolve(engine: .codex, configuredPath: "", path: "/usr/bin:/bin", home: "/fixture") { $0 == bundled }
        try expect(resolved == bundled, "Packaged Codex CLI was not discovered without its GUI")
        let custom = EngineAvailability.resolve(engine: .claude, configuredPath: "/custom/claude", path: "/other", home: "/fixture") { $0 == "/custom/claude" }
        try expect(custom == "/custom/claude", "Explicit executable did not take precedence")
        let broken = EngineAvailability.resolve(engine: .claude, configuredPath: "/missing/claude", path: "/other", home: "/fixture") { $0 == "/other/claude" }
        try expect(broken == nil, "Invalid override silently launched a different executable")
        let relative = EngineAvailability.resolve(engine: .codex, configuredPath: "", path: ".::bin", home: "/fixture") { !$0.hasPrefix("/") }
        try expect(relative == nil, "Relative PATH resolved code from the project directory")
        let npm = EngineAvailability.resolve(engine: .codex, configuredPath: "", path: "", home: "/fixture") { $0 == "/fixture/.npm-global/bin/codex" }
        try expect(npm == "/fixture/.npm-global/bin/codex", "Standalone user npm Codex install missing")
    }

    private static func plansAndParsing(root: URL) throws {
        let env = ["CODEX_HOME": "/shared-codex", "OPENAI_API_KEY": "wrong", "OPENAI_IDENTITY_TOKEN_FILE": "/private/wif",
                   "CODEX_ACCESS_TOKEN": "wrong", "CODEX_API_KEY": "wrong", "PATH": "/usr/bin:/bin"]
        let plan = CodexLoginFlow.plan(executable: "/fake/codex", directory: root, base: env, method: .device)
        try expect(plan.environment["CODEX_HOME"] == root.path && plan.environment["BROWSER"] == "/usr/bin/true", "Login was not private and browser-suppressed")
        try expect(plan.environment["OPENAI_API_KEY"] == nil && plan.environment["OPENAI_IDENTITY_TOKEN_FILE"] == nil && plan.environment["CODEX_ACCESS_TOKEN"] == nil, "Inherited auth overrode selected native login")
        try expect(plan.arguments == ["-c", "cli_auth_credentials_store=\"file\"", "login", "--device-auth"], "Device login command does not enforce isolated file store")
        let api = CodexLoginFlow.plan(executable: "/fake/codex", directory: root, base: env, method: .apiKey)
        try expect(api.arguments.last == "--with-api-key" && !api.arguments.contains("wrong"), "API secret leaked to process arguments")
        let challenge = CodexLoginFlow.challenge(in: "\u{1b}[32mhttps://auth.openai.com/codex/device\u{1b}[0m\n\n  ABCD-EFGHI\n")
        try expect(challenge.url?.host == "auth.openai.com" && challenge.code == "ABCD-EFGHI", "ANSI device challenge parsing failed")
        let inline = CodexLoginFlow.challenge(in: "Device code: ABCD-EFGH (expires in 15 minutes)\nhttps://auth.openai.com/codex/device")
        try expect(inline.code == "ABCD-EFGH", "Labelled device code parsing failed")
        try expect(CodexLoginFlow.challenge(in: "https://evil.example/codex/device\nhttps://user:secret@auth.openai.com/codex/device").url == nil, "Untrusted auth URL accepted")
        let claude = LoginSession.environment(for: root, base: ["ANTHROPIC_API_KEY": "wrong", "ANTHROPIC_BASE_URL": "https://wrong.example", "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_OAUTH_TOKEN": "wrong", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "shared"])
        try expect(claude["ANTHROPIC_API_KEY"] == nil && claude["ANTHROPIC_BASE_URL"] == nil && claude["CLAUDE_CODE_USE_BEDROCK"] == nil && claude["CLAUDE_CODE_OAUTH_TOKEN"] == nil, "Claude login inherited another provider's authentication")
        try expect(claude["CLAUDE_CONFIG_DIR"] == root.path && claude["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == root.path, "Claude login reused the shared keychain service")
        try expect(LoginSession.firstURL(in: "See https://example.com/help then https://claude.ai/oauth/authorize?fixture=true")?.host == "claude.ai", "Claude picked a help URL instead of official authorization")
    }

    @MainActor private static func nativeLoginFixture(root: URL) async throws {
        let executable = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        set -eu
        [ "$1" = '-c' ]
        [ "$2" = 'cli_auth_credentials_store="file"' ]
        [ "$3" = 'login' ]
        [ "$4" = '--with-api-key' ]
        [ -z "${OPENAI_API_KEY+x}" ]
        [ -z "${CODEX_ACCESS_TOKEN+x}" ]
        IFS= read -r fixture_key
        [ "$fixture_key" = 'synthetic-key-only' ]
        printf '%s' '{"OPENAI_API_KEY":"synthetic-key-only"}' > "$CODEX_HOME/auth.json"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let memory = Vault()
        let session = CodexLoginSession(dependencies: .init(executable: { executable.path },
            environment: { ["PATH": "/usr/bin:/bin", "OPENAI_API_KEY": "must-not-inherit", "CODEX_ACCESS_TOKEN": "must-not-inherit"] },
            supportDirectory: { root }, vault: memory.adapter))
        try expect(session.phase == .ready && memory.count == 0, "Creating login session started authentication")
        var finished: CodexAccount?
        session.onFinished = { finished = $0 }
        session.start(method: .apiKey, apiKey: "synthetic-key-only")
        for _ in 0..<100 where finished == nil {
            if case .failed(let message) = session.phase { throw Failure(description: "Synthetic native login failed: " + message) }
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(finished?.email == "Codex API Key" && memory.count == 1, "Native stdin login did not save to injected credential vault")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        try expect(!remaining.contains(where: { $0.hasPrefix("codex-login-") }), "Successful login left plaintext auth file behind")

        let waiting = root.appendingPathComponent("fake-device-codex")
        try "#!/bin/sh\nprintf 'https://auth.openai.com/codex/device\\nABCD-EFGHI\\n'\nexec /bin/sleep 30\n".write(to: waiting, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: waiting.path)
        let cancelled = CodexLoginSession(dependencies: .init(executable: { waiting.path }, environment: { ["PATH": "/usr/bin:/bin"] }, supportDirectory: { root }, vault: memory.adapter))
        var cancelledCallback = false
        cancelled.onFinished = { _ in cancelledCallback = true }
        cancelled.start(method: .device)
        for _ in 0..<100 where cancelled.deviceCode == nil { try await Task.sleep(for: .milliseconds(20)) }
        try expect(cancelled.deviceCode == "ABCD-EFGHI", "Synthetic device code did not reach observable state")
        cancelled.cancel()
        for _ in 0..<100 {
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            if !names.contains(where: { $0.hasPrefix("codex-login-") }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        try expect(!names.contains(where: { $0.hasPrefix("codex-login-") }) && !cancelledCallback && memory.count == 1, "Cancelled device login leaked private files or switched account")
    }
}
