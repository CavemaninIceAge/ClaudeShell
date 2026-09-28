import AppKit
import SwiftUI
import WebKit

/// Renders the actual production WorkspaceView without ordering a window, activating an app,
/// bootstrapping stores, loading credentials, or starting a conversation engine.
@main
struct WorkspaceSnapshot {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Variant {
        let surface: WorkspaceFixtures.Surface
        let width: Int
        let height: Int
        let dark: Bool
        var name: String { "\(surface.rawValue)-\(dark ? "dark" : "light")-\(width)x\(height)" }
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                guard CommandLine.arguments.count >= 2 else { throw Failure(description: "Usage: WorkspaceSnapshot <output-directory>") }
                let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                var results: [[String: Any]] = []
                for surface in [WorkspaceFixtures.Surface.empty, .conversation] {
                    for dark in [false, true] {
                        for size in [(1200, 800), (880, 560)] {
                            results.append(try await render(Variant(surface: surface, width: size.0, height: size.1, dark: dark), output: output))
                        }
                    }
                }
                for variant in [Variant(surface: .richConversation, width: 1200, height: 800, dark: false),
                                Variant(surface: .richConversation, width: 880, height: 560, dark: true)] {
                    results.append(try await render(variant, output: output))
                }
                let metadata: [String: Any] = [
                    "view": "Production WorkspaceView", "fixtures": "Synthetic in-memory metadata and transcript",
                    "activationPolicy": "prohibited", "orderedWindows": false, "bootstrap": false,
                    "credentialAccess": false, "inference": false,
                    "capture": "NSView cacheDisplay; replace each WebKit rectangle with opaque Theme.background before compositing its actual WKWebView snapshot",
                    "variants": results,
                ]
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("workspace-preview.json"), options: .atomic)
                print("Rendered \(results.count) production workspace views offscreen.")
                fflush(nil)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("UI snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func render(_ variant: Variant, output: URL) async throws -> [String: Any] {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        let (store, accounts) = WorkspaceFixtures.make(variant.surface)
        let root = WorkspaceView()
            .environment(store)
            .environment(accounts)
            .preferredColorScheme(variant.dark ? .dark : .light)
            .frame(width: CGFloat(variant.width), height: CGFloat(variant.height))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: variant.width, height: variant.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = app.appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: variant.width, height: variant.height)
        defer { window.contentView = nil }
        // Layout runs in an unordered window. It cannot become key or move the user's pointer/focus.
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        let webViews = descendants(of: host).compactMap { $0 as? WKWebView }
        var webSnapshots: [(NSImage, NSRect)] = []
        var webDiagnostics: [[String: Any]] = []
        for web in webViews {
            // Production transcript's ready bridge populates its actual DOM from the fixture controller.
            var ready = false
            for _ in 0..<80 {
                if let count = try? await web.evaluateJavaScript("document.querySelectorAll('#list > article').length"),
                   let number = count as? NSNumber, number.intValue > 0 { ready = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard ready else { throw Failure(description: "Production transcript did not populate in \(variant.name)") }
            // Capture the entire initial viewport consistently instead of retaining per-thread scroll position.
            _ = try? await web.evaluateJavaScript("window.scrollTo(0,0); document.documentElement.scrollTop=0; document.body.scrollTop=0;")
            try await Task.sleep(for: .milliseconds(150))
            let rect = web.convert(web.bounds, to: host)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = web.bounds
            configuration.afterScreenUpdates = false
            let screenshot: NSImage = try await withCheckedThrowingContinuation { continuation in
                web.takeSnapshot(with: configuration) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? Failure(description: "WebKit returned no snapshot")) }
                }
            }
            webSnapshots.append((screenshot, rect))
            if let diagnostics = try? await web.evaluateJavaScript("({viewportWidth:innerWidth,viewportHeight:innerHeight,scrollWidth:document.documentElement.scrollWidth,scrollHeight:document.documentElement.scrollHeight,theme:getComputedStyle(document.documentElement).colorScheme,codeBlocks:document.querySelectorAll('.codeblock').length,codeHeaders:document.querySelectorAll('.codeblock-head').length,tables:document.querySelectorAll('table').length,tableBottoms:Array.from(document.querySelectorAll('table')).map(t=>t.getBoundingClientRect().bottom)})"),
               var dictionary = diagnostics as? [String: Any] {
                dictionary["nativeRect"] = ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
                webDiagnostics.append(dictionary)
            }
        }
        host.layoutSubtreeIfNeeded()
        guard let cached = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(description: "Native bitmap is unavailable") }
        host.cacheDisplay(in: host.bounds, to: cached)
        let native = NSImage(size: host.bounds.size)
        native.addRepresentation(cached)
        // WebKit remote-layer caching varies by OS version. Its cacheDisplay region may be blank or painted.
        // Replace that entire region with the opaque production background before compositing the actual
        // WK snapshot, so translucent bubbles and antialiased glyphs cannot be painted twice.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: variant.width, pixelsHigh: variant.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure(description: "Output bitmap is unavailable") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        native.draw(in: NSRect(x: 0, y: 0, width: variant.width, height: variant.height))
        for (image, rect) in webSnapshots {
            let destination = host.isFlipped ? NSRect(x: rect.minX, y: CGFloat(variant.height) - rect.maxY, width: rect.width, height: rect.height) : rect
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor(Theme.background).setFill()
                NSBezierPath(rect: destination).fill()
            }
            image.draw(in: destination)
        }
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "PNG encoding failed") }
        let path = output.appendingPathComponent(variant.name + ".png")
        try png.write(to: path, options: .atomic)
        print(path.path)
        fflush(nil)
        return ["file": path.lastPathComponent, "surface": variant.surface.rawValue, "width": variant.width,
                "height": variant.height, "appearance": variant.dark ? "dark" : "light", "web": webDiagnostics,
                "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow,
                "nativeSubviews": descendants(of: host).count]
    }

    @MainActor static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
