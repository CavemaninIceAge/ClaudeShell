import Foundation

/// Local Codex app-server JSON-RPC over stdio. Credentials are supplied in an isolated CODEX_HOME.
/// Protocol verified against `codex app-server generate-ts` and the official app-server documentation.
@MainActor
final class CodexProcess {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    let events: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var sequence = 0
    private var stopped = false
    private(set) var stderrTail = ""
    var isRunning: Bool { process.isRunning && !stopped }

    init() {
        var sink: AsyncStream<JSONValue>.Continuation!
        events = AsyncStream { sink = $0 }
        continuation = sink
    }

    nonisolated static func executable() -> String? {
        let directories = ShellEnvironment.loginPATH().split(separator: ":").map(String.init)
            + [NSHomeDirectory() + "/.npm-global/bin", "/Applications/Codex.app/Contents/Resources"]
        return directories.map { $0 + "/codex" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(cwd: String, environment: [String: String], executable: String? = nil, arguments: [String]? = nil) throws {
        guard let executable = executable ?? Self.executable() else { throw Failure(message: "找不到 codex 命令。请安装 Codex CLI 或 Codex app。") }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments ?? (["app-server", "--listen", "stdio://"] + NativeEngineConfiguration.codexLaunchOverrides)
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Dedicated readers preserve line order and drain stdout fully before publishing exit.
        try process.run()
        let stdout = output.fileHandleForReading
        let stderr = errors.fileHandleForReading
        let proc = process
        Task.detached { [weak self] in
            while true {
                let data = stderr.availableData
                if data.isEmpty { break }
                let text = String(decoding: data, as: UTF8.self)
                await self?.appendStderr(text)
            }
        }
        Task.detached { [weak self] in
            var buffer = Data()
            while true {
                let data = stdout.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer.subdata(in: buffer.startIndex..<end)
                    buffer.removeSubrange(buffer.startIndex...end)
                    if let message = JSONValue.parse(line) { await self?.receive(message) }
                }
            }
            if !buffer.isEmpty, let message = JSONValue.parse(buffer) { await self?.receive(message) }
            proc.waitUntilExit()
            await self?.exited(proc.terminationStatus)
        }
    }

    func initialize() async throws {
        _ = try await request("initialize", params: .object([
            "clientInfo": .object(["name": .string("claudex_shell"), "title": .string("Claudex Shell"), "version": .string("0.2.0")]),
            "capabilities": .object(["experimentalApi": .bool(true), "requestAttestation": .bool(false)]),
        ]))
        try write(.object(["method": .string("initialized")]))
    }

    func request(_ method: String, params: JSONValue, timeout: Duration = .seconds(45)) async throws -> JSONValue {
        guard isRunning else { throw Failure(message: "Codex 进程已停止。请重新发送。") }
        sequence += 1
        let id = "client-\(sequence)"
        return try await withCheckedThrowingContinuation { waiter in
            pending[id] = waiter
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self else { return }
                self.timeouts[id] = nil
                self.pending.removeValue(forKey: id)?.resume(throwing: Failure(message: "Codex \(method) 请求超时。"))
            }
            do { try write(.object(["id": .string(id), "method": .string(method), "params": params])) }
            catch {
                timeouts.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    func reply(id: JSONValue, result: JSONValue) {
        try? write(.object(["id": id, "result": result]))
    }

    func reject(id: JSONValue, method: String) {
        try? write(.object(["id": id, "error": .object([
            "code": .number(-32601), "message": .string("Claudex Shell 尚不支持 \(method)")
        ])]))
    }

    func terminate() {
        guard !stopped else { return }
        stopped = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for waiter in pending.values { waiter.resume(throwing: CancellationError()) }
        pending.removeAll()
        let proc = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
    }

    private func write(_ value: JSONValue) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((value.serialized() + "\n").utf8))
    }

    private func receive(_ value: JSONValue) {
        if value["method"] == nil, let id = value["id"]?.string, let waiter = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if let error = value["error"] {
                waiter.resume(throwing: Failure(message: error["message"]?.string ?? error.serialized()))
            } else { waiter.resume(returning: value["result"] ?? .null) }
        } else { continuation.yield(value) }
    }

    private func appendStderr(_ text: String) { stderrTail = String((stderrTail + text).suffix(8_000)) }

    private func exited(_ code: Int32) {
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for waiter in pending.values {
            waiter.resume(throwing: Failure(message: "Codex 进程退出（代码 \(code)）。\n\(stderrTail)"))
        }
        pending.removeAll()
        continuation.yield(.object(["method": .string("claudex/exited"), "params": .object(["code": .number(Double(code))])]))
        continuation.finish()
    }
}

struct CodexModelOption: Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var efforts: [String]
    var defaultEffort: String?
    var isDefault: Bool

    static func parse(_ value: JSONValue) -> CodexModelOption? {
        guard let id = value["model"]?.string ?? value["id"]?.string else { return nil }
        return CodexModelOption(id: id, name: value["displayName"]?.string ?? id,
                                efforts: value["supportedReasoningEfforts"]?.array?.compactMap { $0["reasoningEffort"]?.string } ?? [],
                                defaultEffort: value["defaultReasoningEffort"]?.string,
                                isDefault: value["isDefault"]?.bool ?? false)
    }
}
