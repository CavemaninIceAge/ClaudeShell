import AppKit
import SwiftUI

/// Account selection is private to this app; publishing a login is a separate named action.
struct AccountFooter: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(ThreadStore.self) private var store
    @State private var hovering = false
    @State private var showingError = false
    private var isCodex: Bool { store.selectedController?.engine == .codex }
    private var title: String {
        if isCodex { return accounts.activeCodex?.email ?? "选择 Codex 账号" }
        return accounts.activeProvider?.name ?? accounts.active?.email ?? "添加账号"
    }
    private var subtitle: String {
        if accounts.busy != nil { return "正在处理账号…" }
        if let note = accounts.switchNote { return note }
        return "\(isCodex ? "Codex" : (accounts.activeProvider == nil ? "Claude" : "GLM / API")) · 仅此 App"
    }
    var body: some View {
        Menu { AccountMenuItems() } label: {
            HStack(spacing: 8) {
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.chipFill))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                    if accounts.busy != nil || accounts.switchNote != nil {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 3)
                if accounts.busy != nil { ProgressView().controlSize(.mini) }
                else { WorkspaceIcon(.more).foregroundStyle(Theme.textTertiary) }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Theme.hoverFill : Color.clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Theme.sidebar)
        .help(accounts.switchNote ?? "切换只影响 Claudex Shell。需要同步登录态时，选择「推送至终端」或「推送至 Codex App」。")
        .onChange(of: accounts.lastError) { _, new in showingError = new != nil }
        .alert("账号操作未完成", isPresented: $showingError) {
            Button("好") { accounts.lastError = nil }
        } message: { Text(accounts.lastError ?? "") }
    }
}

/// Shared by the native account menu and sidebar. Pushes explicitly describe their destination.
struct AccountMenuItems: View {
    @Environment(AccountStore.self) private var accounts
    var body: some View {
        Text("切换账号 · 仅在 Claudex Shell 内生效")
        Divider()
        Text("Claude")
        if accounts.accounts.isEmpty { Text("尚未保存 Claude 登录态") }
        ForEach(Array(accounts.accounts.enumerated()), id: \.element.id) { index, acc in
            Toggle(isOn: Binding(
                get: { accounts.activeProviderId == nil && acc.id == accounts.activeId },
                set: { on in if on { Task { await accounts.switchTo(acc.id) } } }
            )) { Text(acc.planLabel.map { "\(acc.email)  ·  \($0)" } ?? acc.email) }
            .modifier(AccountShortcut(index: index))
            .disabled(accounts.busy != nil)
        }
        if !accounts.providers.isEmpty {
            Divider()
            Text("GLM / API 提供方")
            ForEach(Array(accounts.providers.enumerated()), id: \.element.id) { index, p in
                Toggle(isOn: Binding(
                    get: { p.id == accounts.activeProviderId },
                    set: { on in Task { on ? await accounts.switchToProvider(p.id) : await accounts.deactivateProvider() } }
                )) { Text("\(p.name)  ·  \(p.model ?? p.host)") }
                .modifier(AccountShortcut(index: accounts.accounts.count + index))
                .disabled(accounts.busy != nil)
            }
        }
        Divider()
        Text("Codex")
        if accounts.codexAccounts.isEmpty { Text("尚未保存 Codex 登录态") }
        ForEach(accounts.codexAccounts) { acc in
            Toggle(isOn: Binding(
                get: { acc.id == accounts.activeCodexId },
                set: { on in if on { Task { await accounts.switchToCodex(acc.id) } } }
            )) { Text(acc.planLabel.map { "\(acc.email)  ·  \($0)" } ?? acc.email) }
            .disabled(accounts.busy != nil)
        }
        Divider()
        Menu("推送至终端") {
            Text("将所选 Claude / GLM 登录态写入终端共享配置")
            Text("原登录态会先备份，可在下方撤回")
            Button("推送 \(accounts.activeProvider?.name ?? accounts.active?.shortName ?? "Claude / GLM") 至 Claude Code") {
                Task { await accounts.pushToTerminal() }
            }
            .disabled(!accounts.canPushToTerminal)
            Divider()
            Button("推送 \(accounts.activeCodex?.shortName ?? "Codex") 至 Codex CLI") {
                Task { await accounts.pushCodexToTerminal() }
            }
            .disabled(!accounts.canPushToCodexApp)
            Text("仅更新登录文件；不会切换运行中的 Codex App")
        }
        .disabled((!accounts.canPushToTerminal && !accounts.canPushToCodexApp) || accounts.busy != nil)
        Menu("推送至 Codex App") {
            Text("退出桌面端 → 写入并校验 → 后台重新启动")
            Button("推送 \(accounts.activeCodex?.shortName ?? "当前账号") 并重启 Codex App…") { accounts.requestCodexDesktopPush() }
        }
        .disabled(!accounts.canPushToCodexApp || accounts.busy != nil)
        if let status = accounts.codexPushStatus { Text(status) }
        if accounts.hasPushBackup {
            Button("撤回上次推送") { Task { await accounts.rollbackLastPush() } }
                .disabled(accounts.busy != nil)
        }
        Divider()
        Button("保存本机登录态（Claude / GLM / Codex）") { Task { await accounts.importLocalAccounts() } }
            .disabled(accounts.busy != nil)
        let adding = accounts.loginSession != nil || accounts.codexLoginSession != nil || accounts.addingProvider || accounts.busy != nil
        Button("添加 Codex 账号…") { accounts.beginCodexLogin() }.disabled(adding)
        Button("添加 Claude 账号…") { accounts.beginLogin() }.disabled(adding)
        Button("添加 GLM / API 提供方…") { accounts.addingProvider = true }.disabled(adding)
        let removable = accounts.accounts.filter { $0.id != accounts.activeId }
        let removableProviders = accounts.providers.filter { $0.id != accounts.activeProviderId }
        let removableCodex = accounts.codexAccounts.filter { $0.id != accounts.activeCodexId }
        if !removable.isEmpty || !removableProviders.isEmpty || !removableCodex.isEmpty {
            Menu("移除保存的账号") {
                ForEach(removable) { acc in Button(acc.email) { Task { await accounts.remove(acc.id) } } }
                ForEach(removableProviders) { p in Button(p.name) { Task { await accounts.remove(p.id) } } }
                ForEach(removableCodex) { acc in Button("Codex · \(acc.email)") { Task { await accounts.removeCodex(acc.id) } } }
            }
            .disabled(accounts.busy != nil)
        }
    }
}

/// Captures the selected account before any external application or credential is changed.
struct CodexDesktopPushSheet: View {
    @Environment(AccountStore.self) private var accounts
    let account: CodexAccount
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("推送并重启 Codex App").font(.system(size: 20, weight: .semibold))
            Text(account.email).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
            Text("将正常退出 Codex / ChatGPT 桌面应用，写入并校验此账号的登录态，再在后台重新启动。Codex CLI 也会使用这个账号。")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Text("重启会中断桌面端正在运行的任务，包括其中的当前对话。请等任务结束后再继续。若桌面端拒绝退出，不会强制结束进程，也不会改写账号。")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { accounts.codexPushConfirmation = nil }.keyboardShortcut(.cancelAction)
                Button("推送并重启") {
                    accounts.codexPushConfirmation = nil
                    Task { await accounts.pushToCodexApp(account) }
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(28).frame(width: 460)
    }
}

/// 「添加 API 提供方」面板：中转站 / GLM 这类走 ANTHROPIC_BASE_URL 的后端。密钥进钥匙串，保存后直接切过去。
struct ProviderAddSheet: View {
    @Environment(AccountStore.self) private var accounts
    @State private var name = ""
    @State private var baseURL = ""
    @State private var secret = ""
    @State private var model = ""
    @State private var saving = false
    @State private var failure: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加 GLM / API 提供方")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("通过 Claude 引擎使用兼容的 GLM 或其他 API。密钥保存到本机钥匙串；选中后仅在 Claudex Shell 内生效。需要同步给终端时，再选择「推送至终端」。")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    label("名称")
                    TextField("例如 GLM", text: $name)
                }
                GridRow {
                    label("地址")
                    TextField("https://…（ANTHROPIC_BASE_URL）", text: $baseURL)
                        .font(.system(size: 12.5, design: .monospaced))
                }
                GridRow {
                    label("密钥")
                    SecureField("ANTHROPIC_AUTH_TOKEN", text: $secret)
                        .font(.system(size: 12.5, design: .monospaced))
                }
                GridRow {
                    label("模型")
                    TextField("可不填；非 Claude 模型才要，如 glm-5.3", text: $model)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(saving)

            if let failure {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Theme.danger)
                    Text(failure)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                // 保存中途取消拦不住已经在写的设置，干脆等它完。
                Button("取消") { accounts.addingProvider = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button("保存并切换") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saving || validationError != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.background)
        .interactiveDismissDisabled(saving)
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textSecondary)
            .gridColumnAlignment(.trailing)
    }

    private var trimmedURL: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private var validationError: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "填一个名称" }
        guard let url = URL(string: trimmedURL), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return "地址要以 https:// 开头" }
        if secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "填密钥" }
        return nil
    }

    private func save() {
        guard validationError == nil else { return }
        saving = true
        failure = nil
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let error = await accounts.addProvider(name: name.trimmingCharacters(in: .whitespaces),
                                                   baseURL: trimmedURL,
                                                   secret: secret.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   model: m.isEmpty ? nil : m)
            saving = false
            if let error { failure = error } else { accounts.addingProvider = false }
        }
    }
}

/// 前 9 个账号给 ⌃1…⌃9，菜单栏和侧栏菜单里都显示。
private struct AccountShortcut: ViewModifier {
    let index: Int
    func body(content: Content) -> some View {
        if index < 9 {
            content.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
        } else {
            content
        }
    }
}

/// 「添加账号」面板：浏览器里用另一个账号登录，把页面给的授权码贴回来。
struct AccountLoginSheet: View {
    let session: LoginSession
    @Environment(AccountStore.self) private var accounts
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加 Claude 账号")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("点击下方按钮打开官方认证页，用要添加的账号登录，再将授权码粘贴到这里。无需启动 Claude App 或终端；新登录态只保存到 Claudex Shell。")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                statusIcon
                Text(statusText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isFailed ? Theme.danger : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            SecureField("授权码", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .focused($codeFocused)
                .disabled(!canSubmit)
                .onSubmit(submit)

            HStack {
                Button("打开官方认证页") { session.openBrowser() }
                    .disabled(session.loginURL == nil)
                Button("复制链接") {
                    if let url = session.loginURL { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                }.disabled(session.loginURL == nil)
                Spacer()
                Button("取消") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("完成登录") { submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSubmit || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.background)
        .interactiveDismissDisabled(session.phase == .finishing)
        .onDisappear { session.cancel() }
        .onChange(of: session.phase) { _, phase in
            if phase == .waitingForCode { codeFocused = true }
        }
    }

    private var isFailed: Bool { if case .failed = session.phase { return true }; return false }
    private var canSubmit: Bool { session.phase == .waitingForCode || session.phase == .starting }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.phase {
        case .starting, .finishing:
            ProgressView().controlSize(.small)
        case .waitingForCode:
            Image(systemName: "safari").font(.system(size: 13)).foregroundStyle(Theme.iconMuted)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Theme.danger)
        }
    }

    private var statusText: String {
        switch session.phase {
        case .starting: return "正在启动 claude auth login…"
        case .waitingForCode: return "等待浏览器里的授权码"
        case .finishing: return "正在保存登录态…"
        case .failed(let message): return message
        }
    }

    private func submit() {
        guard canSubmit else { return }
        session.submit(code: code)
    }

    private func cancel() {
        session.cancel()
        accounts.loginSession = nil
    }
}

struct CodexLoginSheet: View {
    let session: CodexLoginSession
    @Environment(AccountStore.self) private var accounts
    @State private var method: CodexLoginMethod = .device
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加 Codex 账号").font(.system(size: 16, weight: .semibold))
            Text("在这里完成 Codex CLI 的原生登录，无需打开 Codex App 或终端。新登录态仅供 Claudex Shell 使用。")
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Picker("登录方式", selection: $method) {
                ForEach(CodexLoginMethod.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(session.isBusy)
            if method == .apiKey {
                SecureField("OpenAI API Key", text: $apiKey).textFieldStyle(.roundedBorder).disabled(session.isBusy)
                Text("通过标准输入交给本机 Codex；保存到钥匙串。不会加入命令参数或日志。")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            status
            if let code = session.deviceCode {
                HStack {
                    Text(code).font(.system(size: 24, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("复制设备码") { copy(code) }
                }
                Text("仅在你主动发起登录时输入此设备码。完成官方网页授权后，这里会自动保存账号。")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if let url = session.loginURL {
                HStack {
                    Button("打开官方认证页") { session.openAuthorizationPage() }
                    Button("复制链接") { copy(url.absoluteString) }
                }
            }
            HStack {
                Button("取消") { session.cancel(); accounts.codexLoginSession = nil }
                    .keyboardShortcut(.cancelAction).disabled(session.phase == .finishing)
                Spacer()
                Button(session.phase == .ready ? "开始登录" : "重新登录") {
                    let secret = apiKey; apiKey = ""
                    session.start(method: method, apiKey: secret)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(session.isBusy || (method == .apiKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 480).background(Theme.background)
        .interactiveDismissDisabled(session.phase == .finishing)
        .onDisappear { session.cancel(); apiKey = "" }
    }

    @ViewBuilder private var status: some View {
        switch session.phase {
        case .ready:
            Text(method == .device ? "点击开始后获取设备码，再在官方网页完成授权。" : "输入 API Key 后开始登录。")
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
        case .starting, .waitingForAuthorization, .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(session.phase == .starting ? "正在准备官方登录…" : session.phase == .finishing ? "正在保存登录态…" : "等待你在官方网页完成授权…")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

/// Embedded setup controls. Discovery happens only on the user's Detect/Save action, never while taking a snapshot.
struct EngineSetupSection: View {
    @Environment(ThreadStore.self) private var threads
    @State private var claudePath = ""
    @State private var codexPath = ""
    @State private var statuses: [EngineAvailability.Status] = []
    @State private var checking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("引擎可执行文件").font(.system(size: 14, weight: .medium))
            Text("自动查找本机 CLI 和桌面应用内置 CLI，无需运行原应用。可指定路径；留空恢复自动查找。")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            row(.claude, title: "Claude Code", path: $claudePath)
            row(.codex, title: "Codex", path: $codexPath)
            HStack {
                Button("重新检测") { Task { await refresh(reset: true) } }.disabled(checking)
                if checking { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear {
            claudePath = EngineAvailability.configuredPath(for: .claude)
            codexPath = EngineAvailability.configuredPath(for: .codex)
        }
    }

    private func row(_ engine: ConversationEngine, title: String, path: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
            HStack(spacing: 8) {
                TextField("自动查找，或输入可执行文件的完整路径", text: path).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced)).accessibilityLabel(title + " 可执行文件路径")
                Button("保存") {
                    do { try EngineAvailability.setConfiguredPath(path.wrappedValue, for: engine); failure = nil; Task { await refresh(reset: false) } }
                    catch { failure = error.localizedDescription }
                }.disabled(checking)
            }
            if let status = statuses.first(where: { $0.engine == engine }) {
                Text(status.executablePath.map { "已找到：" + $0 } ?? "未找到可执行文件。请安装对应 CLI，或指定已安装的路径。")
                    .font(.system(size: 11)).foregroundStyle(status.isAvailable ? Theme.textSecondary : Theme.warn)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refresh(reset: Bool) async {
        guard !checking else { return }
        checking = true
        statuses = await Task.detached(priority: .utility) {
            if reset { ShellEnvironment.resetDiscoveryCache() }
            return EngineAvailability.statuses()
        }.value
        await threads.refreshEngineAvailability()
        checking = false
    }
}
