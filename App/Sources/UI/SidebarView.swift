import AppKit
import SwiftUI

/// The secondary conversation sidebar; the app-level navigation rail lives beside it.
struct SidebarView: View {
    @Environment(ThreadStore.self) private var store
    @Environment(WorkspaceNavigation.self) private var navigation
    var onToggleSidebar: () -> Void = {}
    @AppStorage("workspacePinnedThreads") private var pinnedData = "[]"
    @AppStorage("workspaceSidebarGrouping") private var grouping = "recents"
    @State private var expandedProjects: Set<String> = []
    @State private var allPinnedVisible = false
    @State private var notificationsPresented = false
    @State private var renaming: ThreadSummary?
    @State private var renameText = ""

    private var pinnedIDs: [String] { (try? JSONDecoder().decode([String].self, from: Data(pinnedData.utf8))) ?? [] }
    private var allThreads: [ThreadSummary] { store.groups.flatMap(\.threads).sorted { $0.updatedAt > $1.updatedAt } }
    private var pinned: [ThreadSummary] { pinnedIDs.compactMap { id in allThreads.first { $0.id == id } } }
    private var recent: [ThreadSummary] { allThreads.filter { !pinnedIDs.contains($0.id) } }
    private var workspaceEngine: ConversationEngine { store.selectedController?.engine ?? store.defaultSettings.engine }
    private var activityIDs: [String] {
        store.controllers.values.filter { !$0.pendingPermissions.isEmpty || $0.isWorking }
            .sorted { lhs, rhs in
                if lhs.pendingPermissions.isEmpty != rhs.pendingPermissions.isEmpty { return !lhs.pendingPermissions.isEmpty }
                return lhs.id < rhs.id
            }.map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Button { newThread() } label: {
                HStack(spacing: 8) {
                    WorkspaceIcon(.compose)
                    Text("New chat").font(.system(size: 14))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(SidebarCellStyle())
            .padding(.horizontal, 8).padding(.bottom, 8)
            .help("新聊天（⌘N）")
            .contextMenu {
                Button("新建 Claude 对话") { newThread(engine: .claude) }
                Button("新建 Codex 对话") { newThread(engine: .codex) }
                Divider()
                Button("选择项目文件夹…") { newThreadPickingFolder() }
            }
            Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !store.query.isEmpty {
                            listHeading("搜索结果")
                            ForEach(allThreads) { threadRow($0) }
                            if allThreads.isEmpty { emptyLabel("没有找到对话") }
                        } else {
                            if !pinned.isEmpty {
                                ForEach(Array(pinned.prefix(allPinnedVisible ? pinned.count : 5))) { threadRow($0, pinned: true) }
                                if pinned.count > 5 {
                                    Button(allPinnedVisible ? "Show less" : "Show more") { allPinnedVisible.toggle() }
                                        .font(.system(size: 14)).foregroundStyle(Theme.textTertiary)
                                        .buttonStyle(SidebarCellStyle())
                                        .padding(.leading, 32).frame(height: 31)
                                        .accessibilityLabel(allPinnedVisible ? "收起固定对话" : "显示全部固定对话")
                                }
                            }
                            recentHeader.padding(.top, pinned.isEmpty ? 14 : 26)
                            if grouping == "projects" {
                                ForEach(store.groups) { project($0) }
                                if store.groups.isEmpty { emptyLabel("选择项目文件夹开始") }
                            } else {
                                ForEach(recent) { threadRow($0) }
                                if recent.isEmpty { emptyLabel(store.isScanning ? "正在读取会话…" : "新的对话会显示在这里") }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 16)
                }
                .scrollIndicators(.automatic)
                .onChange(of: store.selectedId) { _, id in
                    if let id, allThreads.contains(where: { $0.id == id }) {
                        proxy.scrollTo("thread:" + id, anchor: .center)
                    }
                }
            }
            if store.updateStatus.failed && !store.updateBannerDismissed { UpdateFailedBanner() }
        }
        .background(Theme.sidebar)
        .onAppear { if let cwd = store.selectedController?.cwd { expandedProjects.insert(cwd) } }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $renameText)
            Button("保存") { if let thread = renaming { store.rename(thread.id, to: renameText) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 2) {
            Menu {
                Text("选择对话引擎")
                ForEach([ConversationEngine.codex, .claude], id: \.self) { engine in
                    Button { newThread(engine: engine) } label: {
                        if engine == workspaceEngine { Label(engine.displayName, systemImage: "checkmark") }
                        else { Text(engine.displayName) }
                    }
                }
                Divider()
                Button("选择项目文件夹…") { newThreadPickingFolder() }
                Button("设置与账号") { navigation.visit(.settings) }
            } label: {
                HStack(spacing: 7) {
                    Text(workspaceEngine.displayName).font(.system(size: 18, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium)).foregroundStyle(Theme.textTertiary)
                }.frame(height: 30).padding(.horizontal, 4)
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(SidebarCellStyle())
            .accessibilityLabel("当前工作区：\(workspaceEngine.displayName)")
            Spacer(minLength: 4)
            Button { notificationsPresented.toggle() } label: {
                Image(systemName: "bell").font(.system(size: 14, weight: .regular))
                    .overlay(alignment: .topTrailing) {
                        if !activityIDs.isEmpty { Circle().fill(Theme.textPrimary).frame(width: 4, height: 4).offset(x: 2, y: -2) }
                    }
            }
            .buttonStyle(SidebarIconButtonStyle())
            .help("通知与运行状态").accessibilityLabel("通知与运行状态")
            .popover(isPresented: $notificationsPresented, arrowEdge: .trailing) { notifications }
            Button { navigation.searchPresented = true } label: { WorkspaceIcon(.search) }
                .buttonStyle(SidebarIconButtonStyle())
                .help("搜索对话（⌘K）").accessibilityLabel("搜索对话")
        }
        .padding(.leading, 12).padding(.trailing, 10).frame(height: 52)
    }

    private var recentHeader: some View {
        HStack(spacing: 0) {
            Menu {
                Button { grouping = "recents" } label: {
                    if grouping == "recents" { Label("最近对话", systemImage: "checkmark") } else { Text("最近对话") }
                }
                Button { grouping = "projects" } label: {
                    if grouping == "projects" { Label("按项目", systemImage: "checkmark") } else { Text("按项目") }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(grouping == "projects" ? "Projects" : "Recents").font(.system(size: 14))
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .foregroundStyle(Theme.textTertiary).frame(height: 28)
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
            .accessibilityLabel("对话列表视图")
            Spacer(minLength: 4)
            if store.isScanning { ProgressView().controlSize(.mini).frame(width: 24) }
            Menu {
                Button("刷新对话列表") { Task { await store.refresh() } }
                Button("查看全部历史") { navigation.visit(.history) }
                Divider()
                Button("选择项目文件夹…") { newThreadPickingFolder() }
            } label: { WorkspaceIcon(.more).frame(width: 24, height: 28) }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary).help("对话列表选项")
            .accessibilityLabel("对话列表选项")
            Button { newThread() } label: { WorkspaceIcon(.compose) }
                .buttonStyle(SidebarIconButtonStyle())
                .help("新聊天").accessibilityLabel("新聊天")
        }
        .padding(.horizontal, 8).padding(.bottom, 2)
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通知").font(.system(size: 14, weight: .semibold))
            if activityIDs.isEmpty {
                Text("当前没有需要处理的通知。")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(activityIDs, id: \.self) { id in
                    Button {
                        selectThread(id); notificationsPresented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.summary(for: id)?.title ?? "新聊天").lineLimit(1)
                            Text(store.controllers[id]?.pendingPermissions.isEmpty == false ? "等待你的批准" : "正在运行")
                                .foregroundStyle(Theme.textSecondary)
                        }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8).contentShape(Rectangle())
                    }.buttonStyle(SidebarCellStyle())
                }
            }
        }.padding(16).frame(width: 280).background(Theme.background)
    }

    private func listHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 6)
    }
    private func emptyLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8).frame(height: 32)
    }
    private func project(_ group: ProjectGroup) -> some View {
        VStack(spacing: 0) {
            Button {
                if !expandedProjects.insert(group.id).inserted { expandedProjects.remove(group.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expandedProjects.contains(group.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium)).frame(width: 8).foregroundStyle(Theme.textTertiary)
                    WorkspaceIcon(.folder).foregroundStyle(Theme.textSecondary)
                    Text(group.name).font(.system(size: 14)).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 8).frame(height: 31).contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(SidebarCellStyle())
            .help(ThreadStore.displayPath(for: group.cwd))
            .contextMenu {
                Button("新建 Claude 对话") { newThread(cwd: group.cwd, engine: .claude) }
                Button("新建 Codex 对话") { newThread(cwd: group.cwd, engine: .codex) }
            }
            if expandedProjects.contains(group.id) {
                ForEach(group.threads) { threadRow($0, nested: true) }
            }
        }
    }
    private func threadRow(_ thread: ThreadSummary, pinned: Bool = false, nested: Bool = false) -> some View {
        SidebarThreadCell(thread: thread, selected: navigation.route == .home && store.selectedId == thread.id,
                          leadingInset: pinned ? 32 : nested ? 24 : 8) { selectThread(thread.id) }
            .id((nested ? "project:" : "thread:") + thread.id)
            .contextMenu {
                Button(pinnedIDs.contains(thread.id) ? "取消固定" : "固定对话") { togglePin(thread.id) }
                if thread.engine == .codex {
                    Button("用 Claude 接管") {
                        Task {
                            await store.takeoverWithClaude(thread.id)
                            if let id = store.selectedId { navigation.visit(.home, threadID: id) }
                        }
                    }
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
    private func selectThread(_ id: String) {
        store.selectedId = id
        navigation.visit(.home, threadID: id)
    }
    private func newThread(cwd: String? = nil, engine: ConversationEngine? = nil) {
        let id = store.newThread(cwd: cwd, engine: engine ?? store.defaultSettings.engine)
        navigation.visit(.home, threadID: id)
    }
    private func newThreadPickingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "开始对话"; panel.message = "选择工作目录"
        if panel.runModal() == .OK, let url = panel.url { newThread(cwd: url.path) }
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
    let leadingInset: CGFloat
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(thread.title).font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if thread.liveStatus != nil { Circle().stroke(Theme.textSecondary, lineWidth: 1.25).frame(width: 8, height: 8) }
            }
            .padding(.leading, leadingInset).padding(.trailing, 8)
            .frame(height: 31).contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(SidebarCellStyle(selected: selected))
        .help("\(thread.engine.displayName) · \(ThreadStore.displayPath(for: thread.cwd))")
        .accessibilityLabel("\(thread.title)，\(thread.engine.displayName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
private struct SidebarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarCellSurface(pressed: configuration.isPressed, selected: false) {
            configuration.label.foregroundStyle(Theme.textTertiary)
                .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct UpdateFailedBanner: View {
    @Environment(ThreadStore.self) private var store
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Claude Code 更新未完成").font(.system(size: 12, weight: .medium))
                Text("在终端运行 claude doctor 查看原因。").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Button { store.updateBannerDismissed = true } label: {
                Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 20)
            }.buttonStyle(.plain).accessibilityLabel("关闭更新提示")
        }
        .foregroundStyle(Theme.warn).padding(12)
        .background(Theme.sidebar)
    }
}
