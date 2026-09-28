import AppKit
import SwiftUI

// Reimplemented from the installed Codex desktop's measured layout and color tokens.
// Native engine behavior and account isolation stay in the existing models.

@main
struct ClaudexShellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let store = ThreadStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(AccountStore.shared)
                .tint(Theme.textPrimary)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Claudex Shell") { AppDelegate.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("新对话") { store.newThread() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("在文件夹中新建对话…") { store.newThreadPickingFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("对话") {
                Button("停止生成") { store.selectedController?.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!(store.selectedController?.isWorking ?? false))
                Button("刷新对话列表") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("复制会话 ID") {
                    if let id = store.selectedId {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(id, forType: .string)
                    }
                }
            }
            // 账号选择只影响本应用；推送至终端 / Codex App 是单独的操作。
            CommandMenu("账号") {
                AccountMenuItems()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // -testAppearance dark|light：只改本进程的外观（网页层跟着走），不动系统设置、不闪用户的屏幕。
        if let name = UserDefaults.standard.string(forKey: "testAppearance"), !name.isEmpty {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        // `pkill` / 脚本发的 SIGTERM 也走正常退出，把 claude 子进程和登录流程收干净。
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { AppDelegate.quit() }
        source.resume()
        sigterm = source
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// SwiftUI 的 `.sheet` 开着时 `terminate:` 会被它按「用户取消」吞掉（⌘Q 也一样），
    /// 所以先把登录面板收了，下一圈 run loop 再退。
    @MainActor static func quit() {
        let store = AccountStore.shared
        if store.loginSession != nil || store.addingProvider {
            store.loginSession?.cancel()
            store.loginSession = nil
            store.addingProvider = false
            DispatchQueue.main.async { NSApp.terminate(nil) }
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点 Dock 图标：有窗口就拉到前面，没窗口交给 SwiftUI 重开。
        if flag {
            sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            ThreadStore.shared.terminateAll()
            // 登录到一半退出：把 claude auth login 收掉，它不会因为 stdin 关了自己退出。
            AccountStore.shared.loginSession?.cancel()
        }
    }
}
