import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(ThreadStore.self) private var store
    @Environment(AccountStore.self) private var accounts
    var onToggleSidebar: () -> Void = {}
    @AppStorage("workspacePinnedThreads") private var pinnedData = "[]"
    @State private var expandedProjects: Set<String> = []
    @State private var recentLimit = 8
    @State private var searching = false
    @State private var renaming: ThreadSummary?
    @State private var renameText = ""
    @FocusState private var searchFocused: Bool

    private var pinnedIDs: [String] { (try? JSONDecoder().decode([String].self, from: Data(pinnedData.utf8))) ?? [] }
    private var allThreads: [ThreadSummary] { store.groups.flatMap(\.threads).sorted { $0.updatedAt > $1.updatedAt } }
    private var pinned: [ThreadSummary] { pinnedIDs.compactMap { id in allThreads.first { $0.id == id } } }
    private var recent: [ThreadSummary] { allThreads.filter { !pinnedIDs.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 76)
                Button(action: onToggleSidebar) { WorkspaceIcon(.sidebar) }
                    .buttonStyle(WorkspaceIconButtonStyle())
                    .help("收起侧栏").accessibilityLabel("收起侧栏")
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.toolbarHeight)
            .background(WindowDragRegion())
            VStack(spacing: 0) {
                navigationRow("新聊天", icon: .compose, shortcut: "⌘N") { store.newThread() }
                    .contextMenu {
                        Button("新建 Claude 对话") { store.newThread(engine: .claude) }
                        Button("新建 Codex 对话") { store.newThread(engine: .codex) }
                        Divider()
                        Button("选择项目文件夹…") { store.newThreadPickingFolder() }
                    }
                navigationRow("搜索对话", icon: .search, shortcut: "⌘K") {
                    searching.toggle(); searchFocused = searching
                    if !searching { store.query = "" }
                }.keyboardShortcut("k", modifiers: .command)
                if searching || !store.query.isEmpty { searchField.padding(.top, 4) }
            }.padding(.horizontal, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !store.query.isEmpty {
                            sectionTitle("搜索结果")
                            ForEach(allThreads) { threadRow($0) }
                            if allThreads.isEmpty { emptyLabel("没有找到对话") }
                        } else {
                            if !pinned.isEmpty {
                                sectionTitle("已固定")
                                ForEach(pinned) { threadRow($0) }
                            }
                            HStack(spacing: 4) {
                                Text("最近").font(.system(size: 14, weight: .medium))
                                Spacer()
                                if store.isScanning { ProgressView().controlSize(.mini) }
                                else {
                                    Menu {
                                        Button("刷新对话列表") { Task { await store.refresh() } }
                                        Button("显示全部对话") { recentLimit = max(8, recent.count) }
                                    } label: { WorkspaceIcon(.more) }
                                        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
                                        .accessibilityLabel("最近对话选项")
                                }
                            }
                            .foregroundStyle(Theme.textTertiary.opacity(0.75))
                            .padding(.vertical, 2)
                            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
                            ForEach(Array(recent.prefix(recentLimit))) { threadRow($0) }
                            if recent.isEmpty { emptyLabel("还没有对话") }
                            if recent.count > recentLimit {
                                Button("显示更多") { recentLimit += 12 }
                                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                                    .buttonStyle(.plain).padding(.horizontal, 8).frame(height: 30)
                            }
                            HStack {
                                Text("项目").font(.system(size: 14, weight: .medium))
                                Spacer()
                                Button { store.newThreadPickingFolder() } label: { WorkspaceIcon(.plus) }
                                    .buttonStyle(.plain).help("打开项目文件夹")
                                    .accessibilityLabel("打开项目文件夹")
                            }
                            .foregroundStyle(Theme.textTertiary.opacity(0.75))
                            .padding(.vertical, 2)
                            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
                            ForEach(store.groups) { project($0) }
                            if store.groups.isEmpty { emptyLabel("打开文件夹开始") }
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                .onChange(of: store.selectedId) { _, id in
                    if let id, allThreads.contains(where: { $0.id == id }) { proxy.scrollTo("thread:" + id, anchor: .center) }
                }
            }
            if store.updateStatus.failed && !store.updateBannerDismissed { UpdateFailedBanner() }
            AccountFooter()
        }
        .background(Theme.sidebar)
        .onAppear { if let cwd = store.selectedController?.cwd { expandedProjects.insert(cwd) } }
        .sheet(item: Binding(get: { accounts.loginSession }, set: { if $0 == nil { accounts.loginSession = nil } })) { AccountLoginSheet(session: $0) }
        .sheet(isPresented: Binding(get: { accounts.addingProvider }, set: { accounts.addingProvider = $0 })) { ProviderAddSheet() }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $renameText)
            Button("保存") { if let thread = renaming { store.rename(thread.id, to: renameText) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    private func navigationRow(_ title: String, icon: WorkspaceIcon.Kind, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                WorkspaceIcon(icon)
                Text(title).font(.system(size: 13))
                Spacer()
                Text(shortcut).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 8).frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(SidebarCellStyle())
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            TextField("搜索标题或项目", text: Binding(get: { store.query }, set: { store.query = $0 }))
                .textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                .onExitCommand { store.query = ""; searching = false }
            Button { store.query = ""; searching = false } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }.buttonStyle(.plain).accessibilityLabel("关闭搜索")
        }
        .padding(.horizontal, 9).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textTertiary.opacity(0.75))
            .padding(.vertical, 2)
            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
    }
    private func emptyLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8).frame(height: 30)
    }
    private func project(_ group: ProjectGroup) -> some View {
        VStack(spacing: 0) {
            Button {
                if !expandedProjects.insert(group.id).inserted { expandedProjects.remove(group.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expandedProjects.contains(group.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium)).frame(width: 8)
                        .foregroundStyle(Theme.textTertiary)
                    WorkspaceIcon(.folder).foregroundStyle(Theme.textSecondary)
                    Text(group.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 8).frame(height: 30).contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(SidebarCellStyle())
            .help(ThreadStore.displayPath(for: group.cwd))
            .contextMenu {
                Button("新建 Claude 对话") { store.newThread(cwd: group.cwd, engine: .claude) }
                Button("新建 Codex 对话") { store.newThread(cwd: group.cwd, engine: .codex) }
            }
            if expandedProjects.contains(group.id) {
                ForEach(group.threads) { thread in threadRow(thread, nested: true) }
            }
        }
    }
    private func threadRow(_ thread: ThreadSummary, nested: Bool = false) -> some View {
        SidebarThreadCell(thread: thread, selected: store.selectedId == thread.id, nested: nested) { store.selectedId = thread.id }
            .id(nested ? "project:" + thread.id : "thread:" + thread.id)
            .contextMenu {
                Button(pinnedIDs.contains(thread.id) ? "取消固定" : "固定对话") { togglePin(thread.id) }
                if thread.engine == .codex {
                    Button("用 Claude 接管") { Task { await store.takeoverWithClaude(thread.id) } }
                        .disabled(store.takingOverId != nil || store.controllers[thread.id]?.showsActivity == true || store.controllers[thread.id]?.isLoadingHistory == true)
                }
                Divider()
                Button("重命名…") { renameText = thread.title; renaming = thread }
                Button("复制会话 ID") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(thread.id, forType: .string)
                }
                Button("在访达中显示目录") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: thread.cwd)]) }
                Divider()
                Button("从列表中移除") { store.hide(thread.id) }
            }
    }
    private func togglePin(_ id: String) {
        var ids = pinnedIDs
        if ids.contains(id) { ids.removeAll { $0 == id } } else { ids.insert(id, at: 0) }
        if let data = try? JSONEncoder().encode(ids), let text = String(data: data, encoding: .utf8) { pinnedData = text }
    }
}

private struct SidebarThreadCell: View {
    let thread: ThreadSummary
    let selected: Bool
    let nested: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if nested { Color.clear.frame(width: 16) }
                Text(thread.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if thread.liveStatus != nil { Circle().fill(Theme.live).frame(width: 5, height: 5) }
                Text(age).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 8).frame(height: 30).contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(SidebarCellStyle(selected: selected))
        .help("\(thread.engine.displayName) · \(ThreadStore.displayPath(for: thread.cwd))")
        .accessibilityLabel("\(thread.title)，\(thread.engine.displayName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var age: String {
        let seconds = max(0, Int(Date().timeIntervalSince(thread.updatedAt)))
        if seconds < 60 { return "现在" }
        if seconds < 3600 { return "\(seconds / 60)分" }
        if seconds < 86400 { return "\(seconds / 3600)时" }
        if seconds < 604800 { return "\(seconds / 86400)天" }
        return thread.updatedAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }
}

private struct SidebarCellStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        SidebarCellSurface(pressed: configuration.isPressed, selected: selected) { configuration.label }
    }
}
private struct SidebarCellSurface<Content: View>: View {
    let pressed: Bool
    let selected: Bool
    @ViewBuilder var content: Content
    @State private var hovered = false
    var body: some View {
        content.foregroundStyle(Theme.textPrimary)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected || pressed ? Theme.selectedFill : hovered ? Theme.hoverFill : Color.clear))
            .onHover { hovered = $0 }
    }
}
private struct UpdateFailedBanner: View {
    @Environment(ThreadStore.self) private var store
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Code 自更新失败")
                    .font(.system(size: 12, weight: .medium))
                Text("在终端里跑 `claude doctor` 排查")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { store.updateBannerDismissed = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("先关掉这条")
        }
        .foregroundStyle(Theme.warn)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            // 先铺一层不透明底，再叠 warn 淡色，免得侧栏列表从半透明里透出来。
            .fill(Theme.background)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.warn.opacity(hovering ? 0.16 : 0.11))))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.warn.opacity(0.28), lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(.bar)   // 整条页脚不透明，列表滚到底不会叠上来
        .onHover { hovering = $0 }
        .help("在终端里运行 claude doctor 查看原因（上次从 \(store.updateStatus.versionFrom ?? "?") 起更新失败）")
    }
}
