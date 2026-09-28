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
            HStack(spacing: 9) {
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.chipFill))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 3)
                if accounts.busy != nil { ProgressView().controlSize(.mini) }
                else { Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Theme.textSecondary) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.chipFill : Color.clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
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
    private var accounts: AccountStore { AccountStore.shared }
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
            Text("Codex CLI 与 Codex App 共用登录态")
        }
        .disabled((!accounts.canPushToTerminal && !accounts.canPushToCodexApp) || accounts.busy != nil)
        Menu("推送至 Codex App") {
            Text("将所选 Codex 登录态写入本机 Codex 配置")
            Text("同时影响 Codex CLI；Codex App 可能需要重启")
            Button("推送 \(accounts.activeCodex?.shortName ?? "当前账号") 至 Codex App") {
                Task { await accounts.pushToCodexApp() }
            }
        }
        .disabled(!accounts.canPushToCodexApp || accounts.busy != nil)
        if accounts.hasPushBackup {
            Button("撤回上次推送") { Task { await accounts.rollbackLastPush() } }
                .disabled(accounts.busy != nil)
        }
        Divider()
        Button("保存本机登录态（Claude / GLM / Codex）") { Task { await accounts.importLocalAccounts() } }
            .disabled(accounts.busy != nil)
        let adding = accounts.loginSession != nil || accounts.addingProvider || accounts.busy != nil
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
            Text("已在浏览器打开 Claude 的登录页。用要添加的账号登录后，页面会给一串授权码，贴到下面。\n终端登录态保持不变；登录成功后在 Claudex Shell 内切换到新账号。")
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

            TextField("授权码", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .focused($codeFocused)
                .disabled(!canSubmit)
                .onSubmit(submit)

            HStack {
                Button("重新打开登录页") { session.openBrowser() }
                    .disabled(session.loginURL == nil)
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
