import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(ThreadStore.self) private var store
    @Environment(AccountStore.self) private var accounts
    @State private var renaming: ThreadSummary?
    @State private var renameText = ""
    @State private var showsProjects = true
    @State private var collapsedProjects: Set<String> = []
    @FocusState private var searchFocused: Bool

    private var recentThreads: [ThreadSummary] {
        store.groups.flatMap(\.threads).sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        let selection = Binding<String?>(get: { store.selectedId }, set: {
            if let id = $0, id != store.selectedId { store.selectedId = id }
        })
        VStack(spacing: 0) {
            sidebarHeader
            HStack(spacing: 14) {
                sectionButton("项目", selected: showsProjects) { showsProjects = true }
                sectionButton("最近", selected: !showsProjects) { showsProjects = false }
                Spacer()
                if store.isScanning { ProgressView().controlSize(.mini) }
                else {
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("刷新对话列表（⌘R）")
                    .accessibilityLabel("刷新对话列表")
                }
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 21)
            .padding(.top, 20)
            .padding(.bottom, 7)
            List(selection: selection) {
                if showsProjects && store.query.isEmpty {
                    ForEach(store.groups) { group in
                        DisclosureGroup(isExpanded: Binding(
                            get: { !collapsedProjects.contains(group.id) },
                            set: { expanded in
                                if expanded { collapsedProjects.remove(group.id) }
                                else { collapsedProjects.insert(group.id) }
                            }
                        )) {
                            ForEach(group.threads) { thread in threadRow(thread) }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "folder").font(.system(size: 12))
                                Text(group.name).lineLimit(1).font(.system(size: 12, weight: .medium))
                                Spacer(minLength: 4)
                                Text("\(group.threads.count)").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                            }
                            .help(ThreadStore.displayPath(for: group.cwd))
                            .contextMenu {
                                Button("在此项目中新建 Claude 对话") { store.newThread(cwd: group.cwd, engine: .claude) }
                                Button("在此项目中新建 Codex 对话") { store.newThread(cwd: group.cwd, engine: .codex) }
                            }
                        }
                    }
                } else {
                    ForEach(recentThreads) { thread in threadRow(thread) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if store.groups.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(store.query.isEmpty ? "你的对话会出现在这里" : "没有找到对话")
                            .font(.system(size: 12, weight: .medium))
                        Text(store.query.isEmpty ? "按项目整理 Claude 与 Codex 对话。" : "试试标题或项目目录中的其他关键词。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .allowsHitTesting(false)
                }
            }
            if store.updateStatus.failed && !store.updateBannerDismissed { UpdateFailedBanner() }
            Divider().overlay(Theme.line).padding(.horizontal, 16)
            AccountFooter()
        }
        .background(Theme.sidebar)
        .sheet(item: Binding(get: { accounts.loginSession }, set: { if $0 == nil { accounts.loginSession = nil } })) { session in
            AccountLoginSheet(session: session)
        }
        .sheet(isPresented: Binding(get: { accounts.addingProvider }, set: { accounts.addingProvider = $0 })) { ProviderAddSheet() }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $renameText)
            Button("保存") {
                if let r = renaming { store.rename(r.id, to: renameText) }; renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    private var sidebarHeader: some View {
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                Button { store.newThread() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "square.and.pencil").font(.system(size: 14))
                        Text("新对话").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("⌘N").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SidebarActionStyle())
                Menu {
                    Button("新建 Claude 对话") { store.newThread(engine: .claude) }
                    Button("新建 Codex 对话") { store.newThread(engine: .codex) }
                    Divider()
                    Button("选择项目文件夹…") { store.newThreadPickingFolder() }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10)).frame(width: 26, height: 34)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("选择对话引擎或工作目录")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                TextField("搜索对话", text: Binding(get: { store.query }, set: { store.query = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .accessibilityLabel("搜索对话或项目")
                if !store.query.isEmpty {
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .help("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebarInput))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? Theme.textSecondary : Color.clear, lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func sectionButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func threadRow(_ thread: ThreadSummary) -> some View {
        ThreadRow(thread: thread).tag(thread.id).contextMenu { menu(for: thread) }
    }

    @ViewBuilder private func menu(for thread: ThreadSummary) -> some View {
        if thread.engine == .codex {
            Button("用 Claude 接管") { Task { await store.takeoverWithClaude(thread.id) } }
                .disabled(store.takingOverId != nil || store.controllers[thread.id]?.showsActivity == true
                          || store.controllers[thread.id]?.isLoadingHistory == true)
            Divider()
        }
        Button("重命名…") { renameText = thread.title; renaming = thread }
        Button("复制会话 ID") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(thread.id, forType: .string)
        }
        Button("在访达中显示目录") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: thread.cwd)]) }
        Divider()
        Button("从列表中移除") { store.hide(thread.id) }
    }
}

private struct ThreadRow: View {
    let thread: ThreadSummary
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: thread.engine == .codex ? "terminal" : "sparkle")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 13)
            Text(thread.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if thread.liveStatus != nil {
                Circle().fill(Theme.live).frame(width: 5, height: 5)
            }
        }
        .padding(.vertical, 3)
        .help("\(thread.engine.displayName) · \(ThreadStore.displayPath(for: thread.cwd))\n\(relative(thread.updatedAt))")
        .accessibilityLabel("\(thread.title)，\(thread.engine.displayName)")
    }
    private func relative(_ date: Date) -> String {
        if Calendar.current.component(.year, from: date) != Calendar.current.component(.year, from: Date()) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct SidebarActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.textPrimary)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Theme.chipFill : Color.clear))
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
