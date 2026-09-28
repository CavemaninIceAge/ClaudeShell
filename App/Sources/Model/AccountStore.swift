import AppKit
import Foundation
import Observation

/// 一个保存下来的登录态。令牌本身在钥匙串（`Claude Shell-account-<id>`，内容和 Claude Code 自己那条一模一样），
/// 这里只有身份信息和切换时要写回 `.claude.json` 的 `oauthAccount`。
struct ClaudeAccount: Codable, Identifiable, Sendable, Equatable {
    var id: String              // Claude 的 accountUuid
    var email: String
    var orgName: String
    var orgId: String
    var subscriptionType: String?
    var oauthAccount: JSONValue
    var addedAt: Date
    var lastActiveAt: Date?

    var keychainService: String { "Claude Shell-account-" + id }

    /// 终端 `/status` 里那种写法：Max、Pro、Team、Enterprise。
    var planLabel: String? {
        guard let s = subscriptionType, !s.isEmpty else { return nil }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// 邮箱 @ 前面那段，够短就整个显示。
    var shortName: String { String(email.split(separator: "@").first ?? Substring(email)) }
}

struct AccountManifest: Codable, Sendable {
    var accounts: [ClaudeAccount] = []
    var activeId: String? = nil
}

/// 账号切换的实际动作，都是阻塞的文件 / 钥匙串 / 子进程操作，只在后台线程调。
enum AccountOps {
    enum LiveState: Sendable {
        case loggedOut
        case account(ClaudeAccount, payload: String)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 从 `oauthAccount` + 钥匙串 JSON（+ 可选的 `claude auth status`）拼出身份。
    static func account(from oauth: JSONValue, payload: String, identity: ClaudeAuth.Identity? = nil) -> ClaudeAccount? {
        let email = identity?.email ?? oauth["emailAddress"]?.string ?? ""
        let orgId = identity?.orgId ?? oauth["organizationUuid"]?.string ?? ""
        guard let id = oauth["accountUuid"]?.string ?? (email.isEmpty ? nil : orgId + "|" + email) else { return nil }
        return ClaudeAccount(id: id,
                             email: email,
                             orgName: identity?.orgName ?? oauth["organizationName"]?.string ?? "",
                             orgId: orgId,
                             subscriptionType: identity?.subscriptionType ?? ClaudeAuth.subscriptionType(inCredentials: payload),
                             oauthAccount: oauth,
                             addedAt: Date())
    }

    /// 现在钥匙串 + `.claude.json` 里登录的是谁。
    static func readLive(env: [String: String]) -> LiveState {
        guard let oauth = ClaudeAuth.readOAuthAccount(env: env),
              let payload = KeychainCLI.read(service: ClaudeAuth.credentialsService(env: env)),
              let acc = account(from: oauth, payload: payload) else { return .loggedOut }
        return .account(acc, payload: payload)
    }

    /// 把当前令牌存进这个账号的快照；内容没变就不写（少弹钥匙串、少改 mdat）。
    static func saveSnapshot(_ account: ClaudeAccount, payload: String) throws {
        let previous = KeychainCLI.read(service: account.keychainService)
        let payload = CredentialFreshness.newest(previous, payload, timestamp: CredentialFreshness.claude)
        if previous == payload { return }
        try KeychainCLI.write(service: account.keychainService, secret: payload)
    }

    /// 真正的切换：快照 → Claude Code 那条钥匙串，`oauthAccount` → `.claude.json`。
    static func switchLive(to account: ClaudeAccount, env: [String: String]) throws {
        guard let payload = KeychainCLI.read(service: account.keychainService) else {
            throw Failure(message: "钥匙串里没有 \(account.email) 的登录态，请移除后重新添加")
        }
        try KeychainCLI.write(service: ClaudeAuth.credentialsService(env: env), secret: payload)
        try ClaudeAuth.writeOAuthAccount(account.oauthAccount, env: env)
    }

    /// `claude auth login` 在临时配置目录里登录完以后，把它写下的令牌搬进快照，再把临时的都清掉。
    static func harvestLogin(dir: URL, env: [String: String]) throws -> ClaudeAccount {
        let service = ClaudeAuth.credentialsService(env: env)
        defer {
            KeychainCLI.delete(service: service)
            try? FileManager.default.removeItem(at: dir)
        }
        guard let payload = KeychainCLI.read(service: service) else {
            throw Failure(message: "登录流程结束了，但钥匙串里没有新账号的令牌（\(service)）")
        }
        let identity = ClaudeAuth.status(env: env)
        if let identity, !identity.loggedIn {
            throw Failure(message: "claude auth status 说没有登录成功")
        }
        // 正常情况 login 会把 oauthAccount 写进临时目录的 .claude.json；万一没写，就用 auth status 报的身份拼一个。
        var oauth = ClaudeAuth.readOAuthAccount(env: env)
        if oauth == nil, let identity, let email = identity.email {
            oauth = .object(["emailAddress": .string(email),
                             "organizationUuid": .string(identity.orgId ?? ""),
                             "organizationName": .string(identity.orgName ?? "")])
        }
        guard let oauth else {
            throw Failure(message: "登录流程结束了，但 \(dir.lastPathComponent)/.claude.json 里没有 oauthAccount，auth status 也没报邮箱")
        }
        guard let acc = account(from: oauth, payload: payload, identity: identity) else {
            throw Failure(message: "认不出新账号的身份（缺 accountUuid / 邮箱）")
        }
        try KeychainCLI.write(service: acc.keychainService, secret: payload)
        return acc
    }
}

/// Saved credentials and selections belong to this app. Shared terminal/Desktop state changes only through a push.
@MainActor
@Observable
final class AccountStore {
    static let shared = AccountStore()
    enum Busy: Equatable { case syncing; case switching(String) }

    private(set) var accounts: [ClaudeAccount] = []
    private(set) var activeId: String?
    private(set) var providers: [APIProvider] = []
    private(set) var activeProviderId: String?
    private(set) var codexAccounts: [CodexAccount] = []
    private(set) var activeCodexId: String?
    private(set) var isLoggedOut = false
    private(set) var busy: Busy?
    var lastError: String?
    private(set) var switchNote: String?
    private(set) var hasPushBackup = false
    var loginSession: LoginSession?
    var codexLoginSession: CodexLoginSession?
    var addingProvider = false
    var onSwitched: (@MainActor (ClaudeAccount?) -> Void)?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    @ObservationIgnored private var blockedManifestPaths: Set<String> = []
    @ObservationIgnored private var legacyProviderBackup: SettingsBackup?

    /// Identity metadata only; no secrets, Keychain reads, or account discovery occur during construction.
    struct Snapshot: Sendable {
        var accounts: [ClaudeAccount] = []
        var activeId: String? = nil
        var providers: [APIProvider] = []
        var activeProviderId: String? = nil
        var codexAccounts: [CodexAccount] = []
        var activeCodexId: String? = nil
    }

    init() {}

    init(snapshot: Snapshot) {
        self.accounts = snapshot.accounts
        self.activeId = snapshot.activeId
        self.providers = snapshot.providers
        self.activeProviderId = snapshot.activeProviderId
        self.codexAccounts = snapshot.codexAccounts
        self.activeCodexId = snapshot.activeCodexId
        self.isLoggedOut = snapshot.activeId == nil && snapshot.activeProviderId == nil
        self.loaded = true
    }

    var active: ClaudeAccount? { accounts.first { $0.id == activeId } }
    var activeProvider: APIProvider? { providers.first { $0.id == activeProviderId } }
    var activeCodex: CodexAccount? { codexAccounts.first { $0.id == activeCodexId } }
    var canPushToTerminal: Bool { active != nil || activeProvider != nil }
    var canPushToCodexApp: Bool { activeCodex != nil }

    private var liveEnv: [String: String] {
        var env = ShellEnvironment.environment()
        if let dir = UserDefaults.standard.string(forKey: "testClaudeConfigDir"), !dir.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = dir
            env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        }
        if let dir = UserDefaults.standard.string(forKey: "testCodexConfigDir"), !dir.isEmpty { env["CODEX_HOME"] = dir }
        return env
    }
    private var manifestURL: URL {
        UserDefaults.standard.string(forKey: "testAccountsFile").map { URL(fileURLWithPath: $0) }
            ?? AppAuthPaths.support.appendingPathComponent("accounts.json")
    }
    private var providersURL: URL {
        UserDefaults.standard.string(forKey: "testProvidersFile").map { URL(fileURLWithPath: $0) }
            ?? AppAuthPaths.support.appendingPathComponent("providers.json")
    }
    private var codexURL: URL { AppAuthPaths.support.appendingPathComponent("codex-accounts.json") }

    func load() {
        guard !loaded else { return }
        loaded = true
        if let data = readManifest(manifestURL) {
            if let m = try? JSONDecoder.standard.decode(AccountManifest.self, from: data) {
                accounts = m.accounts
                activeId = m.activeId
            } else { preserveInvalidManifest(manifestURL) }
        }
        if let data = readManifest(providersURL) {
            if let m = try? JSONDecoder.standard.decode(ProviderManifest.self, from: data) {
                providers = m.providers
                activeProviderId = m.activeId
                // Legacy versions persisted a shared-settings backup. Preserve it, with private permissions;
                // it is never used to silently alter terminal settings in the new app-only model.
                legacyProviderBackup = m.backup
                if m.backup != nil { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: providersURL.path) }
            } else { preserveInvalidManifest(providersURL) }
        }
        if let data = readManifest(codexURL) {
            if let m = try? JSONDecoder.standard.decode(CodexAccountManifest.self, from: data) {
                codexAccounts = m.accounts
                activeCodexId = m.activeId
            } else { preserveInvalidManifest(codexURL) }
        }
        hasPushBackup = AccountPushOps.hasBackup
        isLoggedOut = active == nil && activeProvider == nil
        LoginSession.sweepLeftovers()
        CodexLoginSession.sweepLeftovers()
    }
    private func readManifest(_ url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try Data(contentsOf: url) }
        catch {
            blockedManifestPaths.insert(url.path)
            lastError = "无法读取 \(url.lastPathComponent)，已停止改写这个清单"
            return nil
        }
    }
    private func preserveInvalidManifest(_ url: URL) {
        do {
            let backup = try AccountManifestStorage.preserveInvalid(url)
            lastError = "\(url.lastPathComponent) 无法读取，原文件已保留为 \(backup.lastPathComponent)"
        } catch {
            blockedManifestPaths.insert(url.path)
            lastError = "\(url.lastPathComponent) 无法读取且不能保存备份，已停止写入这个清单"
        }
    }
    private func save() {
        guard !blockedManifestPaths.contains(manifestURL.path) else { return }
        do { try AppAuthPaths.writePrivate(JSONEncoder.standard.encode(AccountManifest(accounts: accounts, activeId: activeId)), to: manifestURL) }
        catch { lastError = "保存账号清单失败：\(error.localizedDescription)" }
    }
    private func saveProviders() {
        guard !blockedManifestPaths.contains(providersURL.path) else { return }
        var m = ProviderManifest()
        m.providers = providers
        m.activeId = activeProviderId
        m.backup = legacyProviderBackup // retained only until successful Keychain migration
        do { try AppAuthPaths.writePrivate(JSONEncoder.standard.encode(m), to: providersURL) }
        catch { lastError = "保存提供方清单失败：\(error.localizedDescription)" }
    }
    private func saveCodex() {
        guard !blockedManifestPaths.contains(codexURL.path) else { return }
        do { try AppAuthPaths.writePrivate(JSONEncoder.standard.encode(CodexAccountManifest(accounts: codexAccounts, activeId: activeCodexId)), to: codexURL) }
        catch { lastError = "保存 Codex 账号失败：\(error.localizedDescription)" }
    }
    private func merge(_ acc: ClaudeAccount) {
        if let i = accounts.firstIndex(where: { $0.id == acc.id }) {
            var updated = acc
            updated.addedAt = accounts[i].addedAt
            updated.lastActiveAt = accounts[i].lastActiveAt
            accounts[i] = updated
        } else { accounts.append(acc) }
    }
    private func mergeCodex(_ acc: CodexAccount) {
        if let i = codexAccounts.firstIndex(where: { $0.id == acc.id }) {
            var updated = acc
            updated.addedAt = codexAccounts[i].addedAt
            updated.lastActiveAt = codexAccounts[i].lastActiveAt
            codexAccounts[i] = updated
        } else { codexAccounts.append(acc) }
    }
    private func note(_ message: String) {
        switchNote = message
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.switchNote = nil
        }
    }

    /// Refresh local snapshots without adopting an externally changed selection.
    func sync() async { await importLocalAccounts(showNote: false) }
    func importLocalAccounts() async { await importLocalAccounts(showNote: true) }
    private func importLocalAccounts(showNote: Bool) async {
        load()
        guard !inFlight else { return }
        inFlight = true
        busy = .syncing
        defer { inFlight = false; busy = nil }
        if showNote { lastError = nil }
        let env = liveEnv, all = providers
        if let legacy = legacyProviderBackup {
            let migrated = await Task.detached(priority: .utility) {
                do {
                    let encoded = try JSONEncoder.standard.encode(legacy)
                    let compact = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: encoded))
                    guard let payload = String(data: compact, encoding: .utf8) else { return false }
                    try KeychainCLI.write(service: "Claudex Shell-legacy-provider-backup", secret: payload)
                    return true
                } catch { return false }
            }.value
            if migrated { legacyProviderBackup = nil; saveProviders() }
        }
        let result = await Task.detached(priority: .utility) {
            var claude: ClaudeAccount?
            var codex: CodexAccount?
            var provider: APIProvider?
            var failures: [String] = []
            if case .account(let account, let payload) = AccountOps.readLive(env: env) {
                do { try AccountOps.saveSnapshot(account, payload: payload); claude = account }
                catch { failures.append(error.localizedDescription) }
            }
            do {
                if let (account, payload) = try CodexAccountOps.readLocal(env: env) {
                    try CodexAccountOps.save(account, payload: payload)
                    codex = account
                }
            } catch { failures.append(error.localizedDescription) }
            do { provider = try ProviderOps.importLocal(among: all, env: env) }
            catch { failures.append(error.localizedDescription) }
            return (claude, codex, provider, failures)
        }.value
        if let account = result.0 {
            merge(account)
            if activeId == nil && activeProviderId == nil { activeId = account.id }
            save()
        }
        if let account = result.1 {
            mergeCodex(account)
            if activeCodexId == nil { activeCodexId = account.id }
            saveCodex()
        }
        if let provider = result.2 {
            if let i = providers.firstIndex(where: { $0.id == provider.id }) { providers[i] = provider }
            else { providers.append(provider) }
            if activeId == nil && activeProviderId == nil { activeProviderId = provider.id }
            saveProviders()
        }
        isLoggedOut = active == nil && activeProvider == nil
        if showNote {
            let count = [result.0 != nil, result.1 != nil, result.2 != nil].filter { $0 }.count
            note(count > 0 ? "已保存本机 \(count) 类登录态；当前应用内选择保持独立" : "未发现可导入的本机登录态")
            if !result.3.isEmpty { lastError = result.3.joined(separator: "\n") }
        }
    }

    func switchTo(_ id: String) async {
        load()
        guard let target = accounts.first(where: { $0.id == id }) else { return }
        while inFlight { try? await Task.sleep(for: .milliseconds(50)) }
        inFlight = true; busy = .switching(id); lastError = nil
        defer { inFlight = false; busy = nil }
        let env = liveEnv
        do {
            _ = try await Task.detached(priority: .userInitiated) { try AccountOps.prepareIsolated(target, base: env) }.value
            activeId = id
            activeProviderId = nil
            isLoggedOut = false
            if let i = accounts.firstIndex(where: { $0.id == id }) { accounts[i].lastActiveAt = Date() }
            save(); saveProviders()
            onSwitched?(target)
            note("已在 Claudex Shell 中切换；终端登录态未改动")
        } catch { lastError = error.localizedDescription }
    }
    func switchToProvider(_ id: String) async {
        lastError = nil
        if let error = await performProviderSwitch(id) { lastError = error }
    }
    private func performProviderSwitch(_ id: String) async -> String? {
        load()
        guard let target = providers.first(where: { $0.id == id }) else { return "找不到这个提供方" }
        while inFlight { try? await Task.sleep(for: .milliseconds(50)) }
        inFlight = true; busy = .switching(id)
        defer { inFlight = false; busy = nil }
        let env = liveEnv
        do {
            _ = try await Task.detached(priority: .userInitiated) { try ProviderOps.prepareIsolated(target, base: env) }.value
        } catch { return error.localizedDescription }
        activeProviderId = id
        isLoggedOut = false
        if let i = providers.firstIndex(where: { $0.id == id }) { providers[i].lastActiveAt = Date() }
        saveProviders()
        onSwitched?(nil)
        note("已在 Claudex Shell 中切换至 \(target.name)；终端登录态未改动")
        return nil
    }
    func deactivateProvider() async {
        if let id = activeId { await switchTo(id); return }
        activeProviderId = nil
        isLoggedOut = true
        saveProviders()
        onSwitched?(nil)
        note("已停用应用内提供方；终端登录态未改动")
    }
    func switchToCodex(_ id: String) async {
        load()
        guard let target = codexAccounts.first(where: { $0.id == id }) else { return }
        while inFlight { try? await Task.sleep(for: .milliseconds(50)) }
        inFlight = true; busy = .switching(id); lastError = nil
        defer { inFlight = false; busy = nil }
        let env = liveEnv
        do {
            _ = try await Task.detached(priority: .userInitiated) { try CodexAccountOps.prepare(target, base: env) }.value
            activeCodexId = id
            if let i = codexAccounts.firstIndex(where: { $0.id == id }) { codexAccounts[i].lastActiveAt = Date() }
            saveCodex()
            onSwitched?(active)
            note("已切换应用内 Codex 账号；Codex app 与终端登录态未改动")
        } catch { lastError = error.localizedDescription }
    }

    func prepareClaudeEnvironment() async throws -> [String: String] {
        load()
        let env = liveEnv
        if let provider = activeProvider {
            return try await Task.detached(priority: .userInitiated) { try ProviderOps.prepareIsolated(provider, base: env) }.value
        }
        guard let account = active else { throw AccountOps.Failure(message: "请先导入本机 Claude/GLM 登录态，或添加一个账号") }
        return try await Task.detached(priority: .userInitiated) { try AccountOps.prepareIsolated(account, base: env) }.value
    }
    func prepareCodexEnvironment() async throws -> [String: String] {
        load()
        guard let account = activeCodex else { throw AccountOps.Failure(message: "请在账号菜单添加 Codex 账号或导入本机登录态，无需先打开 Codex App") }
        let env = liveEnv
        return try await Task.detached(priority: .userInitiated) { try CodexAccountOps.prepare(account, base: env) }.value
    }

    /// Explicit external write. Starting a new terminal session picks up these files; inherited shell overrides may still win.
    func pushToTerminal() async {
        load()
        guard canPushToTerminal else { return }
        while inFlight { try? await Task.sleep(for: .milliseconds(50)) }
        inFlight = true; busy = .switching("push-terminal"); lastError = nil
        defer { inFlight = false; busy = nil; hasPushBackup = AccountPushOps.hasBackup }
        let env = liveEnv, account = active, provider = activeProvider
        do {
            try await Task.detached(priority: .userInitiated) {
                let settingsURL = ClaudeSettings.url(env: env)
                let settingsOriginal = try AccountPushOps.readFile(settingsURL)
                let sourceSettings = try ClaudeSettings.decoded(settingsOriginal, url: settingsURL)
                if let provider {
                    guard let secret = try KeychainCLI.readChecked(service: provider.keychainService), !secret.isEmpty else {
                        throw AccountOps.Failure(message: "提供方密钥不可用，未推送")
                    }
                    let settings = ProviderOps.settings(for: provider, source: sourceSettings)
                    let plan = AccountPushOps.Plan(files: [.init(url: settingsURL, contents: try ClaudeSettings.encoded(settings), expectedOriginal: .some(settingsOriginal))])
                    try AccountPushOps.transaction(plan, label: "终端 · \(provider.name)")
                } else if let account {
                    _ = try AccountOps.prepareIsolated(account, base: env) // save any refresh-token rotation first
                    guard let payload = try KeychainCLI.readChecked(service: account.keychainService) else { throw AccountOps.Failure(message: "Claude 登录态快照不可用") }
                    let service = ClaudeAuth.credentialsService(env: env)
                    let settings = ProviderOps.removingAuthentication(from: sourceSettings)
                    let identityURL = ClaudeAuth.configFileURL(env: env)
                    let identityOriginal = try AccountPushOps.readFile(identityURL)
                    var identity: [String: Any] = [:]
                    if let data = identityOriginal {
                        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AccountOps.Failure(message: "Claude 身份文件不是有效 JSON，未推送") }
                        identity = object
                    }
                    identity["oauthAccount"] = account.oauthAccount.toAny()
                    let identityData = try JSONSerialization.data(withJSONObject: identity, options: [.withoutEscapingSlashes, .sortedKeys, .prettyPrinted])
                    let plan = AccountPushOps.Plan(files: [
                        .init(url: settingsURL, contents: try ClaudeSettings.encoded(settings), expectedOriginal: .some(settingsOriginal)),
                        .init(url: identityURL, contents: identityData, mode: 0o600, expectedOriginal: .some(identityOriginal)),
                    ], credential: .init(service: service, payload: payload))
                    try AccountPushOps.transaction(plan, label: "终端 · Claude")
                }
            }.value
            hasPushBackup = true
            note("已推送至终端并保存恢复备份；请新开 Claude Code 会话使用")
        } catch { lastError = error.localizedDescription }
    }
    /// Codex Desktop and the Codex CLI intentionally share the local auth store.
    func pushToCodexApp() async {
        load()
        guard let account = activeCodex else { return }
        while inFlight { try? await Task.sleep(for: .milliseconds(50)) }
        inFlight = true; busy = .switching("push-codex"); lastError = nil
        defer { inFlight = false; busy = nil; hasPushBackup = AccountPushOps.hasBackup }
        let env = liveEnv
        do {
            try await Task.detached(priority: .userInitiated) {
                let home = AppAuthPaths.localCodexHome(env: env)
                try CodexAccountOps.requireFileStore(home: home)
                _ = try CodexAccountOps.prepare(account, base: env)
                guard let payload = KeychainCLI.read(service: account.keychainService) else { throw AccountOps.Failure(message: "Codex 登录态快照不可用") }
                let authURL = home.appendingPathComponent("auth.json")
                let plan = AccountPushOps.Plan(files: [.init(url: authURL, contents: Data(payload.utf8), mode: 0o600)])
                try AccountPushOps.transaction(plan, label: "Codex app 与 Codex CLI")
            }.value
            hasPushBackup = true
            note("已推送到 Codex app / CLI 共用登录态并备份；运行中的 Codex app 可能需要重启")
        } catch { lastError = error.localizedDescription }
    }
    func pushCodexToTerminal() async { await pushToCodexApp() }

    func removeCodex(_ id: String) async {
        guard codexAccounts.contains(where: { $0.id == id }) else { return }
        await remove(id)
    }

    func rollbackLastPush() async {
        while inFlight { try? await Task.sleep(for: .milliseconds(50)) }
        inFlight = true; busy = .switching("rollback"); lastError = nil
        defer { inFlight = false; busy = nil; hasPushBackup = AccountPushOps.hasBackup }
        do {
            try await Task.detached(priority: .userInitiated) { try AccountPushOps.rollback() }.value
            hasPushBackup = AccountPushOps.hasBackup
            note("已恢复上次推送前的登录态；正在运行的客户端可能需要重启")
        } catch { lastError = error.localizedDescription }
    }

    func remove(_ id: String) async {
        if let p = providers.first(where: { $0.id == id }) {
            guard id != activeProviderId else { return }
            let env = liveEnv, all = providers
            let onDisk = await Task.detached(priority: .utility) { ProviderOps.detectActive(in: all, env: env) }.value
            if onDisk == .provider(id) || onDisk == .unreadable {
                lastError = "此提供方可能仍被终端使用；请先推送其它账号，避免移除钥匙串后终端失去凭据"
                return
            }
            providers.removeAll { $0.id == id }; saveProviders()
            // Retain imported/external Keychain entries. App-owned secrets are retained while a rollback backup may refer to them.
            if p.ownsKeychainItem && !hasPushBackup {
                await Task.detached(priority: .utility) { KeychainCLI.delete(service: p.keychainService) }.value
            }
        } else if let account = codexAccounts.first(where: { $0.id == id }), id != activeCodexId {
            codexAccounts.removeAll { $0.id == id }; saveCodex()
            await Task.detached(priority: .utility) {
                KeychainCLI.delete(service: account.keychainService)
                try? FileManager.default.removeItem(at: AppAuthPaths.codexRuntimeHome(account.id).appendingPathComponent("auth.json"))
            }.value
        } else if let account = accounts.first(where: { $0.id == id }), id != activeId {
            accounts.removeAll { $0.id == id }; save()
            await Task.detached(priority: .utility) {
                KeychainCLI.delete(service: account.keychainService)
                let env = AccountOps.isolatedEnvironment(id: account.id, base: [:])
                KeychainCLI.delete(service: ClaudeAuth.credentialsService(env: env))
            }.value
        }
    }
    func addProvider(name: String, baseURL: String, secret: String, model: String?) async -> String? {
        load()
        guard let url = URL(string: baseURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "请填写有效的 API 地址和密钥" }
        let id = UUID().uuidString.lowercased()
        let provider = APIProvider(id: id, name: name, baseURL: baseURL, keychainService: APIProvider.ownedServicePrefix + id,
                                   model: model, extraEnv: nil, addedAt: Date())
        do {
            try await Task.detached(priority: .userInitiated) { try KeychainCLI.write(service: provider.keychainService, secret: secret) }.value
        } catch { return error.localizedDescription }
        providers.append(provider); saveProviders()
        return await performProviderSwitch(id)
    }
    func beginLogin() {
        load()
        guard loginSession == nil, codexLoginSession == nil, busy == nil else { return }
        let session = LoginSession()
        session.onFinished = { [weak self] account in
            guard let self else { return }
            self.merge(account); self.save(); self.loginSession = nil
            Task { await self.switchTo(account.id) }
        }
        loginSession = session
        session.start()
    }

    func beginCodexLogin() {
        load()
        guard loginSession == nil, codexLoginSession == nil, busy == nil else { return }
        let session = CodexLoginSession()
        session.onFinished = { [weak self] account in
            guard let self else { return }
            self.mergeCodex(account); self.saveCodex(); self.codexLoginSession = nil
            Task { await self.switchToCodex(account.id) }
        }
        codexLoginSession = session
    }
}

/// 「添加账号」：在一个临时配置目录里跑 `claude auth login`，让它把新账号写到一条独立的钥匙串条目，
/// 结束后搬进快照。`claude auth login` 的流程（2.1.273 实测）：打开浏览器 → 用户登录 → 页面给一串授权码 →
/// 贴回 stdin（`Paste code here if prompted >`）→ 进程退出 0。
@MainActor
@Observable
final class LoginSession: Identifiable {
    enum Phase: Equatable {
        case starting
        case waitingForCode
        case finishing
        case failed(String)
    }

    let id = UUID()
    private(set) var phase: Phase = .starting
    private(set) var loginURL: URL? = nil
    /// 子进程输出（去掉终端控制序列），失败时给用户看最后几行。
    private(set) var output = ""
    @ObservationIgnored private var rawOutput = ""
    var onFinished: (@MainActor (ClaudeAccount) -> Void)?

    private let dir: URL
    private let env: [String: String]
    @ObservationIgnored private var process: Process? = nil
    @ObservationIgnored private var stdinPipe: Pipe? = nil
    @ObservationIgnored private var pump: Task<Void, Never>? = nil
    @ObservationIgnored private var cancelled = false

    nonisolated private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Shell", isDirectory: true)
    }

    init() {
        dir = Self.supportDir.appendingPathComponent("login-\(UUID().uuidString.lowercased())", isDirectory: true)
        self.env = Self.environment(for: dir)
    }

    nonisolated static func environment(for dir: URL, base: [String: String]? = nil) -> [String: String] {
        var env = base ?? ShellEnvironment.environment()
        for key in Array(env.keys) where key.hasPrefix("ANTHROPIC_") || ClaudeAuthOverrides.routingKeys.contains(key) {
            env.removeValue(forKey: key)
        }
        env["CLAUDE_CONFIG_DIR"] = dir.path
        env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = dir.path
        env["BROWSER"] = "/usr/bin/true" // Display the URL; opening a browser requires the explicit button.
        return env
    }

    /// 上次登录到一半 app 被杀，临时目录和它那条钥匙串会留下来；启动时扫一遍清掉。
    static func sweepLeftovers() {
        let base = supportDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        let stale = names.filter { name in
            guard name.hasPrefix("login-"), UUID(uuidString: String(name.dropFirst("login-".count))) != nil,
                  let modified = try? base.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
            return modified < Date().addingTimeInterval(-24 * 60 * 60)
        }
        guard !stale.isEmpty else { return }
        Task.detached(priority: .utility) {
            for name in stale {
                let dir = base.appendingPathComponent(name, isDirectory: true)
                KeychainCLI.delete(service: ClaudeAuth.credentialsService(env: environment(for: dir)))
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
        guard let exe = ShellEnvironment.claudeExecutable() else {
            phase = .failed(ShellError.claudeNotFound.localizedDescription)
            return
        }
        do {
            try AppAuthPaths.privateDirectory(dir)
        } catch {
            phase = .failed("建不了临时配置目录：\(error.localizedDescription)")
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["auth", "login", "--claudeai"]
        proc.currentDirectoryURL = dir
        proc.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        enum Chunk: Sendable { case text(String), exit(Int32) }
        let (stream, cont) = AsyncStream.makeStream(of: Chunk.self)
        let forward: @Sendable (FileHandle) -> Void = { handle in
            let data = handle.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) { cont.yield(.text(s)) }
        }
        stdout.fileHandleForReading.readabilityHandler = forward
        stderr.fileHandleForReading.readabilityHandler = forward
        proc.terminationHandler = { p in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            // 管道里可能还剩最后一点，读干净再报退出。
            for pipe in [stdout, stderr] {
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) { cont.yield(.text(s)) }
            }
            cont.yield(.exit(p.terminationStatus))
            cont.finish()
        }
        do {
            try proc.run()
        } catch {
            phase = .failed("起不来 claude auth login：\(error.localizedDescription)")
            return
        }
        process = proc
        stdinPipe = stdin
        pump = Task { [weak self] in
            for await chunk in stream {
                guard let self else { break }
                switch chunk {
                case .text(let s): self.consume(s)
                case .exit(let code): self.exited(code)
                }
            }
        }
    }

    private func consume(_ raw: String) {
        // 控制序列可能被拆在两个 chunk 里，所以每次都从头剥一遍。
        rawOutput = String((rawOutput + raw).suffix(24_000))
        output = Self.stripControl(rawOutput)
        if loginURL == nil, let url = Self.firstURL(in: output) { loginURL = url }
        if phase == .starting, loginURL != nil || output.contains("Paste code") { phase = .waitingForCode }
    }

    /// 把浏览器页面给的授权码贴回去。
    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r"), !trimmed.contains("\0"), let stdinPipe, isRunning else { return }
        phase = .finishing
        stdinPipe.fileHandleForWriting.write(Data((trimmed + "\n").utf8))
    }

    private func exited(_ code: Int32) {
        process = nil
        if cancelled { cleanupTemp(); return }
        guard code == 0 else {
            phase = .failed("登录没有完成（Claude 退出码 \(code)）。请确认授权已完成；也可取消后重新添加账号。")
            cleanupTemp()
            return
        }
        phase = .finishing
        let dir = dir, env = env
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try AccountOps.harvestLogin(dir: dir, env: env) }
            }.value
            guard let self, !self.cancelled else { return }
            switch result {
            case .success(let acc): self.onFinished?(acc)
            case .failure(let error): self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        cancelled = true
        if let process, process.isRunning {
            process.terminate()
            let child = process
            Task {
                try? await Task.sleep(for: .seconds(2))
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        } else { cleanupTemp() }
    }

    private func cleanupTemp() {
        let dir = dir, service = ClaudeAuth.credentialsService(env: env)
        Task.detached(priority: .utility) {
            KeychainCLI.delete(service: service)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func openBrowser() {
        if let loginURL { NSWorkspace.shared.open(loginURL) }
    }

    /// 去掉 ANSI / OSC 序列和其它控制字符，只留可读文字。
    nonisolated static func stripControl(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return String(out.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" })
    }

    nonisolated static func firstURL(in text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"https://[^\s<>\"]+"#) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  let parts = URLComponents(string: String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;"))),
                  ["claude.ai", "console.anthropic.com", "platform.claude.com", "auth.anthropic.com"].contains(parts.host ?? ""),
                  parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
                  parts.path.contains("auth") else { continue }
            return parts.url
        }
        return nil
    }
}
