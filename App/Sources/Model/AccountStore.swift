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
        if KeychainCLI.read(service: account.keychainService) == payload { return }
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

/// 保存过的账号列表 + 谁在生效。切换 = 把快照写回 Claude Code 自己的登录态，终端和这个 app 一起换。
@MainActor
@Observable
final class AccountStore {
    static let shared = AccountStore()

    enum Busy: Equatable {
        case syncing
        case switching(String)
    }

    private(set) var accounts: [ClaudeAccount] = []
    private(set) var activeId: String? = nil
    /// 本机现在根本没登录（钥匙串或 .claude.json 里没有登录态）。
    private(set) var isLoggedOut = false
    private(set) var busy: Busy? = nil
    var lastError: String? = nil
    /// 刚切完账号时那句话（"终端里 N 个会话跟着换"），几秒后自己消失。
    private(set) var switchNote: String? = nil
    /// 「添加账号」进行中的登录流程；非 nil 时侧栏弹出登录面板。
    var loginSession: LoginSession? = nil
    /// 切换成功后回调（ThreadStore 用来把自己起的 claude 进程收掉，让它们下次按新账号起）。
    var onSwitched: (@MainActor (ClaudeAccount) -> Void)?

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var noteTask: Task<Void, Never>? = nil

    var active: ClaudeAccount? { accounts.first { $0.id == activeId } }

    /// 自动化验证用：`-testClaudeConfigDir <dir>` 让登录态的位置整个换成一个临时目录（钥匙串条目名也跟着变），
    /// `-testAccountsFile <path>` 换掉账号清单，真账号一根手指都不碰。
    private var liveEnv: [String: String] {
        var env = ShellEnvironment.environment()
        if let dir = UserDefaults.standard.string(forKey: "testClaudeConfigDir"), !dir.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = dir
            env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        }
        return env
    }

    private var manifestURL: URL {
        if let p = UserDefaults.standard.string(forKey: "testAccountsFile"), !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Claude Shell/accounts.json")
    }

    // MARK: - 读写清单

    func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: manifestURL),
           let m = try? JSONDecoder.standard.decode(AccountManifest.self, from: data) {
            accounts = m.accounts
            activeId = m.activeId
        }
        LoginSession.sweepLeftovers()
    }

    private func save() {
        let m = AccountManifest(accounts: accounts, activeId: activeId)
        guard let data = try? JSONEncoder.standard.encode(m) else { return }
        try? FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// 身份字段以最新读到的为准，addedAt 保留。
    private func merge(_ acc: ClaudeAccount) {
        if let i = accounts.firstIndex(where: { $0.id == acc.id }) {
            var kept = accounts[i]
            kept.email = acc.email
            kept.orgName = acc.orgName
            kept.orgId = acc.orgId
            kept.subscriptionType = acc.subscriptionType ?? kept.subscriptionType
            kept.oauthAccount = acc.oauthAccount
            accounts[i] = kept
        } else {
            accounts.append(acc)
        }
    }

    // MARK: - 和真实登录态对表

    /// 看一眼现在登录的是谁：终端里 `/login` 换过的账号自动收录；正在生效的账号刚刷新过的令牌也同步进快照，
    /// 免得切走再切回来时拿的是旧令牌。启动、激活、每 90 秒各跑一次，切换前也跑。
    func sync() async {
        load()
        guard !inFlight else { return }
        inFlight = true
        busy = busy ?? .syncing
        defer { inFlight = false; if busy == .syncing { busy = nil } }
        let env = liveEnv
        let state = await Task.detached(priority: .utility) { AccountOps.readLive(env: env) }.value
        apply(state)
    }

    private func apply(_ state: AccountOps.LiveState) {
        switch state {
        case .loggedOut:
            isLoggedOut = true
            activeId = nil
        case .account(let acc, let payload):
            isLoggedOut = false
            merge(acc)
            activeId = acc.id
            let snapshot = accounts.first { $0.id == acc.id } ?? acc
            Task.detached(priority: .utility) {
                do { try AccountOps.saveSnapshot(snapshot, payload: payload) } catch {
                    await MainActor.run { AccountStore.shared.lastError = error.localizedDescription }
                }
            }
        }
        save()
    }

    // MARK: - 切换 / 移除 / 添加

    func switchTo(_ id: String) async {
        load()
        guard let target = accounts.first(where: { $0.id == id }) else { return }
        // 正好撞上一次 sync（几十毫秒）就等它完，别把用户这一下点击丢掉。
        while inFlight { try? await Task.sleep(for: .milliseconds(50)) }
        inFlight = true
        busy = .switching(id)
        lastError = nil
        defer { inFlight = false; busy = nil }
        let env = liveEnv
        // 先把当前登录态存进它自己的快照，再换。
        let before = await Task.detached(priority: .userInitiated) { AccountOps.readLive(env: env) }.value
        if case .account(let acc, let payload) = before {
            merge(acc)
            let snapshot = accounts.first { $0.id == acc.id } ?? acc
            do {
                try await Task.detached(priority: .userInitiated) { try AccountOps.saveSnapshot(snapshot, payload: payload) }.value
            } catch {
                lastError = "切换前保存当前账号的登录态失败：\(error.localizedDescription)"
                return
            }
        }
        do {
            try await Task.detached(priority: .userInitiated) { try AccountOps.switchLive(to: target, env: env) }.value
        } catch {
            lastError = error.localizedDescription
            return
        }
        activeId = id
        isLoggedOut = false
        if let i = accounts.firstIndex(where: { $0.id == id }) { accounts[i].lastActiveAt = Date() }
        save()
        onSwitched?(target)
        // 终端里开着的会话不用管：它们下一次请求就会用新账号（实测 0.2 秒后发出的请求已经是新账号）。
        // 这里只是把「有几个会话跟着换了」说给用户听。
        noteSwitch(liveTerminalSessions: ThreadStore.shared.live.count)
        // 问 claude 本尊确认一下，别只相信自己写对了。
        let identity = await Task.detached(priority: .userInitiated) { ClaudeAuth.status(env: env) }.value
        if let identity {
            if !identity.loggedIn {
                lastError = "已写入 \(target.email) 的登录态，但 claude auth status 说未登录；这个账号可能要重新添加"
            } else if let email = identity.email, email.lowercased() != target.email.lowercased() {
                lastError = "已写入 \(target.email) 的登录态，但 claude auth status 报的是 \(email)"
            }
        }
        TestLog.write("account switched to \(target.email) status=\(identity.map { "\($0.loggedIn) \($0.email ?? "-")" } ?? "nil")")
    }

    private func noteSwitch(liveTerminalSessions count: Int) {
        switchNote = count > 0 ? "终端里 \(count) 个会话已跟着换" : "终端里的 Claude Code 也已换成它"
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.switchNote = nil
        }
    }

    /// 只从清单和钥匙串里删快照，不动本机当前的登录态；正在生效的账号不能删（先切走）。
    func remove(_ id: String) async {
        guard id != activeId, let acc = accounts.first(where: { $0.id == id }) else { return }
        accounts.removeAll { $0.id == id }
        save()
        let service = acc.keychainService
        await Task.detached(priority: .utility) { KeychainCLI.delete(service: service) }.value
    }

    func beginLogin() {
        guard loginSession == nil else { return }
        let session = LoginSession()
        session.onFinished = { [weak self] acc in
            guard let self else { return }
            self.merge(acc)
            self.save()
            self.loginSession = nil
            Task { await self.switchTo(acc.id) }
        }
        loginSession = session
        session.start()
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

    nonisolated private static func environment(for dir: URL) -> [String: String] {
        var env = ShellEnvironment.environment()
        env["CLAUDE_CONFIG_DIR"] = dir.path
        env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        return env
    }

    /// 上次登录到一半 app 被杀，临时目录和它那条钥匙串会留下来；启动时扫一遍清掉。
    static func sweepLeftovers() {
        let base = supportDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        let stale = names.filter { $0.hasPrefix("login-") }
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
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        rawOutput += raw
        output = Self.stripControl(rawOutput)
        if loginURL == nil, let url = Self.firstURL(in: output) { loginURL = url }
        if phase == .starting, output.contains("Paste code") { phase = .waitingForCode }
    }

    /// 把浏览器页面给的授权码贴回去。
    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let stdinPipe, isRunning else { return }
        phase = .finishing
        stdinPipe.fileHandleForWriting.write(Data((trimmed + "\n").utf8))
    }

    private func exited(_ code: Int32) {
        process = nil
        if cancelled { return }
        guard code == 0 else {
            let tail = output.split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n")
            phase = .failed("登录没有完成（claude 退出码 \(code)）" + (tail.isEmpty ? "" : "\n" + tail))
            cleanupTemp()
            return
        }
        phase = .finishing
        let dir = dir, env = env
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try AccountOps.harvestLogin(dir: dir, env: env) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let acc): self.onFinished?(acc)
            case .failure(let error): self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        process = nil
        cleanupTemp()
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
    static func stripControl(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return String(out.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" })
    }

    static func firstURL(in text: String) -> URL? {
        guard let range = text.range(of: "https://[A-Za-z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+", options: .regularExpression)
        else { return nil }
        return URL(string: String(text[range]))
    }
}
