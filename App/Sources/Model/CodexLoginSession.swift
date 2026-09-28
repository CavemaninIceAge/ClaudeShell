import AppKit
import Foundation
import Observation

enum CodexLoginMethod: String, CaseIterable, Identifiable, Sendable {
    case device, apiKey
    var id: String { rawValue }
    var title: String { self == .device ? "ChatGPT 账号" : "API Key" }
}

/// Pure plans/parsing can be tested without initiating authentication or reading real credentials.
enum CodexLoginFlow {
    struct Plan: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var directory: URL
    }
    struct Challenge: Equatable, Sendable {
        var url: URL?
        var code: String?
    }

    static func plan(executable: String, directory: URL, base: [String: String], method: CodexLoginMethod) -> Plan {
        var env = base
        for key in Array(env.keys) where key.hasPrefix("OPENAI_") || key.hasPrefix("CODEX_API_") || key == "CODEX_ACCESS_TOKEN" {
            env.removeValue(forKey: key)
        }
        env["CODEX_HOME"] = directory.path
        env["BROWSER"] = "/usr/bin/true"
        env["NO_COLOR"] = "1"
        return Plan(executable: executable,
                    arguments: ["-c", "cli_auth_credentials_store=\"file\"", "login", method == .device ? "--device-auth" : "--with-api-key"],
                    environment: env, directory: directory)
    }

    static func challenge(in text: String) -> Challenge {
        let plain = LoginSession.stripControl(text)
        let pattern = #"https://[^\s<>\"\x1b]+"#
        var url: URL?
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let range = Range(match.range, in: plain) else { continue }
                let raw = String(plain[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;"))
                guard let candidate = URLComponents(string: raw), candidate.scheme == "https", candidate.host == "auth.openai.com",
                      candidate.user == nil, candidate.password == nil, candidate.port == nil || candidate.port == 443,
                      candidate.path.hasPrefix("/codex/device") || candidate.path == "/activate" else { continue }
                url = candidate.url
                break
            }
        }
        // Device codes are short standalone values, not bearer tokens or arbitrary terminal output.
        let codePattern = #"(?m)(?:^\s*|(?:[Cc]ode|[Cc]ode is|验证码|设备码)\s*[:：]\s*)([A-Z0-9]{4}-[A-Z0-9]{4,5}|[A-Z0-9]{8})(?:\s*$|\s+\(expires)"#
        let regex = try? NSRegularExpression(pattern: codePattern)
        let code = regex?.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain))
            .flatMap { Range($0.range(at: 1), in: plain) }.map { String(plain[$0]) }
        return Challenge(url: url, code: code)
    }

    static func harvest(directory: URL, vault: CredentialVault = .system) throws -> CodexAccount {
        let url = directory.appendingPathComponent("auth.json")
        let payload = try CodexAccountOps.compact(String(contentsOf: url, encoding: .utf8))
        let account = try CodexAccountOps.account(payload: payload)
        try CodexAccountOps.save(account, payload: payload, vault: vault)
        return account
    }
}

/// Runs only the native CLI login command in a new private home. No desktop app or terminal is required.
@MainActor @Observable
final class CodexLoginSession: Identifiable {
    enum Phase: Equatable { case ready, starting, waitingForAuthorization, finishing, failed(String) }
    struct Dependencies: Sendable {
        var executable: @Sendable () -> String?
        var environment: @Sendable () -> [String: String]
        var supportDirectory: @Sendable () -> URL
        var vault: CredentialVault
        static let live = Dependencies(executable: { EngineAvailability.executable(for: .codex) },
                                       environment: { ShellEnvironment.environment() },
                                       supportDirectory: { AppAuthPaths.support }, vault: .system)
    }
    let id = UUID()
    private(set) var phase: Phase = .ready
    private(set) var loginURL: URL?
    private(set) var deviceCode: String?
    var onFinished: (@MainActor (CodexAccount) -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var rawOutput = ""
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) { self.dependencies = dependencies }

    var isBusy: Bool { phase == .starting || phase == .waitingForAuthorization || phase == .finishing }

    func start(method: CodexLoginMethod, apiKey: String = "") {
        guard !isBusy else { return }
        guard let executable = dependencies.executable() else {
            phase = .failed("找不到 Codex CLI。请在应用页的引擎设置中指定可执行文件，再重新登录。")
            return
        }
        let secret = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard method != .apiKey || (!secret.isEmpty && !secret.contains("\n") && !secret.contains("\r") && !secret.contains("\0")) else {
            phase = .failed("请输入有效的单行 API Key。")
            return
        }
        cancelled = false; generation = UUID(); loginURL = nil; deviceCode = nil; rawOutput = ""
        let token = generation
        let home = dependencies.supportDirectory().appendingPathComponent("codex-login-" + UUID().uuidString.lowercased(), isDirectory: true)
        directory = home
        let plan = CodexLoginFlow.plan(executable: executable, directory: home, base: dependencies.environment(), method: method)
        do { try AppAuthPaths.privateDirectory(home) }
        catch { phase = .failed("无法创建私有登录目录：\(error.localizedDescription)"); return }
        let proc = Process(), stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        proc.executableURL = URL(fileURLWithPath: plan.executable)
        proc.arguments = plan.arguments
        proc.environment = plan.environment
        proc.currentDirectoryURL = plan.directory
        proc.standardOutput = stdout; proc.standardError = stderr; proc.standardInput = stdin
        enum Event: Sendable { case text(String), exited(Int32) }
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let forward: @Sendable (FileHandle) -> Void = { file in
            let data = file.availableData
            if !data.isEmpty { continuation.yield(.text(String(decoding: data, as: UTF8.self))) }
        }
        stdout.fileHandleForReading.readabilityHandler = forward
        stderr.fileHandleForReading.readabilityHandler = forward
        proc.terminationHandler = { child in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            for pipe in [stdout, stderr] {
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { continuation.yield(.text(String(decoding: rest, as: UTF8.self))) }
            }
            continuation.yield(.exited(child.terminationStatus)); continuation.finish()
        }
        do { try proc.run() }
        catch {
            stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil
            phase = .failed("无法启动 Codex 登录：\(error.localizedDescription)")
            cleanup(home)
            return
        }
        process = proc; phase = .starting
        if method == .apiKey { try? stdin.fileHandleForWriting.write(contentsOf: Data((secret + "\n").utf8)) }
        try? stdin.fileHandleForWriting.close()
        reader = Task { [weak self] in
            for await event in stream {
                guard let self else { if case .exited = event { try? FileManager.default.removeItem(at: home) }; continue }
                guard self.generation == token else { if case .exited = event { self.cleanup(home) }; continue }
                switch event {
                case .text(let text): self.consume(text)
                case .exited(let status): self.exited(status, home: home)
                }
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
            guard let self, self.generation == token, self.process?.isRunning == true else { return }
            self.cancel()
            self.phase = .failed("设备授权已超时，请重新开始登录。")
        }
    }

    private func consume(_ text: String) {
        guard !cancelled else { return }
        rawOutput = String((rawOutput + text).suffix(24_000))
        let challenge = CodexLoginFlow.challenge(in: rawOutput)
        loginURL = challenge.url ?? loginURL
        deviceCode = challenge.code ?? deviceCode
        if loginURL != nil || deviceCode != nil { phase = .waitingForAuthorization }
    }

    private func exited(_ status: Int32, home: URL) {
        deadline?.cancel(); process = nil
        guard !cancelled else { cleanup(home); return }
        guard status == 0 else {
            // Never echo raw native output: API keys and authentication query strings may occur there.
            phase = .failed("Codex 登录未完成（退出码 \(status)）。设备登录需在 ChatGPT 安全设置中允许设备码授权；也可改用 API Key。")
            cleanup(home)
            return
        }
        phase = .finishing
        let token = generation
        let vault = dependencies.vault
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try CodexLoginFlow.harvest(directory: home, vault: vault) } }.value
            guard let self else { try? FileManager.default.removeItem(at: home); return }
            self.cleanup(home)
            guard !self.cancelled, self.generation == token else { return }
            switch result {
            case .success(let account): self.onFinished?(account)
            case .failure: self.phase = .failed("登录结束，但无法保存新的登录态。请检查钥匙串访问权限后重试。")
            }
        }
    }

    func cancel() {
        cancelled = true; deadline?.cancel()
        if let process, process.isRunning {
            process.terminate()
            let child = process
            Task {
                try? await Task.sleep(for: .seconds(2))
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        } else if let directory { cleanup(directory) }
    }

    private func cleanup(_ home: URL) {
        try? FileManager.default.removeItem(at: home)
        if directory == home { directory = nil; rawOutput = "" }
    }

    func openAuthorizationPage() {
        if let loginURL { NSWorkspace.shared.open(loginURL) }
    }

    static func sweepLeftovers() {
        let root = AppAuthPaths.support
        Task.detached(priority: .utility) {
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for folder in folders where folder.lastPathComponent.hasPrefix("codex-login-") {
                let suffix = String(folder.lastPathComponent.dropFirst("codex-login-".count))
                guard UUID(uuidString: suffix) != nil,
                      let modified = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified < Date().addingTimeInterval(-24 * 60 * 60) else { continue }
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
