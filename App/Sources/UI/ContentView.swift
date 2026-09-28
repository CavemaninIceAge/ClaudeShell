import SwiftUI

struct ContentView: View {
    @Environment(ThreadStore.self) private var store
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 360)
        } detail: {
            if let id = store.selectedId, let controller = store.controllers[id] {
                // 是否草稿以 controller 为准：发出第一条消息的瞬间就切成线程标题，不等磁盘扫描。
                let title = controller.isDraft ? "新对话" : (store.summary(for: id)?.title ?? "新对话")
                ThreadView(controller: controller)
                    .id(id)
                    .navigationTitle(title)
                    .navigationSubtitle(ThreadStore.displayPath(for: controller.cwd))
            } else {
                ZStack {
                    Theme.background.ignoresSafeArea()
                    ContentUnavailableView("从左侧选一个对话，或按 ⌘N 新建", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
        }
        .alert("接管未完成", isPresented: Binding(
            get: { store.takeoverError != nil },
            set: { if !$0 { store.takeoverError = nil } }
        )) {
            Button("好") { store.takeoverError = nil }
        } message: { Text(store.takeoverError ?? "") }
        .tint(Theme.textPrimary)
        .task { await store.bootstrap() }
    }
}
