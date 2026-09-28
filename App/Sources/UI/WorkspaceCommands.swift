import SwiftUI

private struct WorkspaceNavigationFocusKey: FocusedValueKey { typealias Value = WorkspaceNavigation }
extension FocusedValues {
    var workspaceNavigation: WorkspaceNavigation? {
        get { self[WorkspaceNavigationFocusKey.self] }
        set { self[WorkspaceNavigationFocusKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    let store: ThreadStore
    @FocusedValue(\.workspaceNavigation) private var navigation
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新聊天") {
                let id = store.newThread()
                navigation?.visit(.home, threadID: id)
            }.keyboardShortcut("n", modifiers: .command)
            Button("在文件夹中新建聊天…") {
                if let id = store.newThreadPickingFolder() { navigation?.visit(.home, threadID: id) }
            }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("搜索对话") { navigation?.searchPresented = true }
                .keyboardShortcut("k", modifiers: .command)
        }
    }
}
