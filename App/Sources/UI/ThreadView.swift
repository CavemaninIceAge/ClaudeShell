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
                    TranscriptWebView(controller: controller)
                    VStack(spacing: 10) {
                        ForEach(controller.pendingPermissions) { request in
                            PermissionCard(request: request, controller: controller)
                        }
                        ComposerView(controller: controller, dropTargeted: dropTargeted)
                    }
                    .frame(maxWidth: Theme.columnWidth)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
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
        .task { controller.loadHistoryIfNeeded() }
        .toolbar {
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
            if let name = e.modelName {
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

/// 新对话的首屏：和 Codex 一样，问候语 + 居中的输入卡。
struct EmptyThreadView: View {
    let controller: ConversationController
    var dropTargeted = false
    @Environment(ThreadStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text(greeting)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("在 \(ThreadStore.displayPath(for: controller.cwd)) 里开始，和终端里的 Claude Code 是同一个")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                ComposerView(controller: controller, dropTargeted: dropTargeted)
                    .frame(maxWidth: 680)
                if store.claudeMissing {
                    Label("没找到 claude 命令，发送会失败。请先在终端里装好 Claude Code。", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warn)
                }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11: return "早上好"
        case 11..<14: return "中午好"
        case 14..<18: return "下午好"
        default: return "晚上好"
        }
    }
}
