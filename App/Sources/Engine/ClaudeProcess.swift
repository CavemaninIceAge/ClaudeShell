import Foundation

struct LaunchConfig: Sendable {
    var executable: String
    var cwd: String
    var sessionId: String
    var resume: Bool
    var model: String?
    var permissionMode: String
    var effort: String?

    var arguments: [String] {
        var a = ["-p",
                 "--input-format", "stream-json",
                 "--output-format", "stream-json",
                 "--verbose",
                 "--include-partial-messages",
                 // 只有声明 stdio 权限工具，CLI 才会把审批以 control_request 发过来，否则直接拒绝。
                 "--permission-prompt-tool", "stdio",
                 "--permission-mode", permissionMode]
        a += resume ? ["--resume", sessionId] : ["--session-id", sessionId]
        if let model, !model.isEmpty { a += ["--model", model] }
        if let effort, !effort.isEmpty { a += ["--effort", effort] }
        return a
    }
}

/// 一个 `claude -p` 子进程：stdin 喂 stream-json，stdout 逐行读回事件。
/// 进程在多轮之间保持存活（stdin 不关），所以一个对话对应一个进程。
final class ClaudeProcess: @unchecked Sendable {
    let config: LaunchConfig
    let events: AsyncStream<ClaudeEvent>

    private let continuation: AsyncStream<ClaudeEvent>.Continuation
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrTail: [String] = []

    init(config: LaunchConfig) {
        self.config = config
        var cont: AsyncStream<ClaudeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: config.executable)
        process.arguments = config.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: config.cwd)
        process.environment = ShellEnvironment.environment()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.consumeStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            self.lock.lock()
            self.stderrTail.append(s)
            if self.stderrTail.count > 200 { self.stderrTail.removeFirst() }
            self.lock.unlock()
            self.continuation.yield(.stderr(s))
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            let rest = self.stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { self.consumeStdout(rest) }
            self.flushRemainder()
            self.continuation.yield(.exited(code: proc.terminationStatus))
            self.continuation.finish()
        }
        try process.run()
    }

    private func consumeStdout(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8),
               !s.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(s)
            }
        }
        lock.unlock()
        for line in lines {
            if let ev = ClaudeEventParser.parse(line: line) { continuation.yield(ev) }
        }
    }

    private func flushRemainder() {
        lock.lock()
        let rest = stdoutBuffer
        stdoutBuffer = Data()
        lock.unlock()
        guard let s = String(data: rest, encoding: .utf8),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let ev = ClaudeEventParser.parse(line: s) else { return }
        continuation.yield(ev)
    }

    /// 最近的 stderr，进程意外退出时给用户看。
    func stderrText() -> String {
        lock.lock(); defer { lock.unlock() }
        return stderrTail.joined()
    }

    private func writeLine(_ json: JSONValue) {
        guard process.isRunning else { return }
        var data = Data(json.serialized().utf8)
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            continuation.yield(.stderr("写入 stdin 失败：\(error.localizedDescription)\n"))
        }
    }

    func sendUser(text: String) {
        writeLine(.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ]),
        ]))
    }

    func respond(requestId: String, allow: Bool, updatedInput: JSONValue?, updatedPermissions: JSONValue?, message: String?) {
        var resp: [String: JSONValue] = ["behavior": .string(allow ? "allow" : "deny")]
        if allow {
            resp["updatedInput"] = updatedInput ?? .object([:])
            if let updatedPermissions { resp["updatedPermissions"] = updatedPermissions }
        } else {
            resp["message"] = .string(message ?? "用户拒绝了这次操作")
        }
        writeLine(.object([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(requestId),
                "response": .object(resp),
            ]),
        ]))
    }

    func respondError(requestId: String, error: String) {
        writeLine(.object([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("error"),
                "request_id": .string(requestId),
                "error": .string(error),
            ]),
        ]))
    }

    func interrupt() {
        writeLine(.object([
            "type": .string("control_request"),
            "request_id": .string("interrupt-\(UUID().uuidString.lowercased())"),
            "request": .object(["subtype": .string("interrupt")]),
        ]))
    }

    /// 先关 stdin 让 CLI 自己收尾，不走就 SIGTERM，再不走就 SIGKILL。
    /// app 退出时用 immediately：延时的信号发不出去了，直接 SIGTERM。
    func terminate(immediately: Bool = false) {
        try? stdinPipe.fileHandleForWriting.close()
        let proc = process
        if immediately {
            if proc.isRunning { proc.terminate() }
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if proc.isRunning { proc.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
    }
}
