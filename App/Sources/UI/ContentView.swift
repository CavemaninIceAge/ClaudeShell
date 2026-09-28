import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(ThreadStore.self) private var store
    var body: some View {
        WorkspaceView()
            .background(WorkspaceWindowStyle())
            .task { await store.bootstrap() }
    }
}

/// The same complete shell is used by the app and the isolated offscreen renderer.
struct WorkspaceView: View {
    @Environment(ThreadStore.self) private var store
    @State private var sidebarVisible = true
    @State private var sidebarWidth = Theme.sidebarWidth
    @State private var resizeOrigin: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if sidebarVisible {
                    SidebarView(onToggleSidebar: toggleSidebar)
                        .frame(width: min(sidebarWidth, max(240, geometry.size.width - 320)))
                    sidebarDivider(totalWidth: geometry.size.width)
                }
                VStack(spacing: 0) {
                    WorkspaceToolbar(sidebarVisible: sidebarVisible, onToggleSidebar: toggleSidebar)
                    if let id = store.selectedId, let controller = store.controllers[id] {
                        ThreadView(controller: controller).id(id)
                    } else {
                        VStack(spacing: 18) {
                            Text("开始新对话").font(.system(size: 28))
                            Button("新对话") { store.newThread() }.buttonStyle(PrimaryButtonStyle())
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
            }
        }
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.textPrimary)
        .alert("接管未完成", isPresented: Binding(
            get: { store.takeoverError != nil },
            set: { if !$0 { store.takeoverError = nil } }
        )) {
            Button("好") { store.takeoverError = nil }
        } message: { Text(store.takeoverError ?? "") }
    }

    private func toggleSidebar() { sidebarVisible.toggle() }
    private func sidebarDivider(totalWidth: CGFloat) -> some View {
        Rectangle().fill(Theme.sidebarSeparator).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 7).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if resizeOrigin == nil { resizeOrigin = sidebarWidth }
                            sidebarWidth = min(min(520, totalWidth - 320), max(240, (resizeOrigin ?? sidebarWidth) + value.translation.width))
                        }
                        .onEnded { _ in resizeOrigin = nil })
            }
            .accessibilityLabel("侧栏宽度")
            .accessibilityAdjustableAction { direction in
                sidebarWidth = min(min(520, totalWidth - 320), max(240, sidebarWidth + (direction == .increment ? 20 : -20)))
            }
    }
}

struct WorkspaceToolbar: View {
    @Environment(ThreadStore.self) private var store
    let sidebarVisible: Bool
    let onToggleSidebar: () -> Void
    private var controller: ConversationController? { store.selectedController }
    private var title: String {
        guard let controller, !controller.isDraft else { return "新聊天" }
        return store.summary(for: controller.id)?.title ?? "对话"
    }

    var body: some View {
        HStack(spacing: 8) {
            if !sidebarVisible {
                Color.clear.frame(width: 64)
                Button(action: onToggleSidebar) { WorkspaceIcon(.sidebar) }
                    .buttonStyle(WorkspaceIconButtonStyle())
                    .help("显示侧栏").accessibilityLabel("显示侧栏")
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
            Text(title).font(.system(size: 13, weight: .medium))
                .lineLimit(1).truncationMode(.tail).help(title)
            if let controller, !controller.isDraft {
                Text(ThreadStore.displayName(for: controller.cwd))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).help(controller.cwd)
            }
            Spacer(minLength: 12)
            if let controller {
                Menu {
                    Button("在访达中打开") { NSWorkspace.shared.open(URL(fileURLWithPath: controller.cwd)) }
                    Button("复制工作目录") { copy(controller.cwd) }
                } label: {
                    HStack(spacing: 5) {
                        WorkspaceIcon(.folder).frame(width: 14, height: 14)
                        Text("打开").font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }.padding(.horizontal, 7).frame(height: 28)
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).help("打开工作目录")
                Menu {
                    Text("\(controller.engine.displayName) 原生会话")
                    Divider()
                    if controller.engine == .codex && !controller.isDraft {
                        Button("用 Claude 接管") { Task { await store.takeoverWithClaude(controller.id) } }
                            .disabled(store.takingOverId != nil || controller.showsActivity || controller.isLoadingHistory)
                        Divider()
                    }
                    Button("复制会话 ID") { copy(controller.id) }
                    Button("刷新对话列表") { Task { await store.refresh() } }
                    if controller.totalCostUSD > 0 {
                        Text(String(format: "本会话 API 估算：$%.2f", controller.totalCostUSD))
                    }
                } label: { WorkspaceIcon(.more).frame(width: 28, height: 28) }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
                    .accessibilityLabel("对话操作").help("对话操作")
            }
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
        .background(WindowDragRegion()).background(Theme.background)
    }
    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// Configures only this app's own window; never activates, orders, moves or resizes it.
private struct WorkspaceWindowStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) { view.configure() }
    final class ChromeView: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
            window.isMovableByWindowBackground = false
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
