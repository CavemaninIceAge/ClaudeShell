import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native input, attachments and engine controls share one compact workspace composer.
struct ComposerView: View {
    let controller: ConversationController
    var dropTargeted = false
    @Environment(ThreadStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var text = ""
    @State private var isComposing = false
    @State private var editorHeight: CGFloat = 22
    @State private var editorDropTargeted = false
    @State private var editingModel = false
    @State private var customModel = ""

    private var liveInTerminal: Bool { controller.isLiveInTerminal }
    private var isCodex: Bool { controller.engine == .codex }
    private var effective: ConversationController.Effective { controller.effective(defaults: store.terminalDefaults) }
    private var highlightDrop: Bool { dropTargeted || editorDropTargeted }
    private var canSend: Bool {
        let hasText = !isComposing && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContent = hasText || (!isComposing && !controller.attachments.isEmpty)
        return hasContent && (liveInTerminal ? !controller.isLoadingHistory : controller.canSend)
    }
    private var placeholder: String {
        liveInTerminal ? "发送到终端中正在进行的对话…" : (controller.handoff?.isPending == true ? "告诉 Claude 接下来做什么…" : "描述任务、提问，或添加文件…")
    }
    private var modelTitle: String {
        if isCodex, let model = controller.codexModels.first(where: { $0.id == effective.modelId }) { return model.name }
        return effective.modelName ?? controller.engine.displayName
    }
    private var displayedEffort: String {
        if let effort = effective.effort { return effort }
        if isCodex {
            let model = controller.codexModels.first { $0.id == effective.modelId }
                ?? controller.codexModels.first { $0.isDefault }
            if let effort = model?.defaultEffort { return effort }
        }
        return "默认"
    }
    private var permissionOptions: [(id: String, title: String)] {
        isCodex ? [("auto", "工作区权限"), ("manual", "逐项询问"), ("plan", "只读模式"), ("bypassPermissions", "完全访问")]
            : PermissionModeOption.all
    }
    private var permissionTitle: String {
        permissionOptions.first { $0.id == controller.settings.permissionMode }?.title
            ?? PermissionModeOption.title(for: controller.settings.permissionMode)
    }

    private var effortOptions: [(id: String, title: String)] {
        if isCodex {
            let model = controller.codexModels.first { $0.id == controller.settings.model }
                ?? controller.codexModels.first { $0.isDefault }
            return [("", "默认强度")] + (model?.efforts ?? []).map { ($0, $0) }
        }
        return EffortOption.all.map { option in
            guard option.id.isEmpty, let effort = store.terminalDefaults.effort else { return option }
            return (option.id, "\(option.title) · \(effort)")
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            if liveInTerminal {
                Label("此对话由终端运行，使用终端当前账号；应用内账号选择不改变它。", systemImage: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            if controller.isDraft { contextRow }
            VStack(alignment: .leading, spacing: 4) {
                if !controller.attachments.isEmpty {
                    AttachmentStrip(attachments: controller.attachments) { controller.removeAttachment($0) }
                        .padding(.horizontal, 8)
                }
                ComposerTextView(text: $text, isComposing: $isComposing, height: $editorHeight, onSubmit: submit,
                                 onDropFiles: { controller.attach(urls: $0) },
                                 onDropImage: { controller.attach(imageData: $0, name: $1) },
                                 onDropTargeted: { editorDropTargeted = $0 })
                    .frame(height: min(max(editorHeight, 44), 220))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty && !isComposing {
                            Text(placeholder)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.placeholder)
                                .frame(height: 20, alignment: .topLeading)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 12)
                HStack(spacing: 5) {
                    attachButton
                    permissionMenu
                    Spacer(minLength: 8)
                    modelMenu
                        .layoutPriority(-1)
                    sendButton
                        .padding(.leading, 8)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)
            .background { composerSurface }
            .overlay {
                if highlightDrop {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Theme.textPrimary, lineWidth: 1.5)
                }
            }
            if !controller.isDraft { contextRow }
        }
        .alert("指定模型", isPresented: $editingModel) {
            TextField("模型 ID", text: $customModel)
            Button("取消", role: .cancel) { }
            Button("使用模型") { updateModel(customModel.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } message: {
            Text("填写当前账号可用的模型 ID；留空恢复引擎默认模型。")
        }
    }

    private var contextRow: some View {
        HStack(spacing: 8) {
            folderButton
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// Codex's normal composer surface (forced-colors rules intentionally excluded).
    @ViewBuilder private var composerSurface: some View {
        if colorScheme == .dark {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.composerFill.shadow(.inner(color: .white.opacity(0.2), radius: 1)))
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.composerFill)
                .background {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Color.black.opacity(6.0 / 255))
                        .padding(-8)
                        .blur(radius: 40)
                        .offset(y: 4)
                }
                .shadow(color: .black.opacity(10.0 / 255), radius: 4, x: 0, y: 2)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.black.opacity(10.0 / 255), lineWidth: 1)
                }
        }
    }

    private var modelMenu: some View {
        Menu {
            Text("对话引擎")
            ForEach([ConversationEngine.claude, .codex], id: \.self) { engine in
                Button { store.setDraftEngine(controller.id, engine: engine) } label: {
                    if controller.engine == engine { Label(engine.displayName, systemImage: "checkmark") }
                    else { Text(engine.displayName) }
                }
                .disabled(!controller.isDraft || controller.isWorking || controller.handoff != nil)
            }
            Divider()
            Text("模型")
            if isCodex {
                Button("使用 Codex 默认模型") { updateModel("") }
                ForEach(controller.codexModels, id: \.id) { model in
                    Button { updateModel(model.id) } label: {
                        if model.id == controller.settings.model { Label(model.name, systemImage: "checkmark") }
                        else { Text(model.name) }
                    }
                }
            } else {
                ForEach(ModelOption.all, id: \.id) { option in
                    Button { updateModel(option.id) } label: {
                        if option.id == (controller.settings.model ?? "") { Label(option.title, systemImage: "checkmark") }
                        else { Text(option.title) }
                    }
                }
            }
            Divider()
            Button("指定模型 ID…") { customModel = controller.settings.model ?? ""; editingModel = true }
            Divider()
            Text("思考强度")
            ForEach(effortOptions, id: \.id) { option in
                Button {
                    var settings = controller.settings
                    settings.effort = option.id.isEmpty ? nil : option.id
                    store.updateSettings(controller.id, settings)
                } label: {
                    if option.id == (controller.settings.effort ?? "") { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
            }
        } label: {
            ComposerControlLabel(title: modelTitle, secondary: displayedEffort, chevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(liveInTerminal)
        .help("\(controller.engine.displayName) · 模型：\(effective.modelId ?? modelTitle)；新对话可在此切换引擎")
        .accessibilityLabel("引擎和模型：\(controller.engine.displayName)，\(modelTitle)")
    }

    private var sendButton: some View {
        Button {
            if controller.isWorking { controller.stop() } else { submit() }
        } label: {
            Image(systemName: controller.isWorking ? "stop.fill" : "arrow.up")
                .font(.system(size: controller.isWorking ? 11 : 15, weight: .semibold))
                .foregroundStyle(Theme.sendFg)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.sendFill))
                .contentShape(Circle())
        }
        .buttonStyle(ComposerSendButtonStyle())
        .disabled(!controller.isWorking && !canSend)
        .help(controller.isWorking ? "停止生成（⌘.）" : "发送（⏎）；⇧⏎ 换行")
        .accessibilityLabel(controller.isWorking ? "停止生成" : "发送消息")
    }

    private func updateModel(_ model: String) {
        var s = controller.settings; s.model = model.isEmpty ? nil : model; store.updateSettings(controller.id, s)
    }

    private func submit() {
        guard canSend else { return }
        let t = text; text = ""; editorHeight = 22
        if liveInTerminal { controller.sendToTerminal(t) } else { controller.send(t) }
    }

    private var attachButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
            panel.prompt = "添加"; panel.message = "选择要附加的文件、照片或目录"
            if panel.runModal() == .OK { controller.attach(urls: panel.urls) }
        } label: {
            ComposerControlLabel(icon: "plus", title: nil, chevron: false)
        }
        .buttonStyle(.plain)
        .help("添加文件、照片或目录（支持拖放和 ⌘V）")
        .accessibilityLabel("添加附件")
    }

    private var folderButton: some View {
        Button {
            guard controller.isDraft else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: controller.cwd); panel.prompt = "选择工作目录"
            if panel.runModal() == .OK, let url = panel.url { store.setDraftCwd(controller.id, cwd: url.path) }
        } label: {
            ComposerControlLabel(icon: "folder", title: ThreadStore.displayName(for: controller.cwd), chevron: controller.isDraft)
        }
        .buttonStyle(.plain)
        .disabled(!controller.isDraft)
        .help("工作目录：\(controller.cwd)\(controller.isDraft ? "" : "（会话开始后不能更改）")")
    }

    private var permissionMenu: some View {
        Menu {
            Text("权限模式")
            ForEach(permissionOptions, id: \.id) { option in
                Button {
                    var settings = controller.settings
                    settings.permissionMode = option.id
                    store.updateSettings(controller.id, settings)
                } label: {
                    if option.id == controller.settings.permissionMode { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
            }
        } label: {
            ComposerControlLabel(icon: "checkmark.shield", title: nil, chevron: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(liveInTerminal)
        .help("\(permissionTitle)；更改在下一轮生效")
        .accessibilityLabel("权限模式：\(permissionTitle)")
    }
}

/// Own the disabled treatment so SwiftUI's plain style does not dim the 50% source opacity twice.
private struct ComposerSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

private struct ComposerControlLabel: View {
    var icon: String? = nil
    var title: String?
    var secondary: String? = nil
    var chevron = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: title == nil ? 16 : 13, weight: .regular))
            }
            if let title {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            if let secondary {
                Text(secondary).font(.system(size: 13)).lineLimit(1).fixedSize()
            }
            if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)) }
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, title == nil ? 0 : 6)
        .frame(minWidth: 28, minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered ? Theme.chipFill : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

/// NSTextView 包一层：回车发送、⇧回车换行、输入法组字中的回车归输入法；高度随内容长。
/// 组字期间 NSTextView 不发 textDidChange，`text` 只在上屏后更新，组字状态单独走 `isComposing`。
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool
    @Binding var height: CGFloat
    var onSubmit: () -> Void
    var onDropFiles: ([URL]) -> Void = { _ in }
    var onDropImage: (Data, String) -> Void = { _, _ in }
    var onDropTargeted: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = NSColor(Theme.textPrimary)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = 20
        paragraphStyle.maximumLineHeight = 20
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.paragraphStyle] = paragraphStyle
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
        textView.onDropFiles = { [weak coordinator = context.coordinator] in coordinator?.parent.onDropFiles($0) }
        textView.onDropImage = { [weak coordinator = context.coordinator] in coordinator?.parent.onDropImage($0, $1) }
        textView.onDropTargeted = { [weak coordinator = context.coordinator] in coordinator?.parent.onDropTargeted($0) }

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.textView = textView
        context.coordinator.observeResize(of: scroll)
        DispatchQueue.main.async { [weak textView] in
            guard NSApp.activationPolicy() != .prohibited, let textView,
                  let window = textView.window, window.isKeyWindow else { return }
            window.makeFirstResponder(textView)
        }
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
        // 拖放 / 粘贴的自动化验证：不发全局键鼠事件，在进程内造一个 NSDraggingInfo / 私有剪贴板喂给同一套代码。
        //   -testDropFiles "/a:/b"   文件拖进输入框（draggingEntered → performDragOperation）
        //   -testDropImage "/x.png"  图片字节拖进输入框（浏览器拖图那种，没有文件路径）
        //   -testPasteFiles "/a:/b"  Finder 里 ⌘C 的文件 ⌘V 进来
        //   -testPasteImage "/x.png" 截图 / 浏览器复制的图片 ⌘V 进来
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak textView] in
            guard let textView else { return }
            let d = UserDefaults.standard
            func urls(_ key: String) -> [URL] {
                (d.string(forKey: key) ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            }
            func imageData(_ key: String) -> Data? {
                d.string(forKey: key).flatMap { $0.isEmpty ? nil : try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            }
            let drop = NSPasteboard(name: NSPasteboard.Name("claude-shell-test-drop"))
            drop.clearContents()
            if !urls("testDropFiles").isEmpty { drop.writeObjects(urls("testDropFiles") as [NSURL]) }
            if let png = imageData("testDropImage") { drop.setData(png, forType: .png) }
            if drop.types?.isEmpty == false {
                let info = TestDraggingInfo(pasteboard: drop)
                let op = textView.draggingEntered(info)
                let ok = textView.performDragOperation(info)
                TestLog.write("testDrop entered=\(op.rawValue) performed=\(ok)")
            }
            let paste = NSPasteboard(name: NSPasteboard.Name("claude-shell-test-paste"))
            paste.clearContents()
            if !urls("testPasteFiles").isEmpty { paste.writeObjects(urls("testPasteFiles") as [NSURL]) }
            if let png = imageData("testPasteImage") { paste.setData(png, forType: .png) }
            if paste.types?.isEmpty == false {
                textView.pasteboardForPaste = paste
                textView.paste(nil)
                textView.pasteboardForPaste = .general
                TestLog.write("testPaste done")
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
    var onDropFiles: (([URL]) -> Void)?
    var onDropImage: ((Data, String) -> Void)?
    var onDropTargeted: ((Bool) -> Void)?

    // MARK: 拖放 / 粘贴：文件和图片不进正文，交给附件条；NSTextView 默认会把拖进来的文件路径当文字插进去。

    private func hasAttachable(_ pb: NSPasteboard) -> Bool { PasteboardAttachments.hasAttachable(pb) }

    /// 取走了就返回 true；否则由调用方交给 NSTextView 自己处理（普通文字）。
    @discardableResult
    private func takeAttachments(from pb: NSPasteboard, source: String, textWins: Bool = false) -> Bool {
        PasteboardAttachments.take(from: pb, source: "composer \(source)", textWins: textWins,
                                   files: { onDropFiles?($0) }, image: { onDropImage?($0, $1) })
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasAttachable(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasAttachable(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargeted?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasAttachable(sender.draggingPasteboard) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTargeted?(false)
        if takeAttachments(from: sender.draggingPasteboard, source: "drop") { return true }
        return super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDropTargeted?(false)
        super.concludeDragOperation(sender)
    }

    var pasteboardForPaste: NSPasteboard = .general   // 测试钩子换成私有剪贴板，不动用户的剪贴板

    override func paste(_ sender: Any?) {
        // Finder 里 ⌘C 的文件、截图 / 浏览器复制的图片：挂成附件；别的照常贴文字。
        if takeAttachments(from: pasteboardForPaste, source: "paste", textWins: true) { return }
        super.paste(sender)
    }

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

/// 测试钩子用的假拖放信息：只有剪贴板是真的，图像随便填；-testWindowDrop 会把落点和窗口也填成真的。
final class TestDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let location: NSPoint
    weak var window: NSWindow?
    init(pasteboard: NSPasteboard, location: NSPoint = .zero, window: NSWindow? = nil) {
        self.pasteboard = pasteboard
        self.location = location
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
