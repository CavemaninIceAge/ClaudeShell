import Foundation

private final class TestCredentialVault: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var failedWrite: (key: String, value: String)?
    func failNextWrite(to key: String, value: String) {
        lock.lock(); defer { lock.unlock() }
        failedWrite = (key, value)
    }
    var vault: CredentialVault {
        CredentialVault(read: { key in self.lock.lock(); defer { self.lock.unlock() }; return self.values[key] },
                        write: { key, value in
                            self.lock.lock(); defer { self.lock.unlock() }
                            if self.failedWrite?.key == key && self.failedWrite?.value == value {
                                self.failedWrite = nil
                                throw AccountsRegression.Failure(message: "injected Keychain write failure")
                            }
                            self.values[key] = value
                        },
                        delete: { key in self.lock.lock(); defer { self.lock.unlock() }; self.values.removeValue(forKey: key) })
    }
}

enum AccountsRegression {
    struct Failure: Error { let message: String }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message: message) }
    }
    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudex-accounts-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prior = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = prior
        arguments["testAccountSupportDir"] = root.appendingPathComponent("app").path
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(prior, forName: UserDefaults.argumentDomain)
            try? FileManager.default.removeItem(at: root)
        }
        let memory = TestCredentialVault(), vault = memory.vault
        let live = root.appendingPathComponent("terminal")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let base = ["CLAUDE_CONFIG_DIR": live.path, "CLAUDE_SECURESTORAGE_CONFIG_DIR": "stale-shared-service",
                    "ANTHROPIC_AUTH_TOKEN": "wrong-provider-token", "ANTHROPIC_BASE_URL": "https://wrong.example",
                    "CLAUDE_CODE_OAUTH_TOKEN": "wrong-subscription-token", "PATH": "/usr/bin:/bin"]
        let settings: [String: Any] = ["env": ["ANTHROPIC_BASE_URL": "https://wrong.example", "ANTHROPIC_API_KEY": "old-secret", "KEEP_ME": "yes"],
                                        "apiKeyHelper": "do-not-execute", "permissions": ["defaultMode": "default"]]
        try ClaudeSettings.write(settings, env: base)
        let liveBytes = try Data(contentsOf: ClaudeSettings.url(env: base))
        let account = ClaudeAccount(id: "test-subscription", email: "test@example.invalid", orgName: "Test", orgId: "org", oauthAccount: .object(["accountUuid": .string("test-subscription")]), addedAt: Date())
        let first = #"{"claudeAiOauth":{"accessToken":"fixture-old","refreshToken":"fixture-refresh","expiresAt":100}}"#
        let rotated = #"{"claudeAiOauth":{"accessToken":"fixture-new","refreshToken":"fixture-rotated","expiresAt":200}}"#
        try vault.write(account.keychainService, first)
        let isolated = try AccountOps.prepareIsolated(account, base: base, vault: vault)
        try expect(isolated["CLAUDE_CONFIG_DIR"] != live.path, "Claude switch reused shared home")
        let nativeProjects = URL(fileURLWithPath: isolated["CLAUDE_CONFIG_DIR"]!).appendingPathComponent("projects")
        let actualProjects = nativeProjects.resolvingSymlinksInPath().standardizedFileURL.path
        let expectedProjects = live.appendingPathComponent("projects").resolvingSymlinksInPath().standardizedFileURL.path
        try expect(actualProjects == expectedProjects, "Claude native sessions differ: \(actualProjects) != \(expectedProjects)")
        try expect(isolated["ANTHROPIC_AUTH_TOKEN"] == nil && isolated["ANTHROPIC_BASE_URL"] == nil && isolated["CLAUDE_CODE_OAUTH_TOKEN"] == nil, "Inherited authentication leaked")
        let privateSettings = try ClaudeSettings.read(env: isolated)
        try expect(privateSettings["apiKeyHelper"] == nil, "Subscription inherited an API key helper")
        try expect((privateSettings["env"] as? [String: String])?["KEEP_ME"] == "yes", "Safe preferences were dropped")
        try expect(try Data(contentsOf: ClaudeSettings.url(env: base)) == liveBytes, "App-only account preparation altered terminal settings")
        try expect(!FileManager.default.fileExists(atPath: ClaudeAuth.configFileURL(env: base).path), "App-only account preparation wrote shared identity")
        let runtimeService = ClaudeAuth.credentialsService(env: isolated)
        try vault.write(runtimeService, rotated)
        _ = try AccountOps.prepareIsolated(account, base: base, vault: vault)
        try expect(vault.read(account.keychainService) == rotated, "Claude refresh token rotation lost to stale snapshot")
        try vault.write(account.keychainService, first)
        _ = try AccountOps.prepareIsolated(account, base: base, vault: vault)
        try expect(vault.read(runtimeService) == rotated, "Stale imported login overwrote newer runtime")

        let provider = APIProvider(id: "fixture-glm", name: "GLM", baseURL: "https://open.bigmodel.cn/api/anthropic", keychainService: "fixture-key", model: "glm-fixture", extraEnv: nil, addedAt: Date())
        try vault.write(provider.keychainService, "fake-glm-secret")
        let providerEnv = try ProviderOps.prepareIsolated(provider, base: base, vault: vault)
        let providerSettings = try ClaudeSettings.read(env: providerEnv)
        let providerVars = providerSettings["env"] as? [String: String]
        try expect(providerVars?["ANTHROPIC_AUTH_TOKEN"] == "" && providerVars?["ANTHROPIC_API_KEY"] == "", "Provider leaves inherited auth overrides")
        try expect(providerVars?["ANTHROPIC_BASE_URL"] == provider.baseURL, "Provider URL not isolated")
        try expect(!(String(data: try Data(contentsOf: ClaudeSettings.url(env: providerEnv)), encoding: .utf8) ?? "").contains("fake-glm-secret"), "Provider secret persisted in plaintext settings")
        try expect(try Data(contentsOf: ClaudeSettings.url(env: base)) == liveBytes, "GLM selection changed shared settings")

        let malformed = root.appendingPathComponent("malformed")
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: malformed.appendingPathComponent("settings.json"))
        do {
            _ = try ProviderOps.prepareIsolated(APIProvider(id: "bad", name: "bad", baseURL: provider.baseURL, keychainService: provider.keychainService, model: nil, extraEnv: nil, addedAt: Date()), base: ["CLAUDE_CONFIG_DIR": malformed.path], vault: vault)
            throw Failure(message: "Malformed shared settings were silently treated as empty")
        } catch is AccountOps.Failure { }
        try expect(try String(contentsOf: malformed.appendingPathComponent("settings.json"), encoding: .utf8) == "{", "Malformed settings changed")

        let localCodex = root.appendingPathComponent("local-codex")
        try FileManager.default.createDirectory(at: localCodex, withIntermediateDirectories: true)
        let codexPayload = #"{"OPENAI_API_KEY":"fixture-api-key","last_refresh":"2026-09-28T10:00:00Z"}"#
        let codex = try CodexAccountOps.account(payload: codexPayload)
        try CodexAccountOps.save(codex, payload: codexPayload, vault: vault)
        let codexEnv = try CodexAccountOps.prepare(codex, base: ["CODEX_HOME": localCodex.path, "OPENAI_API_KEY": "other", "CODEX_ACCESS_TOKEN": "other", "OPENAI_IDENTITY_TOKEN_FILE": "/wrong", "OPENAI_IDENTITY_TOKEN": "wrong"], vault: vault)
        try expect(codexEnv["CODEX_HOME"] != localCodex.path, "Codex app reused shared login home")
        let nativeSessions = URL(fileURLWithPath: codexEnv["CODEX_HOME"]!).appendingPathComponent("sessions")
        try expect(nativeSessions.resolvingSymlinksInPath().standardizedFileURL.path == localCodex.appendingPathComponent("sessions").resolvingSymlinksInPath().standardizedFileURL.path, "Codex native sessions were duplicated")
        try expect(codexEnv["OPENAI_API_KEY"] == nil && codexEnv["CODEX_ACCESS_TOKEN"] == nil && codexEnv["OPENAI_IDENTITY_TOKEN_FILE"] == nil && codexEnv["OPENAI_IDENTITY_TOKEN"] == nil, "Codex auth override leaked")
        try expect(!FileManager.default.fileExists(atPath: localCodex.appendingPathComponent("auth.json").path), "Codex preparation wrote live auth")
        try Data("cli_auth_credentials_store = \"keyring\"\n".utf8).write(to: localCodex.appendingPathComponent("config.toml"))
        do { try CodexAccountOps.requireFileStore(home: localCodex); throw Failure(message: "Keyring silently reported supported") }
        catch is AccountOps.Failure { }

        let invalidManifest = root.appendingPathComponent("broken-providers.json")
        let invalidBytes = Data("{bad manifest".utf8)
        try invalidBytes.write(to: invalidManifest)
        let preserved = try AccountManifestStorage.preserveInvalid(invalidManifest)
        try Data("{}".utf8).write(to: invalidManifest)
        try expect(try Data(contentsOf: preserved) == invalidBytes, "Corrupt manifest original lost after next save")
        let freshCodex = #"{"OPENAI_API_KEY":"fixture-api-key","last_refresh":"2026-09-28T11:00:00Z"}"#
        try CodexAccountOps.save(codex, payload: freshCodex, vault: vault)
        _ = try CodexAccountOps.prepare(codex, base: ["CODEX_HOME": localCodex.path], vault: vault)
        let privateCodexAuth = AppAuthPaths.codexRuntimeHome(codex.id).appendingPathComponent("auth.json")
        try expect(try CodexAccountOps.compact(String(contentsOf: privateCodexAuth, encoding: .utf8)) == CodexAccountOps.compact(freshCodex), "New local Codex login lost to stale private runtime")
        try CodexAccountOps.save(codex, payload: codexPayload, vault: vault)
        _ = try CodexAccountOps.prepare(codex, base: ["CODEX_HOME": localCodex.path], vault: vault)
        try expect(try CodexAccountOps.compact(String(contentsOf: privateCodexAuth, encoding: .utf8)) == CodexAccountOps.compact(freshCodex), "Stale local Codex login replaced fresh credentials")

        let pushFile = root.appendingPathComponent("push-settings.json")
        let original = Data("before-secret".utf8)
        try original.write(to: pushFile)
        try vault.write("external-service", "before-token")
        let firstPlan = AccountPushOps.Plan(files: [.init(url: pushFile, contents: Data("after-secret".utf8))], credential: .init(service: "external-service", payload: "after-token"))
        try AccountPushOps.transaction(firstPlan, label: "fixture", vault: vault)
        let marker = try String(contentsOf: AccountPushOps.markerURL, encoding: .utf8)
        try expect(!marker.contains("secret") && !marker.contains("token"), "Backup marker leaked credentials")
        try AccountPushOps.rollback(vault: vault)
        try expect(try Data(contentsOf: pushFile) == original, "Rollback did not restore original file")
        try expect(vault.read("external-service") == "before-token", "Rollback did not restore original credential")

        // A process crash after writes but before commit still has every intended digest durably staged.
        let staged = try AccountPushOps.stage(firstPlan, label: "interrupted", vault: vault)
        try expect(staged.files[0].writtenDigest != nil && staged.writtenCredentialDigest != nil, "Expected output digests were not durable before mutation")
        try AccountPushOps.apply(firstPlan, backup: staged, vault: vault)
        try AccountPushOps.rollback(vault: vault)
        try expect(try Data(contentsOf: pushFile) == original && vault.read("external-service") == "before-token", "Pre-commit crash could not recover")

        // A partially completed rollback is retryable even when files were already restored.
        try AccountPushOps.transaction(firstPlan, label: "partial-restore", vault: vault)
        memory.failNextWrite(to: "external-service", value: "before-token")
        do { try AccountPushOps.rollback(vault: vault); throw Failure(message: "Expected injected rollback failure") }
        catch is Failure { }
        try expect(try Data(contentsOf: pushFile) == original, "File part of rollback did not complete")
        try expect(vault.read("external-service") == "after-token", "Injected credential restore failure did not occur")
        try AccountPushOps.rollback(vault: vault)
        try expect(vault.read("external-service") == "before-token", "Idempotent rollback retry rejected already restored file")

        // A failing subsequent push must not replace the last successful rollback point.
        try AccountPushOps.transaction(firstPlan, label: "previous-success", vault: vault)
        let previousMarker = try Data(contentsOf: AccountPushOps.markerURL)
        let failingPlan = AccountPushOps.Plan(files: [.init(url: pushFile, contents: Data("partial".utf8))], credential: .init(service: "external-service", payload: "rejected-token"))
        memory.failNextWrite(to: "external-service", value: "rejected-token")
        do { try AccountPushOps.transaction(failingPlan, label: "failing-next", vault: vault); throw Failure(message: "Expected transaction failure") }
        catch is Failure { }
        try expect(try String(contentsOf: pushFile, encoding: .utf8) == "after-secret", "Failed new push did not restore preceding state")
        try expect(try Data(contentsOf: AccountPushOps.markerURL) == previousMarker, "Failed push erased previous successful rollback")
        try expect(!FileManager.default.fileExists(atPath: AccountPushOps.pendingURL.path), "Recovered failed push left a pending transaction")
        try AccountPushOps.rollback(vault: vault)
        try expect(try Data(contentsOf: pushFile) == original && vault.read("external-service") == "before-token", "Previous successful rollback was lost")

        let conflictPlan = AccountPushOps.Plan(files: [.init(url: pushFile, contents: Data("pushed".utf8))])
        try AccountPushOps.transaction(conflictPlan, label: "conflict", vault: vault)
        try Data("user-newer-edit".utf8).write(to: pushFile)
        do { try AccountPushOps.rollback(vault: vault); throw Failure(message: "Rollback overwrote concurrent user edit") }
        catch is AccountOps.Failure { }
        try expect(try String(contentsOf: pushFile, encoding: .utf8) == "user-newer-edit", "Concurrent user edit lost")

        let protectedMarker = try Data(contentsOf: AccountPushOps.markerURL)
        let stalePlan = AccountPushOps.Plan(files: [.init(url: pushFile, contents: Data("would-clobber".utf8), expectedOriginal: .some(original))])
        do { try AccountPushOps.transaction(stalePlan, label: "stale-plan", vault: vault); throw Failure(message: "Stale derived plan should be rejected") }
        catch is AccountOps.Failure { }
        try expect(try String(contentsOf: pushFile, encoding: .utf8) == "user-newer-edit", "Planning race overwrote external edit")
        try expect(try Data(contentsOf: AccountPushOps.markerURL) == protectedMarker, "Rejected stale plan damaged rollback marker")

        // Concurrent profile prepares use unique temporary files and serialized settings replacement.
        let concurrentHome = root.appendingPathComponent("concurrent-settings")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask { try ClaudeSettings.write(["fixture": index], env: ["CLAUDE_CONFIG_DIR": concurrentHome.path]) }
            }
            try await group.waitForAll()
        }
        let finalSettings = try ClaudeSettings.read(env: ["CLAUDE_CONFIG_DIR": concurrentHome.path])
        try expect(finalSettings["fixture"] is Int, "Concurrent settings write produced invalid JSON")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: concurrentHome.path).filter { $0.hasPrefix(".settings.json.claudex-") }
        try expect(leftovers.isEmpty, "Concurrent settings writes left temporary files")
        print("Accounts regression passed (isolated homes, refresh tokens, provider hygiene, Codex import, transactional push/rollback).")
    }
}
