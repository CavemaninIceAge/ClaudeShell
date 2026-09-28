import Foundation

enum ConversationEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var displayName: String { self == .claude ? "Claude" : "Codex" }
}

/// Reads local Codex rollouts without opening Codex or touching its credentials.
enum CodexHistory {
    static func key(_ id: String) -> String { "codex:" + id }
    static func sessionId(_ key: String) -> String { key.hasPrefix("codex:") ? String(key.dropFirst(6)) : key }

    static func scan(homes: [URL], previous: [String: SessionRecord]) -> [String: SessionRecord] {
        var records: [String: SessionRecord] = [:]
        let fm = FileManager.default
        var seen = Set<String>()
        for home in homes {
            let root = home.appendingPathComponent("sessions").resolvingSymlinksInPath()
            guard seen.insert(root.path).inserted else { continue }
            guard let paths = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in paths where file.pathExtension == "jsonl" {
                guard let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = attrs.fileSize, let modified = attrs.contentModificationDate else { continue }
                let suffix = String(file.deletingPathExtension().lastPathComponent.suffix(36))
                guard UUID(uuidString: suffix) != nil else { continue }
                let id = key(suffix)
                let record: SessionRecord?
                if let old = previous[id], old.path == file.path, old.fileModified == modified, old.fileSize == size {
                    record = old
                } else { record = index(file: file, id: id, size: size, modified: modified) }
                if let record, records[id].map({ $0.updatedAt < record.updatedAt }) ?? true { records[id] = record }
            }
        }
        return records
    }

    static func index(file: URL, id: String, size: Int, modified: Date) -> SessionRecord? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        var cwd: String?
        var created: Date?
        var prompt: String?
        var fallbackPrompt: String?
        var consumed = 0
        while consumed < 16 * 1024 * 1024 {
            guard let chunk = try? handle.read(upToCount: 128 * 1024), !chunk.isEmpty else { break }
            consumed += chunk.count
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let value = JSONValue.parse(line), let payload = value["payload"] else { continue }
                if value["type"]?.string == "session_meta" {
                    cwd = payload["cwd"]?.string
                    created = SessionIndex.parseDate(payload["timestamp"]?.string ?? value["timestamp"]?.string)
                    if payload["source"]?.object?["subagent"] != nil { return nil }
                }
                if value["type"]?.string == "event_msg", payload["type"]?.string == "user_message" {
                    if let message = payload["message"]?.string, !message.isEmpty { prompt = message }
                    else if payload["images"]?.array?.isEmpty == false || payload["local_images"]?.array?.isEmpty == false { prompt = "图片对话" }
                }
                if fallbackPrompt == nil, value["type"]?.string == "response_item", payload["role"]?.string == "user" {
                    let candidate = text(payload["content"])
                    if isPrompt(candidate) { fallbackPrompt = candidate }
                    else if candidate.isEmpty, !attachments(payload["content"]).isEmpty { fallbackPrompt = "图片对话" }
                }
                if cwd != nil, prompt != nil { break }
            }
            if cwd != nil, prompt != nil { break }
        }
        guard let cwd, let first = prompt ?? fallbackPrompt, !first.isEmpty else { return nil }
        return SessionRecord(id: id, cwd: cwd, title: TitleMaker.title(from: first), createdAt: created ?? modified,
                             updatedAt: modified, path: file.path, fileSize: size, fileModified: modified, engine: .codex)
    }

    static func load(url: URL) throws -> (items: [TranscriptItem], model: String?) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        var builder = TranscriptBuilder()
        var model: String?
        // response_item is the canonical message/tool stream. event_msg carries lifecycle metadata only.
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let value = JSONValue.parse(line) else { continue }
                consume(value, builder: &builder, model: &model)
            }
        }
        if let value = JSONValue.parse(buffer) { consume(value, builder: &builder, model: &model) }
        return (builder.finish(), model)
    }

    static func consume(_ value: JSONValue, builder: inout TranscriptBuilder, model: inout String?) {
        guard let payload = value["payload"] else { return }
        let at = SessionIndex.parseDate(value["timestamp"]?.string)
        if value["type"]?.string == "turn_context" { model = payload["model"]?.string ?? model; return }
        guard value["type"]?.string == "response_item" else { return }
        switch payload["type"]?.string {
        case "message":
            let content = text(payload["content"])
            let images = attachments(payload["content"])
            if payload["role"]?.string == "user", isPrompt(content) || (content.isEmpty && !images.isEmpty) {
                builder.addUser(text: content, attachments: images, at: at)
            } else if payload["role"]?.string == "assistant", !content.isEmpty {
                builder.addAssistant(content: [.object(["type": .string("text"), "text": .string(content)])], at: at)
            }
        case "reasoning":
            let summary = text(payload["summary"])
            if !summary.isEmpty { builder.addAssistant(content: [.object(["type": .string("thinking"), "thinking": .string(summary)])], at: at) }
        case "function_call", "custom_tool_call":
            let input = payload["arguments"]?.string.flatMap(JSONValue.parse) ?? payload["input"] ?? .object([:])
            builder.addAssistant(content: [.object(["type": .string("tool_use"), "id": payload["call_id"] ?? .string(UUID().uuidString),
                                                  "name": payload["name"] ?? .string("工具"), "input": input])], at: at)
        case "function_call_output", "custom_tool_call_output":
            builder.addToolResult(toolUseId: payload["call_id"]?.string ?? "", content: payload["output"] ?? .null, isError: false, at: at)
        default: break
        }
    }

    static func attachments(_ content: JSONValue?) -> [TranscriptAttachment] {
        var result: [TranscriptAttachment] = []
        for item in content?.array ?? [] {
            let type = item["type"]?.string
            if type == "localImage" || type == "local_image", let path = item["path"]?.string {
                result.append(TranscriptAttachment(kind: "image", name: URL(fileURLWithPath: path).lastPathComponent, path: path))
            } else if type == "input_image" || type == "image" {
                guard let url = item["image_url"]?.string ?? item["image_url"]?["url"]?.string ?? item["url"]?.string else { continue }
                let name = "图片 \(result.count + 1)"
                if url.hasPrefix("data:image/") {
                    result.append(TranscriptAttachment(kind: "image", name: name, preview: url))
                } else if url.hasPrefix("file:"), let file = URL(string: url), file.isFileURL {
                    result.append(TranscriptAttachment(kind: "image", name: file.lastPathComponent, path: file.path))
                } else if url.hasPrefix("/") {
                    result.append(TranscriptAttachment(kind: "image", name: URL(fileURLWithPath: url).lastPathComponent, path: url))
                } else {
                    result.append(TranscriptAttachment(kind: "image", name: "远程图片（仅引用）", sourceURL: url))
                }
            }
        }
        return result
    }

    static func text(_ content: JSONValue?) -> String {
        if let string = content?.string { return string }
        return content?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
    }

    private static func isPrompt(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && !text.hasPrefix("<environment_context>") && !text.hasPrefix("# AGENTS.md instructions")
            && !text.hasPrefix("<permissions instructions>")
    }

}
