import Foundation

/// 把一个会话文件整个读出来变成 transcript。20 MB 的文件也就一两秒，放后台跑。
enum SessionLoader {
    static func load(url: URL) -> [TranscriptItem] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var builder = TranscriptBuilder()
        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(lineSub)
            guard let v = JSONValue.parse(line), let type = v["type"]?.string else { continue }
            if v["isSidechain"]?.bool == true { continue }
            let stamp = SessionIndex.parseDate(v["timestamp"]?.string)
            switch type {
            case "user":
                if v["isMeta"]?.bool == true { continue }
                let content = v["message"]?["content"]
                if let blocks = content?.array {
                    var sawResult = false
                    for b in blocks where b["type"]?.string == "tool_result" {
                        sawResult = true
                        builder.addToolResult(toolUseId: b["tool_use_id"]?.string ?? "",
                                              content: b["content"] ?? .null,
                                              isError: b["is_error"]?.bool ?? false,
                                              at: stamp)
                    }
                    if sawResult { continue }
                }
                guard let t = SessionIndex.userText(content) else { continue }
                if t.hasPrefix("[Request interrupted") {
                    builder.addNote("已打断", level: "info")
                } else if SessionIndex.isRealPrompt(t) {
                    builder.addUser(text: stripReminders(t), at: stamp)
                }
            case "assistant":
                builder.addAssistant(content: v["message"]?["content"]?.array ?? [], at: stamp)
            case "system":
                if v["subtype"]?.string == "compact_boundary" { builder.addNote("上下文已压缩", level: "info") }
            default:
                continue
            }
        }
        return builder.finish()
    }

    /// 终端会把 system-reminder 拼进用户消息里，回放时不用给用户看。
    static func stripReminders(_ text: String) -> String {
        TitleMaker.stripReminders(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
