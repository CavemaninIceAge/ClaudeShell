import Foundation

struct ToolCall: Sendable, Codable, Equatable {
    var id: String
    var name: String
    var input: JSONValue?
    var partialInput = ""       // input_json_delta 拼出来的半截 JSON，完整 input 到了就清空
    var result: String?
    var isError = false
    var done = false
    var startedAt: Date? = nil       // 步骤组头部的"· 12 秒"靠这两个算
    var endedAt: Date? = nil
}

struct Block: Sendable, Codable, Equatable, Identifiable {
    enum Kind: String, Sendable, Codable { case thinking, text, tool }
    var id: String
    var kind: Kind
    var text = ""
    var tool: ToolCall?
    var done = false
}

struct TurnMeta: Sendable, Codable, Equatable {
    var durationMs: Int?
    var costUSD: Double?
    var isError = false
    var stopReason: String?
}

struct TranscriptItem: Sendable, Codable, Equatable, Identifiable {
    enum Kind: String, Sendable, Codable { case user, assistant, note }
    var id: String
    var kind: Kind
    var text = ""
    var blocks: [Block] = []
    var done = true
    var level: String? = nil          // note 用：info | warn | error
    var timestamp: Date? = nil
    var meta: TurnMeta? = nil
    var rev = 0                       // 每次改动 +1，网页层按它判断要不要重画

    static func user(_ text: String, at date: Date? = nil) -> TranscriptItem {
        TranscriptItem(id: "u-" + UUID().uuidString.lowercased(), kind: .user, text: text, timestamp: date)
    }

    static func note(_ text: String, level: String = "info") -> TranscriptItem {
        TranscriptItem(id: "n-" + UUID().uuidString.lowercased(), kind: .note, text: text, level: level, timestamp: Date())
    }

    static func assistantTurn(at date: Date? = nil) -> TranscriptItem {
        TranscriptItem(id: "a-" + UUID().uuidString.lowercased(), kind: .assistant, done: false, timestamp: date)
    }
}

enum ToolResultText {
    /// tool_result 的 content 可能是字符串，也可能是 text/image 块数组；折成可显示的文本并截断。
    static func flatten(_ content: JSONValue, limit: Int = 40_000) -> String {
        var text: String
        if let s = content.string {
            text = s
        } else if let blocks = content.array {
            text = blocks.compactMap { b -> String? in
                switch b["type"]?.string {
                case "text": return b["text"]?.string
                case "image": return "[图片]"
                default: return b.string
                }
            }.joined(separator: "\n")
        } else if content.isNull {
            text = ""
        } else {
            text = content.serialized(pretty: true)
        }
        if text.count > limit {
            let head = text.prefix(limit * 3 / 4)
            let tail = text.suffix(limit / 4)
            text = head + "\n\n…（中间省略 \(text.count - limit) 字符）…\n\n" + tail
        }
        return text
    }
}

extension Block {
    /// 历史回放和实时流共用：把 API 的内容块折成 Block。
    static func from(contentBlock b: JSONValue) -> Block? {
        switch b["type"]?.string {
        case "thinking":
            return Block(id: "th-" + UUID().uuidString.lowercased(), kind: .thinking, text: b["thinking"]?.string ?? "", done: true)
        case "redacted_thinking":
            return Block(id: "th-" + UUID().uuidString.lowercased(), kind: .thinking, text: "（这段思考已被隐藏）", done: true)
        case "text":
            return Block(id: "tx-" + UUID().uuidString.lowercased(), kind: .text, text: b["text"]?.string ?? "", done: true)
        case "tool_use":
            let id = b["id"]?.string ?? ("tool-" + UUID().uuidString.lowercased())
            return Block(id: id, kind: .tool,
                         tool: ToolCall(id: id, name: b["name"]?.string ?? "?", input: b["input"]),
                         done: true)
        default:
            return nil
        }
    }
}

/// 历史回放用的折算器：一轮（用户消息之后到下一条用户消息之前的全部 assistant 消息）合成一个 assistant 条目。
struct TranscriptBuilder: Sendable {
    private(set) var items: [TranscriptItem] = []
    private var openTurn: Int? = nil

    mutating func addUser(text: String, at date: Date?) {
        closeTurn()
        items.append(.user(text, at: date))
    }

    mutating func addAssistant(content: [JSONValue], at date: Date?) {
        if openTurn == nil {
            items.append(.assistantTurn(at: date))
            openTurn = items.count - 1
        }
        guard let i = openTurn else { return }
        for b in content {
            if var block = Block.from(contentBlock: b) {
                // 空文本块（只有 thinking 签名的那种）不值得占一行。
                if block.kind != .tool && block.text.isEmpty { continue }
                if block.kind == .tool { block.tool?.startedAt = date }
                items[i].blocks.append(block)
            }
        }
    }

    mutating func addToolResult(toolUseId: String, content: JSONValue, isError: Bool, at date: Date? = nil) {
        guard let i = openTurn ?? items.indices.last(where: { items[$0].kind == .assistant }) else { return }
        if let bi = items[i].blocks.lastIndex(where: { $0.tool?.id == toolUseId }) {
            items[i].blocks[bi].tool?.result = ToolResultText.flatten(content)
            items[i].blocks[bi].tool?.isError = isError
            items[i].blocks[bi].tool?.done = true
            items[i].blocks[bi].tool?.endedAt = date
        }
    }

    mutating func addNote(_ text: String, level: String = "info") {
        closeTurn()
        items.append(.note(text, level: level))
    }

    mutating func closeTurn() {
        if let i = openTurn {
            items[i].done = true
            // 工具没等到结果（历史里被打断了）也标成完成，别一直转圈。
            for bi in items[i].blocks.indices { items[i].blocks[bi].tool?.done = true }
        }
        openTurn = nil
    }

    mutating func finish() -> [TranscriptItem] {
        closeTurn()
        return items
    }
}
