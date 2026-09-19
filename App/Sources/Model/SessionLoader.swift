import Foundation

/// 把会话文件读成 transcript。既能一次读完（历史回放），也能接着往下读（终端里正在跑的会话，app 只是旁观：
/// 文件每长一段就把新行喂进来，transcript 跟着长）。20 MB 的文件也就一两秒，放后台跑。
struct SessionReader: Sendable {
    let url: URL
    private(set) var builder = TranscriptBuilder()
    private(set) var offset: UInt64 = 0
    private(set) var lastModel: String?      // 最近一条 assistant 记录里的 message.model：终端会话实际用的模型
    private var partial = Data()            // 上次读到的半截行
    private var expectedEchoes: [String] = []   // app 自己刚投进终端的话，文件里再出现时不重复显示

    init(url: URL) { self.url = url }

    /// 兼容旧调用：整个读完给出条目。
    static func load(url: URL) -> [TranscriptItem] {
        var r = SessionReader(url: url)
        r.readMore()
        return r.finishedItems()
    }

    /// 从上次的位置继续读到文件末尾。返回是否读到了新内容。
    @discardableResult
    mutating func readMore() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > offset else { return false }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return false }
        offset = size
        var buf = partial + data
        var consumed = 0
        while let nl = buf[consumed...].firstIndex(of: 0x0A) {
            let lineData = buf[consumed..<nl]
            consumed = nl + 1
            if let line = String(data: lineData, encoding: .utf8) { ingest(line: line) }
        }
        buf.removeSubrange(0..<consumed)
        partial = buf
        return true
    }

    /// 快照：进行中的一轮也带着（终端那边可能还在写），显示时按 done 判断。
    var items: [TranscriptItem] { builder.items }

    mutating func finishedItems() -> [TranscriptItem] { builder.finish() }

    /// app 自己刚投进终端的一句话：本地先显示（display），文件里那条对应记录（正文是 body）到了就跳过。
    mutating func expectEcho(display: String, attachments: [TranscriptAttachment] = [], body: String, at date: Date) {
        builder.addUser(text: display, attachments: attachments, at: date)
        expectedEchoes.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private mutating func ingest(line: String) {
        guard let v = JSONValue.parse(line), let type = v["type"]?.string else { return }
        if v["isSidechain"]?.bool == true { return }
        let stamp = SessionIndex.parseDate(v["timestamp"]?.string)
        switch type {
        case "user":
            // 别的会话（包括本 app）投进来的话：origin.kind == "peer"，正文在 origin.body。这类记录带 isMeta，要先于 isMeta 判断。
            if let origin = v["origin"], origin["kind"]?.string == "peer" {
                addPeerMessage(name: origin["name"]?.string, body: origin["body"]?.string
                               ?? PeerMessenger.unwrap(SessionIndex.userText(v["message"]?["content"]) ?? "")?.body ?? "", at: stamp)
                return
            }
            if v["isMeta"]?.bool == true { return }
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
                if sawResult { return }
            }
            guard let t = SessionIndex.userText(content) else { return }
            if t.hasPrefix("[Request interrupted") {
                builder.addNote("已打断", level: "info")
            } else if SessionIndex.isRealPrompt(t) {
                // 终端里粘贴的图片是 image 块；本 app 发的附件写在正文末尾几行。都拆成缩略图 / 文件片挂在消息上。
                let parsed = UserMessageParser.parse(text: SessionReader.stripReminders(t), blocks: content?.array)
                builder.addUser(text: parsed.text, attachments: parsed.attachments, at: stamp)
            }
        case "assistant":
            if let m = v["message"]?["model"]?.string, !m.isEmpty { lastModel = m }
            builder.addAssistant(content: v["message"]?["content"]?.array ?? [], at: stamp)
        case "attachment":
            // 一轮进行中插进来的话（终端里用户在 Claude 干活时打的字、别的会话投来的消息）只记在这里，不另有 user 记录。
            guard let a = v["attachment"], a["type"]?.string == "queued_command" else { return }
            let origin = a["origin"]
            if origin?["kind"]?.string == "peer" {
                addPeerMessage(name: origin?["name"]?.string,
                               body: origin?["body"]?.string ?? PeerMessenger.unwrap(a["prompt"]?.string ?? "")?.body ?? "",
                               at: stamp)
            } else if let p = a["prompt"]?.string, SessionIndex.isRealPrompt(p) {
                let parsed = UserMessageParser.parse(text: SessionReader.stripReminders(p), blocks: nil)
                builder.addUser(text: parsed.text, attachments: parsed.attachments, at: stamp)
            }
        case "system":
            switch v["subtype"]?.string {
            case "compact_boundary":
                builder.addNote("上下文已压缩", level: "info")
            case "away_summary":
                // 终端里离开 5 分钟以上回来时那条「※ recap:」。
                if let text = v["content"]?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    builder.addNote(text, level: "recap")
                }
            default:
                break
            }
        default:
            return
        }
    }

    private mutating func addPeerMessage(name: String?, body: String, at date: Date?) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if name == PeerMessenger.senderName {
            // 本 app 投进去的：本地已经显示过就不再来一遍；别的实例投的就显示正文（去掉给对方看的那句说明）。
            if let i = expectedEchoes.firstIndex(of: text) { expectedEchoes.remove(at: i); return }
            let parsed = UserMessageParser.parse(text: PeerMessenger.stripUserNote(text), blocks: nil)
            builder.addUser(text: parsed.text, attachments: parsed.attachments, at: date)
        } else {
            builder.addUser(text: "来自会话「\(name ?? "?")」：\n\(text)", at: date)
        }
    }

    /// 终端会把 system-reminder 拼进用户消息里，回放时不用给用户看。
    static func stripReminders(_ text: String) -> String {
        TitleMaker.stripReminders(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 旧名字，其他地方还在用。
enum SessionLoader {
    static func load(url: URL) -> [TranscriptItem] { SessionReader.load(url: url) }
    static func stripReminders(_ text: String) -> String { SessionReader.stripReminders(text) }
}
