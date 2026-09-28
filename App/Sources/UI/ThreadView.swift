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
                        ForEach(controller.pendingPermissions) { request in
                            PermissionCard(request: request, controller: controller)
                        }
                        ComposerView(controller: controller, dropTargeted: dropTargeted)
                    }
                    .frame(maxWidth: Theme.columnWidth)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 18)
                    // 正文列（transcript.css #root）和这张卡都是 780 宽、外加 24 边距，两者严格同轴。
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
        .toolbar {
            if controller.engine == .codex && !controller.isDraft {
                ToolbarItem(placement: .primaryAction) { ClaudeTakeoverButton(threadId: controller.id) }
            }
            // macOS 26 会给工具栏项套一层玻璃胶囊，这行只是一行小字，不要那层壳（One Shadow Rule）。
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { StatusBadge(controller: controller) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { StatusBadge(controller: controller) }
            }
        }
    }
}

/// 工具栏右侧的一小行：模型 · 强度 · 本会话花费——和终端一样明着写，悬停看原始 id 和来源。
/// 进行中的状态只在正文里那一行 shimmer 上显示。
private struct StatusBadge: View {
    let controller: ConversationController
    @Environment(ThreadStore.self) private var store

    var body: some View {
        let e = controller.effective(defaults: store.terminalDefaults)
        HStack(spacing: 0) {
            Text(controller.engine.displayName)
            if let name = e.modelName {
                Text(" · ")
                Text(name)
                    .help("模型：\(e.modelId ?? name)（\(e.modelPinned ? "本对话指定" : "跟随终端设置")）")
            }
            if let effort = e.effort {
                if e.modelName != nil { Text(" · ") }
                Text(effort)
                    .help("强度：\(effort)（\(e.effortPinned ? "本对话指定" : "终端默认")）")
            }
            if controller.totalCostUSD > 0 {
                if e.modelName != nil || e.effort != nil { Text(" · ") }
                Text(String(format: "$%.2f", controller.totalCostUSD))
                    .monospacedDigit()
                    .help("本会话累计花费（按 API 价目估算）")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

/// A quiet, centered start surface with the same working composer as an active thread.
struct EmptyThreadView: View {
    let controller: ConversationController
    var dropTargeted = false
    @Environment(ThreadStore.self) private var store
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)
            VStack(spacing: 28) {
                Text(controller.handoff == nil ? "今天想做些什么？" : "继续这段对话")
                    .font(.system(size: 28, weight: .medium))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                ComposerView(controller: controller, dropTargeted: dropTargeted)
                    .frame(maxWidth: 720)
                VStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "person.crop.circle").font(.system(size: 11))
                        Text(accountLabel).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    Text(controller.handoff?.isPending == true ? "发送后，Claude 会先读取原对话上下文。原 Codex 对话保留。" : "在左下角切换账号，或推送至终端 / Codex App。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    if controller.engine == .codex && store.codexMissing {
                        Label("未找到 Codex。请先在终端安装 codex，再刷新对话列表。", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warn)
                    }
                    if controller.engine == .claude && store.claudeMissing {
                        Label("未找到 Claude Code。请先在终端安装 claude，再刷新对话列表。", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warn)
                    }
                }
            }
            .padding(.horizontal, 32)
            Spacer(minLength: 30)
            Spacer(minLength: 0)
        }
    }

    private var accountLabel: String {
        if controller.engine == .codex {
            return accounts.activeCodex.map { "Codex · \($0.email) · 仅此 App" } ?? "Codex · 从左下角保存本机登录态"
        }
        if let provider = accounts.activeProvider { return "\(provider.name) · 仅此 App" }
        return accounts.active.map { "Claude · \($0.email) · 仅此 App" } ?? "Claude · 从左下角添加账号"
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
        .padding(.horizontal, 24)
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
