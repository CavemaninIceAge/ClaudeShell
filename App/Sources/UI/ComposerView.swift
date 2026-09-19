import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 底部的输入卡：附件条 + 多行文本 + 「+」/ 目录 / 模型 / 权限 / 强度胶囊 + 发送（或停止）键。
/// 文件 / 照片可以拖进来、⌘V 贴进来、或点「+」选；整张卡（连同外面的正文区）都是拖放目标。
struct ComposerView: View {
    let controller: ConversationController
    var dropTargeted = false                  // 外层正文区正被拖着东西经过（ThreadView 报进来）
    @Environment(ThreadStore.self) private var store
    @State private var text = ""
    @State private var isComposing = false   // 输入法正在组字（text 只含已上屏的字）
    @State private var editorHeight: CGFloat = 22
    @State private var editorDropTargeted = false

    private var liveInTerminal: Bool { controller.isLiveInTerminal }

    private var canSend: Bool {
        let hasText = !isComposing && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContent = hasText || (!isComposing && !controller.attachments.isEmpty)
        // 终端里开着的会话：这里发的话投进终端去，那边忙着也行（会在两次工具调用之间送到）。
        return hasContent && (liveInTerminal ? !controller.isLoadingHistory : controller.canSend)
    }

    private var highlightDrop: Bool { dropTargeted || editorDropTargeted }

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
            if !controller.attachments.isEmpty {
                AttachmentStrip(attachments: controller.attachments) { controller.removeAttachment($0) }
            }
            ComposerTextView(text: $text, isComposing: $isComposing, height: $editorHeight, onSubmit: submit,
                             onDropFiles: { controller.attach(urls: $0) },
                             onDropImage: { controller.attach(imageData: $0, name: $1) },
                             onDropTargeted: { editorDropTargeted = $0 })
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
                attachButton
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
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(highlightDrop ? Theme.textPrimary : Theme.line, lineWidth: highlightDrop ? 1.5 : 1))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
        .animation(.easeOut(duration: 0.12), value: highlightDrop)
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

    /// Codex 输入框左下角那个「+」：选文件 / 照片 / 目录挂到这条消息上。
    private var attachButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.prompt = "添加"
            panel.message = "选要发给 Claude 的文件、照片或目录"
            if panel.runModal() == .OK { controller.attach(urls: panel.urls) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.chipFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("添加文件、照片或目录（也可以直接拖进来、⌘V 粘贴）")
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

    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    private func fileURLs(on pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func imageData(on pb: NSPasteboard) -> Data? {
        for t in Self.imageTypes { if let d = pb.data(forType: t) { return d } }
        return nil
    }

    private func hasAttachable(_ pb: NSPasteboard) -> Bool {
        !fileURLs(on: pb).isEmpty || imageData(on: pb) != nil
    }

    /// 取走了就返回 true；否则由调用方交给 NSTextView 自己处理（普通文字）。
    /// textWins：剪贴板同时有文字和图片（Excel / Numbers 复制单元格会附一张渲染图）时按文字贴。
    @discardableResult
    private func takeAttachments(from pb: NSPasteboard, source: String, textWins: Bool = false) -> Bool {
        let urls = fileURLs(on: pb)
        if !urls.isEmpty {
            TestLog.write("composer \(source) files: \(urls.map(\.path))")
            onDropFiles?(urls)
            return true
        }
        if textWins, pb.string(forType: .string) != nil { return false }
        if let data = imageData(on: pb) {
            TestLog.write("composer \(source) image: \(data.count) bytes")
            onDropImage?(data, source == "paste" ? "剪贴板图片.png" : "拖入的图片.png")
            return true
        }
        return false
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

/// 测试钩子用的假拖放信息：只有剪贴板是真的，位置 / 图像都随便填。
final class TestDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
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
