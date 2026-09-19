import Foundation

/// 侧栏需要的一条会话记录：从 `~/.claude/projects/<cwd 编码>/<id>.jsonl` 的头尾各读一段得来，不读整个文件。
struct SessionRecord: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var cwd: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var path: String
    var fileSize: Int
    var fileModified: Date
}

enum SessionIndex {
    static var projectsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static var sessionsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// Claude Code 给项目目录命名的规则：路径里每个非字母数字字符换成 `-`（中文每个字一个 `-`）。
    static func encodeProjectPath(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func sessionFileURL(id: String, cwd: String) -> URL {
        projectsDir.appendingPathComponent(encodeProjectPath(cwd)).appendingPathComponent(id + ".jsonl")
    }

    /// 扫一遍所有项目目录。`previous` 是上次的结果：大小和修改时间没变的文件直接沿用，不重新解析。
    static func scan(previous: [String: SessionRecord]) -> [String: SessionRecord] {
        let fm = FileManager.default
        var result: [String: SessionRecord] = [:]
        guard let dirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { return result }
        for dir in dirs {
            let name = dir.lastPathComponent
            // 子代理/工作流的临时项目目录不算会话。
            if name.contains("subagents") || name.contains("workflows") || name.contains("scratchpad") { continue }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                guard let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = attrs.fileSize, let mtime = attrs.contentModificationDate else { continue }
                if let old = previous[id], old.fileSize == size, old.fileModified == mtime, old.path == file.path {
                    result[id] = old
                    continue
                }
                if let rec = parse(file: file, id: id, size: size, mtime: mtime) {
                    result[id] = rec
                }
            }
        }
        return result
    }

    /// 正在终端里跑的会话：sessionId → 状态（busy / idle）。
    static func liveSessions() -> [String: String] {
        var live: [String: String] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return live }
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let v = JSONValue.parse(data),
                  let sid = v["sessionId"]?.string else { continue }
            // 进程还在才算活着；文件常常留着不删。
            if let pid = v["pid"]?.int, kill(pid_t(pid), 0) != 0 { continue }
            // 本 app 自己起的 -p 进程也会登记在这里，只有交互式终端会话才算"终端里开着"。
            if v["entrypoint"]?.string != "cli" { continue }
            live[sid] = v["status"]?.string ?? "idle"
        }
        return live
    }

    // MARK: - 单个文件

    private static let headBytes = 512 * 1024
    private static let headMaxBytes = 16 * 1024 * 1024
    private static let tailBytes = 256 * 1024

    private static func parse(file: URL, id: String, size: Int, mtime: Date) -> SessionRecord? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var cwd: String? = nil
        var firstPrompt: String? = nil
        var createdAt: Date? = nil
        // 首条消息带图片时一行就有几 MB，512 KB 里截不到完整的一行；按块往下读，直到读到首条真正的用户消息。
        var head = Data()
        var seen = 0
        scan: while head.count < headMaxBytes {
            guard let chunk = try? handle.read(upToCount: headBytes), !chunk.isEmpty else { break }
            head.append(chunk)
            var ls = lines(of: head)
            if chunk.count == headBytes, !ls.isEmpty { ls.removeLast() }   // 最后一行可能还没读完
            for line in ls.dropFirst(seen) {
                // 先做便宜的字符串筛选，再解析 JSON。
                guard line.contains("\"type\":\"user\"") else { continue }
                guard let v = JSONValue.parse(line) else { continue }
                if v["isMeta"]?.bool == true || v["isSidechain"]?.bool == true { continue }
                if cwd == nil { cwd = v["cwd"]?.string }
                guard let text = userText(v["message"]?["content"]), isRealPrompt(text) else { continue }
                firstPrompt = text
                createdAt = parseDate(v["timestamp"]?.string)
                break scan
            }
            seen = ls.count
        }
        var tail = Data()
        if size > head.count {
            try? handle.seek(toOffset: UInt64(max(head.count, size - tailBytes)))
            tail = (try? handle.readToEnd()) ?? Data()
        }
        guard let cwd, let firstPrompt else { return nil }
        // 临时目录里的会话（工作流、探针）不进列表。
        if cwd.hasPrefix("/private/tmp") || cwd.hasPrefix("/tmp") || cwd.contains("/scratchpad") { return nil }

        var customTitle: String? = nil
        var aiTitle: String? = nil
        var lastStamp: Date? = nil
        let tailSource = tail.isEmpty ? head : tail
        for line in lines(of: tailSource) {
            if line.contains("\"type\":\"custom-title\""), let v = JSONValue.parse(line) {
                customTitle = v["customTitle"]?.string
            } else if line.contains("\"type\":\"ai-title\""), let v = JSONValue.parse(line) {
                aiTitle = v["aiTitle"]?.string
            } else if line.contains("\"timestamp\":\""), let r = line.range(of: "\"timestamp\":\"") {
                let rest = line[r.upperBound...]
                if let end = rest.firstIndex(of: "\"") { lastStamp = parseDate(String(rest[..<end])) ?? lastStamp }
            }
        }

        let title = [customTitle, aiTitle].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? TitleMaker.title(from: firstPrompt)
        return SessionRecord(id: id, cwd: cwd, title: title,
                             createdAt: createdAt ?? mtime,
                             updatedAt: lastStamp ?? mtime,
                             path: file.path, fileSize: size, fileModified: mtime)
    }

    private static func lines(of data: Data) -> [String] {
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        return s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    static func userText(_ content: JSONValue?) -> String? {
        if let s = content?.string { return s }
        if let blocks = content?.array {
            let t = blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
            return t.isEmpty ? nil : t
        }
        return nil
    }

    /// 斜杠命令回显、系统提醒这类不是用户真正说的话。CLI 会把 <system-reminder> 块拼在首条消息前面，先剥掉再判断。
    static func isRealPrompt(_ text: String) -> Bool {
        let t = TitleMaker.stripReminders(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.hasPrefix("<command-name>") || t.hasPrefix("<local-command") || t.hasPrefix("<system-reminder>") { return false }
        if t.hasPrefix("Caveat:") { return false }
        return true
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}

enum TitleMaker {
    /// 首条消息 → 侧栏标题：去掉系统提醒块，取第一行，压掉多余空白，最多 48 字。
    static func stripReminders(_ text: String) -> String {
        var t = text
        while let open = t.range(of: "<system-reminder>"), let close = t.range(of: "</system-reminder>", range: open.upperBound..<t.endIndex) {
            t.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return t
    }

    static func title(from prompt: String) -> String {
        let t = stripReminders(prompt)
        let firstLine = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { !$0.isEmpty }) ?? ""
        let squeezed = firstLine.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if squeezed.count > 48 { return String(squeezed.prefix(47)) + "…" }
        return squeezed.isEmpty ? "新对话" : squeezed
    }
}
