import CryptoKit
import Foundation

enum WorkspaceResponseArchive {
    enum Failure: LocalizedError {
        case noAnswer
        var errorDescription: String? { "这条消息没有可保存的回答正文。" }
    }
    static func text(of item: TranscriptItem) -> String {
        guard item.kind == .assistant else { return "" }
        return item.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n")
    }
    /// Only visible answer prose is exported. Tool payloads and hidden reasoning are excluded.
    static func save(_ item: TranscriptItem, threadID: String, directory: URL? = nil) throws -> URL {
        let text = text(of: item)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.noAnswer }
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Shell/Saved Responses", isDirectory: true)
        let key = SHA256.hash(data: Data((threadID + ":" + item.id).utf8)).map { String(format: "%02x", $0) }.joined()
        let url = root.appendingPathComponent("回答-" + key.prefix(16) + ".md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data((text + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
