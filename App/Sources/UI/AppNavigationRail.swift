import SwiftUI

/// Persistent app navigation, independent of the selected conversation and secondary sidebar.
struct AppNavigationRail: View {
    @Environment(WorkspaceNavigation.self) private var navigation
    @Environment(ThreadStore.self) private var store
    @Environment(AccountStore.self) private var accounts

    private var accountName: String {
        if store.selectedController?.engine == .codex { return accounts.activeCodex?.shortName ?? "" }
        return accounts.activeProvider?.name ?? accounts.active?.shortName ?? ""
    }
    private var initials: String {
        let words = accountName.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
        if words.count > 1 { return String(words.prefix(2).compactMap(\.first)).uppercased() }
        return String(accountName.prefix(2)).uppercased()
    }

    var body: some View {
        VStack(spacing: 8) {
            destination(.home, title: "首页", symbol: "house", selectedSymbol: "house.fill", size: 20)
            destination(.history, title: "历史", symbol: "clock", size: 19)
            destination(.library, title: "资料库", symbol: "books.vertical", size: 20)
            destination(.images, title: "图片", symbol: "photo.on.rectangle.angled", size: 20)
            destination(.apps, title: "应用", symbol: "at", size: 20)
            Menu {
                Button("设置与账号") { navigation.visit(.settings) }
                Button("查看历史") { navigation.visit(.history) }
                Divider()
                Button("刷新对话列表") { Task { await store.refresh() } }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(RailButtonStyle())
            .help("更多").accessibilityLabel("更多")
            Spacer(minLength: 16)
            Button { navigation.visit(.settings) } label: {
                Image(systemName: "questionmark.circle").font(.system(size: 17, weight: .regular))
            }
            .buttonStyle(RailButtonStyle(selected: navigation.route == .settings))
            .help("帮助与设置").accessibilityLabel("帮助与设置")
            Menu { AccountMenuItems() } label: {
                ZStack {
                    Circle().fill(Theme.dynamic("#8B9797", "#667373"))
                    if initials.isEmpty {
                        Image(systemName: "person.fill").font(.system(size: 11)).foregroundStyle(.white)
                    } else {
                        Text(initials).font(.system(size: 9, weight: .medium)).foregroundStyle(.white)
                    }
                }
                .frame(width: 24, height: 24)
                .overlay(alignment: .bottomTrailing) {
                    if accounts.busy != nil {
                        ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
                    }
                }
                .frame(width: 36, height: 36)
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(RailButtonStyle())
            .help(accounts.switchNote ?? (accountName.isEmpty ? "账号与登录态" : "\(accountName) · 账号与登录态"))
            .accessibilityLabel("账号与登录态\(accountName.isEmpty ? "" : "：" + accountName)")
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(width: 52)
        .frame(maxHeight: .infinity)
        .background(Theme.dynamic("#F5F5F5", "#141414"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("应用导航")
    }

    private func destination(_ route: WorkspaceRoute, title: String, symbol: String, selectedSymbol: String? = nil, size: CGFloat) -> some View {
        let selected = navigation.route == route
        return Button { navigation.visit(route, threadID: route == .home ? store.selectedId : nil) } label: {
            Image(systemName: selected ? (selectedSymbol ?? symbol) : symbol)
                .font(.system(size: size, weight: .regular))
        }
        .buttonStyle(RailButtonStyle(selected: selected))
        .help(title).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct RailButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        RailButtonSurface(selected: selected, pressed: configuration.isPressed) { configuration.label }
            .opacity(enabled ? 1 : 0.4)
    }
}
private struct RailButtonSurface<Content: View>: View {
    let selected: Bool
    let pressed: Bool
    @ViewBuilder var content: Content
    @State private var hovered = false
    var body: some View {
        content
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected || pressed ? Theme.selectedFill : hovered ? Theme.hoverFill : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovered = $0 }
    }
}
