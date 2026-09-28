import Foundation

enum CodexEvents {
    static func block(_ item: JSONValue, done: Bool) -> Block? {
        guard let type = item["type"]?.string, let id = item["id"]?.string else { return nil }
        switch type {
        case "agentMessage", "plan":
            return Block(id: id, kind: .text, text: item["text"]?.string ?? "", done: done)
        case "reasoning":
            return Block(id: id, kind: .thinking, text: (item["summary"]?.array ?? []).compactMap(\.string).joined(separator: "\n"), done: done)
        case "userMessage", "hookPrompt": return nil
        default:
            let name: String
            let input: JSONValue
            let output: String?
            switch type {
            case "commandExecution":
                name = "Bash"; input = .object(["command": item["command"] ?? .string(""), "cwd": item["cwd"] ?? .null])
                output = item["aggregatedOutput"]?.string
            case "fileChange": name = "Edit"; input = .object(["changes": item["changes"] ?? .array([])]); output = item["changes"]?.serialized(pretty: true)
            case "mcpToolCall", "dynamicToolCall": name = item["tool"]?.string ?? type; input = item["arguments"] ?? .object([:]); output = item["result"]?.serialized(pretty: true)
            case "webSearch": name = "WebSearch"; input = item; output = item["action"]?.serialized(pretty: true)
            default: name = type; input = item; output = nil
            }
            let error = item["status"]?.string == "failed" || (item["exitCode"]?.int ?? 0) != 0 || item["error"]?.isNull == false
            return Block(id: id, kind: .tool, tool: ToolCall(id: id, name: name, input: input, result: output,
                                                          isError: error, done: done, startedAt: Date(), endedAt: done ? Date() : nil), done: done)
        }
    }

    static func permission(id: JSONValue, method: String, params: JSONValue) -> PermissionRequest? {
        let name: String
        var input = params
        var suggestions: JSONValue?
        switch method {
        case "item/commandExecution/requestApproval": name = "Bash"; suggestions = .array([.string("session")])
        case "item/fileChange/requestApproval": name = "Edit"; suggestions = .array([.string("session")])
        case "item/permissions/requestApproval": name = "Codex permissions"; suggestions = .array([.string("session")])
        case "item/tool/requestUserInput":
            name = "AskUserQuestion"
            input = .object(["questions": .array(params["questions"]?.array ?? [])])
        default: return nil
        }
        return PermissionRequest(id: "codex-rpc:" + id.serialized(), toolName: name, displayName: name, input: input,
                                 description: params["reason"]?.string, suggestions: suggestions, toolUseId: params["itemId"]?.string)
    }

    static func approvalResult(method: String, params: JSONValue, allow: Bool, always: Bool) -> JSONValue {
        switch method {
        case "item/tool/requestUserInput": return .object(["answers": .object([:])])
        case "item/permissions/requestApproval":
            var grant: [String: JSONValue] = [:]
            if allow {
                for key in ["network", "fileSystem"] { if let value = params["permissions"]?[key], !value.isNull { grant[key] = value } }
            }
            return .object(["permissions": .object(grant), "scope": .string(always ? "session" : "turn")])
        default: return .object(["decision": .string(allow ? (always ? "acceptForSession" : "accept") : "decline")])
        }
    }

    static func questionResult(params: JSONValue, answers: [String: String]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for question in params["questions"]?.array ?? [] {
            guard let id = question["id"]?.string else { continue }
            let text = answers[question["question"]?.string ?? ""] ?? answers[id] ?? ""
            result[id] = .object(["answers": .array([.string(text)])])
        }
        return .object(["answers": .object(result)])
    }
}
