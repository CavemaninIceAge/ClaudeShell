import Foundation

/// CLI 通过 stdout 发来的权限请求（`control_request` / `can_use_tool`）。
struct PermissionRequest: Sendable, Identifiable, Equatable {
    let id: String              // request_id，回复时原样带回
    let toolName: String
    let displayName: String
    let input: JSONValue
    let description: String?
    /// `permission_suggestions` 原样保留；"本会话总是允许"时作为 updatedPermissions 回传。
    let suggestions: JSONValue?
    let toolUseId: String?
}

struct ToolResultPayload: Sendable, Equatable {
    let toolUseId: String
    let content: JSONValue
    let isError: Bool
}

/// 把 stream-json 的一行折成 app 关心的事件。字段名以 2026-09-13 对 Claude Code 2.1.270 的实测为准（docs/protocol.md）。
enum ClaudeEvent: Sendable {
    case initialized(sessionId: String, model: String?, permissionMode: String?)
    case messageStart
    case blockStart(index: Int, block: JSONValue)
    case blockDelta(index: Int, delta: JSONValue)
    case blockStop(index: Int)
    case messageStop
    case assistantMessage(content: [JSONValue])
    case toolResults([ToolResultPayload])
    case userText(String)                       // CLI 自己塞进来的用户消息，比如"[Request interrupted by user]"
    case permissionRequest(PermissionRequest)
    case controlRequestUnsupported(requestId: String, subtype: String)
    case controlResponse(requestId: String, payload: JSONValue)
    case result(JSONValue)
    case status(String?)
    case permissionDenied(tool: String, message: String)
    case rateLimit(JSONValue)
    case systemNote(subtype: String, payload: JSONValue)
    case stderr(String)
    case exited(code: Int32)
}

enum ClaudeEventParser {
    static func parse(line: String) -> ClaudeEvent? {
        guard let v = JSONValue.parse(line), let type = v["type"]?.string else { return nil }
        switch type {
        case "system":
            let sub = v["subtype"]?.string ?? ""
            switch sub {
            case "init":
                return .initialized(sessionId: v["session_id"]?.string ?? "",
                                    model: v["model"]?.string,
                                    permissionMode: v["permissionMode"]?.string)
            case "status":
                return .status(v["status"]?.string)
            case "permission_denied":
                return .permissionDenied(tool: v["tool_name"]?.string ?? "", message: v["message"]?.string ?? "")
            case "thinking_tokens":
                return nil
            default:
                return .systemNote(subtype: sub, payload: v)
            }

        case "stream_event":
            // 子代理（Task）的流带 parent_tool_use_id，不进主对话。
            if let parent = v["parent_tool_use_id"], !parent.isNull { return nil }
            guard let ev = v["event"], let et = ev["type"]?.string else { return nil }
            switch et {
            case "message_start": return .messageStart
            case "content_block_start": return .blockStart(index: ev["index"]?.int ?? 0, block: ev["content_block"] ?? .null)
            case "content_block_delta": return .blockDelta(index: ev["index"]?.int ?? 0, delta: ev["delta"] ?? .null)
            case "content_block_stop": return .blockStop(index: ev["index"]?.int ?? 0)
            case "message_stop": return .messageStop
            default: return nil
            }

        case "assistant":
            if let parent = v["parent_tool_use_id"], !parent.isNull { return nil }
            return .assistantMessage(content: v["message"]?["content"]?.array ?? [])

        case "user":
            if let parent = v["parent_tool_use_id"], !parent.isNull { return nil }
            let content = v["message"]?["content"]
            if let blocks = content?.array {
                let results = blocks.compactMap { b -> ToolResultPayload? in
                    guard b["type"]?.string == "tool_result" else { return nil }
                    return ToolResultPayload(toolUseId: b["tool_use_id"]?.string ?? "",
                                             content: b["content"] ?? .null,
                                             isError: b["is_error"]?.bool ?? false)
                }
                if !results.isEmpty { return .toolResults(results) }
                let text = blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
                    .joined(separator: "\n")
                return text.isEmpty ? nil : .userText(text)
            }
            if let s = content?.string { return .userText(s) }
            return nil

        case "control_request":
            let rid = v["request_id"]?.string ?? ""
            let req = v["request"] ?? .null
            let sub = req["subtype"]?.string ?? ""
            if sub == "can_use_tool" {
                let name = req["tool_name"]?.string ?? "?"
                return .permissionRequest(PermissionRequest(
                    id: rid,
                    toolName: name,
                    displayName: req["display_name"]?.string ?? name,
                    input: req["input"] ?? .object([:]),
                    description: req["description"]?.string,
                    suggestions: req["permission_suggestions"],
                    toolUseId: req["tool_use_id"]?.string))
            }
            return .controlRequestUnsupported(requestId: rid, subtype: sub)

        case "control_response":
            let r = v["response"] ?? .null
            return .controlResponse(requestId: r["request_id"]?.string ?? "", payload: r)

        case "result":
            return .result(v)

        case "rate_limit_event":
            return .rateLimit(v["rate_limit_info"] ?? .null)

        default:
            return nil
        }
    }
}
