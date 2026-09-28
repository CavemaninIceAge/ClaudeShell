import Foundation

@MainActor
enum NativeInteractionRegression {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw CodexRegression.Failure(description: message) }
    }

    static func wait(_ message: String, until condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CodexRegression.Failure(description: "Timed out: " + message)
    }

    static func run() async throws {
        try mappingFixtures()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudex-interaction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("server.py")
        let log = root.appendingPathComponent("wire.jsonl")
        let rollout = root.appendingPathComponent("fixture-rollout.jsonl")
        try Data(server.utf8).write(to: script)
        var processes: [CodexProcess] = []
        let controller = ConversationController(id: "draft", cwd: root.path, settings: ThreadSettings(model: "first-model", engine: .codex), hasSessionFile: false) { cwd in
            let process = CodexProcess()
            try process.start(cwd: cwd, environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], executable: "/usr/bin/python3",
                              arguments: ["-u", script.path, log.path, rollout.path])
            processes.append(process)
            return process
        }
        defer { controller.terminate(); for process in processes { process.terminate() } }
        var composerChanges = 0
        controller.onComposerChanged = { _ in composerChanges += 1 }
        controller.composerDraft = "draft"
        controller.composerDraft = "draft"
        let attachment = ComposerAttachment(id: "fixture", kind: .file, name: "fixture.txt", path: root.appendingPathComponent("fixture.txt").path)
        controller.restoreComposerDraft(text: "draft", attachments: [attachment])
        controller.restoreComposerDraft(text: "draft", attachments: [attachment])
        controller.removeAttachment("fixture")
        try expect(composerChanges == 3, "composer notifications only fire for changed text/attachments")

        controller.send("interaction")
        try await wait("approval and questions") { controller.pendingPermissions.count == 2 }
        try expect(controller.codexModels.map(\.id) == ["first-model", "second-model"], "all model pages populate the picker")
        let approval = controller.pendingPermissions.first { $0.toolName == "Bash" }!
        controller.respondCodexDecision(to: approval, decision: .string("acceptForSession"))
        try expect(controller.pendingPermissions.contains { $0.id == approval.id }, "unavailable decision cannot be sent")
        controller.respondCodexDecision(to: approval, decision: .string("accept"))
        let question = controller.pendingPermissions.first { $0.toolName == "AskUserQuestion" }!
        controller.answerQuestion(question, selections: ["first": ["A"], "second": ["B"]])
        try await wait("interactive turn completed") { !controller.isWorking }
        try expect(controller.canSend && controller.pendingPermissions.isEmpty, "answers release the next turn")
        controller.send("second")
        try await wait("second turn") { !controller.isWorking }
        try expect(processes.count == 1, "multi-turn keeps the native process")
        controller.send("form")
        try await wait("MCP form") { controller.pendingPermissions.first?.toolName == "MCP input" }
        let formRequest = controller.pendingPermissions[0]
        controller.answerElicitation(formRequest, values: ["count": "2"])
        try await wait("MCP form completed") { !controller.isWorking }

        controller.settings.model = "second-model"
        controller.send("hold")
        try await wait("hold active") { controller.items.contains { $0.blocks.contains { $0.text == "holding" } } }
        try expect(processes.count == 2, "model change respawns with native resume")
        controller.stop()
        try await wait("failed interrupt cleanly stops") { !controller.isWorking }
        try expect(!processes[1].isRunning && controller.canSend, "failed interrupt terminates the old process and permits another turn")
        controller.send("after")
        try await wait("resume after failed stop") { !controller.isWorking }
        try expect(processes.count == 3, "stopped process is replaced")
        controller.send("interrupt-ok")
        try await wait("interruptible turn starts") { controller.items.contains { $0.blocks.contains { $0.text == "interruptible" } } }
        controller.stop()
        try await wait("native interrupt completed") { !controller.isWorking }
        controller.send("final")
        try await wait("continue after native interrupt") { !controller.isWorking }
        try expect(processes.count == 3 && processes[2].isRunning, "successful interruption preserves native multi-turn transport")
        controller.settings.permissionMode = "plan"
        controller.settings.effort = "high"
        controller.send("plan")
        try await wait("native plan") { !controller.isWorking }
        controller.settings.permissionMode = "auto"
        controller.send("default")
        try await wait("leave plan") { !controller.isWorking }
        let messages = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
        let approvalReply = messages.first { $0["id"]?.int == 71 }
        try expect(approvalReply?["result"]?["decision"]?.string == "accept", "wire approval is one-time acceptance")
        let answers = messages.first { $0["id"]?.int == 72 }?["result"]?["answers"]
        try expect(answers?["first"]?["answers"]?[0]?.string == "A" && answers?["second"]?["answers"]?[0]?.string == "B", "same-label questions retain separate IDs on wire")
        try expect(messages.first { $0["id"]?.int == 73 }?["result"]?["currentTimeAt"]?.double != nil, "currentTime/read receives whole Unix seconds")
        try expect(messages.first { $0["id"]?.int == 74 }?["result"]?["content"]?["count"]?.int == 2, "MCP form submits typed content through the controller")
        let resumes = messages.filter { $0["method"]?.string == "thread/resume" }
        try expect(resumes.count == 4 && resumes.allSatisfy { $0["params"]?["path"]?.string == rollout.path }, "model/mode switches and forced stop resume the existing native rollout")
        try expect(resumes.first?["params"]?["model"]?.string == "second-model", "selected model reaches native resume")
        try expect(messages.contains { $0["method"]?.string == "turn/start" && $0["params"]?["model"]?.string == "second-model" }, "selected model reaches turn/start")
        let turns = messages.filter { $0["method"]?.string == "turn/start" }
        let plan = turns.first { $0["params"]?["input"]?[0]?["text"]?.string == "plan" }?["params"]?["collaborationMode"]
        try expect(plan?["mode"]?.string == "plan" && plan?["settings"]?["model"]?.string == "second-model"
                   && plan?["settings"]?["reasoning_effort"]?.string == "high" && plan?["settings"]?["developer_instructions"]?.isNull == true,
                   "Plan uses the native collaboration mode, selected model/effort and built-in instructions")
        try expect(turns.last?["params"]?["collaborationMode"]?["mode"]?.string == "default", "leaving Plan explicitly restores Default mode")
        print("PASS — native interaction IDs, approvals, questions, MCP forms, model pagination, multi-turn, stop and resume")
    }

    static func mappingFixtures() throws {
        let params = JSONValue.parse(#"{"questions":[{"id":"a","header":"First","question":"Same?","isOther":false,"isSecret":false,"options":[{"label":"A"}]},{"id":"b","question":"Same?","isOther":true,"isSecret":true,"options":null}]}"#)!
        let request = CodexEvents.permission(id: .number(7), method: "item/tool/requestUserInput", params: params)!
        let questions = InteractionQuestion.parse(request)
        try expect(questions.map(\.id) == ["a", "b"] && !questions[0].allowsCustom && questions[1].secret, "Codex question IDs, isOther and isSecret survive normalization")
        let reply = CodexEvents.questionResult(params: params, selections: ["a": ["A"], "b": ["private"]])
        try expect(reply["answers"]?["b"]?["answers"]?[0]?.string == "private", "secret answer travels only in the wire reply")
        let claude = PermissionRequest(id: "claude-question", toolName: "AskUserQuestion", displayName: "AskUserQuestion", input: JSONValue.parse(#"{"questions":[{"question":"Which?","multiSelect":true,"options":[{"label":"A"},{"label":"B"}]}]}"#)!, description: nil, suggestions: nil, toolUseId: nil)
        try expect(InteractionQuestion.parse(claude)[0].multiple, "Claude multiSelect is preserved")
        try expect(InteractionQuestion.claudeAnswers(["Which?": ["A", "B"]])["Which?"]?.string == "A, B", "Claude multi-select follows native comma-separated answer schema")
        let limited = JSONValue.parse(#"{"availableDecisions":["accept","decline"]}"#)!
        let limitedRequest = CodexEvents.permission(id: .string("limited"), method: "item/commandExecution/requestApproval", params: limited)!
        try expect(limitedRequest.suggestions == nil, "session approval is unavailable when server excludes it")
        try expect(CodexEvents.approvalResult(method: "item/commandExecution/requestApproval", params: limited, allow: true, always: true)["decision"]?.string == "decline", "unavailable session grants fail closed")
        let amendment = JSONValue.parse(#"{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["git","status"]}}"#)!
        try expect(CodexEvents.approvalDecisions(.object(["availableDecisions": .array([amendment])])) == [amendment], "server-specified rule amendments are preserved verbatim")
        try expect(CodexEvents.currentTimeResult(at: Date(timeIntervalSince1970: 1234.75))["currentTimeAt"]?.double == 1234, "currentTime whole seconds")
        let form = JSONValue.parse(#"{"mode":"form","requestedSchema":{"type":"object","properties":{"name":{"type":"string","minLength":2},"count":{"type":"integer","minimum":1,"maximum":4},"enabled":{"type":"boolean"},"color":{"type":"string","enum":["red","blue"]}},"required":["name","count","enabled","color"]}}"#)!
        let valid = CodexElicitation.result(params: form, values: ["name": "test", "count": "3", "enabled": "false", "color": "red"])
        try expect(valid?["content"]?["count"]?.int == 3 && valid?["content"]?["enabled"]?.bool == false, "MCP forms preserve numeric and boolean types")
        try expect(CodexElicitation.result(params: form, values: ["name": "t", "count": "3.5", "enabled": "false", "color": "red"]) == nil, "MCP constraints reject invalid values")
        try expect(CodexElicitation.fields(.object(["mode": .string("url")])) == nil, "external MCP verification is not silently accepted")
        let skipped = CodexEvents.approvalResult(method: "mcpServer/elicitation/request", params: form, allow: false, always: false)
        try expect(skipped["action"]?.string == "decline" && skipped["content"]?.isNull == true, "MCP decline has protocol-valid response")
    }

    static let server = #"""
import sys,json,os
log,rollout=sys.argv[1:]
turn=0
mode=''
def emit(v): print(json.dumps(v),flush=True)
def reply(v,result): emit({'id':v['id'],'result':result})
def event(method,params): emit({'method':method,'params':params})
def complete(status='completed'):
    event('turn/completed',{'threadId':'fixture-thread','turn':{'id':str(turn),'status':status}})
for line in sys.stdin:
    v=json.loads(line)
    with open(log,'a') as f: f.write(json.dumps(v)+'\n')
    method=v.get('method'); p=v.get('params',{})
    if method=='initialize': reply(v,{})
    elif method in ('thread/start','thread/resume'):
        reply(v,{'thread':{'id':'fixture-thread','path':rollout},'model':p.get('model')})
    elif method=='model/list':
        second=p.get('cursor')=='page-2'
        reply(v,{'data':[{'model':'second-model' if second else 'first-model','displayName':'Fixture'}],'nextCursor':None if second else 'page-2'})
    elif method=='turn/start':
        turn+=1; mode=p['input'][0]['text']
        with open(rollout,'a') as f: f.write('{}\n')
        event('turn/started',{'threadId':'fixture-thread','turn':{'id':str(turn)}})
        reply(v,{'turn':{'id':str(turn)}})
        if mode=='interaction':
            emit({'id':71,'method':'item/commandExecution/requestApproval','params':{'threadId':'fixture-thread','turnId':str(turn),'itemId':'cmd','command':'true','availableDecisions':['accept','decline']}})
            emit({'id':72,'method':'item/tool/requestUserInput','params':{'threadId':'fixture-thread','turnId':str(turn),'itemId':'question','questions':[{'id':'first','question':'Same?','isOther':False,'isSecret':False,'options':[{'label':'A'}]},{'id':'second','question':'Same?','isOther':False,'isSecret':False,'options':[{'label':'B'}]}]}})
            emit({'id':73,'method':'currentTime/read','params':{'threadId':'fixture-thread'}})
        elif mode=='form':
            emit({'id':74,'method':'mcpServer/elicitation/request','params':{'threadId':'fixture-thread','turnId':str(turn),'serverName':'fixture','mode':'form','message':'Fixture count','requestedSchema':{'type':'object','properties':{'count':{'type':'integer','minimum':1}},'required':['count']}}})
        elif mode in ('hold','interrupt-ok'):
            event('item/agentMessage/delta',{'threadId':'fixture-thread','turnId':str(turn),'itemId':'item-'+str(turn),'delta':'holding' if mode=='hold' else 'interruptible'})
        else: complete()
    elif method=='turn/interrupt':
        if mode=='hold': emit({'id':v['id'],'error':{'code':-32000,'message':'fixture interrupt failure'}})
        else: complete('interrupted'); reply(v,{})
    elif v.get('id') in (72,74) and 'result' in v: complete()
"""#
}
