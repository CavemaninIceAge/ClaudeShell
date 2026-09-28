import Foundation

/// 一个 API 提供方：中转站、智谱 GLM 这类走 `ANTHROPIC_BASE_URL` 的后端。和订阅账号并列在账号菜单里，选中就切。
///
/// 应用内选择使用独立配置目录；只有明确“推送至终端”才写共享 settings.json。
/// apiKeyHelper 仅引用钥匙串，密钥不会写入设置或账号清单。
struct APIProvider: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    /// 密钥所在的钥匙串条目（账户名 `$USER`）。app 添加的是 `Claude Shell-provider-<id>`；也可以直接指向用户已有的条目。
    var keychainService: String
    /// 设了就把默认模型、三档模型别名、子代理模型都指到它（GLM 这类不认 Claude 模型名的后端）。
    var model: String?
    /// 其余要带上的环境变量，比如 `API_TIMEOUT_MS`。
    var extraEnv: [String: String]?
    var addedAt: Date
    var lastActiveAt: Date?

    static let ownedServicePrefix = "Claude Shell-provider-"
    static let modelKeys = ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                            "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"]

    /// 钥匙串条目是不是 app 自己建的；只有自己建的，移除时才一起删。
    var ownsKeychainItem: Bool { keychainService.hasPrefix(Self.ownedServicePrefix) }

    var host: String { URL(string: baseURL)?.host ?? baseURL }

    /// 写进 settings.json `env` 的键值。
    /// settings.json 的 env 盖过进程环境变量，所以终端里残留的 `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` 会被当成
    /// Bearer / x-api-key 发给这家（别家的 key 漏过来）；置成空串等于没设，两个头就都用 apiKeyHelper 的值。
    var settingsEnv: [String: String] {
        var env = extraEnv ?? [:]
        env["ANTHROPIC_BASE_URL"] = baseURL
        env["ANTHROPIC_AUTH_TOKEN"] = ""
        env["ANTHROPIC_API_KEY"] = ""
        if let model, !model.isEmpty {
            for key in Self.modelKeys { env[key] = model }
        }
        return env
    }

    /// Claude Code 用 shell 跑这条命令，stdout 就是密钥（同时作 `Authorization: Bearer` 和 `x-api-key`）。
    var apiKeyHelper: String {
        "/usr/bin/security find-generic-password -a \(Self.shellQuote(KeychainCLI.accountName)) -s \(Self.shellQuote(keychainService)) -w"
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// settings.json 里被提供方占用的那几项，在第一次切到提供方之前原来是什么；切回订阅账号时原样放回。
/// 值为 nil 表示原来没有这一项。
struct SettingsBackup: Codable, Sendable, Equatable {
    var env: [String: String?] = [:]
    var apiKeyHelper: String?? = .none

    enum CodingKeys: String, CodingKey { case env, apiKeyHelper, hadApiKeyHelper }

    init(env: [String: String?] = [:], apiKeyHelper: String?? = .none) {
        self.env = env
        self.apiKeyHelper = apiKeyHelper
    }

    // `String??` 编码时分不清「没记」和「记了原来没有」，拆成两个字段存。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        env = try c.decodeIfPresent([String: String?].self, forKey: .env) ?? [:]
        if try c.decodeIfPresent(Bool.self, forKey: .hadApiKeyHelper) == true {
            apiKeyHelper = .some(try c.decodeIfPresent(String.self, forKey: .apiKeyHelper))
        } else {
            apiKeyHelper = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(env, forKey: .env)
        if case .some(let original) = apiKeyHelper {
            try c.encode(true, forKey: .hadApiKeyHelper)
            try c.encodeIfPresent(original, forKey: .apiKeyHelper)
        }
    }
}

/// 清单可能是手改的（比如指向已有的钥匙串条目）：缺 addedAt 不算错，坏掉的单项跳过，不连累整份清单。
extension APIProvider {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        keychainService = try c.decode(String.self, forKey: .keychainService)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        extraEnv = try c.decodeIfPresent([String: String].self, forKey: .extraEnv)
        addedAt = (try? c.decodeIfPresent(Date.self, forKey: .addedAt)) ?? Date()
        lastActiveAt = try? c.decodeIfPresent(Date.self, forKey: .lastActiveAt)
    }
}

struct ProviderManifest: Codable, Sendable {
    var providers: [APIProvider] = []
    var activeId: String? = nil
    var backup: SettingsBackup? = nil

    private struct Lenient: Decodable {
        let value: APIProvider?
        init(from decoder: Decoder) throws { value = try? APIProvider(from: decoder) }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = (try c.decodeIfPresent([Lenient].self, forKey: .providers) ?? []).compactMap(\.value)
        activeId = try c.decodeIfPresent(String.self, forKey: .activeId)
        backup = try c.decodeIfPresent(SettingsBackup.self, forKey: .backup)
    }
}

/// Claude Code 的用户设置文件：`$CLAUDE_CONFIG_DIR/settings.json`，缺省 `~/.claude/settings.json`。
enum ClaudeSettings {
    private static let writeLock = NSLock()
    static func url(env: [String: String]) -> URL {
        URL(fileURLWithPath: ClaudeAuth.configDir(env: env)).appendingPathComponent("settings.json")
    }

    /// 只有「文件不存在」才当空设置。读不了（权限、I/O、编辑器保存到一半的空文件）或不是合法 JSON 都报错——
    /// 否则写回时会拿一份空设置把用户的 hooks、权限规则整个盖掉。
    static func read(env: [String: String]) throws -> [String: Any] {
        let url = url(env: env)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AccountOps.Failure(message: "读不了 \(url.path)：\(error.localizedDescription)，不敢改写")
        }
        return try decoded(data, url: url)
    }

    static func decoded(_ data: Data?, url: URL) throws -> [String: Any] {
        guard let data else { return [:] }
        guard !data.isEmpty, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountOps.Failure(message: "\(url.path) 是空的或不是合法 JSON，不敢改写")
        }
        return obj
    }

    /// 整个写回，原子替换；权限沿用原文件（没有就 0644，和 Claude Code 自己建的一样）。
    /// settings.json 是软链接（dotfiles 仓库管着）时写到链接指向的文件，链接本身不动。
    static func encoded(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes, .sortedKeys, .prettyPrinted]) + Data("\n".utf8)
    }

    static func write(_ obj: [String: Any], env: [String: String]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        let url = url(env: env).resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try encoded(obj)
        let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int ?? 0o644
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".settings.json.claudex-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try out.write(to: tmp, options: .atomic)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp, options: [.usingNewMetadataOnly])
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}

/// 提供方的切换动作：读写 settings.json 和钥匙串，都是阻塞操作，只在后台线程调。
enum ProviderOps {
    enum Detection: Sendable, Equatable {
        /// settings.json 读不了 / 不是合法 JSON：什么也说明不了，别据此改状态。
        case unreadable
        case none
        case provider(String)
    }

    /// settings.json 里现在生效的是哪个提供方。
    static func detectActive(in providers: [APIProvider], env: [String: String]) -> Detection {
        guard let obj = try? ClaudeSettings.read(env: env) else { return .unreadable }
        return matching(providers, in: obj).map { .provider($0.id) } ?? .none
    }

    /// `ANTHROPIC_BASE_URL` 和 `apiKeyHelper` 都对得上才算。
    private static func matching(_ providers: [APIProvider], in obj: [String: Any]) -> APIProvider? {
        let settingsEnv = obj["env"] as? [String: Any] ?? [:]
        guard let base = settingsEnv["ANTHROPIC_BASE_URL"] as? String,
              let helper = obj["apiKeyHelper"] as? String else { return nil }
        return providers.first { $0.baseURL == base && $0.apiKeyHelper == helper }
    }

    /// 从当前设置里撤掉 `current` 写进去的那几项，按备份放回原值。返回撤完的设置。
    /// 调用前必须确认设置还和 `current` 对得上（见 `matching`）：地址和 helper 一起撤、一起还原，
    /// 不会留下「有 ANTHROPIC_BASE_URL、没有密钥」的状态——那样 Claude Code 会把订阅账号的 OAuth 令牌发给那个地址。
    private static func removing(_ current: APIProvider, backup: SettingsBackup?, from obj: [String: Any]) -> [String: Any] {
        var obj = obj
        var env = obj["env"] as? [String: Any] ?? [:]
        for (key, value) in current.settingsEnv {
            // 用户在生效期间自己改过这一项（模型之类）就不动它。
            guard (env[key] as? String) == value else { continue }
            if let original = backup?.env[key] ?? nil {
                env[key] = original
            } else {
                env.removeValue(forKey: key)
            }
        }
        if env.isEmpty { obj.removeValue(forKey: "env") } else { obj["env"] = env }
        if (obj["apiKeyHelper"] as? String) == current.apiKeyHelper {
            if case .some(.some(let original)) = backup?.apiKeyHelper {
                obj["apiKeyHelper"] = original
            } else {
                obj.removeValue(forKey: "apiKeyHelper")
            }
        }
        return obj
    }

    static func settings(for target: APIProvider, source: [String: Any]) -> [String: Any] {
        var obj = removingAuthentication(from: source)
        var env = obj["env"] as? [String: Any] ?? [:]
        target.settingsEnv.forEach { env[$0.key] = $0.value }
        obj["env"] = env
        obj["apiKeyHelper"] = target.apiKeyHelper
        return obj
    }

    /// 切到 `target`：先把设置里正在生效的提供方撤干净，再记下 target 要占的那几项原来的值，最后写进去。一次原子写。
    /// 正在生效的是谁以文件为准：app 记的 `current` 对不上（外面改过）就不拿它的备份去还原；
    /// app 以为没有、文件里却已经是某个提供方（清单丢过状态），先按「原来没有」撤掉它，免得把提供方自己的值记成原值。
    static func apply(_ target: APIProvider, replacing current: APIProvider?, backup: SettingsBackup?,
                      among providers: [APIProvider], env: [String: String]) throws -> SettingsBackup {
        guard let secret = KeychainCLI.read(service: target.keychainService), !secret.isEmpty else {
            throw AccountOps.Failure(message: "钥匙串里没有「\(target.name)」的密钥（条目 \(target.keychainService)），请移除后重新添加")
        }
        var obj = try ClaudeSettings.read(env: env)
        if let onDisk = matching(providers, in: obj) {
            obj = removing(onDisk, backup: onDisk.id == current?.id ? backup : nil, from: obj)
        }
        obj = removingAuthentication(from: obj)
        var env0 = obj["env"] as? [String: Any] ?? [:]
        var newBackup = SettingsBackup()
        for (key, value) in target.settingsEnv {
            newBackup.env[key] = .some(env0[key] as? String)
            env0[key] = value
        }
        newBackup.apiKeyHelper = .some(obj["apiKeyHelper"] as? String)
        obj["env"] = env0
        obj["apiKeyHelper"] = target.apiKeyHelper
        try ClaudeSettings.write(obj, env: env)
        return newBackup
    }

    /// 停用 `current`，settings.json 回到切过来之前的样子（订阅账号的登录态重新生效）。
    /// 文件里的地址 / helper 已经不是它（外面改过）就一项也不动，报错让用户自己看。
    static func deactivate(_ current: APIProvider, backup: SettingsBackup?, env: [String: String]) throws {
        let obj = try ClaudeSettings.read(env: env)
        guard matching([current], in: obj) != nil else {
            throw AccountOps.Failure(message: "settings.json 里的 ANTHROPIC_BASE_URL / apiKeyHelper 已经不是「\(current.name)」写的了"
                                     + "（在 app 外改过），没敢动它；请检查 \(ClaudeSettings.url(env: env).path)")
        }
        let restored = removing(current, backup: backup, from: obj)
        if NSDictionary(dictionary: restored).isEqual(to: obj) { return }
        try ClaudeSettings.write(restored, env: env)
    }
}
