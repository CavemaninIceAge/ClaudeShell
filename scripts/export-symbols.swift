#!/usr/bin/env swift
// 把网页层用到的 SF Symbols 导成 PNG 蒙版（黑色、透明底、4x），CSS 用 mask + currentColor 上色，
// 这样正文里的图标和原生侧的 SF Symbols 是同一套画法。用法：swift scripts/export-symbols.swift App/Resources/web/icons
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let symbols: [(String, String)] = [
    ("terminal", "terminal"), ("file", "doc.text"), ("pencil", "pencil.line"), ("search", "magnifyingglass"),
    ("globe", "globe"), ("agent", "person.2"), ("wrench", "wrench.and.screwdriver"), ("sparkle", "sparkles"),
    ("steps", "list.bullet"), ("chevron", "chevron.right"), ("folder", "folder"), ("photo", "photo"),
]
let scale: CGFloat = 4
let canvas: CGFloat = 20
var css = "/* 由 scripts/export-symbols.swift 生成，别手改。SF Symbols 蒙版，配合 transcript.css 里的 .icon 用 currentColor 上色。 */\n"
for (name, symbol) in symbols {
    guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
          let img = base.withSymbolConfiguration(.init(pointSize: 14, weight: .regular, scale: .medium)) else {
        print("missing", symbol); continue
    }
    let px = Int(canvas * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    // 上下文是按像素建的，要自己放大到 4x，不然符号只画在左下角 20px 里。
    ctx.cgContext.scaleBy(x: scale, y: scale)
    let size = img.size
    let rect = NSRect(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2, width: size.width, height: size.height)
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: out.appendingPathComponent(name + ".png"))
        // WebKit 对 mask-image 做 CORS 校验，file:// 下每个文件都是独立源会被拒；内嵌成 data URI 就没这个问题。
        css += ".icon-\(name) { -webkit-mask-image: url(data:image/png;base64,\(data.base64EncodedString())); mask-image: url(data:image/png;base64,\(data.base64EncodedString())); }\n"
        print(name, symbol, size)
    }
}
try? css.write(to: out.deletingLastPathComponent().appendingPathComponent("icons.css"), atomically: true, encoding: .utf8)
print("icons.css written")
