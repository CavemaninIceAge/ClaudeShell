import AppKit
import SwiftUI

/// 底部的输入卡：多行文本 + 目录 / 模型 / 权限 / 强度四枚胶囊 + 发送（或停止）键。
struct ComposerView: View {
    let controller: ConversationController
    @Environment(ThreadStore.self) private var store
    @State private var text = ""
    @State private var isComposing = false   // 输入法正在组字（text 只含已上屏的字）
    @State private var editorHeight: CGFloat = 22

    private var liveInTerminal: Bool { controller.isLiveInTerminal }

    private var canSend: Bool {
        let hasText = !isComposing && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 终端里开着的会话：这里发的话投进终端去，那边忙着也行（会在两次工具调用之间送到）。
        return hasText && (liveInTerminal ? !controller.isLoadingHistory : controller.canSend)
    }

    private var placeholder: String {
        liveInTerminal ? "发到终端里的这个对话，那边的 Claude 回答后这里同步显示" : "问 Claude 任何事"
    }

    // 胶囊上永远写具体生效的值（和终端一样），「跟随终端设置 / 默认强度」只留在菜单里当选项。
    private var effective: ConversationController.Effective { controller.effective(defaults: store.terminalDefaults) }

    private var modelOptions: [(id: String, title: String)] {
        ModelOption.all.map { option in
            guard option.id.isEmpty, let name = store.terminalDefaults.model.map(ModelOption.displayName(for:)) else { return option }
            return (option.id, "\(option.title) · \(name)")
        }
    }

    private var effortOptions: [(id: String, title: String)] {
        EffortOption.all.map { option in
            guard option.id.isEmpty, let effort = store.terminalDefaults.effort else { return option }
            return (option.id, "\(option.title) · \(effort)")
        }
    }

    private var modelHelp: String {
        let e = effective
        if liveInTerminal { return "模型：\(e.modelId ?? "?")（终端里的会话，由终端决定）" }
        guard let id = e.modelId else { return "模型：跟随终端设置" }
        return "模型：\(id)（\(e.modelPinned ? "本对话指定" : "跟随终端设置")）"
    }

    private var effortHelp: String {
        let e = effective
        if liveInTerminal { return "强度：\(e.effort ?? "?")（终端里的会话，按终端默认估计）" }
        guard let effort = e.effort else { return "强度：默认" }
        return "强度：\(effort)（\(e.effortPinned ? "本对话指定" : "终端默认")）"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposerTextView(text: $text, isComposing: $isComposing, height: $editorHeight, onSubmit: submit)
                .frame(height: min(max(editorHeight, 22), 220))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty && !isComposing {
                        Text(placeholder)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.placeholder)
                            .padding(.leading, 3)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 6) {
                folderChip
                settingsMenu(icon: "cpu", title: effective.modelName ?? "跟随终端设置", help: modelHelp,
                             options: modelOptions, selection: controller.settings.model ?? "") { new in
                    var s = controller.settings; s.model = new.isEmpty ? nil : new; store.updateSettings(controller.id, s)
                }
                settingsMenu(icon: "checkmark.shield", title: PermissionModeOption.title(for: controller.settings.permissionMode),
                             help: "权限模式：\(controller.settings.permissionMode)",
                             options: PermissionModeOption.all, selection: controller.settings.permissionMode) { new in
                    var s = controller.settings; s.permissionMode = new; store.updateSettings(controller.id, s)
                }
                settingsMenu(icon: "gauge.with.needle", title: effective.effort ?? "默认强度", help: effortHelp,
                             options: effortOptions, selection: controller.settings.effort ?? "") { new in
                    var s = controller.settings; s.effort = new.isEmpty ? nil : new; store.updateSettings(controller.id, s)
                }
                Spacer(minLength: 8)
                if controller.isWorking {
                    Button(action: controller.stop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.sendFg)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.sendFill))
                    }
                    .buttonStyle(.plain)
                    .help("停止生成（⌘.）")
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.sendFg)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.sendFill))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.3)
                    .help("发送（⏎）；⇧⏎ 换行")
                }
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.composerFill))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }

    private func submit() {
        guard canSend else { return }
        let t = text
        text = ""
        editorHeight = 22
        if liveInTerminal {
            controller.sendToTerminal(t)
        } else {
            controller.send(t)
        }
    }

    // 目录只能在第一条消息之前换：会话一旦开始，cwd 就是 Claude Code 的会话属性了。
    private var folderChip: some View {
        let locked = !controller.isDraft
        return Button {
            guard !locked else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: controller.cwd)
            panel.prompt = "选这个目录"
            if panel.runModal() == .OK, let url = panel.url {
                store.setDraftCwd(controller.id, cwd: url.path)
            }
        } label: {
            Chip(icon: "folder", title: ThreadStore.displayName(for: controller.cwd))
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(locked ? "工作目录：\(controller.cwd)（会话开始后不能换）" : "换工作目录")
    }

    private func settingsMenu(icon: String, title: String, help: String, options: [(id: String, title: String)],
                              selection: String, onChange: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.id) { option in
                Button {
                    onChange(option.id)
                } label: {
                    if option.id == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Chip(icon: icon, title: title, showsChevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(liveInTerminal)   // 终端里的会话：这几样由终端决定，这里只看不改
        .help(controller.isWorking ? "\(help)；改动在下一轮生效" : help)
    }
}

struct Chip: View {
    var icon: String
    var title: String
    var showsChevron = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.leading, 1)
            }
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.chipFill))
        .contentShape(Capsule())
    }
}

/// NSTextView 包一层：回车发送、⇧回车换行、输入法组字中的回车归输入法；高度随内容长。
/// 组字期间 NSTextView 不发 textDidChange，`text` 只在上屏后更新，组字状态单独走 `isComposing`。
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool
    @Binding var height: CGFloat
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 3
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
        textView.onCompositionChange = { [weak coordinator = context.coordinator] in coordinator?.compositionDidChange() }

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.textView = textView
        context.coordinator.observeResize(of: scroll)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        // 自动化验证用：-testMarkedText "ciao" 模拟输入法组字（输入法走的就是这个方法），不发全局键盘事件。
        // 等窗口成为 key、输入上下文激活之后再塞，否则激活过程会把没有输入法会话撑腰的组字悄悄清掉。
        if let marked = UserDefaults.standard.string(forKey: "testMarkedText"), !marked.isEmpty {
            let notFound = NSRange(location: NSNotFound, length: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak textView] in
                textView?.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0),
                                        replacementRange: notFound)
            }
            // -testMarkedCommit "你好"：再过 3 秒把组字上屏（输入法上屏走的也是 insertText）。
            if let commit = UserDefaults.standard.string(forKey: "testMarkedCommit"), !commit.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak textView] in
                    textView?.insertText(commit, replacementRange: notFound)
                }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // 组字中 textView.string 带着未上屏的拼音，和 text 必然不等；此时回写会把组字冲掉。
        if !textView.hasMarkedText(), textView.string != text {
            TestLog.write("composer sync: view=[\(textView.string)] -> text=[\(text)]")
            textView.string = text
            context.coordinator.recalcHeight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: SubmitTextView?
        private var resizeObserver: NSObjectProtocol?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func observeResize(of scroll: NSScrollView) {
            scroll.contentView.postsFrameChangedNotifications = true
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.recalcHeight() }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            TestLog.write("composer textDidChange: [\(textView.string)] marked=\(textView.hasMarkedText())")
            parent.text = textView.string
            syncComposing()
            recalcHeight()
        }

        // 组字被系统悄悄清掉（比如失焦时输入上下文丢弃组字）不一定经过 setMarkedText/unmarkText，选区变化兜底再对一次。
        func textViewDidChangeSelection(_ notification: Notification) {
            syncComposing()
        }

        func compositionDidChange() {
            TestLog.write("composer composition: [\(textView?.string ?? "")] marked=\(textView?.hasMarkedText() ?? false)")
            syncComposing()
            recalcHeight()
        }

        private func syncComposing() {
            guard let textView else { return }
            let composing = textView.hasMarkedText()
            if parent.isComposing != composing { parent.isComposing = composing }
        }

        func recalcHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            let h = ceil(used + textView.textContainerInset.height * 2)
            if abs(parent.height - h) > 0.5 { parent.height = h }
        }
    }
}

final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCompositionChange: (() -> Void)?

    // 输入法组字（拼音上屏前）不走 textDidChange，得自己报。
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChange?()
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            // 输入法还在组字：回车归输入法。⇧回车：换行。其余：发送。
            if hasMarkedText() { super.doCommand(by: selector); return }
            if NSEvent.modifierFlags.contains(.shift) {
                insertText("\n", replacementRange: selectedRange())
                return
            }
            onSubmit?()
            return
        }
        super.doCommand(by: selector)
    }
}
