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
        case "item/commandExecution/requestApproval":
            name = "Bash"
            if approvalDecisions(params).contains(.string("acceptForSession")) { suggestions = .array([.string("session")]) }
        case "item/fileChange/requestApproval": name = "Edit"; suggestions = .array([.string("session")])
        case "item/permissions/requestApproval": name = "Codex permissions"; suggestions = .array([.string("session")])
        case "item/tool/requestUserInput":
            name = "AskUserQuestion"
            input = .object(["questions": .array(params["questions"]?.array ?? [])])
        case "mcpServer/elicitation/request":
            name = "MCP input"
        default: return nil
        }
        let displayName = method == "mcpServer/elicitation/request" ? (params["serverName"]?.string ?? name) : name
        return PermissionRequest(id: "codex-rpc:" + id.serialized(), toolName: name, displayName: displayName, input: input,
                                 description: params["reason"]?.string, suggestions: suggestions, toolUseId: params["itemId"]?.string)
    }

    static func approvalResult(method: String, params: JSONValue, allow: Bool, always: Bool) -> JSONValue {
        switch method {
        case "item/tool/requestUserInput": return .object(["answers": .object([:])])
        case "mcpServer/elicitation/request":
            return .object(["action": .string("decline"), "content": .null, "_meta": .null])
        case "item/permissions/requestApproval":
            var grant: [String: JSONValue] = [:]
            if allow {
                for key in ["network", "fileSystem"] { if let value = params["permissions"]?[key], !value.isNull { grant[key] = value } }
            }
            return .object(["permissions": .object(grant), "scope": .string(always ? "session" : "turn")])
        default:
            let desired = JSONValue.string(allow ? (always ? "acceptForSession" : "accept") : "decline")
            let available = approvalDecisions(params)
            // Never turn an unsupported approval into a broader grant.
            let decision = available.contains(desired) ? desired : available.contains(.string("decline")) ? .string("decline") : .string("cancel")
            return .object(["decision": decision])
        }
    }

    static func questionResult(params: JSONValue, answers: [String: String]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for question in params["questions"]?.array ?? [] {
            guard let id = question["id"]?.string else { continue }
            let text = answers[id] ?? answers[question["question"]?.string ?? ""] ?? ""
            result[id] = .object(["answers": .array([.string(text)])])
        }
        return .object(["answers": .object(result)])
    }

    static func questionResult(params: JSONValue, selections: [String: [String]]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for question in params["questions"]?.array ?? [] {
            guard let id = question["id"]?.string else { continue }
            result[id] = .object(["answers": .array((selections[id] ?? []).map(JSONValue.string))])
        }
        return .object(["answers": .object(result)])
    }

    static func approvalDecisions(_ params: JSONValue) -> [JSONValue] {
        params["availableDecisions"]?.array ?? [.string("accept"), .string("acceptForSession"), .string("decline"), .string("cancel")]
    }

    static func decisionLabel(_ decision: JSONValue) -> String {
        switch decision.string {
        case "accept": return "允许一次"
        case "acceptForSession": return "本会话允许"
        case "decline": return "拒绝"
        case "cancel": return "取消本轮"
        default:
            if decision["acceptWithExecpolicyAmendment"] != nil { return "允许并保存命令规则" }
            if decision["applyNetworkPolicyAmendment"] != nil { return "应用网络规则" }
            return "未知决定"
        }
    }

    static func isKnownDecision(_ decision: JSONValue) -> Bool {
        ["accept", "acceptForSession", "decline", "cancel"].contains(decision.string ?? "")
            || decision["acceptWithExecpolicyAmendment"] != nil || decision["applyNetworkPolicyAmendment"] != nil
    }

    static func currentTimeResult(at date: Date = Date()) -> JSONValue {
        .object(["currentTimeAt": .number(floor(date.timeIntervalSince1970))])
    }
}

/// UI identity is separate from the provider's wire key: Claude uses question text, Codex uses IDs.
struct InteractionQuestion: Identifiable {
    let id: String
    let wireKey: String
    let text: String
    let header: String?
    let options: [JSONValue]
    let multiple: Bool
    let allowsCustom: Bool
    let secret: Bool

    static func parse(_ request: PermissionRequest) -> [InteractionQuestion] {
        let codex = request.id.hasPrefix("codex-rpc:")
        return (request.input["questions"]?.array ?? []).enumerated().map { index, question in
            let text = question["question"]?.string ?? ""
            let wireKey = codex ? (question["id"]?.string ?? String(index)) : text
            let options = question["options"]?.array ?? []
            return InteractionQuestion(id: codex ? wireKey : String(index), wireKey: wireKey, text: text,
                                       header: question["header"]?.string, options: options,
                                       multiple: !codex && question["multiSelect"]?.bool == true,
                                       allowsCustom: !codex || options.isEmpty || question["isOther"]?.bool == true,
                                       secret: codex && question["isSecret"]?.bool == true)
        }
    }

    static func claudeAnswers(_ selections: [String: [String]]) -> JSONValue {
        .object(selections.mapValues { .string($0.joined(separator: ", ")) })
    }
}

/// Standard flat MCP forms. Unsupported schemas remain visible with a decline action.
enum CodexElicitation {
    static func fields(_ params: JSONValue) -> [(String, JSONValue)]? {
        guard params["mode"]?.string == "form", let schema = params["requestedSchema"],
              schema["type"]?.string == "object", let properties = schema["properties"]?.object else { return nil }
        for field in properties.values {
            guard ["string", "number", "integer", "boolean"].contains(field["type"]?.string ?? ""),
                  field["format"] == nil, field["oneOf"] == nil, field["anyOf"] == nil else { return nil }
        }
        return properties.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    static func result(params: JSONValue, values: [String: String]) -> JSONValue? {
        guard let fields = fields(params) else { return nil }
        let required = Set(params["requestedSchema"]?["required"]?.array?.compactMap(\.string) ?? [])
        var content: [String: JSONValue] = [:]
        for (key, schema) in fields {
            if required.contains(key), values[key] == nil { return nil }
            let raw = values[key] ?? ""
            if raw.isEmpty && !required.contains(key) { continue }
            switch schema["type"]?.string {
            case "string":
                if let min = schema["minLength"]?.int, raw.count < min { return nil }
                if let max = schema["maxLength"]?.int, raw.count > max { return nil }
                if let options = schema["enum"]?.array, !options.contains(.string(raw)) { return nil }
                content[key] = .string(raw)
            case "boolean":
                guard raw == "true" || raw == "false" else { return nil }
                content[key] = .bool(raw == "true")
            case "number", "integer":
                guard let value = Double(raw), value.isFinite else { return nil }
                if schema["type"]?.string == "integer", value.rounded() != value { return nil }
                if let min = schema["minimum"]?.double, value < min { return nil }
                if let max = schema["maximum"]?.double, value > max { return nil }
                content[key] = .number(value)
            default: return nil
            }
        }
        return .object(["action": .string("accept"), "content": .object(content), "_meta": .null])
    }
}
