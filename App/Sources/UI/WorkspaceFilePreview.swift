import AppKit
import Quartz
import SwiftUI

/// A user-requested local preview stays in this app (PDFs, images, text and documents).
struct WorkspaceFilePreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(ThreadStore.self) private var store
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc")
                Text(url.lastPathComponent).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer()
                Button("添加到当前对话") { store.selectedController?.attach(urls: [url]); dismiss() }
                    .disabled(store.selectedController == nil)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if FileManager.default.fileExists(atPath: url.path) {
                LocalQuickLook(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("文件已移动或删除", systemImage: "doc.badge.ellipsis", description: Text(url.path))
            }
        }.frame(minWidth: 600, idealWidth: 820, minHeight: 420, idealHeight: 620)
            .background(Theme.background)
    }
}

private struct LocalQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
