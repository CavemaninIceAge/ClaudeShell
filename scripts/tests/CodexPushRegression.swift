import Foundation

/// Synthetic credentials and a temporary native home; never reads the user's auth files or Keychain.
enum CodexPushRegression {
    struct Failure: Error, CustomStringConvertible { var description: String }
    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var writes = 0
        func set(_ key: String, _ value: String?) {
            lock.lock(); defer { lock.unlock() }
            values[key] = value
        }
        func read(_ key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }
        var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
        var vault: CredentialVault {
            CredentialVault(read: { self.read($0) }, write: { key, value in
                self.lock.lock(); defer { self.lock.unlock() }
                self.values[key] = value
                self.writes += 1
            }, delete: { self.set($0, nil) })
        }
    }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }
    private static func rejected(_ operation: () throws -> Void, _ message: String) throws {
        var failed = false
        do { try operation() } catch { failed = true }
        try expect(failed, message)
    }
    private static func plannedPayload(_ plan: AccountPushOps.Plan, equals payload: String) -> Bool {
        plan.files.first?.contents.flatMap(JSONValue.parse) == JSONValue.parse(payload)
    }
    private static func payload(account: String = "selected", time: Int?, token: String) throws -> String {
        func jwt(_ claims: [String: Any]) throws -> String {
            let bytes = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
            let encoded = bytes.base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "fixture.\(encoded).fixture"
        }
        let idToken = try jwt(["sub": "fixture-user", "email": "fixture@example.invalid",
                               "https://api.openai.com/auth": ["chatgpt_account_id": account]])
        var claims: [String: Any] = ["sub": "fixture-user"]
        if let time { claims["iat"] = time }
        let accessToken = try jwt(claims)
        let data = try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": account,
            "id_token": idToken, "access_token": accessToken, "refresh_token": token]], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    @MainActor static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudex-codex-push-test-" + UUID().uuidString)
        let home = root.appendingPathComponent("native")
        let support = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let prior = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = prior
        arguments["testAccountSupportDir"] = support.path
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(prior, forName: UserDefaults.argumentDomain)
            try? FileManager.default.removeItem(at: root)
        }
        let memory = Memory(), vault = memory.vault
        let base = ["CODEX_HOME": home.path]
        let authURL = home.appendingPathComponent("auth.json")
        let stale = try payload(time: 100, token: "synthetic-stale")
        let refreshed = try payload(time: 300, token: "synthetic-refreshed")
        let privateFresh = try payload(time: 400, token: "synthetic-private-newest")
        let other = try payload(account: "other", time: 900, token: "synthetic-other")
        let account = try CodexAccountOps.account(payload: stale)
        let runtime = AppAuthPaths.codexRuntimeHome(account.id).appendingPathComponent("auth.json")
        memory.set(account.keychainService, stale)
        try Data(refreshed.utf8).write(to: authURL)
        let firstPlan = try CodexAccountOps.pushPlan(account, base: base, vault: vault)
        try expect(plannedPayload(firstPlan, equals: refreshed), "Push replaced the native client's refreshed token with a stale snapshot")
        try expect(try Data(contentsOf: authURL) == Data(refreshed.utf8), "Planning changed native credentials")
        try expect(!FileManager.default.fileExists(atPath: support.path) && memory.writeCount == 0, "Planning mutated private files or saved credentials")

        try AppAuthPaths.writePrivate(Data(privateFresh.utf8), to: runtime)
        let runtimePlan = try CodexAccountOps.pushPlan(account, base: base, vault: vault)
        try expect(plannedPayload(runtimePlan, equals: privateFresh), "Newest same-account private runtime was ignored")
        try Data(other.utf8).write(to: authURL)
        let replacementPlan = try CodexAccountOps.pushPlan(account, base: base, vault: vault)
        try expect(plannedPayload(replacementPlan, equals: privateFresh), "A different native account displaced the selected account")
        try AccountPushOps.transaction(replacementPlan, label: "synthetic Codex push", vault: vault)
        try CodexAccountOps.verifyPushedAccount(account, home: home)
        try AccountPushOps.rollback(vault: vault)
        try expect(try Data(contentsOf: authURL) == Data(other.utf8), "Push rollback failed to restore previous native account")

        // A new native login between planning and staging must survive unchanged.
        let racePlan = try CodexAccountOps.pushPlan(account, base: base, vault: vault)
        try Data(refreshed.utf8).write(to: authURL)
        try rejected({ try AccountPushOps.transaction(racePlan, label: "synthetic race", vault: vault) }, "Push ignored an intervening native auth change")
        try expect(try Data(contentsOf: authURL) == Data(refreshed.utf8), "Push overwrote a concurrently changed native credential")
        try expect(!AccountPushOps.hasBackup, "Rejected planning race left a misleading push backup")

        for bad in ["{invalid synthetic JSON", other] {
            memory.set(account.keychainService, bad)
            try rejected({ _ = try CodexAccountOps.pushPlan(account, base: base, vault: vault) }, "Corrupt or wrong-account saved credential was accepted")
        }
        memory.set(account.keychainService, stale)
        try FileManager.default.removeItem(at: runtime)
        let undated = try payload(time: nil, token: "synthetic-undated")
        try Data(undated.utf8).write(to: authURL)
        let datedPlan = try CodexAccountOps.pushPlan(account, base: base, vault: vault)
        try expect(plannedPayload(datedPlan, equals: stale), "Undated native credential displaced a dated snapshot")
        try Data(other.utf8).write(to: authURL)
        try rejected({ try CodexAccountOps.verifyPushedAccount(account, home: home) }, "Readback accepted a different account")
        try Data("{invalid".utf8).write(to: authURL)
        try rejected({ try CodexAccountOps.verifyPushedAccount(account, home: home) }, "Readback accepted malformed credentials")

        // Missing local file is an explicit expected state, not a wildcard for later writes.
        try FileManager.default.removeItem(at: authURL)
        let absentPlan = try CodexAccountOps.pushPlan(account, base: base, vault: vault)
        try Data(other.utf8).write(to: authURL)
        try rejected({ try AccountPushOps.transaction(absentPlan, label: "synthetic absent race", vault: vault) }, "New login created after planning was overwritten")
        var deniedVault = vault
        deniedVault.checkedRead = { _ in throw Failure(description: "Synthetic inaccessible Keychain") }
        try rejected({ _ = try CodexAccountOps.pushPlan(account, base: base, vault: deniedVault) }, "Unreadable Keychain was treated as a missing saved credential")
        try Data("cli_auth_credentials_store = \"keyring\"\n".utf8).write(to: home.appendingPathComponent("config.toml"))
        try rejected({ _ = try CodexAccountOps.pushPlan(account, base: base, vault: vault) }, "Unsupported native credential store was silently reported as pushed")
        print("PASS Codex push: identity, native refresh preservation, pure planning, readback, races, rollback")
    }
}
