import AppKit
import SwiftUI

/// 底部的输入卡：多行文本 + 目录 / 模型 / 权限 / 强度四枚胶囊 + 发送（或停止）键。
struct ComposerView: View {
    let controller: ConversationController
    @Environment(ThreadStore.self) private var store
    @State private var text = ""
    @State private var editorHeight: CGFloat = 22

    private var liveInTerminal: Bool { store.summary(for: controller.id)?.liveStatus != nil }

    private var canSend: Bool {
        controller.canSend && !liveInTerminal && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        liveInTerminal ? "这个对话正在终端里进行，那边结束后才能从这里续聊" : "问 Claude 任何事"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposerTextView(text: $text, height: $editorHeight, onSubmit: submit)
                .frame(height: min(max(editorHeight, 22), 220))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
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
                settingsMenu(icon: "cpu", title: ModelOption.title(for: controller.settings.model),
                             options: ModelOption.all, selection: controller.settings.model ?? "") { new in
                    var s = controller.settings; s.model = new.isEmpty ? nil : new; store.updateSettings(controller.id, s)
                }
                settingsMenu(icon: "checkmark.shield", title: PermissionModeOption.title(for: controller.settings.permissionMode),
                             options: PermissionModeOption.all, selection: controller.settings.permissionMode) { new in
                    var s = controller.settings; s.permissionMode = new; store.updateSettings(controller.id, s)
                }
                settingsMenu(icon: "gauge.with.needle", title: EffortOption.title(for: controller.settings.effort),
                             options: EffortOption.all, selection: controller.settings.effort ?? "") { new in
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
        controller.send(t)
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

    private func settingsMenu(icon: String, title: String, options: [(id: String, title: String)],
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
        .help(controller.isWorking ? "改动在下一轮生效" : "")
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
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
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

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.textView = textView
        context.coordinator.observeResize(of: scroll)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
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
            parent.text = textView.string
            recalcHeight()
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
