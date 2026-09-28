import AppKit
import SwiftUI

// 方向契约（impeccable · code-first · 用户钦定"完全参照 Codex"，未走方向抽签）
// THESIS: 这是终端里那个 Claude Code 的窗口，不是另一个聊天客户端。拒绝的默认版式：左右对齐的双色气泡流。
// OWN-WORLD: Codex 桌面版的灰白世界——白/深灰单色地、系统字、无边框正文、灰色圆角的用户消息、
//            一枚 16pt 圆角的输入卡、折叠成一行的"思考"和"已完成 N 步"。没有主题色，只有黑白与一枚陶土橙的图标。
// STORY: 点 Dock 图标 → 居中的问候 + 输入卡 → 敲回车 → 看到思考、工具步骤、Markdown 回答依次出现 → 左侧切另一个对话继续。
// FIRST VIEWPORT: 左 264pt 原生侧栏（"新对话"按钮、按项目分组的会话）；右侧居中 780pt 单列：
//                 顶部问候语 24pt，其下一张输入卡（占位文字、目录/模型/权限三枚胶囊、右下黑色圆形发送键）。
// FORM: canon——Codex 桌面版对话壳，候选清单第 1 位；brief 钦定，无 seed key。
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict,
//         DESIGN.md, and every shipping raster carrying its provenance

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
        .windowToolbarStyle(.unified)
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
