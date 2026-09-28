import CryptoKit
import Foundation

/// The visible name can change without moving existing accounts or breaking Keychain references.
enum AppAuthPaths {
    static var support: URL {
        if let path = UserDefaults.standard.string(forKey: "testAccountSupportDir") { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Shell", isDirectory: true)
    }
    static var claudeHome: URL { support.appendingPathComponent("runtime/claude", isDirectory: true) }
    static var codexHome: URL { support.appendingPathComponent("runtime/codex", isDirectory: true) }
    static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func claudeRuntimeHome(_ id: String) -> URL { claudeHome.appendingPathComponent(key(id), isDirectory: true) }
    static func codexRuntimeHome(_ id: String) -> URL { codexHome.appendingPathComponent(key(id), isDirectory: true) }
    static func localCodexHome(env: [String: String] = ShellEnvironment.environment()) -> URL {
        URL(fileURLWithPath: env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.codex", isDirectory: true)
    }
    static func claudeRuntimeHomes() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: claudeHome, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
    }
    static func codexRuntimeHomes() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
    }
    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    /// The official engines own these files; private auth homes share their native session directories.
    static func linkNativeSessions(from source: URL, at destination: URL) throws {
        let fm = FileManager.default
        let target = source.resolvingSymlinksInPath().standardizedFileURL
        if destination.standardizedFileURL.path == target.path { return }
        try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let existing = try? fm.destinationOfSymbolicLink(atPath: destination.path) {
            let url = existing.hasPrefix("/") ? URL(fileURLWithPath: existing) : destination.deletingLastPathComponent().appendingPathComponent(existing)
            guard url.resolvingSymlinksInPath().standardizedFileURL.path == target.path else {
                throw AccountOps.Failure(message: "应用的 \(destination.lastPathComponent) 已指向另一处会话目录，未覆盖；请检查 \(destination.path)")
            }
            return
        }
        guard !fm.fileExists(atPath: destination.path) else {
            throw AccountOps.Failure(message: "应用内已有独立的 \(destination.lastPathComponent) 目录，为保留记录未覆盖它：\(destination.path)")
        }
        try fm.createSymbolicLink(at: destination, withDestinationURL: target)
    }
    static func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct CodexAccount: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var email: String
    var subscriptionType: String?
    var addedAt: Date
    var lastActiveAt: Date?
    var keychainService: String { "Claudex Shell-codex-" + AppAuthPaths.key(id) }
    var shortName: String { String(email.split(separator: "@").first ?? Substring(email)) }
    var planLabel: String? { subscriptionType?.capitalized }
}

struct CodexAccountManifest: Codable, Sendable {
    var accounts: [CodexAccount] = []
    var activeId: String?
}

enum CodexAccountOps {
    /// JWT claims are only labels for a locally saved login, never a proof of authentication.
    static func account(payload: String) throws -> CodexAccount {
        guard let object = JSONValue.parse(payload) else { throw AccountOps.Failure(message: "Codex 登录文件不是有效 JSON") }
        if let apiKey = object["OPENAI_API_KEY"]?.string, !apiKey.isEmpty {
            return CodexAccount(id: "api-" + AppAuthPaths.key(apiKey), email: "Codex API Key", subscriptionType: "API", addedAt: Date())
        }
        guard let tokens = object["tokens"], let access = tokens["access_token"]?.string, !access.isEmpty else {
            throw AccountOps.Failure(message: "Codex 登录态缺少 access_token，请先在终端运行 codex login")
        }
        let claims = jwtClaims(tokens["id_token"]?.string ?? access)
        let auth = claims?["https://api.openai.com/auth"]
        let accountID = tokens["account_id"]?.string ?? auth?["chatgpt_account_id"]?.string
        let subject = claims?["sub"]?.string
        let email = claims?["email"]?.string ?? claims?["https://api.openai.com/profile"]?["email"]?.string
        guard let id = accountID ?? subject ?? email else {
            throw AccountOps.Failure(message: "无法识别 Codex 登录身份；请重新登录后导入")
        }
        return CodexAccount(id: id + "|" + (subject ?? email ?? ""), email: email ?? "Codex · " + String(id.suffix(8)),
                            subscriptionType: auth?["chatgpt_plan_type"]?.string, addedAt: Date())
    }
    static func jwtClaims(_ token: String) -> JSONValue? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        return Data(base64Encoded: body).flatMap(JSONValue.parse)
    }
    static func compact(_ payload: String) throws -> String {
        guard let object = JSONValue.parse(payload) else { throw AccountOps.Failure(message: "Codex 登录文件不是有效 JSON") }
        return object.serialized()
    }
    /// Codex supports keyring/auto stores too. Refuse an ambiguous stale auth.json rather than report a false switch.
    static func requireFileStore(home: URL) throws {
        let url = home.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let source = try String(contentsOf: url, encoding: .utf8)
        let topLevel = source.components(separatedBy: .newlines).prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }.joined(separator: "\n")
        let pattern = #"(?m)^\s*cli_auth_credentials_store\s*=\s*["']([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: topLevel, range: NSRange(topLevel.startIndex..., in: topLevel)),
           let range = Range(match.range(at: 1), in: topLevel) {
            let store = String(topLevel[range])
            guard store == "file" else {
                throw AccountOps.Failure(message: "本机 Codex 使用 \(store) 凭据存储。请在 \(url.path) 设置 cli_auth_credentials_store = \"file\"，重新 codex login 后导入；此次没有改写任何登录态。")
            }
        }
    }
    static func readLocal(env: [String: String]) throws -> (CodexAccount, String)? {
        let home = AppAuthPaths.localCodexHome(env: env)
        try requireFileStore(home: home)
        let url = home.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let payload = try compact(String(contentsOf: url, encoding: .utf8))
        return (try account(payload: payload), payload)
    }
    static func save(_ account: CodexAccount, payload: String, vault: CredentialVault = .system) throws {
        let previous = vault.read(account.keychainService)
        let payload = CredentialFreshness.newest(previous, try compact(payload), timestamp: CredentialFreshness.codex)
        if previous != payload { try vault.write(account.keychainService, payload) }
    }
    static func prepare(_ account: CodexAccount, base: [String: String], vault: CredentialVault = .system) throws -> [String: String] {
        let home = AppAuthPaths.codexRuntimeHome(account.id)
        let authURL = home.appendingPathComponent("auth.json")
        try AppAuthPaths.privateDirectory(home)
        let sharedHome = AppAuthPaths.localCodexHome(env: base)
        for folder in ["sessions", "archived_sessions"] {
            try AppAuthPaths.linkNativeSessions(from: sharedHome.appendingPathComponent(folder), at: home.appendingPathComponent(folder))
        }
        let saved = vault.read(account.keychainService)
        let runtime = try? String(contentsOf: authURL, encoding: .utf8)
        let validRuntime = runtime.flatMap { payload in (try? Self.account(payload: payload).id) == account.id ? payload : nil }
        guard let candidate = saved ?? validRuntime else {
            throw AccountOps.Failure(message: "钥匙串中没有这个 Codex 账号的登录态，请重新导入")
        }
        let payload = CredentialFreshness.newest(validRuntime, candidate, timestamp: CredentialFreshness.codex)
        if saved != payload { try vault.write(account.keychainService, try compact(payload)) }
        if runtime != payload { try AppAuthPaths.writePrivate(Data(payload.utf8), to: authURL) }
        // Preserve native user instructions and non-auth defaults; credentials remain file-only in this private home.
        try NativeEngineConfiguration.prepareCodex(from: sharedHome, at: home)
        var env = base
        env["CODEX_HOME"] = home.path
        for key in Array(env.keys) where key.hasPrefix("OPENAI_") || key.hasPrefix("CODEX_API_") || key == "CODEX_ACCESS_TOKEN" {
            env.removeValue(forKey: key)
        }
        return env
    }
}

/// Only these operations can write outside the app's private runtime homes.
/// Each transaction is staged durably before mutation. Backup secrets remain in unique Keychain entries.
enum AccountPushOps {
    struct FileChange: Sendable {
        var url: URL
        var contents: Data?
        /// nil preserves an existing mode, otherwise uses 0600 for a new file.
        var mode: Int? = nil
        /// .some(nil) expects absence; .none means the change does not derive from existing content.
        var expectedOriginal: Data?? = .none
    }
    struct CredentialChange: Sendable { var service: String; var payload: String? }
    struct Plan: Sendable { var files: [FileChange]; var credential: CredentialChange? = nil }
    struct FileState: Codable, Sendable {
        var path: String
        var original: Data?
        var originalMode: Int?
        /// Digest of the planned result, persisted BEFORE any external file is changed. nil means planned absence.
        var writtenDigest: String?
    }
    struct Backup: Codable, Sendable {
        var id: String
        var label: String
        var files: [FileState]
        var credentialService: String?
        var credentialPayload: String?
        var writtenCredentialDigest: String?
    }
    struct Marker: Codable, Sendable {
        var id: String
        var label: String
        var service: String?
        var keychainService: String { service ?? AccountPushOps.backupService }
    }
    private static let lock = NSRecursiveLock()
    /// Kept only to read backups made by an earlier app build.
    static let backupService = "Claudex Shell-last-account-push"
    static var markerURL: URL { AppAuthPaths.support.appendingPathComponent("last-push.json") }
    static var pendingURL: URL { AppAuthPaths.support.appendingPathComponent("pending-push.json") }
    static var hasBackup: Bool { FileManager.default.fileExists(atPath: pendingURL.path) || FileManager.default.fileExists(atPath: markerURL.path) }
    static func digest(_ data: Data) -> String { AppAuthPaths.key(data.base64EncodedString()) }
    static func service(for backup: Backup) -> String { "Claudex Shell-account-push-" + backup.id }
    static func readFile(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
    static func readMarker(_ url: URL) throws -> Marker? {
        guard let data = try readFile(url) else { return nil }
        return try JSONDecoder.standard.decode(Marker.self, from: data)
    }
    static func writeMarker(_ marker: Marker, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".push-marker-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try JSONEncoder.standard.encode(marker).write(to: temporary, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // Commit the pointer only after every potentially failing encoding/permission operation.
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temporary, options: [.usingNewMetadataOnly]) }
        else { try fm.moveItem(at: temporary, to: url) }
    }
    static func stage(_ plan: Plan, label: String, vault: CredentialVault = .system) throws -> Backup {
        guard try readMarker(pendingURL) == nil else {
            throw AccountOps.Failure(message: "上一次推送尚未完成恢复，请先使用“撤销上次推送”恢复后再推送")
        }
        // Validate an existing marker before any mutation; a malformed pointer must not erase a usable backup.
        _ = try readMarker(markerURL)
        let files = try plan.files.map { change -> FileState in
            let resolved = change.url.resolvingSymlinksInPath()
            let original = try readFile(resolved)
            if case .some(let expected) = change.expectedOriginal, original != expected {
                throw AccountOps.Failure(message: "规划推送时文件已发生变化，已停止：\(resolved.lastPathComponent)")
            }
            return FileState(path: resolved.path, original: original,
                             originalMode: (try? FileManager.default.attributesOfItem(atPath: resolved.path))?[.posixPermissions] as? Int,
                             writtenDigest: change.contents.map(digest))
        }
        guard Set(files.map(\.path)).count == files.count else { throw AccountOps.Failure(message: "推送计划包含重复文件路径") }
        let backup = Backup(id: UUID().uuidString, label: label, files: files,
                            credentialService: plan.credential?.service,
                            credentialPayload: try plan.credential.flatMap { try vault.readForBackup($0.service) },
                            writtenCredentialDigest: plan.credential?.payload.map { AppAuthPaths.key($0) })
        let data = try JSONEncoder.standard.encode(backup)
        let compact = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data))
        guard let payload = String(data: compact, encoding: .utf8) else { throw AccountOps.Failure(message: "无法编码推送备份") }
        let service = service(for: backup)
        try vault.write(service, payload)
        // The previous successful marker is untouched until commit; a staging failure leaves it usable.
        do { try writeMarker(Marker(id: backup.id, label: label, service: service), to: pendingURL) }
        catch { try? vault.deleteForBackup(service); throw error }
        return backup
    }
    static func apply(_ plan: Plan, backup: Backup, vault: CredentialVault = .system) throws {
        guard plan.files.count == backup.files.count else { throw AccountOps.Failure(message: "推送计划与备份不一致") }
        // Check every target first. No forced restore ever overwrites a concurrent edit.
        for file in backup.files {
            guard try readFile(URL(fileURLWithPath: file.path)) == file.original else {
                throw AccountOps.Failure(message: "推送前文件已发生变化，已停止：\(URL(fileURLWithPath: file.path).lastPathComponent)")
            }
        }
        if let service = backup.credentialService {
            guard try vault.readForBackup(service) == backup.credentialPayload else { throw AccountOps.Failure(message: "推送前凭据已发生变化，已停止") }
        }
        for (change, file) in zip(plan.files, backup.files) {
            guard change.url.resolvingSymlinksInPath().path == file.path, change.contents.map(digest) == file.writtenDigest else {
                throw AccountOps.Failure(message: "推送计划在备份后发生变化，已停止")
            }
            let url = URL(fileURLWithPath: file.path)
            if let contents = change.contents {
                try AppAuthPaths.writePrivate(contents, to: url)
                try FileManager.default.setAttributes([.posixPermissions: change.mode ?? file.originalMode ?? 0o600], ofItemAtPath: url.path)
            } else if try readFile(url) != nil { try FileManager.default.removeItem(at: url) }
        }
        if let change = plan.credential {
            guard change.service == backup.credentialService,
                  change.payload.map({ AppAuthPaths.key($0) }) == backup.writtenCredentialDigest else { throw AccountOps.Failure(message: "凭据计划在备份后发生变化，已停止") }
            if let payload = change.payload { try vault.write(change.service, payload) }
            else { try vault.deleteForBackup(change.service) }
        }
    }
    static func committed(_ backup: Backup, vault: CredentialVault = .system) throws {
        for file in backup.files {
            guard try readFile(URL(fileURLWithPath: file.path)).map(digest) == file.writtenDigest else { throw AccountOps.Failure(message: "推送后文件验证失败，保留恢复备份") }
        }
        if let service = backup.credentialService {
            guard try vault.readForBackup(service).map({ AppAuthPaths.key($0) }) == backup.writtenCredentialDigest else { throw AccountOps.Failure(message: "推送后凭据验证失败，保留恢复备份") }
        }
        let previous = try readMarker(markerURL)
        try writeMarker(Marker(id: backup.id, label: backup.label, service: service(for: backup)), to: markerURL)
        // If a crash occurs here both markers refer to the same durable backup; recovery handles that case.
        try? FileManager.default.removeItem(at: pendingURL)
        if let previous, previous.id != backup.id { try? vault.deleteForBackup(previous.keychainService) }
    }
    static func restore(_ backup: Backup, vault: CredentialVault = .system) throws {
        // Idempotent recovery permits either the intended new value or the original, already-restored value.
        // Validate all targets before restoring any, so unrelated later changes are always preserved.
        for file in backup.files {
            let data = try readFile(URL(fileURLWithPath: file.path))
            guard data == file.original || data.map(digest) == file.writtenDigest else {
                throw AccountOps.Failure(message: "\(URL(fileURLWithPath: file.path).lastPathComponent) 在推送后又发生变化，未覆盖它；原始备份仍保存在钥匙串。")
            }
        }
        if let service = backup.credentialService {
            let payload = try vault.readForBackup(service)
            guard payload == backup.credentialPayload || payload.map({ AppAuthPaths.key($0) }) == backup.writtenCredentialDigest else {
                throw AccountOps.Failure(message: "终端凭据在推送后已刷新或切换，未覆盖它；原始备份仍保存在钥匙串。")
            }
        }
        for file in backup.files {
            let url = URL(fileURLWithPath: file.path)
            if try readFile(url) != file.original {
                if let original = file.original { try AppAuthPaths.writePrivate(original, to: url) }
                else { try FileManager.default.removeItem(at: url) }
            }
            if file.original != nil, let mode = file.originalMode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
        }
        if let service = backup.credentialService, try vault.readForBackup(service) != backup.credentialPayload {
            if let payload = backup.credentialPayload { try vault.write(service, payload) }
            else { try vault.deleteForBackup(service) }
        }
    }
    static func rollback(vault: CredentialVault = .system) throws {
        lock.lock(); defer { lock.unlock() }
        let pending = try readMarker(pendingURL)
        guard let marker = try pending ?? readMarker(markerURL),
              let payload = try vault.readForBackup(marker.keychainService), let data = payload.data(using: .utf8) else {
            throw AccountOps.Failure(message: "没有可恢复的推送备份")
        }
        let backup = try JSONDecoder.standard.decode(Backup.self, from: data)
        guard backup.id == marker.id else { throw AccountOps.Failure(message: "推送备份与索引不匹配，未改动登录态") }
        try restore(backup, vault: vault)
        if pending != nil { try FileManager.default.removeItem(at: pendingURL) }
        if try readMarker(markerURL)?.id == marker.id { try FileManager.default.removeItem(at: markerURL) }
        // Failure to discard a fully restored secret must not lose the durable successful backup of a preceding push.
        try? vault.deleteForBackup(marker.keychainService)
    }
    static func transaction(_ plan: Plan, label: String, vault: CredentialVault = .system) throws {
        lock.lock(); defer { lock.unlock() }
        let backup = try stage(plan, label: label, vault: vault)
        do { try apply(plan, backup: backup, vault: vault); try committed(backup, vault: vault) }
        catch {
            let original = error
            do {
                try restore(backup, vault: vault)
                if try readMarker(pendingURL)?.id == backup.id { try FileManager.default.removeItem(at: pendingURL) }
                try? vault.deleteForBackup(service(for: backup))
            } catch {
                throw AccountOps.Failure(message: "推送失败且自动恢复未完成；可再次点“撤销上次推送”继续恢复。\(original.localizedDescription)；恢复错误：\(error.localizedDescription)")
            }
            // last-push.json still points to the preceding successful transaction.
            throw original
        }
    }
}

/// Injectable only at the operation boundary, so regression tests never contact the user's Keychain.
struct CredentialVault: Sendable {
    var read: @Sendable (String) -> String?
    var write: @Sendable (String, String) throws -> Void
    var delete: @Sendable (String) -> Void
    var checkedRead: (@Sendable (String) throws -> String?)? = nil
    var checkedDelete: (@Sendable (String) throws -> Void)? = nil
    func readForBackup(_ key: String) throws -> String? {
        if let checkedRead { return try checkedRead(key) }
        return read(key)
    }
    func deleteForBackup(_ key: String) throws {
        if let checkedDelete { try checkedDelete(key) } else { delete(key) }
    }
    static let system = CredentialVault(read: { KeychainCLI.read(service: $0) },
                                        write: { try KeychainCLI.write(service: $0, secret: $1) },
                                        delete: { KeychainCLI.delete(service: $0) },
                                        checkedRead: { try KeychainCLI.readChecked(service: $0) },
                                        checkedDelete: { try KeychainCLI.deleteChecked(service: $0) })
}

enum CredentialFreshness {
    static func claude(_ payload: String) -> Double? {
        let value = JSONValue.parse(payload)?["claudeAiOauth"]?["expiresAt"]
        if let number = value?.double { return number }
        return value?.string.flatMap(Double.init)
    }
    static func codex(_ payload: String) -> Double? {
        if let date = JSONValue.parse(payload)?["last_refresh"]?.string {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let time = formatter.date(from: date)?.timeIntervalSince1970 { return time }
            formatter.formatOptions = [.withInternetDateTime]
            if let time = formatter.date(from: date)?.timeIntervalSince1970 { return time }
        }
        guard let token = JSONValue.parse(payload)?["tokens"]?["access_token"]?.string else { return nil }
        return CodexAccountOps.jwtClaims(token)?["iat"]?.double
    }
    static func newest(_ existing: String?, _ incoming: String, timestamp: (String) -> Double?) -> String {
        guard let existing else { return incoming }
        if let before = timestamp(existing), let after = timestamp(incoming), before > after { return existing }
        return incoming
    }
}

extension AccountOps {
    static func isolatedEnvironment(id: String, base: [String: String]) -> [String: String] {
        var env = base
        for key in Array(env.keys) where key.hasPrefix("ANTHROPIC_") || key == "CLAUDE_CODE_OAUTH_TOKEN" || key == "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR" || key == "CLAUDE_CODE_API_KEY" {
            env.removeValue(forKey: key)
        }
        env["CLAUDE_CONFIG_DIR"] = AppAuthPaths.claudeRuntimeHome(id).path
        env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        return env
    }
    static func prepareIsolated(_ account: ClaudeAccount, base: [String: String], vault: CredentialVault = .system) throws -> [String: String] {
        let env = isolatedEnvironment(id: account.id, base: base)
        let home = URL(fileURLWithPath: ClaudeAuth.configDir(env: env))
        try AppAuthPaths.privateDirectory(home)
        try AppAuthPaths.linkNativeSessions(from: URL(fileURLWithPath: ClaudeAuth.configDir(env: base)).appendingPathComponent("projects"), at: home.appendingPathComponent("projects"))
        try NativeEngineConfiguration.prepareClaude(from: URL(fileURLWithPath: ClaudeAuth.configDir(env: base)), at: home)
        // Import only non-auth settings once. Every profile keeps an independent config and identity.
        if !FileManager.default.fileExists(atPath: ClaudeSettings.url(env: env).path) {
            let settings = try ProviderOps.removingAuthentication(from: ClaudeSettings.read(env: base))
            try ClaudeSettings.write(settings, env: env)
        }
        let service = ClaudeAuth.credentialsService(env: env)
        let saved = vault.read(account.keychainService)
        let runtime = vault.read(service)
        guard let candidate = saved ?? runtime else { throw Failure(message: "钥匙串里没有这个 Claude 账号的登录态，请重新导入或登录") }
        let payload = CredentialFreshness.newest(runtime, candidate, timestamp: CredentialFreshness.claude)
        if saved != payload { try vault.write(account.keychainService, payload) }
        if runtime != payload { try vault.write(service, payload) }
        try ClaudeAuth.writeOAuthAccount(account.oauthAccount, env: env)
        return env
    }
}

extension ProviderOps {
    /// A subscription profile must never inherit a proxy URL/helper or a key belonging to a provider.
    static func removingAuthentication(from source: [String: Any]) -> [String: Any] {
        var object = source
        var env = object["env"] as? [String: Any] ?? [:]
        for key in Array(env.keys) where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_CODE_OAUTH") || key == "CLAUDE_CODE_SUBAGENT_MODEL" {
            env.removeValue(forKey: key)
        }
        if env.isEmpty { object.removeValue(forKey: "env") } else { object["env"] = env }
        object.removeValue(forKey: "apiKeyHelper")
        return object
    }
    static func prepareIsolated(_ provider: APIProvider, base: [String: String], vault: CredentialVault = .system) throws -> [String: String] {
        let env = AccountOps.isolatedEnvironment(id: "provider-" + provider.id, base: base)
        let home = URL(fileURLWithPath: ClaudeAuth.configDir(env: env))
        try AppAuthPaths.privateDirectory(home)
        try AppAuthPaths.linkNativeSessions(from: URL(fileURLWithPath: ClaudeAuth.configDir(env: base)).appendingPathComponent("projects"), at: home.appendingPathComponent("projects"))
        try NativeEngineConfiguration.prepareClaude(from: URL(fileURLWithPath: ClaudeAuth.configDir(env: base)), at: home)
        guard let secret = vault.read(provider.keychainService), !secret.isEmpty else { throw AccountOps.Failure(message: "钥匙串里没有「\(provider.name)」的密钥，请重新添加") }
        let existing = FileManager.default.fileExists(atPath: ClaudeSettings.url(env: env).path)
            ? try ClaudeSettings.read(env: env) : try ClaudeSettings.read(env: base)
        var settings = removingAuthentication(from: existing)
        var variables = settings["env"] as? [String: Any] ?? [:]
        provider.settingsEnv.forEach { variables[$0.key] = $0.value }
        settings["env"] = variables
        settings["apiKeyHelper"] = provider.apiKeyHelper
        try ClaudeSettings.write(settings, env: env)
        return env
    }
    /// Import static local API settings; arbitrary apiKeyHelper shell commands are never executed.
    static func importLocal(among providers: [APIProvider], env: [String: String], vault: CredentialVault = .system) throws -> APIProvider? {
        let settings = try ClaudeSettings.read(env: env)
        let vars = settings["env"] as? [String: String] ?? [:]
        guard let base = vars["ANTHROPIC_BASE_URL"] ?? env["ANTHROPIC_BASE_URL"], !base.isEmpty else { return nil }
        let helper = settings["apiKeyHelper"] as? String
        if let existing = providers.first(where: { $0.baseURL == base && $0.apiKeyHelper == helper }) { return existing }
        let token = [vars["ANTHROPIC_AUTH_TOKEN"], vars["ANTHROPIC_API_KEY"], env["ANTHROPIC_AUTH_TOKEN"], env["ANTHROPIC_API_KEY"]]
            .compactMap { $0 }.first { !$0.isEmpty }
        var externalService: String?
        if let helper {
            // Only accept the known read-only Keychain helper shape; no eval, pipes, substitutions, or custom commands.
            let pattern = #"^\s*(?:/usr/bin/)?security\s+find-generic-password\s+-a\s+'[^']*'\s+-s\s+'([^']+)'\s+-w\s*$"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: helper, range: NSRange(helper.startIndex..., in: helper)),
               let range = Range(match.range(at: 1), in: helper) { externalService = String(helper[range]) }
        }
        let secret = token ?? externalService.flatMap { vault.read($0) }
        guard let secret, !secret.isEmpty else {
            throw AccountOps.Failure(message: "发现本机 API 地址，但无法安全读取密钥；请用“添加 API 提供方”保存。自定义 apiKeyHelper 不会被自动执行。")
        }
        let id = "local-" + String(AppAuthPaths.key(base + "|" + secret).prefix(24))
        if let existing = providers.first(where: { $0.id == id }) { return existing }
        let service = APIProvider.ownedServicePrefix + id
        try vault.write(service, secret)
        let host = URL(string: base)?.host ?? base
        let glm = host.contains("bigmodel.cn") || host.contains("z.ai")
        var extra: [String: String] = [:]
        for key in APIProvider.modelKeys + ["API_TIMEOUT_MS"] { if let value = vars[key] { extra[key] = value } }
        return APIProvider(id: id, name: glm ? "本机 GLM" : "本机 · \(host)", baseURL: base, keychainService: service,
                           model: vars["ANTHROPIC_MODEL"] ?? vars["ANTHROPIC_DEFAULT_SONNET_MODEL"], extraEnv: extra, addedAt: Date())
    }
}

/// Preserve malformed manifests before any later import can write a new list.
enum AccountManifestStorage {
    static func preserveInvalid(_ url: URL) throws -> URL {
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".unreadable-" + UUID().uuidString)
        try FileManager.default.copyItem(at: url, to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup
    }
}
