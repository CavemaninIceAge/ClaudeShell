import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 输入框里挂着、还没发出去的一个文件 / 图片 / 目录（拖进来、粘贴进来、或点「+」选的）。
struct ComposerAttachment: Identifiable, Equatable {
    enum Kind: Equatable { case image, file, directory }
    let id: String
    var kind: Kind
    var name: String
    var path: String?          // 剪贴板贴进来的图片没有路径
    var imageData: Data?       // 图片：发给模型的字节（已按上限缩过）
    var mediaType: String?     // image/png | image/jpeg | image/gif | image/webp
    var thumbnail: NSImage?    // 原生侧输入框里的缩略图
    var preview: String?       // 网页层正文里的缩略图（data URL）

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    var transcriptAttachment: TranscriptAttachment {
        TranscriptAttachment(kind: kind == .image ? "image" : (kind == .directory ? "directory" : "file"),
                             name: name, path: path, preview: preview)
    }
}

/// 正文里用户消息上挂的附件（缩略图 / 文件名），历史回放和本地发送共用。
struct TranscriptAttachment: Sendable, Codable, Equatable {
    var kind: String       // image | file | directory
    var name: String
    var path: String?
    var preview: String?   // 图片：data:image/jpeg;base64,… 的缩略图
    var sourceURL: String? = nil // 远程原图只保留引用，不自动请求网络
}

enum AttachmentMaker {
    /// 和终端粘贴图片的处理一致：长边超过 2000 就缩，单张控制在 3.5 MB 内（API 上限 5 MB，base64 还会涨 1/3）。
    static let imageMaxPixels = 2000
    static let imageMaxBytes = 3_500_000
    static let previewMaxPixels = 400
    /// API 直接收的图片格式；别的（HEIC、TIFF、BMP…）转成 JPEG / PNG 再发。
    private static let nativeTypes: [UTType: String] = [.png: "image/png", .jpeg: "image/jpeg", .gif: "image/gif", .webP: "image/webp"]

    static func make(url: URL) -> ComposerAttachment {
        let path = url.path
        let name = url.lastPathComponent
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return ComposerAttachment(id: newId(), kind: .directory, name: name, path: path)
        }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image), let data = try? Data(contentsOf: url),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let (bytes, mediaType) = encode(source: source, original: data, type: type) {
            return ComposerAttachment(id: newId(), kind: .image, name: name, path: path, imageData: bytes, mediaType: mediaType,
                                      thumbnail: thumbnailImage(source), preview: previewDataURL(source))
        }
        return ComposerAttachment(id: newId(), kind: .file, name: name, path: path)
    }

    /// 剪贴板 / 浏览器拖来的图片字节（png、tiff 都行）。
    static func make(imageData data: Data, name: String) -> ComposerAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let (bytes, mediaType) = encode(source: source, original: data, type: sourceType(source)) else { return nil }
        return ComposerAttachment(id: newId(), kind: .image, name: name, path: nil, imageData: bytes, mediaType: mediaType,
                                  thumbnail: thumbnailImage(source), preview: previewDataURL(source))
    }

    /// 历史回放：会话文件里的 base64 图片块 → 正文缩略图。
    static func preview(base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return previewDataURL(source)
    }

    private static func newId() -> String { "att-" + UUID().uuidString.lowercased() }

    private static func sourceType(_ source: CGImageSource) -> UTType? {
        (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
    }

    private static func pixelSize(_ source: CGImageSource) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return max(w, h)
    }

    /// 原图能直接发就直接发（格式对、不超限），否则按长边缩到上限再转码。
    private static func encode(source: CGImageSource, original: Data, type: UTType?) -> (Data, String)? {
        if let type, let mediaType = nativeTypes[type], original.count <= imageMaxBytes, pixelSize(source) <= imageMaxPixels {
            return (original, mediaType)
        }
        // 有透明通道的（png / gif）转 PNG，其余转 JPEG；太大就一路缩到合规为止。
        let keepsAlpha = type?.conforms(to: .png) == true || type?.conforms(to: .gif) == true
        var limit = min(imageMaxPixels, max(pixelSize(source), 1))
        for _ in 0..<6 {
            guard let cg = thumbnail(source, maxPixels: limit) else { return nil }
            let out = NSMutableData()
            let uti: UTType = keepsAlpha ? .png : .jpeg
            guard let dest = CGImageDestinationCreateWithData(out, uti.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, cg, keepsAlpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            if out.length <= imageMaxBytes { return (out as Data, keepsAlpha ? "image/png" : "image/jpeg") }
            limit = limit * 7 / 10
        }
        return nil
    }

    /// ImageIO 的缩略图：按 EXIF 方向转正、长边不超过 maxPixels。HEIC 这类系统认得的格式都能读。
    private static func thumbnail(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    private static func thumbnailImage(_ source: CGImageSource) -> NSImage? {
        guard let cg = thumbnail(source, maxPixels: previewMaxPixels) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func previewDataURL(_ source: CGImageSource) -> String? {
        guard let cg = thumbnail(source, maxPixels: previewMaxPixels) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return "data:image/jpeg;base64," + (out as Data).base64EncodedString()
    }

    /// 没有路径的图片（剪贴板贴的）要投进终端会话时才落盘：那条协议只能带文字，终端那边的 Claude 按路径去读。
    static func persistIfNeeded(_ a: ComposerAttachment) -> String? {
        if let p = a.path { return p }
        guard let data = a.imageData else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Shell/pasted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = a.mediaType == "image/png" ? "png" : (a.mediaType == "image/gif" ? "gif" : (a.mediaType == "image/webp" ? "webp" : "jpg"))
        let url = dir.appendingPathComponent(a.id + "." + ext)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url.path
    }
}

/// 把「打的字 + 附件」折成一条要发出去的消息：正文里附件写成终端也认的写法，图片另带 image 块。
///
///     打的字
///
///     [Image #1] /path/photo.jpg      ← 图片：和终端粘贴一样的标记，image 块另带（有路径就顺手写上）
///     @"/path/report.pdf"             ← 文件 / 目录：CLI 认 @ 引用，文本文件和目录会自动附上内容，其余的 Claude 自己去读
struct OutgoingMessage {
    var wireText: String
    var imageBlocks: [JSONValue]
    var displayText: String
    var attachments: [TranscriptAttachment]
    var titleText: String

    /// inlineImages = false：投进终端的会话，协议只能带文字，图片也按路径引用。
    init(text: String, attachments atts: [ComposerAttachment], inlineImages: Bool) {
        var lines: [String] = []
        var blocks: [JSONValue] = []
        var shown: [TranscriptAttachment] = []
        var imageIndex = 0
        for a in atts {
            var t = a.transcriptAttachment
            if a.kind == .image, inlineImages, let data = a.imageData, let mediaType = a.mediaType {
                imageIndex += 1
                lines.append("[Image #\(imageIndex)]" + (a.path.map { " " + $0 } ?? ""))
                blocks.append(.object([
                    "type": .string("image"),
                    "source": .object(["type": .string("base64"), "media_type": .string(mediaType),
                                       "data": .string(data.base64EncodedString())]),
                ]))
            } else {
                guard let path = AttachmentMaker.persistIfNeeded(a) else { continue }
                t.path = path
                lines.append("@\"\(path)\"")
            }
            shown.append(t)
        }
        var wire = text
        if !lines.isEmpty { wire += (text.isEmpty ? "" : "\n\n") + lines.joined(separator: "\n") }
        wireText = wire
        imageBlocks = blocks
        displayText = text
        attachments = shown
        titleText = text.isEmpty ? shown.map(\.name).joined(separator: "、") : text
    }
}

/// 历史回放：把会话文件里一条用户消息拆回「正文 + 附件」。终端粘贴的图片（`[Image #1] 这是啥` + image 块）、
/// 本 app 发的（末尾的 `[Image #1] path` / `@"path"` 行）都认。
enum UserMessageParser {
    static func parse(text: String, blocks: [JSONValue]?) -> (text: String, attachments: [TranscriptAttachment]) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var imagePaths: [Int: String] = [:]
        var files: [TranscriptAttachment] = []
        // 末尾那几行附件标记是本 app 写的，从后往前剥。
        while let last = lines.last?.trimmingCharacters(in: .whitespaces) {
            if let (n, path) = imageMarker(last) {
                if let path { imagePaths[n] = path }
            } else if last.hasPrefix("@\"/"), last.hasSuffix("\""), last.count > 4 {
                let path = String(last.dropFirst(2).dropLast())
                var isDir: ObjCBool = false
                let dir = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                files.insert(TranscriptAttachment(kind: dir ? "directory" : "file", name: (path as NSString).lastPathComponent, path: path), at: 0)
            } else {
                break
            }
            lines.removeLast()
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        var images: [TranscriptAttachment] = []
        var n = 0
        for b in blocks ?? [] where b["type"]?.string == "image" {
            n += 1
            let preview = b["source"]?["data"]?.string.flatMap(AttachmentMaker.preview(base64:))
            let path = imagePaths[n]
            images.append(TranscriptAttachment(kind: "image", name: path.map { ($0 as NSString).lastPathComponent } ?? "图片 \(n)",
                                               path: path, preview: preview))
        }
        return (lines.joined(separator: "\n"), images + files)
    }

    /// `[Image #3]` 或 `[Image #3] /绝对路径`。终端粘贴的 `[Image #1] 这是啥` 后面跟的是正文，不算。
    private static func imageMarker(_ line: String) -> (Int, String?)? {
        guard line.hasPrefix("[Image #"), let close = line.firstIndex(of: "]") else { return nil }
        guard let n = Int(line[line.index(line.startIndex, offsetBy: 8)..<close]) else { return nil }
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return (n, nil) }
        return rest.hasPrefix("/") ? (n, rest) : nil
    }
}
