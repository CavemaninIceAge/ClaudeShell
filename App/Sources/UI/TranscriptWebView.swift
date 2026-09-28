import AppKit
import SwiftUI
import WebKit

/// 对话正文：一个 WKWebView，Markdown 由 web/transcript.js 用 marked + highlight.js 渲染。
/// Swift 只把变了的条目（按 rev）推过去，网页层按 id 替换 DOM。
/// WKWebView 一出生就把自己登记成拖放目标（文件、图片、文字……十几种类型），AppKit 派拖放是「落点下面最深的、
/// 登记过的视图接」，所以已有对话里正文占的那一大片会把拖进来的文件 / 照片截走：网页不可编辑，WebKit 回「不收」，
/// 光标变禁止号，什么也不发生；新对话没有正文，才显得拖放能用。这里正文自己接文件 / 图片，挂到输入框上，
/// 其余类型（拖文字之类）照旧交给 WebKit。
final class TranscriptWKWebView: WKWebView {
    var onDropFiles: (([URL]) -> Void)?
    var onDropImage: ((Data, String) -> Void)?
    var onDropTargeted: ((Bool) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        // WebKit 登记的是老式的 NSFilenamesPboardType；把 public.file-url 也补上，Finder 拖来的文件两种写法都能对上。
        registerForDraggedTypes(registeredDraggedTypes + [.fileURL] + PasteboardAttachments.imageTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func hasAttachable(_ pb: NSPasteboard) -> Bool { PasteboardAttachments.hasAttachable(pb) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasAttachable(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasAttachable(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargeted?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasAttachable(sender.draggingPasteboard) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTargeted?(false)
        if PasteboardAttachments.take(from: sender.draggingPasteboard, source: "transcript drop",
                                      files: { onDropFiles?($0) }, image: { onDropImage?($0, $1) }) { return true }
        return super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDropTargeted?(false)
        super.concludeDragOperation(sender)
    }
}

struct TranscriptWebView: NSViewRepresentable {
    @Environment(WorkspaceContentStore.self) private var content
    let controller: ConversationController
    var onDropTargeted: (Bool) -> Void = { _ in }   // 文件 / 照片拖过正文时，输入框跟着亮边

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "bridge")
        let home = JSONValue.string(NSHomeDirectory()).serialized()
        config.userContentController.addUserScript(WKUserScript(
            source: "window.CS_HOME = \(home);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let web = TranscriptWKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.onDropFiles = { [controller] in controller.attach(urls: $0) }
        web.onDropImage = { [controller] in controller.attach(imageData: $0, name: $1) }
        web.onDropTargeted = { [weak coordinator = context.coordinator] in coordinator?.parent.onDropTargeted($0) }
        web.setValue(false, forKey: "drawsBackground")
        web.allowsMagnification = false
        context.coordinator.webView = web
        if let url = Bundle.main.url(forResource: "transcript", withExtension: "html", subdirectory: "web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(items: controller.items, working: controller.showsActivity,
                                 status: controller.activityText ?? "", effort: controller.activeEffortLabel)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
        web.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: TranscriptWebView
        weak var webView: WKWebView?
        init(_ parent: TranscriptWebView) { self.parent = parent }
        private var ready = false
        private var sentRevs: [String: Int] = [:]
        private var pending: (items: [TranscriptItem], working: Bool, status: String, effort: String)?
        private var snapshotTask: Task<Void, Never>?

        func sync(items: [TranscriptItem], working: Bool, status: String, effort: String) {
            guard ready, let web = webView else {
                pending = (items, working, status, effort)
                return
            }
            var js = ""
            let ids = Set(items.map(\.id))
            let stale = sentRevs.keys.filter { !ids.contains($0) }
            for id in stale {
                js += "CS.remove(\(JSONValue.string(id).serialized()));"
                sentRevs[id] = nil
            }
            for (index, item) in items.enumerated() where sentRevs[item.id] != item.rev {
                if let data = try? JSONEncoder.standard.encode(item), let s = String(data: data, encoding: .utf8) {
                    js += "CS.upsert(\(s), \(index));"
                    let key = parent.controller.id + ":" + item.id
                    let feedback = UserDefaults.standard.dictionary(forKey: "workspaceResponseFeedback")?[key] as? Bool ?? false
                    js += "CSResponseActions.setFeedback(\(JSONValue.string(item.id).serialized()), \(feedback ? "true" : "false"));"
                }
                sentRevs[item.id] = item.rev
            }
            js += "CS.setEffort(\(JSONValue.string(effort).serialized()));"
            js += "CS.setWorking(\(working ? "true" : "false"), \(JSONValue.string(status).serialized()));"
            if UserDefaults.standard.bool(forKey: "testExpandAll") {
                js += "document.querySelectorAll('details').forEach(function (d) { d.open = true; });"
            }
            web.evaluateJavaScript(js) { _, error in
                if let error { TestLog.write("web eval error: \(error.localizedDescription)") }
            }
            // -testWebSnapshot <png 路径>：每次同步后把网页层自己截下来。窗口在别的桌面时 WebKit 不往窗口画，
            // screencapture 拿到的正文是空白；takeSnapshot 不受这个限制，验证正文渲染用它。
            if !working, !items.isEmpty, let path = UserDefaults.standard.string(forKey: "testWebSnapshot"), !path.isEmpty {
                snapshotTask?.cancel()
                snapshotTask = Task { [weak web] in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let web else { return }
                    // -testScrollTo <css 选择器>：先把那个元素滚到视口中间再截（长对话里看某一条）。
                    if let sel = UserDefaults.standard.string(forKey: "testScrollTo"), !sel.isEmpty {
                        let js = "(function(){var e=document.querySelector(\(JSONValue.string(sel).serialized()));if(e)e.scrollIntoView({block:'center'});return !!e;})()"
                        let found = try? await web.evaluateJavaScript(js)
                        TestLog.write("testScrollTo \(sel): \(String(describing: found))")
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    let cfg = WKSnapshotConfiguration()
                    cfg.rect = CGRect(origin: .zero, size: web.bounds.size)
                    web.takeSnapshot(with: cfg) { image, error in
                        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                              let png = rep.representation(using: .png, properties: [:]) else {
                            TestLog.write("web snapshot failed: \(error?.localizedDescription ?? "?")"); return
                        }
                        try? png.write(to: URL(fileURLWithPath: path))
                        TestLog.write("web snapshot -> \(path) \(Int(image.size.width))x\(Int(image.size.height))")
                    }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "log":
                TestLog.write("web: \(body["text"] as? String ?? "")")
            case "ready":
                TestLog.write("web ready")
                ready = true
                if let p = pending {
                    pending = nil
                    sync(items: p.items, working: p.working, status: p.status, effort: p.effort)
                }
            case "open":
                if let s = body["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
            case "copy_response", "response_feedback", "save_response":
                guard let id = body["id"] as? String,
                      let item = parent.controller.items.first(where: { $0.id == id && $0.kind == .assistant }) else { return }
                if type == "copy_response" {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(WorkspaceResponseArchive.text(of: item), forType: .string)
                } else if type == "response_feedback", let liked = body["liked"] as? Bool {
                    var feedback = UserDefaults.standard.dictionary(forKey: "workspaceResponseFeedback") ?? [:]
                    feedback[parent.controller.id + ":" + id] = liked
                    UserDefaults.standard.set(feedback, forKey: "workspaceResponseFeedback")
                } else if type == "save_response" {
                    do {
                        let url = try WorkspaceResponseArchive.save(item, threadID: parent.controller.id)
                        parent.content.add(url: url, threadID: parent.controller.id)
                        if parent.content.lastError == nil {
                            webView?.evaluateJavaScript("CSResponseActions.saved(\(JSONValue.string(id).serialized()));", completionHandler: nil)
                        }
                    } catch { parent.content.lastError = error.localizedDescription }
                }
            case "copy":
                if let text = body["text"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if url.isFileURL || url.scheme == "about" { return .allow }
            NSWorkspace.shared.open(url)
            return .cancel
        }
    }
}
