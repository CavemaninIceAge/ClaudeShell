import Foundation

@MainActor
enum CodexRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run() async throws {
        let old = try JSONDecoder().decode(ThreadSettings.self, from: Data(#"{"model":"sonnet","permissionMode":"manual"}"#.utf8))
        try expect(old.engine == .claude && old.effort == nil, "legacy settings must remain Claude")
        let codex = ThreadSettings(model: "fixture-model", permissionMode: "manual", effort: "high", engine: .codex)
        let roundtrip = try JSONDecoder().decode(ThreadSettings.self, from: JSONEncoder().encode(codex))
        try expect(roundtrip == codex, "Codex settings roundtrip")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudex-codex-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let rollout = root.appendingPathComponent("rollout-2026-09-28T10-00-00-" + sid + ".jsonl")
        let lines = [
            #"{"timestamp":"2026-09-28T10:00:00Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","cwd":"/fixture/project","timestamp":"2026-09-28T10:00:00Z"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"private system instructions"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the test"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Fix the test"}}"#,
            #"{"type":"turn_context","payload":{"model":"fixture-model"}}"#,
            #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Checking the fixture."}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","call_id":"tool-1","name":"exec_command","arguments":"{\"cmd\":\"true\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"tool-1","output":"success"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"Done."}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: rollout)
        let loaded = try CodexHistory.load(url: rollout)
        try expect(loaded.items.count == 2, "history must not duplicate event and response messages")
        try expect(loaded.items[0].text == "Fix the test", "canonical user history")
        try expect(loaded.items[1].blocks.count == 3, "reasoning, tool, and assistant history")
        try expect(loaded.items[1].blocks[1].tool?.result == "success", "tool output attaches to original call")
        try expect(loaded.model == "fixture-model", "history model")
        let record = CodexHistory.index(file: rollout, id: CodexHistory.key(sid), size: lines.utf8.count, modified: Date())
        try expect(record?.engine == .codex && record?.title == "Fix the test", "rollout indexing")
        let permission = CodexEvents.permission(id: .number(17), method: "item/commandExecution/requestApproval", params: .object(["command": .string("ls")]))
        try expect(permission?.toolName == "Bash" && permission?.id == "codex-rpc:17", "numeric RPC approval IDs preserved")
        let rejected = CodexEvents.approvalResult(method: "item/fileChange/requestApproval", params: .null, allow: false, always: false)
        try expect(rejected["decision"]?.string == "decline", "reject approval mapping")
        let approved = CodexEvents.approvalResult(method: "item/commandExecution/requestApproval", params: .null, allow: true, always: true)
        try expect(approved["decision"]?.string == "acceptForSession", "session approval mapping")
        let questionParams: JSONValue = .object(["questions": .array([.object(["id": .string("choice"), "question": .string("Which?")])])])
        let answers = CodexEvents.questionResult(params: questionParams, answers: ["Which?": "A"])
        try expect(answers["answers"]?["choice"]?["answers"]?[0]?.string == "A", "question IDs survive UI text mapping")
        let block = CodexEvents.block(.object(["type": .string("commandExecution"), "id": .string("cmd"), "command": .string("false"), "exitCode": .number(1), "aggregatedOutput": .string("failed")]), done: true)
        try expect(block?.tool?.done == true && block?.tool?.isError == true, "completed tool failure")
        try handoffFixture(root: root, source: loaded.items, sourceFile: rollout)
        try imageHandoffFixture(root: root)
        try nativeConfigurationFixture(root: root)
        try resumeStateFixture(root: root)
        try await transport(root: root)
        print("PASS — Codex protocol, approvals, history, migration, error, timeout and cancellation fixtures")
    }

    static func handoffFixture(root: URL, source: [TranscriptItem], sourceFile: URL) throws {
        let originalBytes = try Data(contentsOf: sourceFile)
        var visible = source
        let longText = String(repeating: "完整正文不能被截断。", count: 2000)
        visible.append(.user(longText))
        let handoff = try ConversationHandoff.prepare(sourceThreadId: "codex:source", sourceTitle: "Original task",
                                                       sourceEngine: .codex, cwd: "/fixture/project", items: visible,
                                                       directory: root.appendingPathComponent("handoffs"))
        let context = try String(contentsOfFile: handoff.contextPath, encoding: .utf8)
        try expect(context.contains(longText), "handoff must preserve full user/assistant prose")
        try expect(!context.contains("Checking the fixture."), "handoff excludes reasoning")
        try expect(!context.contains("private system instructions"), "handoff excludes system messages")
        try expect(handoff.messageCount == 3 && handoff.toolCount == 1, "handoff counts visible messages and tools")
        let mode = try FileManager.default.attributesOfItem(atPath: handoff.contextPath)[.posixPermissions] as? Int
        try expect(mode == 0o600, "handoff context is private")
        let unchanged = try Data(contentsOf: sourceFile) == originalBytes
        try expect(unchanged, "source native session remains byte-for-byte unchanged")
        var override = ThreadOverride()
        override.settings = ThreadSettings(engine: .claude)
        override.handoff = handoff
        let recovered = try JSONDecoder.standard.decode(ThreadOverride.self, from: JSONEncoder.standard.encode(override))
        try expect(recovered.handoff?.isPending == true && recovered.settings?.engine == .claude, "pending handoff persists separately from source Codex")
        let prompt = handoff.prompt(continuation: "继续完成测试")
        let nativeTarget = root.appendingPathComponent("native-claude-fixture.jsonl")
        let nativeRecord: JSONValue = .object(["type": .string("user"), "message": .object(["content": .string(prompt)])])
        try Data((nativeRecord.serialized() + "\n").utf8).write(to: nativeTarget)
        try expect(handoff.appearsInNativeSession(at: nativeTarget.path), "native persisted context prevents duplicate delivery after crash")
        try expect(!handoff.appearsInNativeSession(at: sourceFile.path), "unrelated source is not marked delivered")
        try expect(prompt.contains(handoff.contextPath) && prompt.contains("继续完成测试"), "native first message carries context path and user's continuation")
        let target = ConversationController(id: "new-claude-id", cwd: handoff.cwd, settings: ThreadSettings(engine: .claude), hasSessionFile: false, handoff: handoff)
        try expect(target.engine == .claude && target.id != handoff.sourceThreadId && target.handoff?.isPending == true,
                   "takeover is a distinct Claude native draft linked to original session")
    }

    static func imageHandoffFixture(root: URL) throws {
        let originalBytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let imageURL = "data:image/png;base64," + originalBytes.base64EncodedString()
        let content: JSONValue = .array([
            .object(["type": .string("input_image"), "image_url": .string(imageURL)]),
            .object(["type": .string("localImage"), "path": .string("/fixture/original.jpg")]),
            .object(["type": .string("input_image"), "image_url": .string("https://example.test/reference.png")]),
        ])
        var builder = TranscriptBuilder()
        var model: String?
        CodexHistory.consume(.object(["type": .string("response_item"), "payload": .object([
            "type": .string("message"), "role": .string("user"), "content": content,
        ])]), builder: &builder, model: &model)
        let messages = builder.finish()
        try expect(messages.count == 1 && messages[0].attachments.count == 3, "image-only user messages remain visible")
        try expect(messages[0].attachments[2].preview == nil && messages[0].attachments[2].sourceURL != nil,
                   "remote images are references, never automatic network previews")
        let directory = root.appendingPathComponent("image-handoff")
        let handoff = try ConversationHandoff.prepare(sourceThreadId: "codex:image-source", sourceTitle: "Screenshot task", sourceEngine: .codex,
                                                       cwd: "/fixture", items: messages, directory: directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard let exported = files.first(where: { $0.pathExtension == "png" }) else { throw Failure(description: "embedded image was lost") }
        let bytes = try Data(contentsOf: exported)
        try expect(bytes == originalBytes, "image export preserves bytes without processing")
        let attributes = try FileManager.default.attributesOfItem(atPath: exported.path)
        try expect((attributes[.posixPermissions] as? Int) == 0o600, "exported context images are private")
        let context = try String(contentsOfFile: handoff.contextPath, encoding: .utf8)
        try expect(context.contains(directory.appendingPathComponent(exported.lastPathComponent).path) && context.contains("/fixture/original.jpg") && context.contains("https://example.test/reference.png"),
                   "takeover includes embedded, local, and remote-only image references")
    }

    static func nativeConfigurationFixture(root: URL) throws {
        let original = root.appendingPathComponent("native-config-source")
        let runtime = root.appendingPathComponent("native-config-runtime")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let source = "model = \"fixture-native-model\"\nmodel_reasoning_effort = 'high' # omitted source comment\nmodel_context_window = 256_000\nmodel_provider = 'custom'\n[model_providers.custom]\nmodel = 'not-top-level'\nbase_url = 'https://untrusted.example.test'\n"
        let sourceURL = original.appendingPathComponent("config.toml")
        try Data(source.utf8).write(to: sourceURL)
        try Data("Fixture global instructions".utf8).write(to: original.appendingPathComponent("AGENTS.md"))
        try NativeEngineConfiguration.prepareCodex(from: original, at: runtime)
        let snapshot = try String(contentsOf: runtime.appendingPathComponent("config.toml"), encoding: .utf8)
        try expect(snapshot.contains("fixture-native-model") && snapshot.contains("model_reasoning_effort = 'high'") && snapshot.contains("256_000"),
                   "native model and effort defaults preserved")
        try expect(!snapshot.contains("untrusted") && !snapshot.contains("not-top-level") && !snapshot.contains("omitted source comment"),
                   "provider routes, table values and source comments excluded")
        try expect(runtime.appendingPathComponent("AGENTS.md").resolvingSymlinksInPath().path == original.appendingPathComponent("AGENTS.md").resolvingSymlinksInPath().path,
                   "native global instructions shared without reading or copying")
        let unchanged = try String(contentsOf: sourceURL, encoding: .utf8) == source
        try expect(unchanged, "native source configuration remains unchanged")
    }

    static func resumeStateFixture(root: URL) throws {
        let file = root.appendingPathComponent("allocated-but-not-persisted.jsonl")
        var newSession = CodexResumeState(existingHistory: false)
        try expect(newSession.shouldStartFresh(at: file.path), "failed native allocation without rollout must retry thread/start")
        try Data("native persisted user message".utf8).write(to: file)
        try expect(!newSession.shouldStartFresh(at: file.path) && newSession.established, "first persisted native history must resume")
        try FileManager.default.removeItem(at: file)
        try expect(!newSession.shouldStartFresh(at: file.path), "an established rollout disappearing must not create another history")
        var imported = CodexResumeState(existingHistory: true)
        try expect(!imported.shouldStartFresh(at: file.path), "missing imported histories must remain errors")
        var completed = CodexResumeState(existingHistory: false)
        completed.recordCompletedTurn()
        try expect(!completed.shouldStartFresh(at: file.path), "completed native turn cannot be silently recreated")
        var unknown = CodexResumeState(existingHistory: false)
        try expect(!unknown.shouldStartFresh(at: nil), "missing path is not proof an existing history can be replaced")
    }

    static func transport(root: URL) async throws {
        let script = root.appendingPathComponent("fake-codex.py")
        try Data(#"""
import sys, json
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialized': continue
    if method == 'hang': continue
    if method == 'fail':
        print(json.dumps({'id':request['id'], 'error':{'code':-32000,'message':'fixture error'}}), flush=True)
        continue
    if method == 'turn/start':
        # Fragmented UTF-8 lines and interleaved notifications exercise the stream reader.
        for message in [
          {'method':'turn/started','params':{'turn':{'id':'turn-1'}}},
          {'method':'item/agentMessage/delta','params':{'itemId':'text-1','delta':'你好'}},
          {'id':41,'method':'item/commandExecution/requestApproval','params':{'command':'true'}},
          {'method':'turn/completed','params':{'turn':{'id':'turn-1','status':'completed'}}}]:
            wire=(json.dumps(message,ensure_ascii=False)+'\n').encode()
            sys.stdout.buffer.write(wire[:7]);sys.stdout.buffer.flush()
            sys.stdout.buffer.write(wire[7:]);sys.stdout.buffer.flush()
    if 'id' in request and method:
        print(json.dumps({'id':request['id'], 'result':{'ok':True}}), flush=True)
"""#.utf8).write(to: script)
        let process = CodexProcess()
        try process.start(cwd: root.path, environment: ["PATH": "/usr/bin:/bin"], executable: "/usr/bin/python3", arguments: ["-u", script.path])
        defer { process.terminate() }
        var messages: [JSONValue] = []
        let pump = Task { for await event in process.events { messages.append(event) } }
        try await process.initialize()
        _ = try await process.request("turn/start", params: .object([:]))
        // The transport awaits each main-actor receive, so response ordering guarantees prior notifications delivered.
        for _ in 0..<20 where messages.count < 4 { await Task.yield() }
        try expect(messages.contains { $0["params"]?["delta"]?.string == "你好" }, "UTF-8 streamed notification")
        try expect(messages.contains { $0["id"]?.int == 41 }, "server request routing")
        do { _ = try await process.request("fail", params: .null); throw Failure(description: "RPC error was lost") }
        catch let error as CodexProcess.Failure { try expect(error.message == "fixture error", "RPC error text") }
        do { _ = try await process.request("hang", params: .null, timeout: .milliseconds(50)); throw Failure(description: "RPC did not time out") }
        catch let error as CodexProcess.Failure { try expect(error.message.contains("超时"), "request timeout") }
        let waiting = Task { try await process.request("hang", params: .null) }
        await Task.yield()
        process.terminate()
        do { _ = try await waiting.value; throw Failure(description: "termination did not cancel pending RPC") }
        catch is CancellationError {}
        pump.cancel()
    }
}
