import AppKit
import Foundation

/// In-memory view fixtures. No engine, shell, session file, or credential store is involved.
/// The reference surface additionally reads only the screenshot attachment explicitly supplied by its caller.
@MainActor
enum WorkspaceFixtures {
    enum Surface: String, CaseIterable {
        case empty, conversation, richConversation = "rich-conversation", referenceConversation = "reference-conversation"
        case history, library, images, apps, settings, files, git, command
        var route: WorkspaceRoute {
            switch self {
            case .empty, .conversation, .richConversation, .referenceConversation, .files, .git, .command: return .home
            case .history: return .history
            case .library: return .library
            case .images: return .images
            case .apps: return .apps
            case .settings: return .settings
            }
        }
    }
    static let date = Date().addingTimeInterval(-300)
    static let project = "/Preview/Projects/Claudex Shell"

    static func make(_ surface: Surface, assets: [WorkspaceAsset], projectOverride: String? = nil) -> (ThreadStore, AccountStore, WorkspaceNavigation, WorkspaceContentStore) {
        let project = projectOverride ?? Self.project
        let isReference = surface == .referenceConversation
        let selectedID = surface == .empty ? "preview-draft" : (isReference ? "preview-reference" : "preview-accounts")
        let settings = ThreadSettings(model: "gpt-6-astra", permissionMode: "auto", effort: isReference ? "ultra" : "high", engine: .codex)
        let items: [TranscriptItem]
        switch surface {
        case .empty: items = []
        case .conversation, .history, .library, .images, .apps, .settings, .files, .git, .command: items = transcript(assets: assets)
        case .richConversation: items = richTranscript
        case .referenceConversation: items = referenceTranscript
        }
        let controller = ConversationController(snapshot: .init(id: selectedID, cwd: project, settings: settings,
            items: items, model: "gpt-6-astra"))
        if isReference {
            controller.composerDraft = "这些东西为什么你没有复刻，我要的是整个的codex，明白么？"
            // The caller explicitly supplies the user's reference attachment. No private files are discovered.
            if let path = ProcessInfo.processInfo.environment["CLAUDEX_REFERENCE_ATTACHMENT"],
               FileManager.default.isReadableFile(atPath: path) {
                controller.attach(urls: [URL(fileURLWithPath: path)])
            }
        }
        UserDefaults.standard.set("[\"preview-pin-1\",\"preview-pin-2\",\"preview-pin-3\",\"preview-pin-4\",\"preview-pin-5\",\"preview-pin-6\"]", forKey: "workspacePinnedThreads")
        let history: [(String, String, String, ConversationEngine)] = isReference ? referenceHistory(project: project) : [
            ("preview-accounts", "让账号切换只作用于当前应用", project, .codex),
            ("preview-interface", "调整侧栏和对话输入框的布局", project, .claude),
            ("preview-handoff", "接管 Codex 对话继续实现", project, .claude),
            ("preview-web", "完善产品页的响应式布局", "/Preview/Projects/Website", .codex),
            ("preview-animation", "检查导航栏的交互与动效", "/Preview/Projects/Website", .claude),
            ("preview-notes", "整理本周的工作记录", "/Preview/Projects/Notes", .claude),
            ("preview-release", "准备发布说明和回归检查", "/Preview/Projects/Notes", .codex),
            ("preview-pin-1", "设计完整工作区导航", project, .codex),
            ("preview-pin-2", "整理项目资料与参考", project, .claude),
            ("preview-pin-3", "回顾本周的开发进度", project, .codex),
            ("preview-pin-4", "检查深色主题与交互", project, .claude),
            ("preview-pin-5", "准备新版发布计划", project, .codex),
            ("preview-pin-6", "保存常用的项目模板", project, .claude),
        ]
        let records = history.enumerated().map { index, item in
            let ageOffsets: [TimeInterval] = [0, 900, 2700, 6900, 21_300, 86_100, 172_500]
            let updated = date.addingTimeInterval(-(index < ageOffsets.count ? ageOffsets[index] : TimeInterval(index * 86_400)))
            return SessionRecord(id: item.0, cwd: item.2, title: item.1, createdAt: updated, updatedAt: updated,
                                 path: "/Preview/NotARealSession/\(item.0).jsonl", fileSize: 0, fileModified: updated, engine: item.3)
        }
        let drafts = surface == .empty ? [ThreadSummary(id: selectedID, title: "新对话", cwd: project,
            createdAt: date, updatedAt: date, isDraft: true, liveStatus: nil, engine: .codex)] : []
        let store = ThreadStore(snapshot: .init(records: records, drafts: drafts, controllers: [controller], selectedId: selectedID))
        let claude = ClaudeAccount(id: "preview-claude", email: "alex@example.invalid", orgName: "Personal", orgId: "preview",
                                  subscriptionType: "max", oauthAccount: .object([:]), addedAt: date)
        let codex = CodexAccount(id: "preview-codex", email: "alex@example.invalid", subscriptionType: "pro", addedAt: date)
        let provider = APIProvider(id: "preview-glm", name: "GLM · 示例账号", baseURL: "https://api.example.invalid",
                                   keychainService: "preview-not-a-keychain-entry", model: "glm-demo", addedAt: date)
        let accounts = AccountStore(snapshot: .init(accounts: [claude], activeId: claude.id, providers: [provider],
                                                   codexAccounts: [codex], activeCodexId: codex.id))
        let navigation = WorkspaceNavigation(route: surface.route, threadID: surface.route == .home ? selectedID : nil,
                                              inspectorVisible: surface != .empty)
        let content = WorkspaceContentStore(snapshot: isReference ? [] : assets)
        return (store, accounts, navigation, content)
    }

    /// Reference-only reconstruction of the screenshot supplied by the user.
    /// These messages, timings and completed tools are visual fixtures, not claims about a run.
    /// Fragment links preserve the screenshot's link layout without opening files or remote services.
    static var referenceTranscript: [TranscriptItem] {
        let firstDuration = 31 * 60 + 4
        let secondDuration = 2 * 60 + 24
        var firstTools = [
            referenceTool(id: "reference-app-tools", name: "ChatGPT App Tools", duration: firstDuration),
            referenceTool(id: "reference-web-search", name: "Web search", duration: firstDuration),
        ]
        for index in 1...5 {
            let id = "reference-agent-\(index)"
            firstTools.append(Block(id: id, kind: .tool, tool: ToolCall(id: id, name: "collabAgentToolCall",
                input: .object(["tool": .string("spawnAgent"), "receiverThreadIds": .array([.string(id)]),
                                "description": .string("截图中的示例子代理 \(index)"),
                                "agentsStates": .object([id: .string("completed")])]),
                result: "仅用于复现用户提供截图；没有启动子代理。", done: true,
                startedAt: date.addingTimeInterval(-Double(firstDuration)), endedAt: date), done: true))
        }
        firstTools.append(Block(id: "reference-first-answer", kind: .text, text: """
        已完成 **Claudex Shell 0.2.1**：侧栏、标题栏、输入框、对话排版和浅深色主题均按本机 Codex 重做。10 张界面截图、回归测试及 Release 构建通过；尚未验证逐像素一致。

        [浅色预览](#reference-light-preview) · [深色预览](#reference-dark-preview) · [安装包](#reference-package)

        代码已提交 `8d43d89`。是否确认推送至 [ClaudeShell 仓库](#reference-repository)，并安装、启动新版？

        自动审批拒绝了推送，要求确认具体代码与目标仓库；启动窗口也需要遵守你 AGENTS.md 的单独授权要求。目前尚未推送或重启。
        """, done: true))
        return [
            TranscriptItem(id: "reference-first-assistant", kind: .assistant, blocks: firstTools,
                timestamp: date, meta: TurnMeta(durationMs: firstDuration * 1000, costUSD: nil)),
            TranscriptItem(id: "reference-user-approval", kind: .user, text: "同意推送与重启",
                timestamp: date.addingTimeInterval(1)),
            TranscriptItem(id: "reference-second-assistant", kind: .assistant, blocks: [
                referenceTool(id: "reference-install-result", name: "ChatGPT App Tools", duration: secondDuration),
                Block(id: "reference-second-answer", kind: .text, text: """
                已完成：

                - 已推送至 GitHub `main`，提交 [`8d43d89`](#reference-commit)。
                - 已安装并启动 **Claudex Shell 0.2.1（构建 3）**，运行正常。
                - 旧版已备份，现在打开的是新版界面。
                """, done: true),
            ], timestamp: date.addingTimeInterval(Double(secondDuration + 1)),
               meta: TurnMeta(durationMs: secondDuration * 1000, costUSD: nil)),
        ]
    }

    private static func referenceTool(id: String, name: String, duration: Int) -> Block {
        Block(id: id, kind: .tool, tool: ToolCall(id: id, name: name,
            input: .object(["description": .string("用户截图的离屏视觉参考")]),
            result: "仅用于复现用户提供截图；没有执行此工具。", done: true,
            startedAt: date.addingTimeInterval(-Double(duration)), endedAt: date), done: true)
    }

    private static func referenceHistory(project: String) -> [(String, String, String, ConversationEngine)] {
        let supplied: [String]? = ProcessInfo.processInfo.environment["CLAUDEX_REFERENCE_TITLES"]
            .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        let defaults = ["整理项目提醒与任务", "升级 Claudex Shell 多账号与对话", "迁移历史会话", "分析产品数据", "查找项目术语", "整理调研笔记", "核实公开资料", "解释统计指标", "构建移动客户端", "Clarify task request", "准备访谈提纲", "查询地点资料", "翻译项目文档", "解释术语含义", "Recent Voice Chat Topic", "比较技术方案", "解释参数含义", "整理上线流程", "解释.env文件", "https://example.invalid/reference", "AI研究", "数据重整", "更多固定对话 1", "更多固定对话 2"]
        return defaults.enumerated().map { index, fallback in
            let id = index == 1 ? "preview-reference" : index >= 18 ? "preview-pin-\(index - 17)" : "reference-history-\(index)"
            let title = supplied.flatMap { index < $0.count ? $0[index] : nil } ?? fallback
            return (id, title, project, index == 2 ? .claude : .codex)
        }
    }

    static func transcript(assets: [WorkspaceAsset]) -> [TranscriptItem] {
        [
            TranscriptItem(id: "preview-user", kind: .user,
                text: "把账号切换和推送分开。默认只切换应用内账号，需要时再同步到终端或 Codex App。", timestamp: date),
            TranscriptItem(id: "preview-assistant", kind: .assistant, blocks: [
                Block(id: "preview-intro", kind: .text, text: "已把账号选择与外部推送拆开，并接入了原生会话。", done: true),
                Block(id: "preview-tool", kind: .tool, tool: ToolCall(id: "preview-tool", name: "Read",
                    input: .object(["file_path": .string("App/Sources/Model/AccountStore.swift")]),
                    result: "Reviewed account selection and isolated runtime configuration.", done: true,
                    startedAt: date, endedAt: date.addingTimeInterval(1)), done: true),
                Block(id: "preview-agent-interface", kind: .tool, tool: ToolCall(id: "preview-agent-interface", name: "Agent",
                    input: .object(["description": .string("界面检查"), "prompt": .string("检查合成示例中的导航布局。")]),
                    result: "示例布局检查完成。", done: true, startedAt: date, endedAt: date.addingTimeInterval(1)), done: true),
                Block(id: "preview-agent-tests", kind: .tool, tool: ToolCall(id: "preview-agent-tests", name: "Agent",
                    input: .object(["description": .string("回归检查"), "prompt": .string("验证合成示例数据。")]),
                    result: "示例数据检查完成。", done: true, startedAt: date, endedAt: date.addingTimeInterval(1)), done: true),
                Block(id: "preview-answer", kind: .text, text: """
                现在可以分别管理 Claude、GLM 和 Codex 登录态：

                - **切换账号**：只更新 Claudex Shell 内的新请求。
                - **推送至终端**：明确同步所选账号，并保存恢复备份。
                - **推送至 Codex App**：同步 Codex App 与 CLI 共用的登录态。

                会话继续由 Claude Code 和 Codex 原生引擎管理。账号操作与对话记录保持独立。

                [查看示例交付说明](<\(assets.first { !$0.isImage }?.url.path ?? "/Preview/示例交付说明.md")>) · [参考资料](https://example.invalid/reference)
                """, done: true),
            ], timestamp: date.addingTimeInterval(2), meta: TurnMeta(durationMs: 1200, costUSD: nil)),
        ]
    }

    /// Creates only synthetic test assets within the snapshot output directory.
    /// Each image is plainly labelled as a fixture; no user files or sessions are read.
    static func makeAssets(in directory: URL) throws -> [WorkspaceAsset] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var assets: [WorkspaceAsset] = []
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.91, 0.69, 0.49), (0.65, 0.78, 0.86), (0.72, 0.79, 0.65)]
        for (index, color) in colors.enumerated() {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720, pixelsHigh: 480,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            NSColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 720, height: 480)).fill()
            NSColor.white.withAlphaComponent(0.25).setStroke()
            for x in stride(from: 0, through: 720, by: 60) {
                let line = NSBezierPath(); line.move(to: NSPoint(x: CGFloat(x), y: 0)); line.line(to: NSPoint(x: CGFloat(x), y: 480)); line.stroke()
            }
            for y in stride(from: 0, through: 480, by: 60) {
                let line = NSBezierPath(); line.move(to: NSPoint(x: 0, y: CGFloat(y))); line.line(to: NSPoint(x: 720, y: CGFloat(y))); line.stroke()
            }
            ("SAMPLE 0\(index + 1)" as NSString).draw(at: NSPoint(x: 38, y: 370), withAttributes: [
                .font: NSFont.systemFont(ofSize: 46, weight: .medium), .foregroundColor: NSColor.black.withAlphaComponent(0.75),
            ])
            ("Offline UI fixture · 合成示例" as NSString).draw(at: NSPoint(x: 40, y: 38), withAttributes: [
                .font: NSFont.systemFont(ofSize: 21), .foregroundColor: NSColor.black.withAlphaComponent(0.65),
            ])
            graphics.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            let url = directory.appendingPathComponent("示例图片-0\(index + 1).png")
            try png.write(to: url, options: .atomic)
            assets.append(WorkspaceAsset(id: "preview-image-\(index)", url: url, name: url.lastPathComponent,
                                         threadID: index == 0 ? "preview-accounts" : nil, addedAt: date.addingTimeInterval(-Double(index * 100))))
        }
        for (index, document) in [("示例交付说明.md", "# 合成示例\n\n此文件仅用于离屏界面检查，不包含真实用户数据。\n"),
                                  ("示例检查记录.csv", "页面,结果\n导航,示例\n资料库,示例\n")].enumerated() {
            let url = directory.appendingPathComponent(document.0)
            try Data(document.1.utf8).write(to: url, options: .atomic)
            assets.append(WorkspaceAsset(id: "preview-document-\(index)", url: url, name: url.lastPathComponent,
                                         threadID: "preview-accounts", addedAt: date.addingTimeInterval(-Double(index * 100))))
        }
        return assets
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
