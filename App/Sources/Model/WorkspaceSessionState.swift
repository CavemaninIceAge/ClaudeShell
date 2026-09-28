import AppKit
import Foundation

/// Only application-owned drafts and navigation metadata live here. Native transcript
/// files, credentials, and engine session state remain owned by Claude Code / Codex.
struct WorkspaceSessionState: Codable {
    var version = 1
    var selectedID: String?
    var projects: [String] = []
    var composers: [Composer] = []

    struct Composer: Codable {
        var id: String
        var cwd: String
        var title: String
        var createdAt: Date
        var settings: ThreadSettings
        var isDraft: Bool
        var text: String
        var attachments: [Attachment]
    }
    struct Attachment: Codable {
        var id: String
        var kind: String
        var name: String
        var path: String?
        var imageData: Data?
        var mediaType: String?
        var preview: String?

        init(_ value: ComposerAttachment) {
            id = value.id; name = value.name; path = value.path
            kind = value.kind == .image ? "image" : value.kind == .directory ? "directory" : "file"
            imageData = value.imageData; mediaType = value.mediaType; preview = value.preview
        }
        func restore() -> ComposerAttachment {
            ComposerAttachment(id: id, kind: kind == "image" ? .image : kind == "directory" ? .directory : .file,
                               name: name, path: path, imageData: imageData, mediaType: mediaType,
                               thumbnail: imageData.flatMap(NSImage.init(data:)), preview: preview)
        }
    }

    static func load(from url: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder.standard.decode(Self.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw Failure(message: "工作区由更新版本创建，请更新应用后再打开。") }
        return value
    }
    func save(to url: URL) throws {
        try AppAuthPaths.writePrivate(JSONEncoder.standard.encode(self), to: url)
    }
    struct Failure: LocalizedError { var message: String; var errorDescription: String? { message } }
}
