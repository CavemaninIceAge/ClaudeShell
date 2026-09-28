import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native input, attachments and engine controls share one compact workspace composer.
struct ComposerView: View {
    let controller: ConversationController
    var dropTargeted = false
    @Environment(ThreadStore.self) private var store
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
    private var modelTitle: String { effective.modelName ?? (isCodex ? "Codex 默认模型" : "Claude 默认模型") }
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
        VStack(spacing: 9) {
            if liveInTerminal {
                Label("此对话由终端运行，使用终端当前账号；应用内账号选择不改变它。", systemImage: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 14) {
                if !controller.attachments.isEmpty {
                    AttachmentStrip(attachments: controller.attachments) { controller.removeAttachment($0) }
                }
                ComposerTextView(text: $text, isComposing: $isComposing, height: $editorHeight, onSubmit: submit,
                                 onDropFiles: { controller.attach(urls: $0) },
                                 onDropImage: { controller.attach(imageData: $0, name: $1) },
                                 onDropTargeted: { editorDropTargeted = $0 })
                    .frame(height: min(max(editorHeight, controller.isDraft ? 56 : 36), 220))
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
                HStack(spacing: 7) {
                    attachButton
                    engineMenu
                    modelMenu
                    Spacer(minLength: 4)
                    sendButton
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.composerFill))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(highlightDrop ? Theme.textPrimary : Theme.line, lineWidth: highlightDrop ? 1.5 : 1))
            HStack(spacing: 10) {
                folderButton
                Spacer(minLength: 4)
                settingsMenu(icon: "checkmark.shield", title: permissionTitle,
                             options: permissionOptions, selection: controller.settings.permissionMode) { new in
                    var s = controller.settings; s.permissionMode = new; store.updateSettings(controller.id, s)
                }
                settingsMenu(icon: "gauge.with.needle", title: effective.effort ?? "默认强度",
                             options: effortOptions, selection: controller.settings.effort ?? "") { new in
                    var s = controller.settings; s.effort = new.isEmpty ? nil : new; store.updateSettings(controller.id, s)
                }
            }
            .padding(.horizontal, 5)
        }
        .alert("指定模型", isPresented: $editingModel) {
            TextField("模型 ID", text: $customModel)
            Button("取消", role: .cancel) { }
            Button("使用模型") { updateModel(customModel.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } message: {
            Text("填写当前账号可用的模型 ID；留空恢复引擎默认模型。")
        }
    }

    private var engineMenu: some View {
        Menu {
            ForEach([ConversationEngine.claude, .codex], id: \.self) { engine in
                Button {
                    store.setDraftEngine(controller.id, engine: engine)
                } label: {
                    if controller.engine == engine { Label(engine.displayName, systemImage: "checkmark") }
                    else { Text(engine.displayName) }
                }
            }
        } label: {
            Chip(icon: isCodex ? "terminal" : "sparkle", title: controller.engine.displayName, showsChevron: controller.isDraft)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!controller.isDraft || controller.isWorking || controller.handoff != nil)
        .help(controller.handoff != nil ? "这段对话由 Claude 接管；原 Codex 对话保留" : (controller.isDraft ? "选择这次对话使用的引擎" : "对话使用 \(controller.engine.displayName)；新建对话可切换引擎"))
        .accessibilityLabel("对话引擎：\(controller.engine.displayName)")
    }

    private var modelMenu: some View {
        Menu {
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
        } label: {
            HStack(spacing: 4) {
                Text(modelTitle).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(liveInTerminal)
        .help("模型：\(effective.modelId ?? modelTitle)；更改在下一轮生效")
    }

    private var sendButton: some View {
        Button {
            if controller.isWorking { controller.stop() } else { submit() }
        } label: {
            Image(systemName: controller.isWorking ? "stop.fill" : "arrow.up")
                .font(.system(size: controller.isWorking ? 11 : 15, weight: .semibold))
                .foregroundStyle(Theme.sendFg)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.sendFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.isWorking && !canSend)
        .opacity(controller.isWorking || canSend ? 1 : 0.3)
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
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
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
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 11))
                Text(ThreadStore.displayName(for: controller.cwd)).lineLimit(1).truncationMode(.middle)
                if controller.isDraft { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.isDraft)
        .help("工作目录：\(controller.cwd)\(controller.isDraft ? "" : "（会话开始后不能更改）")")
    }

    private func settingsMenu(icon: String, title: String, options: [(id: String, title: String)],
                              selection: String, onChange: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.id) { option in
                Button { onChange(option.id) } label: {
                    if option.id == selection { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .padding(.vertical, 4)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(liveInTerminal)
        .help("\(title)；更改在下一轮生效")
    }
}

struct Chip: View {
    var icon: String
    var title: String
    var showsChevron = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium))
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if showsChevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill))
        .contentShape(Rectangle())
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
