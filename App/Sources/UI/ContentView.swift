import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(ThreadStore.self) private var store
    @State private var navigation = WorkspaceNavigation()
    @State private var content = WorkspaceContentStore()
    @State private var tools = WorkspaceToolsStore()
    @AppStorage("workspaceAppearance") private var appearance = "system"
    var body: some View {
        WorkspaceView()
            .environment(navigation)
            .environment(content)
            .environment(tools)
            .focusedSceneValue(\.workspaceNavigation, navigation)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .background(WorkspaceWindowStyle())
            .task { content.load(); await store.bootstrap() }
            .onChange(of: store.selectedController?.cwd, initial: true) { _, cwd in
                if let cwd { tools.activate(cwd: cwd) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in tools.shutdown() }
    }
}

/// The complete application shell; production and offline fixtures render the same view.
struct WorkspaceView: View {
    @Environment(ThreadStore.self) private var store
    @Environment(AccountStore.self) private var accounts
    @Environment(WorkspaceNavigation.self) private var navigation
    @Environment(WorkspaceContentStore.self) private var content
    @Environment(WorkspaceToolsStore.self) private var tools
    @State private var sidebarVisible = true
    @State private var sidebarWidth = Theme.sidebarWidth
    @State private var resizeOrigin: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let width = min(sidebarWidth, max(240, geometry.size.width - Theme.railWidth - 420))
            let inlineInspector = geometry.size.width >= 1240
            VStack(spacing: 0) {
                WorkspaceToolbar(sidebarVisible: sidebarVisible, sidebarWidth: width, onToggleSidebar: toggleSidebar)
                HStack(spacing: 0) {
                    AppNavigationRail()
                        .frame(width: Theme.railWidth)
                    HStack(spacing: 0) {
                        if sidebarVisible {
                            SidebarView(onToggleSidebar: toggleSidebar).frame(width: width)
                            sidebarDivider(totalWidth: geometry.size.width)
                        }
                        page
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.background)
                        if navigation.route == .home && navigation.toolsVisible && geometry.size.width >= 1400 {
                            toolsPanel.frame(width: min(620, max(440, geometry.size.width * 0.38)))
                        }
                        if navigation.route == .home && !navigation.toolsVisible && navigation.inspectorVisible && inlineInspector {
                            inspector.frame(width: 300).padding(.trailing, 5)
                                .padding(.top, 6).frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .background(Theme.background)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16))
                }
            }
            .background(Theme.rail)
            .overlay(alignment: .topTrailing) {
                if navigation.route == .home && !navigation.toolsVisible && navigation.inspectorVisible && !inlineInspector {
                    VStack(alignment: .trailing, spacing: 4) {
                        Button { navigation.inspectorVisible = false } label: {
                            Label("关闭详情", systemImage: "xmark")
                                .font(.system(size: 12)).padding(8)
                                .background(Theme.background, in: Capsule())
                        }.buttonStyle(.plain)
                        inspector.frame(width: 300)
                    }
                    .padding(.top, Theme.toolbarHeight + 8).padding(.trailing, 8)
                }
            }
            .sheet(isPresented: Binding(get: { navigation.toolsVisible && geometry.size.width < 1400 }, set: { if !$0 { navigation.toolsVisible = false } })) {
                toolsPanel.frame(width: min(920, max(720, geometry.size.width - 60)), height: max(440, min(760, geometry.size.height - 70)))
            }
            .onChange(of: geometry.size.width, initial: true) { _, newWidth in
                if newWidth < 1240 { navigation.inspectorVisible = false }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .onAppear { navigation.seed(threadID: store.selectedId); recordArtifacts() }
        .onChange(of: store.selectedId) { previous, id in
            if previous == nil { navigation.seed(threadID: id) }
            if let previous, let id, store.threadIdentityChanges[previous] == id {
                navigation.replaceThreadID(from: previous, to: id)
                content.reassociateThread(from: previous, to: id)
            } else if navigation.location.threadID != id {
                navigation.visit(.home, threadID: id)
            }
            recordArtifacts()
        }
        .onChange(of: store.threadIdentityChanges) { old, new in
            for (previous, current) in new where old[previous] != current {
                navigation.replaceThreadID(from: previous, to: current)
                content.reassociateThread(from: previous, to: current)
            }
        }
        .onChange(of: navigation.location) { _, location in
            if location.route == .home, let id = location.threadID, store.selectedId != id {
                store.selectedId = id
            }
        }
        .onChange(of: store.selectedController?.items) { _, _ in recordArtifacts() }
        .sheet(isPresented: Binding(get: { navigation.previewURL != nil }, set: { if !$0 { navigation.previewURL = nil } })) {
            if let url = navigation.previewURL { WorkspaceFilePreview(url: url) }
        }
        .sheet(isPresented: Binding(get: { navigation.searchPresented }, set: { navigation.searchPresented = $0 })) {
            WorkspaceSearchSheet()
        }
        .sheet(item: Binding(get: { accounts.loginSession }, set: { if $0 == nil { accounts.loginSession = nil } })) {
            AccountLoginSheet(session: $0)
        }
        .sheet(item: Binding(get: { accounts.codexLoginSession }, set: { if $0 == nil { accounts.codexLoginSession?.cancel(); accounts.codexLoginSession = nil } })) {
            CodexLoginSheet(session: $0)
        }
        .sheet(isPresented: Binding(get: { accounts.addingProvider }, set: { accounts.addingProvider = $0 })) { ProviderAddSheet() }
        .sheet(item: Binding(get: { accounts.codexPushConfirmation }, set: { accounts.codexPushConfirmation = $0 })) {
            CodexDesktopPushSheet(account: $0)
        }
        .alert("接管未完成", isPresented: Binding(get: { store.takeoverError != nil }, set: { if !$0 { store.takeoverError = nil } })) {
            Button("好") { store.takeoverError = nil }
        } message: { Text(store.takeoverError ?? "") }
        .alert("操作未完成", isPresented: Binding(
            get: { accounts.lastError != nil || content.lastError != nil || store.workspaceError != nil },
            set: { if !$0 { accounts.lastError = nil; content.lastError = nil; store.workspaceError = nil } }
        )) {
            Button("好") { accounts.lastError = nil; content.lastError = nil; store.workspaceError = nil }
        } message: { Text(accounts.lastError ?? content.lastError ?? store.workspaceError ?? "") }
    }

    @ViewBuilder private var page: some View {
        switch navigation.route {
        case .home:
            if let id = store.selectedId, let controller = store.controllers[id] {
                ThreadView(controller: controller).id(id)
            } else {
                VStack(spacing: 18) {
                    Text("我们开始吧").font(.system(size: 28))
                    Button("新聊天") { store.newThread() }.buttonStyle(PrimaryButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .history: WorkspaceHistoryPage()
        case .library: WorkspaceLibraryPage()
        case .images: WorkspaceImagesPage()
        case .apps: WorkspaceAppsPage()
        case .settings: WorkspaceSettingsPage()
        }
    }
    private var toolsPanel: some View {
        WorkspaceToolsPanel(cwd: store.selectedController?.cwd ?? NSHomeDirectory(), initialTab: navigation.toolsTab,
                            onClose: { navigation.toolsVisible = false },
                            onAttachFile: { url in store.selectedController?.attach(urls: [url]) })
            .environment(tools)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
    }
    private var inspector: some View {
        WorkspaceInspector()
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line, lineWidth: 0.75))
            .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 3)
    }
    private func recordArtifacts() {
        guard let c = store.selectedController else { return }
        content.recordArtifacts(items: c.items, cwd: c.cwd, threadID: c.id)
    }
    private func toggleSidebar() { sidebarVisible.toggle() }
    private func sidebarDivider(totalWidth: CGFloat) -> some View {
        Rectangle().fill(Theme.sidebarSeparator).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 7).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if resizeOrigin == nil { resizeOrigin = sidebarWidth }
                            sidebarWidth = min(min(440, totalWidth - Theme.railWidth - 420), max(240, (resizeOrigin ?? sidebarWidth) + value.translation.width))
                        }.onEnded { _ in resizeOrigin = nil })
            }
            .accessibilityLabel("侧栏宽度")
            .accessibilityAdjustableAction { direction in
                sidebarWidth = min(min(440, totalWidth - Theme.railWidth - 420), max(240, sidebarWidth + (direction == .increment ? 20 : -20)))
            }
    }
}

struct WorkspaceToolbar: View {
    @Environment(ThreadStore.self) private var store
    @Environment(WorkspaceNavigation.self) private var navigation
    let sidebarVisible: Bool
    let sidebarWidth: CGFloat
    let onToggleSidebar: () -> Void
    private var controller: ConversationController? { store.selectedController }
    private var title: String {
        guard navigation.route == .home else { return navigation.route.title }
        guard let controller, !controller.isDraft else { return "新聊天" }
        return store.summary(for: controller.id)?.title ?? "对话"
    }
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Color.clear.frame(width: 89)
                iconButton("arrow.left", title: "后退", action: navigation.back)
                    .disabled(!navigation.canGoBack).keyboardShortcut("[", modifiers: .command)
                iconButton("arrow.right", title: "前进", action: navigation.forward)
                    .disabled(!navigation.canGoForward).keyboardShortcut("]", modifiers: .command)
                Button(action: onToggleSidebar) { WorkspaceIcon(.sidebar) }
                    .buttonStyle(WorkspaceIconButtonStyle())
                    .help(sidebarVisible ? "收起侧栏" : "显示侧栏")
                    .accessibilityLabel("切换侧栏").keyboardShortcut("s", modifiers: [.command, .control])
                Spacer(minLength: 0)
            }.frame(width: sidebarVisible ? Theme.railWidth + sidebarWidth : 235)
            Rectangle().fill(Theme.line).frame(width: 1, height: 20)
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                .truncationMode(.tail).padding(.horizontal, 12).help(title)
            Spacer(minLength: 12)
            Menu {
                if let controller, navigation.route == .home {
                    Text("\(controller.engine.displayName) 原生会话")
                    Divider()
                    if controller.engine == .codex && !controller.isDraft {
                        Button("用 Claude 接管") { Task { await store.takeoverWithClaude(controller.id) } }
                            .disabled(store.takingOverId != nil || controller.showsActivity || controller.isLoadingHistory)
                        Divider()
                    }
                    Button("项目文件") { showTools(.files) }
                    Button("查看代码改动") { showTools(.git) }
                    Button("运行命令") { showTools(.command) }
                    Divider()
                    Button("在访达中打开目录") { NSWorkspace.shared.open(URL(fileURLWithPath: controller.cwd)) }
                    Button("复制工作目录") { copy(controller.cwd) }
                    Button("复制会话 ID") { copy(controller.id) }
                    if controller.totalCostUSD > 0 { Text(String(format: "本会话 API 估算：$%.2f", controller.totalCostUSD)) }
                    Divider()
                }
                Button("刷新对话列表") { Task { await store.refresh() } }
                Button("搜索对话") { navigation.searchPresented = true }
                Button("设置") { navigation.visit(.settings) }
            } label: { WorkspaceIcon(.more).frame(width: 28, height: 28) }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
                .help("更多操作").accessibilityLabel("更多操作")
            Button { navigation.inspectorVisible.toggle() } label: { WorkspaceIcon(.inspector) }
                .buttonStyle(WorkspaceIconButtonStyle())
                .help("产物、子代理与来源").accessibilityLabel("产物、子代理与来源")
                .background(navigation.inspectorVisible && navigation.route == .home ? Theme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 9))
                .disabled(navigation.route != .home)
                .keyboardShortcut("i", modifiers: [.command, .option])
            Rectangle().fill(Theme.line).frame(width: 1, height: 16).padding(.horizontal, 7)
            iconButton("plus.square", title: "新聊天") { store.newThread(); navigation.visit(.home, threadID: store.selectedId) }
        }
        .padding(.trailing, 8).frame(height: Theme.toolbarHeight)
        .foregroundStyle(Theme.textSecondary)
        .background(WindowDragRegion()).background(Theme.toolbar)
    }
    private func iconButton(_ icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 13, weight: .regular)).frame(width: 28, height: 28) }
            .buttonStyle(WorkspaceIconButtonStyle()).help(title).accessibilityLabel(title)
    }
    private func showTools(_ tab: WorkspaceToolTab) { navigation.toolsTab = tab; navigation.toolsVisible = true }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

private struct WorkspaceSearchSheet: View {
    @Environment(ThreadStore.self) private var store
    @Environment(WorkspaceNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool
    private var matches: [ThreadSummary] {
        store.groups.flatMap(\.threads).filter {
            query.isEmpty || ($0.title + " " + $0.cwd + " " + $0.engine.displayName).localizedCaseInsensitiveContains(query)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("搜索对话或项目", text: $query).textFieldStyle(.plain).focused($focused)
                Button("取消") { dismiss() }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            }.font(.system(size: 15))
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(matches) { thread in
                        Button {
                            store.selectedId = thread.id; navigation.visit(.home, threadID: thread.id); dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(thread.title).lineLimit(1).foregroundStyle(Theme.textPrimary)
                                    Text(thread.engine.displayName + " · " + ThreadStore.displayPath(for: thread.cwd))
                                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.left").foregroundStyle(Theme.textTertiary)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    ForEach(store.savedProjects.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { cwd in
                        Button {
                            let id = store.newThread(cwd: cwd); navigation.visit(.home, threadID: id); dismiss()
                        } label: {
                            Label("在项目中开始：" + ThreadStore.displayPath(for: cwd), systemImage: "folder")
                                .font(.system(size: 13)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    if matches.isEmpty && store.savedProjects.isEmpty { Text("没有找到对话").foregroundStyle(Theme.textSecondary).padding(12) }
                }
            }
        }.padding(20).frame(width: 560, height: 430).background(Theme.background)
            .onAppear { if NSApp.activationPolicy() != .prohibited { focused = true } }
            .onExitCommand { dismiss() }
    }
}

/// Configures only this app's own window; never activates, orders, moves or resizes it.
struct WorkspaceWindowStyle: NSViewRepresentable {
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
            alignWindowControls()
        }
        override func layout() { super.layout(); alignWindowControls() }
        private func alignWindowControls() {
            guard let window, let frameView = window.contentView?.superview else { return }
            // Position the real AppKit controls inside our 44pt titlebar; never draw substitutes.
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window.standardWindowButton(kind), let titlebar = button.superview else { continue }
                let center = titlebar.convert(CGPoint(x: 23.25 + CGFloat(index) * 23, y: frameView.bounds.maxY - 23.75), from: frameView)
                let next = NSRect(x: center.x - button.frame.width / 2, y: center.y - button.frame.height / 2,
                                  width: button.frame.width, height: button.frame.height)
                if button.frame != next { button.setFrameOrigin(next.origin) }
            }
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
