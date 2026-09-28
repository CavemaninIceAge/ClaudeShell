import Foundation

/// Synthetic, non-sensitive view data. No engine, shell, session file, or credential store is involved.
@MainActor
enum WorkspaceFixtures {
    enum Surface: String, CaseIterable { case empty, conversation, richConversation = "rich-conversation" }
    static let date = Date().addingTimeInterval(-300)
    static let project = "/Preview/Projects/Claudex Shell"

    static func make(_ surface: Surface) -> (ThreadStore, AccountStore) {
        let selectedID = surface == .empty ? "preview-draft" : "preview-accounts"
        let settings = ThreadSettings(model: "gpt-6-astra", permissionMode: "auto", effort: "high", engine: .codex)
        let items: [TranscriptItem]
        switch surface {
        case .empty: items = []
        case .conversation: items = transcript
        case .richConversation: items = richTranscript
        }
        let controller = ConversationController(snapshot: .init(id: selectedID, cwd: project, settings: settings,
            items: items, model: "gpt-6-astra"))
        let history: [(String, String, String, ConversationEngine)] = [
            ("preview-accounts", "让账号切换只作用于当前应用", project, .codex),
            ("preview-interface", "调整侧栏和对话输入框的布局", project, .claude),
            ("preview-handoff", "接管 Codex 对话继续实现", project, .claude),
            ("preview-web", "完善产品页的响应式布局", "/Preview/Projects/Website", .codex),
            ("preview-animation", "检查导航栏的交互与动效", "/Preview/Projects/Website", .claude),
            ("preview-notes", "整理本周的工作记录", "/Preview/Projects/Notes", .claude),
            ("preview-release", "准备发布说明和回归检查", "/Preview/Projects/Notes", .codex),
        ]
        let records = history.enumerated().map { index, item in
            let ageOffsets: [TimeInterval] = [0, 900, 2700, 6900, 21_300, 86_100, 172_500]
            let updated = date.addingTimeInterval(-ageOffsets[index])
            return SessionRecord(id: item.0, cwd: item.2, title: item.1, createdAt: updated, updatedAt: updated,
                                 path: "/Preview/NotARealSession/\(item.0).jsonl", fileSize: 0, fileModified: updated, engine: item.3)
        }
        let drafts = surface == .empty ? [ThreadSummary(id: selectedID, title: "新对话", cwd: project,
            createdAt: date, updatedAt: date, isDraft: true, liveStatus: nil, engine: .codex)] : []
        let store = ThreadStore(snapshot: .init(records: records, drafts: drafts, controllers: [controller], selectedId: selectedID))
        let claude = ClaudeAccount(id: "preview-claude", email: "alex@example.invalid", orgName: "Personal", orgId: "preview",
                                  subscriptionType: "max", oauthAccount: .object([:]), addedAt: date)
        let codex = CodexAccount(id: "preview-codex", email: "alex@example.invalid", subscriptionType: "pro", addedAt: date)
        let accounts = AccountStore(snapshot: .init(accounts: [claude], activeId: claude.id, codexAccounts: [codex], activeCodexId: codex.id))
        return (store, accounts)
    }

    static var transcript: [TranscriptItem] {
        [
            TranscriptItem(id: "preview-user", kind: .user,
                text: "把账号切换和推送分开。默认只切换应用内账号，需要时再同步到终端或 Codex App。", timestamp: date),
            TranscriptItem(id: "preview-assistant", kind: .assistant, blocks: [
                Block(id: "preview-intro", kind: .text, text: "已把账号选择与外部推送拆开，并接入了原生会话。", done: true),
                Block(id: "preview-tool", kind: .tool, tool: ToolCall(id: "preview-tool", name: "Read",
                    input: .object(["file_path": .string("App/Sources/Model/AccountStore.swift")]),
                    result: "Reviewed account selection and isolated runtime configuration.", done: true,
                    startedAt: date, endedAt: date.addingTimeInterval(1)), done: true),
                Block(id: "preview-answer", kind: .text, text: """
                现在可以分别管理 Claude、GLM 和 Codex 登录态：

                - **切换账号**：只更新 Claudex Shell 内的新请求。
                - **推送至终端**：明确同步所选账号，并保存恢复备份。
                - **推送至 Codex App**：同步 Codex App 与 CLI 共用的登录态。

                会话继续由 Claude Code 和 Codex 原生引擎管理。账号操作与对话记录保持独立。
                """, done: true),
            ], timestamp: date.addingTimeInterval(2), meta: TurnMeta(durationMs: 1200, costUSD: nil)),
        ]
    }

    /// Compact rich Markdown coverage: both the code header and two-row table fit the narrow viewport.
    static var richTranscript: [TranscriptItem] {
        [
            TranscriptItem(id: "preview-rich-user", kind: .user,
                text: "给出切换示例，并列出作用范围。", timestamp: date),
            TranscriptItem(id: "preview-rich-assistant", kind: .assistant, blocks: [
                Block(id: "preview-rich-code-table", kind: .text, text: """
                ```swift
                let scope = LoginScope.application
                await accounts.select(id, in: scope)
                let sharedLoginIsUnchanged = true
                ```

                | 操作 | 作用范围 |
                | --- | --- |
                | 切换账号 | 当前应用 |
                | 推送账号 | 本机终端 |
                """, done: true),
            ], timestamp: date.addingTimeInterval(2)),
        ]
    }

}
