import CryptoKit
import Foundation

/// Claude Code 的登录态放在两处：钥匙串里一条 `Claude Code-credentials`（JSON，含 access / refresh token、
/// 订阅类型），和 `~/.claude.json` 里的 `oauthAccount`（账号 uuid、邮箱、组织）。两处一起换，就等于换了账号。
///
/// 位置规则照 2.1.273 的实现：
/// - 配置目录 = `$CLAUDE_CONFIG_DIR`，缺省 `~/.claude`；`.claude.json` 在 `$CLAUDE_CONFIG_DIR/.claude.json`，
///   没设就在 `~/.claude.json`。
/// - 钥匙串条目名 = `Claude Code-credentials` + 后缀。设了 `CLAUDE_SECURESTORAGE_CONFIG_DIR`（非空）后缀是
///   `-` + sha256(它)[0..<8]；否则设了 `CLAUDE_CONFIG_DIR` 后缀是 `-` + sha256(配置目录)[0..<8]；都没设就没有后缀。
///   所以给 `claude auth login` 挂一个临时的 `CLAUDE_CONFIG_DIR`，它就会把新账号写到一条独立的钥匙串条目里，
///   不碰当前登录态——「添加账号」就是这么做的。
enum ClaudeAuth {
    struct Identity: Sendable, Equatable {
        var loggedIn: Bool
        var email: String?
        var orgId: String?
        var orgName: String?
        var subscriptionType: String?
        var authMethod: String?
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func configDir(env: [String: String]) -> String {
        if let d = env["CLAUDE_CONFIG_DIR"], !d.isEmpty { return d }
        return NSHomeDirectory() + "/.claude"
    }

    static func configFileURL(env: [String: String]) -> URL {
        if let d = env["CLAUDE_CONFIG_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d).appendingPathComponent(".claude.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")
    }

    static func credentialsService(env: [String: String]) -> String {
        let secure = env["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
        let noSuffix = secure != nil ? secure!.isEmpty : (env["CLAUDE_CONFIG_DIR"] ?? "").isEmpty
        if noSuffix { return "Claude Code-credentials" }
        let dir = (secure ?? configDir(env: env)).precomposedStringWithCanonicalMapping   // NFC
        let digest = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + digest.prefix(8)
    }

    // MARK: - .claude.json 里的 oauthAccount

    static func readOAuthAccount(env: [String: String]) -> JSONValue? {
        guard let data = try? Data(contentsOf: configFileURL(env: env)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any] else { return nil }
        return JSONValue(any: account)
    }

    /// 只改 `oauthAccount` 这一个键，其余原样写回；原子替换，权限保持 0600（Claude Code 自己就是 0600）。
    static func writeOAuthAccount(_ account: JSONValue?, env: [String: String]) throws {
        let url = configFileURL(env: env).resolvingSymlinksInPath()
        let fm = FileManager.default
        var obj: [String: Any] = [:]
        do {
            let data = try Data(contentsOf: url)
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure(message: "\(url.path) 不是合法 JSON，不敢改写")
            }
            obj = parsed
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // Creating the first config is allowed. All other read failures preserve existing data.
        }
        if let account {
            obj["oauthAccount"] = account.toAny()
        } else {
            obj.removeValue(forKey: "oauthAccount")
        }
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes, .sortedKeys, .prettyPrinted])
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".claude.json.claudex-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try out.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp, options: [.usingNewMetadataOnly])
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    // MARK: - claude auth status

    /// `claude auth status --json`；找不到 claude 或跑失败返回 nil。阻塞，放后台线程。
    static func status(env: [String: String]) -> Identity? {
        guard let exe = ShellEnvironment.claudeExecutable() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["auth", "status", "--json"]
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let deadline = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        deadline.cancel()
        guard let v = JSONValue.parse(data) else { return nil }
        return Identity(loggedIn: v["loggedIn"]?.bool ?? false,
                        email: v["email"]?.string,
                        orgId: v["orgId"]?.string,
                        orgName: v["orgName"]?.string,
                        subscriptionType: v["subscriptionType"]?.string,
                        authMethod: v["authMethod"]?.string)
    }

    /// 钥匙串条目 JSON 里的订阅类型（max / pro / …）；只读这一个字段，令牌本身不解析。
    static func subscriptionType(inCredentials payload: String) -> String? {
        JSONValue.parse(payload)?["claudeAiOauth"]?["subscriptionType"]?.string
    }
}
