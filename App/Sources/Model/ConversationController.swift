import Foundation
import Observation

struct ThreadSettings: Sendable, Codable, Equatable {
    var model: String? = nil            // nil = 跟随 ~/.claude/settings.json
    var permissionMode: String = "auto" // 和用户终端里一样
    var effort: String? = nil
    var engine: ConversationEngine = .claude

    enum CodingKeys: String, CodingKey { case model, permissionMode, effort, engine }
    init(model: String? = nil, permissionMode: String = "auto", effort: String? = nil, engine: ConversationEngine = .claude) {
        self.model = model; self.permissionMode = permissionMode; self.effort = effort; self.engine = engine
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode) ?? "auto"
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        engine = try c.decodeIfPresent(ConversationEngine.self, forKey: .engine) ?? .claude
    }
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
final class ConversationController: @preconcurrency Identifiable {
    private(set) var id: String
    let cwd: String
    var engine: ConversationEngine { settings.engine }
    private(set) var codexModels: [CodexModelOption] = []
    private(set) var sessionPath: String?
    var onSessionStarted: (@MainActor (ConversationController, String) -> Void)?
    private(set) var handoff: ConversationHandoff?
    var onHandoffConsumed: (@MainActor (ConversationController, ConversationHandoff) -> Void)?

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
    /// 终端里开着这个会话：登记表里的 status（idle / busy）；nil = 终端里没开。
    private(set) var terminalStatus: String? = nil
    /// 会话文件里最近一条 assistant 记录的 model：终端会话实际在用的模型（app 自己的进程以 system/init 为准）。
    private(set) var fileModel: String? = nil
    /// 终端默认强度，ThreadStore 探到后灌进来：本对话没显式选强度时，思考 shimmer 用它。
    var terminalDefaultEffort: String? = nil
    /// 输入框里挂着、还没发出去的附件（拖 / 贴 / 「+」选进来的），随对话走，切换对话不丢。
    private(set) var attachments: [ComposerAttachment] = []
    var settings: ThreadSettings {
        didSet { if settings != oldValue { settingsChanged() } }
    }
    var onTurnFinished: (@MainActor (ConversationController) -> Void)?
    var onFirstMessage: (@MainActor (ConversationController, String) -> Void)?

    // 流式期间的改动先落在 working 里，每 60ms 才发布到 items，免得每个 token 都触发一次视图更新。
    @ObservationIgnored private var working: [TranscriptItem] = []
    @ObservationIgnored private var process: ClaudeProcess?
    @ObservationIgnored private var codexProcess: CodexProcess?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var codexResumeState = CodexResumeState(existingHistory: false)
    @ObservationIgnored private var codexThreadId: String?
    @ObservationIgnored private var codexTurnId: String?
    @ObservationIgnored private var codexRequests: [String: (id: JSONValue, method: String, params: JSONValue)] = [:]
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var sendGeneration = UUID()
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var streamBlockIds: [Int: String] = [:]
    @ObservationIgnored private var turnIndex: Int? = nil
    @ObservationIgnored private var needsRespawn = false
    // 旁观终端会话用：会话文件读到哪了，以及每秒去看一眼有没有长的任务。
    @ObservationIgnored private var reader: SessionReader?
    @ObservationIgnored private var tailTask: Task<Void, Never>?

    init(id: String, cwd: String, settings: ThreadSettings, hasSessionFile: Bool, sessionPath: String? = nil, handoff: ConversationHandoff? = nil) {
        self.id = id
        self.sessionPath = sessionPath
        self.handoff = handoff
        self.codexThreadId = hasSessionFile && settings.engine == .codex ? CodexHistory.sessionId(id) : nil
        self.codexResumeState = CodexResumeState(existingHistory: hasSessionFile && settings.engine == .codex)
        self.cwd = cwd
        self.settings = settings
        self.hasSessionFile = hasSessionFile
        self.historyLoaded = !hasSessionFile
    }

    /// A transcript already loaded in memory; useful for offline rendering without a session file or engine.
    struct Snapshot: Sendable {
        var id: String
        var cwd: String
        var settings: ThreadSettings
        var items: [TranscriptItem] = []
        var model: String? = nil
    }

    convenience init(snapshot: Snapshot) {
        self.init(id: snapshot.id, cwd: snapshot.cwd, settings: snapshot.settings, hasSessionFile: false)
        self.working = snapshot.items
        self.items = snapshot.items
        self.fileModel = snapshot.model
        self.historyLoaded = true
    }

    var isDraft: Bool { !hasSessionFile && working.isEmpty }
    var canSend: Bool { !isWorking && pendingPermissions.isEmpty && !isLoadingHistory }
    var isLiveInTerminal: Bool { terminalStatus != nil }
    /// 正文底部那行 shimmer：自己的进程在跑，或者终端那边在跑。
    var showsActivity: Bool { isWorking || terminalStatus == "busy" }
    var activityText: String? { isWorking ? statusText : (terminalStatus == "busy" ? "终端里正在运行…" : nil) }

    // MARK: - 历史

    func loadHistoryIfNeeded() {
        guard hasSessionFile, !historyLoaded, !isLoadingHistory else { return }
        isLoadingHistory = true
        let url = sessionPath.map { URL(fileURLWithPath: $0) } ?? SessionIndex.sessionFileURL(id: id, cwd: cwd)
        if engine == .codex {
            Task { [weak self] in
                do {
                    let result = try await Task.detached(priority: .userInitiated) { try CodexHistory.load(url: url) }.value
                    guard let self else { return }
                    self.working = result.items + self.working
                    self.fileModel = result.model
                    self.historyLoaded = true
                    self.isLoadingHistory = false
                    self.publish()
                } catch {
                    self?.isLoadingHistory = false
                    self?.working.append(.note("无法读取 Codex 历史：\(error.localizedDescription)", level: "error"))
                    self?.publish()
                }
            }
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            var r = SessionReader(url: url)
            r.readMore()
            await MainActor.run { self?.applyHistory(r) }
        }
    }

    private func applyHistory(_ r: SessionReader) {
        var r = r
        // 终端那边还在写：最后一轮保持"进行中"，后面 tail 接着补；否则收尾。
        let loaded = isLiveInTerminal ? r.items : r.finishedItems()
        reader = r
        fileModel = r.lastModel
        if let t = turnIndex { turnIndex = t + loaded.count }
        working = loaded + working
        historyLoaded = true
        isLoadingHistory = false
        publish()
    }

    // MARK: - 旁观 / 投递终端会话

    /// 由 ThreadStore 按登记表刷新调用。
    func setTerminalStatus(_ status: String?) {
        guard engine == .claude, status != terminalStatus else { return }
        terminalStatus = status
        if status != nil {
            startTailing()
        } else {
            stopTailing()
        }
    }

    private func startTailing() {
        guard tailTask == nil else { return }
        tailTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { break }
                self.readTail(closing: false)
            }
        }
    }

    private func stopTailing() {
        tailTask?.cancel()
        tailTask = nil
        readTail(closing: true)
    }

    /// 增量只读新追加的那几行，放主线程也不碍事；terminal 退出时把最后一轮收尾。
    private func readTail(closing: Bool) {
        guard historyLoaded, var r = reader, process == nil else { return }
        let grew = r.readMore()
        if closing {
            working = r.finishedItems()
            reader = nil
            publish()
            return
        }
        reader = r
        if grew {
            if fileModel != r.lastModel { fileModel = r.lastModel }
            working = r.items
            publish()
        }
    }

    /// 把这句话投进终端里正在跑的这个会话：那边的 Claude 会在终端里回答，回答再经 tail 同步回来。
    /// 这条协议只能带文字，附件（包括图片）都按路径引用，终端那边的 Claude 自己去读。
    func sendToTerminal(_ rawText: String) {
        let typed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !attachments.isEmpty, isLiveInTerminal, !isLoadingHistory else { return }
        guard let target = PeerMessenger.target(forSessionId: id) else {
            working.append(.note(PeerMessenger.SendError.notFound.localizedDescription, level: "error"))
            publish()
            return
        }
        let outgoing = OutgoingMessage(text: typed, attachments: attachments, inlineImages: false)
        attachments = []
        let text = outgoing.wireText
        let body = PeerMessenger.body(forUserText: text)
        if reader != nil {
            reader?.expectEcho(display: outgoing.displayText, attachments: outgoing.attachments, body: body, at: Date())
            working = reader?.items ?? working
        } else {
            working.append(.user(outgoing.displayText, attachments: outgoing.attachments, at: Date()))
        }
        publish()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try PeerMessenger.send(body, to: target)
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard let self else { return }
                    self.working.append(.note(message, level: "error"))
                    self.publish()
                }
            }
        }
    }

    // MARK: - 附件

    /// 拖 / 贴 / 选进来的文件：图片在这里就读进内存、按上限缩好（读盘和转码放后台，大照片也不卡输入框）。
    func attach(urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let made = files.map { AttachmentMaker.make(url: $0) }
            await MainActor.run { self?.append(made) }
        }
    }

    func attach(imageData: Data, name: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let a = AttachmentMaker.make(imageData: imageData, name: name) else { return }
            await MainActor.run { self?.append([a]) }
        }
    }

    private func append(_ new: [ComposerAttachment]) {
        // 同一个文件拖两次只算一次。
        let paths = Set(attachments.compactMap(\.path))
        attachments += new.filter { $0.path == nil || !paths.contains($0.path!) }
        TestLog.write("attachments: \(attachments.map { "\($0.kind) \($0.name)" })")
    }

    func removeAttachment(_ id: String) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: - 发送 / 停止 / 审批

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, canSend else { return }
        let isFirst = !hasSessionFile && working.isEmpty
        let outgoing = OutgoingMessage(text: text, attachments: attachments, inlineImages: true)
        attachments = []
        working.append(.user(outgoing.displayText, attachments: outgoing.attachments, at: Date()))
        isWorking = true
        statusText = "正在思考…" + thinkingEffortSuffix
        idleTask?.cancel()
        publish()
        stopRequested = false
        let generation = UUID()
        sendGeneration = generation
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                if self.engine == .codex {
                    try await self.sendCodex(outgoing)
                } else {
                    try await self.ensureProcess()
                    guard !Task.isCancelled, !self.stopRequested else { self.finishStopped(); return }
                    let nativeText = try self.handoffMessage(outgoing.wireText)
                    guard self.process?.sendUser(text: nativeText, images: outgoing.imageBlocks) == true else {
                        throw HandoffFailure(message: "Claude Code 消息发送失败，请重新发送。")
                    }
                    self.consumeHandoff()
                    self.hasSessionFile = true
                }
                if isFirst { self.onFirstMessage?(self, outgoing.titleText) }
            } catch is CancellationError {
                guard self.sendGeneration == generation else { return }
                self.finishStopped()
            } catch {
                guard self.sendGeneration == generation else { return }
                if self.engine == .codex { self.codexProcess?.terminate(); self.codexProcess = nil }
                self.fail(error.localizedDescription)
            }
            if self.sendGeneration == generation { self.sendTask = nil }
        }
    }

    func stop() {
        guard isWorking else { return }
        statusText = "正在停止…"
        stopRequested = true
        if engine == .codex {
            if let p = codexProcess, let thread = codexThreadId, let turn = codexTurnId {
                Task { [weak self] in
                    do { _ = try await p.request("turn/interrupt", params: .object(["threadId": .string(thread), "turnId": .string(turn)])) }
                    catch { self?.fail(error.localizedDescription) }
                }
            } else {
                codexProcess?.terminate()
                codexProcess = nil
                sendTask?.cancel()
                finishStopped()
            }
        } else if let process { process.interrupt() }
        else { sendTask?.cancel(); finishStopped() }
    }

    func respond(to request: PermissionRequest, allow: Bool, always: Bool = false) {
        pendingPermissions.removeAll { $0.id == request.id }
        if engine == .codex { respondCodex(request, allow: allow, always: always); return }
        process?.respond(requestId: request.id, allow: allow,
                         updatedInput: request.input,
                         updatedPermissions: always ? request.suggestions : nil,
                         message: nil)
        if allow { statusText = "正在运行 \(request.toolName)…" } else { statusText = "正在思考…" }
    }

    /// AskUserQuestion：把答案塞进 updatedInput.answers 一起放行。
    func answerQuestion(_ request: PermissionRequest, answers: [String: String]) {
        pendingPermissions.removeAll { $0.id == request.id }
        if engine == .codex { answerCodex(request, answers: answers); return }
        var input = request.input.object ?? [:]
        input["answers"] = .object(answers.mapValues { .string($0) })
        process?.respond(requestId: request.id, allow: true, updatedInput: .object(input), updatedPermissions: nil, message: nil)
        statusText = "正在思考…"
    }

    func terminate(immediately: Bool = false) {
        idleTask?.cancel()
        sendTask?.cancel()
        codexProcess?.terminate()
        codexProcess = nil
        pumpTask?.cancel()
        tailTask?.cancel()
        tailTask = nil
        process?.terminate(immediately: immediately)
        process = nil
    }

    private func handoffMessage(_ text: String) throws -> String {
        guard let handoff, handoff.isPending else { return text }
        if let sessionPath, handoff.appearsInNativeSession(at: sessionPath) {
            consumeHandoff()
            return text
        }
        guard FileManager.default.isReadableFile(atPath: handoff.contextPath) else {
            throw HandoffFailure(message: "接管上下文文件不可读。请从源会话重新创建接管。")
        }
        return handoff.prompt(continuation: text)
    }

    private func consumeHandoff() {
        guard var handoff, handoff.isPending else { return }
        handoff.isPending = false
        self.handoff = handoff
        onHandoffConsumed?(self, handoff)
    }

    // MARK: - 进程

    private func ensureProcess() async throws {
        if let p = process, p.isRunning, !needsRespawn { return }
        if let p = process { p.terminate() }
        pumpTask?.cancel()
        process = nil
        needsRespawn = false
        guard let exe = ShellEnvironment.claudeExecutable() else { throw ShellError.claudeNotFound }
        let env = try await AccountStore.shared.prepareClaudeEnvironment()
        try Task.checkCancellation()
        // Account isolation shares Claude Code's own project history directory; the CLI owns resume/persistence.
        let nativeFile = URL(fileURLWithPath: ClaudeAuth.configDir(env: env)).appendingPathComponent("projects")
            .appendingPathComponent(SessionIndex.encodeProjectPath(cwd)).appendingPathComponent(id + ".jsonl")
        sessionPath = nativeFile.resolvingSymlinksInPath().path
        let resume = FileManager.default.fileExists(atPath: nativeFile.path)
        let config = LaunchConfig(executable: exe, cwd: cwd, sessionId: id, resume: resume,
                                  model: settings.model, permissionMode: settings.permissionMode, effort: settings.effort, environment: env)
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

    /// 换了账号：空闲的进程直接收掉（下次发送 `--resume` 拉起、按新账号登录），正在跑的这一轮跑完再换。
    func dropProcess() {
        if isWorking {
            needsRespawn = true
        } else {
            sessionModel = nil
            sessionPermissionMode = nil
            codexModels = []
            process?.terminate()
            process = nil
            codexProcess?.terminate()
            codexProcess = nil
        }
    }

    private func settingsChanged() {
        // 进程报回来的模型是上一轮的，设置一改就不作数了，下一轮 init 会重新报。
        sessionModel = nil
        if isWorking {
            needsRespawn = true
        } else {
            process?.terminate()
            process = nil
            codexProcess?.terminate()
            codexProcess = nil
        }
    }

    /// 界面上「当前生效」的模型 / 强度：显式选择 > 进程报回来的 > 终端默认。
    struct Effective {
        var modelId: String?
        var modelPinned: Bool
        var effort: String?
        var effortPinned: Bool
        var modelName: String? { modelId.map(ModelOption.displayName(for:)) }
    }

    func effective(defaults: ClaudeDefaults.Resolved) -> Effective {
        if engine == .codex {
            return Effective(modelId: settings.model ?? sessionModel ?? fileModel, modelPinned: settings.model != nil,
                             effort: settings.effort, effortPinned: settings.effort != nil)
        }
        // 终端里开着的会话：模型 / 强度由终端决定，app 里的选择不作数；模型看会话文件，强度只能按终端默认猜。
        if isLiveInTerminal {
            return Effective(modelId: fileModel ?? defaults.model, modelPinned: false,
                             effort: defaults.effort, effortPinned: false)
        }
        let modelPinned = !(settings.model ?? "").isEmpty
        let effortPinned = !(settings.effort ?? "").isEmpty
        return Effective(modelId: modelPinned ? settings.model : (sessionModel ?? AccountStore.shared.activeProvider?.model ?? defaults.model),
                         modelPinned: modelPinned,
                         effort: effortPinned ? settings.effort : defaults.effort,
                         effortPinned: effortPinned)
    }

    /// 思考时那个强度名，和终端「thinking with xhigh effort」一致；ultracode 实际强度是 xhigh。
    /// 终端里旁观的会话按它自己文件里的默认强度显示；本 app 的进程按本对话选的（没选就用终端默认）。
    var activeEffortLabel: String {
        if engine == .codex { return settings.effort ?? "" }
        let raw: String
        if isLiveInTerminal {
            raw = terminalDefaultEffort ?? ""
        } else {
            raw = (settings.effort?.isEmpty == false ? settings.effort : terminalDefaultEffort) ?? ""
        }
        return raw == EffortOption.ultracode ? "xhigh" : raw
    }

    private var thinkingEffortSuffix: String {
        activeEffortLabel.isEmpty ? "" : "（\(activeEffortLabel)）"
    }

    private func scheduleIdleKill() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20 * 60))
            guard let self, !Task.isCancelled, !self.isWorking else { return }
            self.process?.terminate()
            self.process = nil
            self.codexProcess?.terminate()
            self.codexProcess = nil
        }
    }

    private func fail(_ message: String) {
        pendingPermissions = []
        codexRequests = [:]
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
            case .thinking: statusText = "正在思考…" + thinkingEffortSuffix
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
            sessionModel = nil
            sessionPermissionMode = nil
            codexModels = []
            process?.terminate()
            process = nil
            codexProcess?.terminate()
            codexProcess = nil
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

// MARK: - Codex app-server
private extension ConversationController {
    func sendCodex(_ outgoing: OutgoingMessage) async throws {
        if codexProcess?.isRunning != true || needsRespawn {
            // thread/start allocates an ID/path but does not persist a rollout until the first turn.
            // Retry a failed allocation through native thread/start, never manufacture an empty history.
            if codexThreadId != nil, codexResumeState.shouldStartFresh(at: sessionPath) {
                codexThreadId = nil
                sessionPath = nil
                hasSessionFile = false
            }
            codexProcess?.terminate()
            pumpTask?.cancel()
            let environment = try await AccountStore.shared.prepareCodexEnvironment()
            try Task.checkCancellation()
            let p = CodexProcess()
            try p.start(cwd: cwd, environment: environment)
            codexProcess = p
            needsRespawn = false
            pumpTask = Task { [weak self] in
                for await event in p.events {
                    guard let self, self.codexProcess === p else { break }
                    self.handleCodex(event, from: p)
                }
            }
            try await p.initialize()
            try Task.checkCancellation()
            var parameters: [String: JSONValue] = [
                "cwd": .string(cwd), "approvalPolicy": .string(codexApprovalPolicy), "approvalsReviewer": .string("user"),
                "sandbox": .string(settings.permissionMode == "bypassPermissions" ? "danger-full-access" : settings.permissionMode == "plan" ? "read-only" : "workspace-write"),
            ]
            if let model = settings.model, !model.isEmpty { parameters["model"] = .string(model) }
            let response: JSONValue
            if let thread = codexThreadId {
                parameters["threadId"] = .string(thread)
                // Pass the native rollout path to app-server. It owns locking, resume, and persistence;
                // the shell never creates another same-ID transcript or reconstructs model context.
                if let sessionPath { parameters["path"] = .string(sessionPath) }
                response = try await p.request("thread/resume", params: .object(parameters))
            } else {
                response = try await p.request("thread/start", params: .object(parameters))
            }
            guard let thread = response["thread"]?["id"]?.string else {
                throw CodexProcess.Failure(message: "Codex 未返回会话编号。")
            }
            codexThreadId = thread
            sessionModel = response["model"]?.string
            sessionPermissionMode = settings.permissionMode
            sessionPath = response["thread"]?["path"]?.string ?? sessionPath
            hasSessionFile = codexResumeState.observePersistence(at: sessionPath) || codexResumeState.established
            let previousId = id
            id = CodexHistory.key(thread)
            if previousId != id { onSessionStarted?(self, previousId) }
            // Fetch actual available models from this account; no hardcoded model assumptions.
            if let result = try? await p.request("model/list", params: .object(["includeHidden": .bool(false)]), timeout: .seconds(15)) {
                codexModels = result["data"]?.array?.compactMap(CodexModelOption.parse) ?? []
            }
        }
        try Task.checkCancellation()
        guard !stopRequested, let p = codexProcess, let thread = codexThreadId else { throw CancellationError() }
        var inputs: [JSONValue] = [.object(["type": .string("text"), "text": .string(outgoing.wireText), "text_elements": .array([])])]
        for image in outgoing.imageBlocks {
            if let data = image["source"]?["data"]?.string, let mime = image["source"]?["media_type"]?.string {
                inputs.append(.object(["type": .string("image"), "url": .string("data:\(mime);base64,\(data)")]))
            }
        }
        var params: [String: JSONValue] = ["threadId": .string(thread), "input": .array(inputs), "approvalPolicy": .string(codexApprovalPolicy)]
        if let model = settings.model, !model.isEmpty { params["model"] = .string(model) }
        if let effort = settings.effort, !effort.isEmpty { params["effort"] = .string(effort) }
        let result = try await p.request("turn/start", params: .object(params))
        hasSessionFile = codexResumeState.observePersistence(at: sessionPath) || codexResumeState.established
        // Completion notifications may precede this response for very short turns.
        if isWorking { codexTurnId = result["turn"]?["id"]?.string ?? codexTurnId }
        if stopRequested, isWorking { stop() }
    }

    var codexApprovalPolicy: String {
        if settings.permissionMode == "bypassPermissions" { return "never" }
        return settings.permissionMode == "manual" || settings.permissionMode == "default" ? "untrusted" : "on-request"
    }

    func handleCodex(_ event: JSONValue, from p: CodexProcess) {
        guard let method = event["method"]?.string else { return }
        let params = event["params"] ?? .object([:])
        if let thread = params["threadId"]?.string, let active = codexThreadId, thread != active { return }
        if let turn = params["turnId"]?.string, let active = codexTurnId, turn != active { return }
        if method == "turn/completed", let turn = params["turn"]?["id"]?.string,
           let active = codexTurnId, turn != active { return }
        if let requestId = event["id"] {
            if let request = CodexEvents.permission(id: requestId, method: method, params: params) {
                codexRequests[request.id] = (requestId, method, params)
                pendingPermissions.append(request)
                statusText = request.toolName == "AskUserQuestion" ? "等待你的回答" : "等待你的批准"
            } else {
                p.reject(id: requestId, method: method)
                working.append(.note("Codex 请求了尚未支持的交互：\(method)。请求已拒绝。", level: "warn"))
                flushNow()
            }
            return
        }
        switch method {
        case "turn/started":
            codexTurnId = params["turn"]?["id"]?.string
            openTurnIfNeeded()
        case "item/started", "item/completed":
            guard let item = params["item"], var block = CodexEvents.block(item, done: method == "item/completed") else { return }
            openTurnIfNeeded()
            if hasBlock(block.id) {
                mutateBlock(block.id) { old in
                    if block.text.isEmpty { block.text = old.text }
                    if block.tool?.result == nil { block.tool?.result = old.tool?.result }
                    let started = old.tool?.startedAt ?? block.tool?.startedAt
                    block.tool?.startedAt = started
                    old = block
                }
            } else { mutateTurn { $0.blocks.append(block) } }
            statusText = block.kind == .tool ? "正在运行 \(block.tool?.name ?? "工具")…" : block.kind == .thinking ? "正在思考…" : "正在回答…"
            scheduleFlush()
        case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/plan/delta":
            guard let id = params["itemId"]?.string else { return }
            let delta = params["delta"]?.string ?? ""
            openTurnIfNeeded()
            if !hasBlock(id) {
                mutateTurn { $0.blocks.append(Block(id: id, kind: method.contains("reasoning") ? .thinking : .text)) }
            }
            mutateBlock(id) { $0.text += delta }
            scheduleFlush()
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            guard let id = params["itemId"]?.string else { return }
            mutateBlock(id) { block in
                let result = String(((block.tool?.result ?? "") + (params["delta"]?.string ?? "")).suffix(40_000))
                block.tool?.result = result
            }
            scheduleFlush()
        case "turn/completed":
            let turn = params["turn"] ?? .object([:])
            let status = turn["status"]?.string ?? "completed"
            if status == "completed" || status == "interrupted" { codexResumeState.recordCompletedTurn() }
            hasSessionFile = codexResumeState.observePersistence(at: sessionPath) || codexResumeState.established
            if status == "interrupted" { working.append(.note("已停止")) }
            pendingPermissions = []
            codexRequests = [:]
            codexTurnId = nil
            finishTurn(with: .object(["is_error": .bool(status == "failed"), "stop_reason": .string(status),
                                      "result": turn["error"]?["message"] ?? .string("")]))
        case "error":
            if params["willRetry"]?.bool == true { statusText = "Codex 正在重试…" }
            else {
                // A late completion from this failed process must never close a subsequent turn.
                p.terminate()
                codexProcess = nil
                codexTurnId = nil
                fail(params["error"]?["message"]?.string ?? params["message"]?.string ?? "Codex 请求失败")
            }
        case "serverRequest/resolved":
            if let id = params["requestId"] {
                let key = "codex-rpc:" + id.serialized()
                codexRequests[key] = nil
                pendingPermissions.removeAll { $0.id == key }
            }
        case "claudex/exited":
            codexProcess = nil
            if isWorking { fail("Codex 进程退出（代码 \(params["code"]?.int ?? -1)）。\n\(p.stderrTail)") }
        default: break
        }
    }

    func respondCodex(_ request: PermissionRequest, allow: Bool, always: Bool) {
        guard let pending = codexRequests.removeValue(forKey: request.id) else { return }
        codexProcess?.reply(id: pending.id, result: CodexEvents.approvalResult(method: pending.method, params: pending.params, allow: allow, always: always))
        statusText = allow ? "正在继续…" : "操作已拒绝，正在继续…"
    }

    func answerCodex(_ request: PermissionRequest, answers: [String: String]) {
        guard let pending = codexRequests.removeValue(forKey: request.id) else { return }
        codexProcess?.reply(id: pending.id, result: CodexEvents.questionResult(params: pending.params, answers: answers))
        statusText = "正在思考…"
    }

    func finishStopped() {
        if isWorking {
            pendingPermissions = []
            codexRequests = [:]
            working.append(.note("已停止"))
            finishTurn(with: .object(["is_error": .bool(false), "stop_reason": .string("interrupted")]))
        }
    }
}
