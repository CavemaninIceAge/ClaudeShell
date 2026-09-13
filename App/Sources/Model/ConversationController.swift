import Foundation
import Observation

struct ThreadSettings: Sendable, Codable, Equatable {
    var model: String? = nil            // nil = 跟随 ~/.claude/settings.json
    var permissionMode: String = "auto" // 和用户终端里一样
    var effort: String? = nil
}

enum ShellError: LocalizedError {
    case claudeNotFound
    var errorDescription: String? {
        switch self {
        case .claudeNotFound: return "找不到 claude 命令。请确认 Claude Code 已安装（通常在 ~/.local/bin/claude）。"
        }
    }
}

/// 一个对话：持有 transcript、对应的 claude 子进程，处理发送 / 打断 / 审批。
@MainActor
@Observable
final class ConversationController: Identifiable {
    let id: String
    let cwd: String

    private(set) var items: [TranscriptItem] = []
    private(set) var isWorking = false
    private(set) var statusText: String? = nil
    private(set) var pendingPermissions: [PermissionRequest] = []
    private(set) var sessionModel: String? = nil
    private(set) var sessionPermissionMode: String? = nil
    private(set) var totalCostUSD: Double = 0
    private(set) var rateLimitUtilization: Double? = nil
    private(set) var historyLoaded = false
    private(set) var isLoadingHistory = false
    private(set) var hasSessionFile: Bool
    var settings: ThreadSettings {
        didSet { if settings != oldValue { settingsChanged() } }
    }
    var onTurnFinished: (@MainActor (ConversationController) -> Void)?
    var onFirstMessage: (@MainActor (ConversationController, String) -> Void)?

    // 流式期间的改动先落在 working 里，每 60ms 才发布到 items，免得每个 token 都触发一次视图更新。
    @ObservationIgnored private var working: [TranscriptItem] = []
    @ObservationIgnored private var process: ClaudeProcess?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var streamBlockIds: [Int: String] = [:]
    @ObservationIgnored private var turnIndex: Int? = nil
    @ObservationIgnored private var needsRespawn = false

    init(id: String, cwd: String, settings: ThreadSettings, hasSessionFile: Bool) {
        self.id = id
        self.cwd = cwd
        self.settings = settings
        self.hasSessionFile = hasSessionFile
        self.historyLoaded = !hasSessionFile
    }

    var isDraft: Bool { !hasSessionFile && working.isEmpty }
    var canSend: Bool { !isWorking && pendingPermissions.isEmpty && !isLoadingHistory }

    // MARK: - 历史

    func loadHistoryIfNeeded() {
        guard hasSessionFile, !historyLoaded, !isLoadingHistory else { return }
        isLoadingHistory = true
        let url = SessionIndex.sessionFileURL(id: id, cwd: cwd)
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = SessionLoader.load(url: url)
            await MainActor.run { self?.applyHistory(loaded) }
        }
    }

    private func applyHistory(_ loaded: [TranscriptItem]) {
        if let t = turnIndex { turnIndex = t + loaded.count }
        working = loaded + working
        historyLoaded = true
        isLoadingHistory = false
        publish()
    }

    // MARK: - 发送 / 停止 / 审批

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend else { return }
        let isFirst = !hasSessionFile && working.isEmpty
        working.append(.user(text, at: Date()))
        isWorking = true
        statusText = "正在思考…"
        idleTask?.cancel()
        publish()
        do {
            try ensureProcess()
        } catch {
            fail(error.localizedDescription)
            return
        }
        process?.sendUser(text: text)
        hasSessionFile = true
        if isFirst { onFirstMessage?(self, text) }
    }

    func stop() {
        guard isWorking, let process else { return }
        statusText = "正在停止…"
        process.interrupt()
    }

    func respond(to request: PermissionRequest, allow: Bool, always: Bool = false) {
        pendingPermissions.removeAll { $0.id == request.id }
        process?.respond(requestId: request.id, allow: allow,
                         updatedInput: request.input,
                         updatedPermissions: always ? request.suggestions : nil,
                         message: nil)
        if allow { statusText = "正在运行 \(request.toolName)…" } else { statusText = "正在思考…" }
    }

    /// AskUserQuestion：把答案塞进 updatedInput.answers 一起放行。
    func answerQuestion(_ request: PermissionRequest, answers: [String: String]) {
        pendingPermissions.removeAll { $0.id == request.id }
        var input = request.input.object ?? [:]
        input["answers"] = .object(answers.mapValues { .string($0) })
        process?.respond(requestId: request.id, allow: true, updatedInput: .object(input), updatedPermissions: nil, message: nil)
        statusText = "正在思考…"
    }

    func terminate(immediately: Bool = false) {
        idleTask?.cancel()
        pumpTask?.cancel()
        process?.terminate(immediately: immediately)
        process = nil
    }

    // MARK: - 进程

    private func ensureProcess() throws {
        if let p = process, p.isRunning, !needsRespawn { return }
        if let p = process { p.terminate() }
        pumpTask?.cancel()
        process = nil
        needsRespawn = false
        guard let exe = ShellEnvironment.claudeExecutable() else { throw ShellError.claudeNotFound }
        let resume = FileManager.default.fileExists(atPath: SessionIndex.sessionFileURL(id: id, cwd: cwd).path)
        let config = LaunchConfig(executable: exe, cwd: cwd, sessionId: id, resume: resume,
                                  model: settings.model, permissionMode: settings.permissionMode, effort: settings.effort)
        let p = ClaudeProcess(config: config)
        try p.start()
        process = p
        pumpTask = Task { [weak self] in
            for await event in p.events {
                guard let self else { break }
                self.handle(event, from: p)
            }
        }
    }

    private func settingsChanged() {
        if isWorking {
            needsRespawn = true
        } else {
            process?.terminate()
            process = nil
        }
    }

    private func scheduleIdleKill() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20 * 60))
            guard let self, !Task.isCancelled, !self.isWorking else { return }
            self.process?.terminate()
            self.process = nil
        }
    }

    private func fail(_ message: String) {
        closeTurn()
        working.append(.note(message, level: "error"))
        isWorking = false
        statusText = nil
        flushNow()
    }

    // MARK: - 事件

    private func handle(_ event: ClaudeEvent, from p: ClaudeProcess) {
        if p !== process {
            if case .exited = event {} else { return }
        }
        switch event {
        case .initialized(_, let model, let mode):
            sessionModel = model
            sessionPermissionMode = mode

        case .messageStart:
            openTurnIfNeeded()
            streamBlockIds = [:]

        case .blockStart(let index, let block):
            openTurnIfNeeded()
            guard var b = Block.from(contentBlock: block) else { return }
            b.done = false
            b.text = ""                       // 流式开始时是空的，靠 delta 补
            if b.kind == .tool { b.tool?.input = nil; b.tool?.startedAt = Date() }
            streamBlockIds[index] = b.id
            mutateTurn { $0.blocks.append(b) }
            switch b.kind {
            case .thinking: statusText = "正在思考…"
            case .text: statusText = "正在回答…"
            case .tool: statusText = "正在调用 \(b.tool?.name ?? "工具")…"
            }
            scheduleFlush()

        case .blockDelta(let index, let delta):
            guard let bid = streamBlockIds[index] else { return }
            switch delta["type"]?.string {
            case "text_delta":
                mutateBlock(bid) { $0.text += delta["text"]?.string ?? "" }
            case "thinking_delta":
                mutateBlock(bid) { $0.text += delta["thinking"]?.string ?? "" }
            case "input_json_delta":
                mutateBlock(bid) { $0.tool?.partialInput += delta["partial_json"]?.string ?? "" }
            default:
                return
            }
            scheduleFlush()

        case .blockStop(let index):
            guard let bid = streamBlockIds[index] else { return }
            mutateBlock(bid) { $0.done = true }
            scheduleFlush()

        case .messageStop:
            break

        case .assistantMessage(let content):
            openTurnIfNeeded()
            for c in content {
                guard let full = Block.from(contentBlock: c) else { continue }
                switch full.kind {
                case .tool:
                    if let tid = full.tool?.id, hasBlock(tid) {
                        mutateBlock(tid) { $0.tool?.input = full.tool?.input; $0.tool?.partialInput = ""; $0.done = true }
                    } else {
                        var b = full
                        b.tool?.done = false
                        b.tool?.startedAt = Date()
                        mutateTurn { $0.blocks.append(b) }
                    }
                case .text, .thinking:
                    // 流里最后一个同类且还没收尾的块，就是这条的最终版。
                    if let bid = lastOpenBlockId(kind: full.kind) {
                        mutateBlock(bid) { $0.text = full.text; $0.done = true }
                    } else if !full.text.isEmpty {
                        mutateTurn { $0.blocks.append(full) }
                    }
                }
            }
            scheduleFlush()

        case .toolResults(let results):
            for r in results {
                mutateBlock(r.toolUseId) {
                    $0.tool?.result = ToolResultText.flatten(r.content)
                    $0.tool?.isError = r.isError
                    $0.tool?.done = true
                    $0.tool?.endedAt = Date()
                    $0.done = true
                }
            }
            statusText = "正在思考…"
            flushNow()

        case .userText(let s):
            if s.hasPrefix("[Request interrupted") {
                closeTurn()
                working.append(.note("已停止", level: "info"))
                flushNow()
            }

        case .permissionRequest(let req):
            pendingPermissions.append(req)
            statusText = "等待你的批准"
            // 自动化验证用：-testAutoApprove <秒> 让审批卡显示几秒后自动放行。
            let delay = UserDefaults.standard.double(forKey: "testAutoApprove")
            if delay > 0 {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, self.pendingPermissions.contains(where: { $0.id == req.id }) else { return }
                    self.respond(to: req, allow: true)
                }
            }

        case .controlRequestUnsupported(let rid, let sub):
            p.respondError(requestId: rid, error: "Claude Shell 不支持 \(sub)")

        case .controlResponse:
            break

        case .result(let v):
            finishTurn(with: v)

        case .status(let s):
            if s == "requesting", isWorking { statusText = "正在请求模型…" }

        case .permissionDenied(let tool, let message):
            working.append(.note("\(tool)：\(message)", level: "warn"))
            flushNow()

        case .rateLimit(let info):
            rateLimitUtilization = info["unifiedWindows"]?["five_hour"]?["utilization"]?.double

        case .systemNote(let sub, _):
            if sub == "compact_boundary" {
                working.append(.note("上下文已压缩", level: "info"))
                flushNow()
            }

        case .stderr:
            break

        case .exited(let code):
            guard p === process else { return }
            process = nil
            pendingPermissions = []
            if isWorking {
                closeTurn()
                let tail = p.stderrText().trimmingCharacters(in: .whitespacesAndNewlines)
                let lines = tail.split(separator: "\n").suffix(8).joined(separator: "\n")
                working.append(.note("claude 进程退出（代码 \(code)）" + (lines.isEmpty ? "" : "\n" + lines), level: "error"))
                isWorking = false
                statusText = nil
                flushNow()
            }
        }
    }

    private func finishTurn(with v: JSONValue) {
        closeTurn()
        if let i = working.lastIndex(where: { $0.kind == .assistant }) {
            working[i].meta = TurnMeta(durationMs: v["duration_ms"]?.int,
                                       costUSD: v["total_cost_usd"]?.double,
                                       isError: v["is_error"]?.bool ?? false,
                                       stopReason: v["stop_reason"]?.string)
            working[i].rev += 1
        }
        if let cost = v["total_cost_usd"]?.double { totalCostUSD = cost }
        let wasInterrupted = working.last?.kind == .note && working.last?.text == "已停止"
        if v["is_error"]?.bool == true, !wasInterrupted {
            var message = v["result"]?.string ?? ""
            if message.isEmpty, let errs = v["errors"]?.array {
                message = errs.compactMap { $0.string }.joined(separator: "\n")
            }
            if message.isEmpty { message = "这一轮出错了（\(v["subtype"]?.string ?? "未知原因")）" }
            working.append(.note(message, level: "error"))
        }
        isWorking = false
        statusText = nil
        turnIndex = nil
        streamBlockIds = [:]
        flushNow()
        onTurnFinished?(self)
        scheduleIdleKill()
        if needsRespawn {
            process?.terminate()
            process = nil
            needsRespawn = false
        }
    }

    // MARK: - transcript 改动

    private func openTurnIfNeeded() {
        if let t = turnIndex, working.indices.contains(t), working[t].kind == .assistant, !working[t].done { return }
        working.append(.assistantTurn(at: Date()))
        turnIndex = working.count - 1
    }

    private func closeTurn() {
        guard let t = turnIndex, working.indices.contains(t) else { turnIndex = nil; return }
        working[t].done = true
        for bi in working[t].blocks.indices {
            working[t].blocks[bi].done = true
            working[t].blocks[bi].tool?.done = true
        }
        working[t].rev += 1
        turnIndex = nil
    }

    private func mutateTurn(_ body: (inout TranscriptItem) -> Void) {
        guard let t = turnIndex, working.indices.contains(t) else { return }
        body(&working[t])
        working[t].rev += 1
    }

    private func mutateBlock(_ id: String, _ body: (inout Block) -> Void) {
        guard let t = turnIndex ?? working.lastIndex(where: { $0.kind == .assistant }),
              let bi = working[t].blocks.lastIndex(where: { $0.id == id }) else { return }
        body(&working[t].blocks[bi])
        working[t].rev += 1
    }

    private func hasBlock(_ id: String) -> Bool {
        guard let t = turnIndex else { return false }
        return working[t].blocks.contains { $0.id == id }
    }

    private func lastOpenBlockId(kind: Block.Kind) -> String? {
        guard let t = turnIndex else { return nil }
        return working[t].blocks.last(where: { $0.kind == kind && !$0.done })?.id
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.publish()
        }
    }

    private func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        publish()
    }

    private func publish() {
        items = working
    }
}
