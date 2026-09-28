import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 输入卡顶上那一排还没发出去的附件：图片是方缩略图，文件 / 目录是图标 + 名字的小片；悬停出「×」。
struct AttachmentStrip: View {
    let attachments: [ComposerAttachment]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    AttachmentTile(attachment: a) { onRemove(a.id) }
                }
            }
            .padding(.top, 4)      // 给「×」露出来的那一角留位置
            .padding(.trailing, 4)
        }
    }
}

private struct AttachmentTile: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.sendFg)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Theme.sendFill))
                    .overlay(Circle().strokeBorder(Theme.composerFill, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .opacity(hovering ? 1 : 0)
            .help("去掉这个附件")
        }
        .onHover { hovering = $0 }
        .help(attachment.path ?? attachment.name)
    }

    @ViewBuilder
    private var content: some View {
        if attachment.kind == .image, let image = attachment.thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipped()
        } else {
            HStack(spacing: 7) {
                Image(systemName: attachment.kind == .directory ? "folder" : "doc.text")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(kindLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .frame(maxWidth: 220)
            .background(Theme.chipFill)
        }
    }

    private var kindLabel: String {
        if attachment.kind == .directory { return "目录" }
        let ext = (attachment.name as NSString).pathExtension
        return ext.isEmpty ? "文件" : ext.uppercased()
    }
}

/// 剪贴板 / 拖放里能挂成附件的东西：文件 URL，或没有路径的图片字节（浏览器拖图、截图粘贴）。
/// 输入框（SubmitTextView）和正文（TranscriptWKWebView）接拖放走的是同一套判断。
enum PasteboardAttachments {
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    static func fileURLs(on pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func imageData(on pb: NSPasteboard) -> Data? {
        for t in imageTypes { if let d = pb.data(forType: t) { return d } }
        return nil
    }

    static func hasAttachable(_ pb: NSPasteboard) -> Bool {
        !fileURLs(on: pb).isEmpty || imageData(on: pb) != nil
    }

    /// 取走了就返回 true；否则由调用方按普通文字处理。
    /// textWins：剪贴板同时有文字和图片（Excel / Numbers 复制单元格会附一张渲染图）时按文字贴。
    @discardableResult
    static func take(from pb: NSPasteboard, source: String, textWins: Bool = false,
                     files: ([URL]) -> Void, image: (Data, String) -> Void) -> Bool {
        let urls = fileURLs(on: pb)
        if !urls.isEmpty {
            TestLog.write("\(source) files: \(urls.map(\.path))")
            files(urls)
            return true
        }
        if textWins, pb.string(forType: .string) != nil { return false }
        if let data = imageData(on: pb) {
            TestLog.write("\(source) image: \(data.count) bytes")
            image(data, source.hasSuffix("paste") ? "剪贴板图片.png" : "拖入的图片.png")
            return true
        }
        return false
    }
}

/// 拖到正文区任何位置都算数：从 NSItemProvider 里取文件 URL 或图片字节，交给控制器。
enum DropHandler {
    static let types: [UTType] = [.fileURL, .png, .jpeg, .tiff, .image]

    static func handle(_ providers: [NSItemProvider], controller: ConversationController) -> Bool {
        // 各 provider 是异步取的，攒齐再按拖进来的顺序一次挂上，免得顺序乱掉。
        final class Gather: @unchecked Sendable {
            var slots: [URL?]
            var remaining: Int
            let lock = NSLock()
            init(count: Int) { slots = Array(repeating: nil, count: count); remaining = count }
            func fill(_ i: Int, _ url: URL?, done: @escaping ([URL]) -> Void) {
                lock.lock()
                slots[i] = url
                remaining -= 1
                let finished = remaining == 0
                let urls = slots.compactMap { $0 }
                lock.unlock()
                if finished { done(urls) }
            }
        }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            let gather = Gather(count: fileProviders.count)
            for (i, p) in fileProviders.enumerated() {
                p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    gather.fill(i, url) { urls in Task { @MainActor in controller.attach(urls: urls) } }
                }
            }
        }
        var took = !fileProviders.isEmpty
        for p in providers where !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            for t in [UTType.png, .jpeg, .tiff] where p.hasItemConformingToTypeIdentifier(t.identifier) {
                took = true
                p.loadDataRepresentation(forTypeIdentifier: t.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in controller.attach(imageData: data, name: "拖入的图片.\(t.preferredFilenameExtension ?? "png")") }
                }
                break
            }
        }
        return took
    }
}
