import Foundation

@MainActor enum WorkspaceNavigationRegression {
    static func run() throws {
        let nav = WorkspaceNavigation(threadID: "claude-a")
        nav.visit(.library)
        nav.visit(.home, threadID: "codex-b")
        nav.back()
        try CodexRegression.expect(nav.route == .library && nav.canGoForward, "back retains the library destination")
        nav.back()
        try CodexRegression.expect(nav.location.threadID == "claude-a" && !nav.canGoBack, "back retains native thread identity")
        nav.forward()
        nav.visit(.images)
        try CodexRegression.expect(!nav.canGoForward && nav.route == .images, "new navigation discards the stale forward branch")
        let count = nav.locations.count
        nav.visit(.images)
        try CodexRegression.expect(nav.locations.count == count, "reselecting a destination does not duplicate history")
        let renamed = WorkspaceNavigation(threadID: "draft")
        renamed.visit(.library)
        renamed.replaceThreadID(from: "draft", to: "codex:native")
        renamed.back()
        try CodexRegression.expect(renamed.location.threadID == "codex:native" && renamed.locations.count == 2, "native ID migration updates prior history without adding navigation")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudex-response-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let answer = TranscriptItem(id: "../../answer", kind: .assistant, blocks: [
            Block(id: "visible", kind: .text, text: "Visible **answer**", done: true),
            Block(id: "reasoning", kind: .thinking, text: "Private thought", done: true),
            Block(id: "tool", kind: .tool, tool: ToolCall(id: "tool", name: "Read", result: "private payload", done: true), done: true)
        ])
        let file = try WorkspaceResponseArchive.save(answer, threadID: "../../thread", directory: root)
        let text = try String(contentsOf: file, encoding: .utf8)
        try CodexRegression.expect(file.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path && text == "Visible **answer**\n", "saved response is local, path-safe and visible prose only")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        try CodexRegression.expect(permissions == 0o600, "saved response remains private")
        let draftSettings = ThreadSettings(model: "fixture-model", effort: "high", engine: .codex)
        let controller = ConversationController(id: "draft-fixture", cwd: "/fixture/old", settings: draftSettings, hasSessionFile: false)
        controller.composerDraft = "未发送的草稿"
        let draft = ThreadSummary(id: controller.id, title: "草稿", cwd: controller.cwd, createdAt: Date(), updatedAt: Date(), isDraft: true, liveStatus: nil, engine: .codex)
        let store = ThreadStore(snapshot: .init(drafts: [draft], controllers: [controller], selectedId: controller.id))
        store.setDraftCwd(controller.id, cwd: "/fixture/new")
        try CodexRegression.expect(store.selectedController?.composerDraft == "未发送的草稿" && store.selectedController?.settings == draftSettings,
                                   "changing draft folders preserves unsent text and engine/model settings")
        print("PASS — application navigation, drafts and saved-response fixtures")
    }
}
