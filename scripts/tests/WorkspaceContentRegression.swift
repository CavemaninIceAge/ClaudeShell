import Foundation

enum WorkspaceContentRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor static func run() async throws {
        try derivation()
        try library()
        print("PASS — workspace artifact derivation and isolated library metadata")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func tool(_ id: String, _ name: String, input: String = "{}", result: String? = nil,
                             done: Bool = true, isError: Bool = false) -> Block {
        Block(id: id, kind: .tool,
              tool: ToolCall(id: id, name: name, input: JSONValue.parse(input), result: result, isError: isError, done: done), done: done)
    }

    private static func derivation() throws {
        let cwd = "/workspace/fixtures"
        let text = """
        [报告](outputs/report.pdf) ![图](</workspace/fixtures/output image.png>)
        [源文件](/workspace/fixtures/code.swift:17) [资料](https://example.com/reference)
        [无效](javascript:bad.txt) [无效](mailto:bad.txt)
        """
        let blocks = [
            tool("read", "Read", input: #"{"file_path":"/private/never-read.txt"}"#),
            tool("write", "Write", input: #"{"file_path":"outputs/generated.docx"}"#),
            tool("pending", "Write", input: #"{"file_path":"outputs/not-created.pdf"}"#, done: false),
            tool("failed", "Write", input: #"{"file_path":"outputs/failed.pdf"}"#, isError: true),
            tool("edit", "Edit", input: #"{"changes":[{"path":"src/changed.swift","kind":"update"},{"path":"src/deleted.swift","kind":"delete"}]}"#),
            tool("image", "mcp__images__generate_image", input: #"{"output_path":"outputs/chart.webp"}"#),
            tool("web", "mcp__research__fetch", input: #"{"url":"https://example.org/evidence"}"#),
            tool("task", "Task", input: #"{"description":"检查报告","prompt":"核验合成 fixture"}"#, result: "完成"),
            tool("running", "Agent", input: #"{"description":"整理来源"}"#, done: false),
            tool("spawn", "functions.spawn_agent", input: #"{"task_name":"新任务"}"#, result: #"{"agent_id":"child-1"}"#),
            tool("background", "Task", input: #"{"run_in_background":true,"description":"后台任务"}"#, result: "已创建")
        ]
        let item = TranscriptItem(id: "fixture", kind: .assistant, text: text, blocks: blocks, timestamp: Date(timeIntervalSince1970: 1))
        let before = WorkspaceConversationArtifacts.derive(items: [.user("[输入](/private/input.pdf)"), item], cwd: cwd)
        let paths = Set(before.outputs.map(\.url.path))
        try expect(paths == Set(["/workspace/fixtures/outputs/report.pdf", "/workspace/fixtures/output image.png", "/workspace/fixtures/code.swift",
                                "/workspace/fixtures/outputs/generated.docx", "/workspace/fixtures/src/changed.swift", "/workspace/fixtures/outputs/chart.webp"]), "Artifact derivation included non-output input or lost a document/image")
        try expect(before.sources.contains { $0.name == "mcp__research__fetch" && $0.url == nil }, "Actual MCP tool name missing")
        try expect(before.sources.contains { $0.url?.absoluteString == "https://example.org/evidence" }, "Actual tool source URL missing")
        try expect(before.runningCount == 1 && before.completedCount == 1, "Agent counts inferred status from spawn completion")
        try expect(before.subagents.first { $0.id == "child-1" }?.state == .unknown, "Spawned child should remain unknown without reported state")
        try expect(before.subagents.first { $0.id == "background" }?.state == .unknown, "Background launch falsely shown completed")
        let wait = TranscriptItem(id: "wait", kind: .assistant, blocks: [tool("wait", "functions.wait_agent", result: #"{"status":{"child-1":"completed"}}"#)])
        let after = WorkspaceConversationArtifacts.derive(items: [item, wait], cwd: cwd)
        try expect(after.completedCount == 2 && after.runningCount == 1 && after.subagents.count == 4, "Explicit child status was not reconciled")
        let native = TranscriptItem(id: "native", kind: .assistant, blocks: [
            tool("native-spawn", "collabAgentToolCall", input: #"{"tool":"spawnAgent","receiverThreadIds":["native-child"],"prompt":"检查合成内容","agentsStates":{"native-child":{"status":"running"}}}"#),
            tool("native-wait", "collabAgentToolCall", input: #"{"tool":"wait","receiverThreadIds":["native-child"],"agentStates":{"native-child":{"status":"completed"}}}"#)
        ])
        let nativeResult = WorkspaceConversationArtifacts.derive(items: [native], cwd: cwd)
        try expect(nativeResult.subagents.count == 1 && nativeResult.completedCount == 1, "Native wait duplicated an agent or dropped explicit state")
        try expect(nativeResult.subagents.first?.details.contains("检查合成内容") == true, "Native wait erased original agent details")
        try expect(WorkspaceConversationArtifacts.httpsURL("https://user:password@example.com/a") == nil, "Credential-bearing URL accepted")
        try expect(WorkspaceConversationArtifacts.httpsURL("http://example.com") == nil, "Non-HTTPS source accepted")
        try expect(WorkspaceConversationArtifacts.localURL("file://remote.example/a.pdf", cwd: cwd) == nil, "Remote file host treated as local output")
        try expect(WorkspaceConversationArtifacts.localURL("data:text/plain,a.pdf", cwd: cwd) == nil, "Data URL treated as local output")
    }

    @MainActor private static func library() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-content-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("user-file.png")
        let originalBytes = Data("synthetic original file; not a real image".utf8)
        try originalBytes.write(to: original)
        let storage = root.appendingPathComponent("metadata/library.json")
        let store = WorkspaceContentStore(storageURL: storage)
        store.add(url: original, threadID: "thread-a")
        try expect(!FileManager.default.fileExists(atPath: storage.path), "Constructor or mutation before explicit load wrote to disk")
        store.load()
        try expect(FileManager.default.fileExists(atPath: storage.path), "Explicit load did not flush pending metadata")
        store.add(url: original, threadID: "thread-a")
        try expect(store.assets.count == 1 && store.assets.first?.isImage == true, "Library duplicate or image classification failed")
        try expect(store.addSource(url: URL(string: "https://example.com/source")!, threadID: "thread-a"), "Valid source rejected")
        try expect(!store.addSource(url: URL(string: "http://example.com/source")!, threadID: "thread-a"), "Invalid source persisted")
        let second = WorkspaceContentStore(storageURL: storage)
        second.add(url: root.appendingPathComponent("before-load.pdf"), threadID: "thread-b")
        second.load()
        try expect(second.assets.count == 2 && second.sources.count == 1, "Load lost pending or saved metadata")
        try expect(second.assets(for: "thread-a").count == 1 && second.assets(for: "thread-b").count == 1, "Conversation library filtering leaked other thread entries")
        let items = [TranscriptItem(id: "artifact", kind: .assistant, text: "[结果](generated/report.pdf)")]
        second.recordArtifacts(items: items, cwd: root.path, threadID: "thread-a")
        second.recordArtifacts(items: items, cwd: root.path, threadID: "thread-a")
        try expect(second.assets.count == 3, "Recording loaded artifacts failed deduplication")
        second.remove(id: second.assets.first { $0.url == original }!.id)
        let afterBytes = try Data(contentsOf: original)
        try expect(afterBytes == originalBytes, "Removing a library reference modified the original file")
        let snapshot = WorkspaceContentStore(snapshot: second.assets, sources: second.sources)
        snapshot.load()
        snapshot.add(url: root.appendingPathComponent("snapshot-only.pdf"), threadID: nil)
        snapshot.removeSource(id: snapshot.sources[0].id)
        let persisted = WorkspaceContentStore(storageURL: storage)
        persisted.load()
        try expect(persisted.assets.count == 2 && persisted.sources.count == 1, "Snapshot mutation persisted fixture state")
        let generated = root.appendingPathComponent("generated/report.pdf")
        persisted.remove(id: persisted.assets.first { $0.url == generated }!.id)
        persisted.recordArtifacts(items: items, cwd: root.path, threadID: "thread-a")
        try expect(persisted.assets.count == 1, "Removed artifact reappeared on transcript refresh")
        let afterRemoval = WorkspaceContentStore(storageURL: storage)
        // Derivation can happen before explicit load; persisted dismissals must still win.
        afterRemoval.recordArtifacts(items: items, cwd: root.path, threadID: "thread-a")
        afterRemoval.load()
        afterRemoval.recordArtifacts(items: items, cwd: root.path, threadID: "thread-a")
        try expect(afterRemoval.assets.count == 1, "Removed artifact reappeared after library reload")
        afterRemoval.add(url: root.appendingPathComponent("kept.md"), threadID: "thread-a")
        afterRemoval.reassociateThread(from: "thread-a", to: "native-session")
        try expect(afterRemoval.assets(for: "native-session").count == 1 && afterRemoval.sources(for: "native-session").count == 1, "Draft migration lost files or sources")
        try expect(afterRemoval.assets(for: "thread-a").isEmpty && afterRemoval.sources(for: "thread-a").isEmpty, "Draft associations survived native migration")
        afterRemoval.recordArtifacts(items: items, cwd: root.path, threadID: "native-session")
        try expect(afterRemoval.isDismissed(url: generated, threadID: "native-session") && afterRemoval.assets(for: "native-session").count == 1, "Draft migration lost dismissed artifact state")
        afterRemoval.add(url: generated, threadID: "native-session")
        try expect(!afterRemoval.isDismissed(url: generated, threadID: "native-session") && afterRemoval.assets(for: "native-session").count == 2, "Manual import did not restore a dismissed artifact")
        let corruptURL = root.appendingPathComponent("broken.json")
        let corruptBytes = Data("{corrupt-original".utf8)
        try corruptBytes.write(to: corruptURL)
        let broken = WorkspaceContentStore(storageURL: corruptURL)
        broken.load()
        broken.add(url: original, threadID: nil)
        let afterCorrupt = try Data(contentsOf: corruptURL)
        try expect(afterCorrupt == corruptBytes && broken.lastError != nil, "Corrupt metadata was overwritten")
    }
}
