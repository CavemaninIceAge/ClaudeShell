import AppKit
import Foundation
import Observation

struct ThreadSummary: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var cwd: String
    var createdAt: Date
    var updatedAt: Date
    var isDraft: Bool
    var liveStatus: String?
}

struct ProjectGroup: Identifiable, Hashable {
    var cwd: String
    var name: String
    var threads: [ThreadSummary]
    var id: String { cwd }
}

/// app 自己记的、会话文件里没有的东西。
struct ThreadOverride: Codable, Sendable, Equatable {
    var customTitle: String? = nil
    var settings: ThreadSettings? = nil
    var hidden = false
}

@MainActor
@Observable
final class ThreadStore {
    static let shared = ThreadStore()

    private(set) var records: [String: SessionRecord] = [:]
    private(set) var drafts: [String: ThreadSummary] = [:]
    private(set) var live: [String: String] = [:]
    private(set) var overrides: [String: ThreadOverride] = [:]
    private(set) var controllers: [String: ConversationController] = [:]
    private(set) var isScanning = false
    private(set) var claudeMissing = false
    /// 终端里的默认模型 / 强度（问 claude 本尊得来），给「跟随终端设置」「默认强度」显示具体值用。
    private(set) var terminalDefaults = ClaudeDefaults.Resolved() {
        didSet { if terminalDefaults != oldValue { pushDefaultsToControllers() } }
    }
    /// Claude Code 上次自更新失败了没：失败就在侧栏底部挂一条提示（和终端一样）。用户点掉就不再显示这一条。
    private(set) var updateStatus = UpdateStatus.Result(failed: false)
    var updateBannerDismissed = false
    var query = ""
    var defaultSettings = ThreadSettings()
    var selectedId: String? {
        didSet {
            TestLog.write("selectedId \(oldValue ?? "nil") -> \(selectedId ?? "nil")")
            if let selectedId { prepareController(for: selectedId) }
        }
    }

    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var liveTimer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Claude Shell", isDirectory: true)
    }
    private var cacheURL: URL { supportDir.appendingPathComponent("sessions-cache.json") }
    private var overridesURL: URL { supportDir.appendingPathComponent("threads.json") }
    private var defaultsData: Data? { UserDefaults.standard.data(forKey: "defaultThreadSettings") }

    // MARK: - 派生

    var selectedController: ConversationController? {
        guard let selectedId else { return nil }
        return controllers[selectedId]
    }

    var groups: [ProjectGroup] {
        // 还没开口的草稿不进列表（Codex 的做法）；发过第一条就立刻出现，不等磁盘扫描。
        var all: [ThreadSummary] = drafts.values.filter { controllers[$0.id]?.isDraft == false }
        for r in records.values where drafts[r.id] == nil {
            let o = overrides[r.id]
            if o?.hidden == true { continue }
            all.append(ThreadSummary(id: r.id, title: o?.customTitle ?? r.title, cwd: r.cwd,
                                     createdAt: r.createdAt, updatedAt: r.updatedAt,
                                     isDraft: false, liveStatus: live[r.id]))
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            all = all.filter { $0.title.lowercased().contains(q) || $0.cwd.lowercased().contains(q) }
        }
        let grouped = Dictionary(grouping: all, by: \.cwd)
        return grouped.map { cwd, threads in
            ProjectGroup(cwd: cwd, name: Self.displayName(for: cwd),
                         threads: threads.sorted { ($0.isDraft ? 1 : 0, $0.updatedAt) > ($1.isDraft ? 1 : 0, $1.updatedAt) })
        }.sorted { a, b in
            let ka = (a.threads.first?.isDraft == true ? 1 : 0, a.threads.first?.updatedAt ?? .distantPast)
            let kb = (b.threads.first?.isDraft == true ? 1 : 0, b.threads.first?.updatedAt ?? .distantPast)
            return ka > kb
        }
    }

    func summary(for id: String) -> ThreadSummary? {
        if let d = drafts[id] { return d }
        guard let r = records[id] else { return nil }
        return ThreadSummary(id: r.id, title: overrides[id]?.customTitle ?? r.title, cwd: r.cwd,
                             createdAt: r.createdAt, updatedAt: r.updatedAt, isDraft: false, liveStatus: live[id])
    }

    static func displayName(for cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    static func displayPath(for cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }

    // MARK: - 启动

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder.standard.decode([String: SessionRecord].self, from: data) {
            records = cached
        }
        if let data = try? Data(contentsOf: overridesURL),
           let saved = try? JSONDecoder.standard.decode([String: ThreadOverride].self, from: data) {
            overrides = saved
        }
        if let data = defaultsData, let saved = try? JSONDecoder.standard.decode(ThreadSettings.self, from: data) {
            defaultSettings = saved
        }
        // 一进来就是一个新对话页面（和 Codex 一样）。
        // -testCwd <目录>：起始的新对话直接开在这个目录（scratchpad 里的会话不进侧栏列表），得在任何视图出现之前定下来。
        if selectedId == nil { newThread(cwd: UserDefaults.standard.string(forKey: "testCwd").flatMap { $0.isEmpty ? nil : $0 }) }
        // 找 claude 要跑一次登录 shell，放后台；找到了顺手问它终端默认的模型 / 强度。
        Task.detached(priority: .utility) {
            let missing = ShellEnvironment.claudeExecutable() == nil
            await MainActor.run { ThreadStore.shared.claudeMissing = missing }
            let resolved = ClaudeDefaults.probe()
            await MainActor.run { ThreadStore.shared.terminalDefaults = resolved }
        }
        updateStatus = UpdateStatus.read()
        // 账号：读清单，收录当前登录的账号；切换成功后把自己起的 claude 进程收掉。
        AccountStore.shared.load()
        AccountStore.shared.onSwitched = { [weak self] _ in
            self?.controllers.values.forEach { $0.dropProcess() }
        }
        Task { await AccountStore.shared.sync() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await ThreadStore.shared.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { _ in
            Task { @MainActor in await ThreadStore.shared.refresh() }
        }
        // 终端里的会话开着没、忙不忙，两秒看一眼登记表（十来个小文件），侧栏绿点和旁观状态都靠它。
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in ThreadStore.shared.refreshLive() }
        }
        await refresh()
        runTestHooksIfNeeded()
    }

    /// 自动化验证用：`open -n "Claude Shell.app" --args -testPrompt "…" -testModel haiku -testMode manual`
    /// 会在启动后把这句话直接发出去。不发全局键鼠事件，只走 app 内部。
    private func runTestHooksIfNeeded() {
        let defaults = UserDefaults.standard
        if let sel = defaults.string(forKey: "testSelect"), records[sel] != nil {
            selectedId = sel
        }
        // -testBeginLogin 1：启动后直接弹「添加账号」面板（会真的起 claude auth login、开浏览器）。
        if defaults.bool(forKey: "testBeginLogin") { AccountStore.shared.beginLogin() }
        // -testSwitchAccount <accountId>：启动后切到这个账号（配合 -testClaudeConfigDir 在沙盒里验证切换）。
        if let accountId = defaults.string(forKey: "testSwitchAccount"), !accountId.isEmpty {
            Task {
                await AccountStore.shared.sync()
                await AccountStore.shared.switchTo(accountId)
                TestLog.write("testSwitchAccount done active=\(AccountStore.shared.activeId ?? "nil") error=\(AccountStore.shared.lastError ?? "-")")
            }
        }
        guard let id = selectedId else { return }
        // -testAttach "/a:/b"：启动后把这些文件 / 照片挂到输入框上（走 controller.attach，验附件条、发送格式与正文渲染）。
        // -testProviderDrop "/a:/b"：同上，但经 SwiftUI onDrop 那条 NSItemProvider 路径。
        var delay: Double = 0
        if let paths = defaults.string(forKey: "testAttach"), !paths.isEmpty {
            controllers[id]?.attach(urls: paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
            delay = 3
        }
        if let paths = defaults.string(forKey: "testProviderDrop"), !paths.isEmpty, let c = controllers[id] {
            let providers = paths.split(separator: ":").compactMap { NSItemProvider(contentsOf: URL(fileURLWithPath: String($0))) }
            TestLog.write("testProviderDrop handled=\(DropHandler.handle(providers, controller: c)) providers=\(providers.count)")
            delay = 3
        }
        guard let prompt = defaults.string(forKey: "testPrompt") else { return }
        // -testPromptDelay <秒>：等附件挂好（或输入框里的拖放 / 粘贴钩子跑完）再发；正文可以为空，只发附件。
        delay = max(delay, defaults.double(forKey: "testPromptDelay"))
        var s = defaultSettings
        // testModel / testEffort 写 "terminal" 表示跟随终端设置（清掉本对话的指定）。
        if let model = defaults.string(forKey: "testModel"), !model.isEmpty { s.model = model == "terminal" ? nil : model }
        if let mode = defaults.string(forKey: "testMode"), !mode.isEmpty { s.permissionMode = mode }
        if let effort = defaults.string(forKey: "testEffort"), !effort.isEmpty { s.effort = effort == "terminal" ? nil : effort }
        // 只给这一次测试用，不写进"下次新对话的默认"。
        controllers[id]?.settings = s
        if controllers[id]?.isLiveInTerminal == true {
            // 选中的是终端里开着的会话：等历史读完再投递，看那边回答能不能同步回来。
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(2, delay)))
                self?.controllers[id]?.sendToTerminal(prompt)
            }
        } else if delay > 0 {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                TestLog.write("testPrompt send with \(self?.controllers[id]?.attachments.count ?? -1) attachments")
                self?.controllers[id]?.send(prompt)
            }
        } else {
            controllers[id]?.send(prompt)
        }
    }

    func refresh() async {
        guard !isScanning else { return }
        TestLog.write("refresh begin")
        isScanning = true
        let previous = records
        let result = await Task.detached(priority: .utility) {
            (SessionIndex.scan(previous: previous), SessionIndex.liveSessions())
        }.value
        records = result.0
        applyLive(result.1)
        // settings.json 改过（终端里 /model、/effort 持久化了）就重新问一次默认值。
        if let modified = ClaudeDefaults.settingsModifiedDate(), modified != terminalDefaults.settingsModified,
           terminalDefaults.settingsModified != nil {
            let resolved = await Task.detached(priority: .utility) { ClaudeDefaults.probe() }.value
            terminalDefaults = resolved
        }
        // 草稿一旦在磁盘上有了文件，就从草稿名单里退出。
        for id in drafts.keys where records[id] != nil { drafts[id] = nil }
        isScanning = false
        // 终端里 /login 换过账号、或令牌刷新过，都在这一趟收进账号清单。
        await AccountStore.shared.sync()
        TestLog.write("refresh end, records=\(records.count) drafts=\(drafts.count)")
        if let data = try? JSONEncoder.standard.encode(records) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    func refreshLive() {
        applyLive(SessionIndex.liveSessions())
    }

    private func applyLive(_ new: [String: String]) {
        if new != live { live = new }
        for (id, c) in controllers { c.setTerminalStatus(new[id]) }
        let latest = UpdateStatus.read()
        if latest != updateStatus {
            updateStatus = latest
            if !latest.failed { updateBannerDismissed = false }   // 装好了就重置，下次再失败还会提示
        }
    }

    private func pushDefaultsToControllers() {
        for c in controllers.values { c.terminalDefaultEffort = terminalDefaults.effort }
    }

    // MARK: - 对话

    @discardableResult
    func newThread(cwd: String? = nil) -> String {
        let dir = cwd ?? NSHomeDirectory()
        // 当前已经是一个还没开口的新对话，就不再堆一个。
        if let sid = selectedId, let d = drafts[sid], controllers[sid]?.isDraft ?? true {
            if d.cwd == dir { return sid }
            setDraftCwd(sid, cwd: dir)
            return sid
        }
        let id = UUID().uuidString.lowercased()
        let now = Date()
        drafts[id] = ThreadSummary(id: id, title: "新对话", cwd: dir, createdAt: now, updatedAt: now, isDraft: true, liveStatus: nil)
        selectedId = id
        return id
    }

    func newThreadPickingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "在这里开始对话"
        panel.message = "选择 Claude 的工作目录"
        if panel.runModal() == .OK, let url = panel.url {
            newThread(cwd: url.path)
        }
    }

    func setDraftCwd(_ id: String, cwd: String) {
        guard var d = drafts[id] else { return }
        d.cwd = cwd
        drafts[id] = d
        controllers[id]?.terminate()
        controllers[id] = nil
        prepareController(for: id)
    }

    func prepareController(for id: String) {
        if controllers[id] != nil { return }
        guard let cwd = drafts[id]?.cwd ?? records[id]?.cwd else { return }
        let settings = overrides[id]?.settings ?? defaultSettings
        let c = ConversationController(id: id, cwd: cwd, settings: settings, hasSessionFile: records[id] != nil)
        c.onTurnFinished = { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        c.onFirstMessage = { [weak self] controller, text in
            guard let self, var d = self.drafts[controller.id] else { return }
            d.title = TitleMaker.title(from: text)
            d.updatedAt = Date()
            self.drafts[controller.id] = d
        }
        c.setTerminalStatus(live[id])
        c.terminalDefaultEffort = terminalDefaults.effort
        controllers[id] = c
    }

    func rename(_ id: String, to title: String) {
        var o = overrides[id] ?? ThreadOverride()
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        o.customTitle = t.isEmpty ? nil : t
        overrides[id] = o
        if var d = drafts[id], !t.isEmpty { d.title = t; drafts[id] = d }
        saveOverrides()
    }

    func hide(_ id: String) {
        if drafts[id] != nil {
            drafts[id] = nil
        } else {
            var o = overrides[id] ?? ThreadOverride()
            o.hidden = true
            overrides[id] = o
            saveOverrides()
        }
        controllers[id]?.terminate()
        controllers[id] = nil
        if selectedId == id { selectedId = nil; newThread() }
    }

    func updateSettings(_ id: String, _ settings: ThreadSettings) {
        var o = overrides[id] ?? ThreadOverride()
        o.settings = settings
        overrides[id] = o
        controllers[id]?.settings = settings
        defaultSettings = settings   // 下一个新对话沿用这次的选择
        if let data = try? JSONEncoder.standard.encode(settings) {
            UserDefaults.standard.set(data, forKey: "defaultThreadSettings")
        }
        saveOverrides()
    }

    private func saveOverrides() {
        if let data = try? JSONEncoder.standard.encode(overrides) {
            try? data.write(to: overridesURL, options: .atomic)
        }
    }

    func terminateAll() {
        for c in controllers.values { c.terminate(immediately: true) }
    }
}

extension JSONEncoder {
    static let standard: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let standard: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}


/// 自动化验证用的日志：只有带 -testLog 启动时才写 /tmp/claude-shell-test.log。
enum TestLog {
    private static let enabled = UserDefaults.standard.bool(forKey: "testLog")
    static func write(_ message: String) {
        guard enabled else { return }
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/claude-shell-test.log") {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: "/tmp/claude-shell-test.log", atomically: true, encoding: .utf8)
        }
    }
}
