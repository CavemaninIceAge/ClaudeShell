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
