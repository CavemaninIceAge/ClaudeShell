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
            Button("项目文件") { navigation?.toolsTab = .files; navigation?.toolsVisible = true }.keyboardShortcut("e", modifiers: [.command, .option])
            Button("查看代码改动") { navigation?.toolsTab = .git; navigation?.toolsVisible = true }.keyboardShortcut("g", modifiers: [.command, .option])
            Button("运行命令") { navigation?.toolsTab = .command; navigation?.toolsVisible = true }.keyboardShortcut("j", modifiers: [.command, .option])
            Divider()
            Button("搜索对话") { navigation?.searchPresented = true }
                .keyboardShortcut("k", modifiers: .command)
        }
    }
}
