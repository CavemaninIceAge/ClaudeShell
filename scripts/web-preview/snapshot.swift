#!/usr/bin/env swift
// 离屏渲染网页层样张：swift scripts/web-preview/snapshot.swift <html> <out.png> [dark]
// 不碰用户屏幕，只用来看 transcript.css / .js 的效果。
import AppKit
import WebKit

let args = CommandLine.arguments
let html = URL(fileURLWithPath: args[1]).standardizedFileURL
let out = URL(fileURLWithPath: args[2])
let dark = args.count > 3 && args[3] == "dark"
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 828, height: 900))
web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = web
// 允许读整个仓库：样张用相对路径引用 App/Resources/web。
let root = html.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
web.loadFileURL(html, allowingReadAccessTo: root)
DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
    let cfg = WKSnapshotConfiguration()
    web.takeSnapshot(with: cfg) { image, error in
        if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out)
            print(out.path)
        } else {
            print("snapshot failed: \(error?.localizedDescription ?? "?")")
        }
        exit(0)
    }
}
app.run()
