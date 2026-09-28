import AppKit
import SwiftUI

struct ThreadView: View {
    let controller: ConversationController
    @Environment(ThreadStore.self) private var store
    @State private var dropTargeted = false   // 文件 / 照片正被拖着经过正文区

    private var showsEmptyState: Bool {
        controller.items.isEmpty && !controller.isWorking && !controller.isLoadingHistory
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if showsEmptyState {
                EmptyThreadView(controller: controller, dropTargeted: dropTargeted)
            } else {
                VStack(spacing: 0) {
                    TranscriptWebView(controller: controller, onDropTargeted: { dropTargeted = $0 })
                    VStack(spacing: 10) {
                        if !controller.pendingPermissions.isEmpty {
                            ScrollView {
                                VStack(spacing: 10) {
                                    ForEach(controller.pendingPermissions) { request in
                                        PermissionCard(request: request, controller: controller)
                                    }
                                }
                            }.frame(maxHeight: 320)
                        }
                        ComposerView(controller: controller, dropTargeted: dropTargeted)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: Theme.columnWidth)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                    // Transcript and composer share a 768pt outer column including 16pt gutters.
                }
            }
            if controller.isLoadingHistory && controller.items.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        // 拖到窗口正文任何位置都挂到输入框上（和 Codex 一样），不必精确拖进输入框。
        .onDrop(of: DropHandler.types, isTargeted: $dropTargeted) { providers in
            DropHandler.handle(providers, controller: controller)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let handoff = controller.handoff { HandoffSourceBar(handoff: handoff) }
        }
        .task { controller.loadHistoryIfNeeded() }
    }
}

/// A quiet, centered start surface with the same working composer as an active thread.
struct EmptyThreadView: View {
    let controller: ConversationController
    var dropTargeted = false
    @Environment(ThreadStore.self) private var store

    var body: some View {
        GeometryReader { geometry in
            let composerTop = max(152, (geometry.size.height + Theme.toolbarHeight) * 0.42 - Theme.toolbarHeight)
            VStack(spacing: 24) {
                heading.frame(minHeight: 112, alignment: .bottom)
                ComposerView(controller: controller, dropTargeted: dropTargeted)
                if controller.handoff?.isPending == true {
                    Text("发送后，Claude 会读取原对话上下文。原 Codex 对话保留。")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                if controller.engine == .codex && store.codexMissing {
                    Label("未找到 Codex。安装 codex 后刷新对话列表。", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
                if controller.engine == .claude && store.claudeMissing {
                    Label("未找到 Claude Code。安装 claude 后刷新对话列表。", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: Theme.columnWidth)
            .padding(.top, max(8, composerTop - 136))
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func chooseWorkingDirectory() {
        guard controller.isDraft, controller.handoff == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: controller.cwd)
        panel.prompt = "选择工作目录"
        if panel.runModal() == .OK, let url = panel.url {
            // Changing the directory must preserve the draft's selected engine and model.
            store.setDraftCwd(controller.id, cwd: url.path)
        }
    }

    @ViewBuilder private var heading: some View {
        if controller.handoff != nil {
            Text("继续这段对话").font(.system(size: 28)).tracking(-0.35)
                .foregroundStyle(Theme.textPrimary)
        } else if controller.cwd == NSHomeDirectory() {
            Text("我们要构建什么？").font(.system(size: 28)).tracking(-0.35)
                .foregroundStyle(Theme.textPrimary)
        } else {
            Button(action: chooseWorkingDirectory) {
                (Text("我们应该在")
                 + Text(ThreadStore.displayName(for: controller.cwd)).underline(true, pattern: .dot, color: Theme.textTertiary)
                 + Text("中做些什么？"))
                    .font(.system(size: 28)).tracking(-0.35)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .help("选择工作文件夹")
        }
    }
}

/// The original native session remains accessible after creating the Claude continuation.
struct HandoffSourceBar: View {
    let handoff: ConversationHandoff
    @Environment(ThreadStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Text("接管自 \(handoff.sourceEngine.displayName) · \(handoff.sourceTitle)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Button("查看原对话") { store.selectedId = handoff.sourceThreadId }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .disabled(store.summary(for: handoff.sourceThreadId) == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.cardFill)
        .help(handoff.isPending ? "发送下一条消息时，Claude 将读取 \(handoff.messageCount) 条历史消息的上下文；原 Codex 对话保留。" : "已从 \(handoff.messageCount) 条历史消息继续，使用独立的 Claude 原生会话；原 Codex 对话保留。")
    }
}

struct ClaudeTakeoverButton: View {
    let threadId: String
    @Environment(ThreadStore.self) private var store

    private var unavailable: Bool {
        store.takingOverId != nil || store.controllers[threadId]?.showsActivity == true
            || store.controllers[threadId]?.isLoadingHistory == true
    }

    var body: some View {
        Button { Task { await store.takeoverWithClaude(threadId) } } label: {
            HStack(spacing: 5) {
                if store.takingOverId == threadId { ProgressView().controlSize(.mini) }
                else { Image(systemName: "arrow.triangle.branch").font(.system(size: 11)) }
                Text(store.takingOverId == threadId ? "正在准备接管…" : "用 Claude 接管")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .disabled(unavailable)
        .help("将这段 Codex 对话的上下文带入新的 Claude 会话，原对话保留。运行中的对话需先停止。")
    }
}
