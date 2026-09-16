import AppKit
import SwiftUI

/// 侧栏最底下那一行：当前账号（Codex 桌面版左下角的账号行）。点开是账号菜单——选一个就切，终端也跟着换。
struct AccountFooter: View {
    @Environment(AccountStore.self) private var accounts
    @State private var hovering = false
    @State private var showingError = false

    var body: some View {
        Menu {
            AccountMenuItems()
        } label: {
            row
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)   // 和更新提示条一样铺一层不透明底，列表滚到底不会叠上来
        .help(helpText)
        .onChange(of: accounts.lastError) { _, new in showingError = new != nil }
        .alert("账号切换", isPresented: $showingError) {
            Button("好") { accounts.lastError = nil }
        } message: {
            Text(accounts.lastError ?? "")
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if case .switching = accounts.busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(hovering ? Color.primary.opacity(0.07) : Color.clear))
        .contentShape(Rectangle())
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(Theme.chipFill)
            Text(initial)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(width: 22, height: 22)
    }

    private var initial: String {
        guard let a = accounts.active, let c = a.email.first else { return "?" }
        return String(c).uppercased()
    }

    private var title: String {
        if case .switching(let id) = accounts.busy, let t = accounts.accounts.first(where: { $0.id == id }) {
            return t.email
        }
        return accounts.active?.email ?? (accounts.isLoggedOut ? "未登录" : "账号")
    }

    private var subtitle: String {
        if case .switching = accounts.busy { return "正在切换…" }
        if let note = accounts.switchNote { return note }
        guard let a = accounts.active else {
            return accounts.isLoggedOut ? "添加一个账号登录" : "正在读取登录态…"
        }
        var parts: [String] = []
        if let plan = a.planLabel { parts.append(plan) }
        if accounts.accounts.count > 1 { parts.append("\(accounts.accounts.count) 个账号") }
        return parts.isEmpty ? a.orgName : parts.joined(separator: " · ")
    }

    private var helpText: String {
        guard let a = accounts.active else { return "在这里添加账号；添加后可在多个账号间切换，不必再去浏览器登录" }
        return "\(a.email) · \(a.orgName)\n切换会换掉本机的登录态：终端里已经开着的 Claude Code 也跟着换，下一次请求就用新账号，不用重开、不用重登"
    }
}

/// 账号菜单的条目，侧栏底部和菜单栏「账号」共用（菜单栏的 Commands 拿不到 environment，所以直接用单例）。
struct AccountMenuItems: View {
    private var accounts: AccountStore { AccountStore.shared }

    var body: some View {
        if accounts.accounts.isEmpty {
            Text(accounts.isLoggedOut ? "本机还没有登录" : "还没有保存的账号")
        }
        ForEach(Array(accounts.accounts.enumerated()), id: \.element.id) { index, acc in
            Toggle(isOn: Binding(
                get: { acc.id == accounts.activeId },
                set: { on in if on { Task { await accounts.switchTo(acc.id) } } }
            )) {
                Text(acc.planLabel.map { "\(acc.email)  ·  \($0)" } ?? acc.email)
            }
            .modifier(AccountShortcut(index: index))
        }
        Divider()
        Button("添加账号…") { accounts.beginLogin() }
            .disabled(accounts.loginSession != nil)
        let removable = accounts.accounts.filter { $0.id != accounts.activeId }
        if !removable.isEmpty {
            Menu("移除账号") {
                ForEach(removable) { acc in
                    Button(acc.email) { Task { await accounts.remove(acc.id) } }
                }
            }
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
            Text("添加账号")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("已在浏览器打开 Claude 的登录页。用要添加的账号登录后，页面会给一串授权码，贴到下面。\n当前账号的登录态不受影响；登录成功后会切到新账号。")
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
