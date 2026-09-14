import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(ThreadStore.self) private var store
    @State private var renaming: ThreadSummary? = nil
    @State private var renameText = ""

    var body: some View {
        // List 在数据刷新时偶尔会把 selection 置成 nil；选中状态以 store 为准，nil 一律不收。
        let selection = Binding<String?>(
            get: { store.selectedId },
            set: { if let id = $0, id != store.selectedId { store.selectedId = id } }
        )
        List(selection: selection) {
            ForEach(store.groups) { group in
                Section {
                    ForEach(group.threads) { thread in
                        ThreadRow(thread: thread)
                            .tag(thread.id)
                            .contextMenu { menu(for: thread) }
                    }
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text(group.name)
                    }
                    .help(ThreadStore.displayPath(for: group.cwd))
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: Binding(get: { store.query }, set: { store.query = $0 }), placement: .sidebar, prompt: "搜索对话")
        .safeAreaInset(edge: .top, spacing: 0) { NewThreadButton() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.updateStatus.failed && !store.updateBannerDismissed {
                UpdateFailedBanner()
            }
        }
        .overlay {
            if store.groups.isEmpty {
                ContentUnavailableView(store.query.isEmpty ? "还没有对话" : "没有匹配的对话",
                                       systemImage: "text.bubble")
                    .font(.callout)
            }
        }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $renameText)
            Button("保存") {
                if let r = renaming { store.rename(r.id, to: renameText) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private func menu(for thread: ThreadSummary) -> some View {
        Button("重命名…") {
            renameText = thread.title
            renaming = thread
        }
        Button("复制会话 ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(thread.id, forType: .string)
        }
        Button("在访达中显示目录") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: thread.cwd)])
        }
        Divider()
        Button("从列表中移除") { store.hide(thread.id) }
    }
}

private struct ThreadRow: View {
    let thread: ThreadSummary

    var body: some View {
        HStack(spacing: 6) {
            Text(thread.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if thread.liveStatus != nil {
                Circle()
                    .fill(Theme.live)
                    .frame(width: 6, height: 6)
                    .help(thread.liveStatus == "busy" ? "终端里正在运行" : "终端里已打开")
            }
        }
        .help(relative(thread.updatedAt))
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Codex 侧栏顶上那一行"New thread"。
/// Claude Code 自更新失败时侧栏底部那条提示，和终端「✗ Auto-update failed · Run claude doctor」对应。
/// 点整条给个怎么修的说明，右边 ✕ 可以先关掉；下次装好或再失败都会重来。
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

private struct NewThreadButton: View {
    @Environment(ThreadStore.self) private var store
    @State private var hovering = false

    var body: some View {
        Button { store.newThread() } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                Text("新对话")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("⌘N")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}
