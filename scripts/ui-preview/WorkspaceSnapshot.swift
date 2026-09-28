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
        var scale: Int { 2 }
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
                let fixtureAssets = try WorkspaceFixtures.makeAssets(in: output.appendingPathComponent("synthetic-fixtures", isDirectory: true))
                var results: [[String: Any]] = []
                for surface in [WorkspaceFixtures.Surface.empty, .conversation] {
                    for dark in [false, true] {
                        results.append(try await render(Variant(surface: surface, width: 1566, height: 895, dark: dark),
                                                        assets: fixtureAssets, output: output))
                    }
                }
                for dark in [false, true] {
                    results.append(try await render(Variant(surface: .conversation, width: 880, height: 560, dark: dark),
                                                    assets: fixtureAssets, output: output))
                }
                for surface in [WorkspaceFixtures.Surface.history, .library, .images, .apps, .settings] {
                    results.append(try await render(Variant(surface: surface, width: 1200, height: 800, dark: false),
                                                    assets: fixtureAssets, output: output))
                }
                for variant in [Variant(surface: .settings, width: 1200, height: 800, dark: true),
                                Variant(surface: .richConversation, width: 880, height: 560, dark: true)] {
                    results.append(try await render(variant, assets: fixtureAssets, output: output))
                }
                for surface in [WorkspaceFixtures.Surface.files, .git, .command] {
                    results.append(try await render(Variant(surface: surface, width: 1566, height: 895, dark: surface == .command), assets: fixtureAssets, output: output))
                }
                results.append(try await render(Variant(surface: .referenceConversation, width: 1566, height: 895, dark: false), assets: fixtureAssets, output: output))
                let chrome = try await verifyNativeChrome(output: output)
                let interaction = try await verifyDraftNavigation(assets: fixtureAssets)
                let metadata: [String: Any] = [
                    "interaction": interaction, "nativeChrome": chrome,
                    "view": "Production WorkspaceView", "fixtures": "Synthetic in-memory metadata/transcript plus plainly labelled local sample files",
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

    @MainActor static func render(_ variant: Variant, assets: [WorkspaceAsset], output: URL) async throws -> [String: Any] {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        let isTools = [WorkspaceFixtures.Surface.files, .git, .command].contains(variant.surface)
        let toolRoot = output.appendingPathComponent("synthetic-workspace", isDirectory: true)
        if isTools { try makeToolProject(toolRoot) }
        let (store, accounts, navigation, content) = WorkspaceFixtures.make(variant.surface, assets: assets, projectOverride: isTools ? toolRoot.path : nil)
        if variant.surface == .referenceConversation, ProcessInfo.processInfo.environment["CLAUDEX_REFERENCE_ATTACHMENT"] != nil {
            for _ in 0..<100 where store.selectedController?.attachments.isEmpty != false { try await Task.sleep(for: .milliseconds(30)) }
            guard store.selectedController?.attachments.isEmpty == false else { throw Failure(description: "Reference attachment failed to load") }
        }
        let tools = WorkspaceToolsStore(environmentProvider: { ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"] })
        defer { tools.shutdown() }
        if isTools {
            navigation.toolsVisible = true
            navigation.toolsTab = variant.surface == .files ? .files : variant.surface == .git ? .git : .command
            let session = tools.activate(cwd: toolRoot.path)
            if variant.surface == .files {
                session.files.loadDirectory(); session.files.open("README.md")
                for _ in 0..<100 where !session.files.loading.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
                guard session.files.selectedDocument != nil else { throw Failure(description: "File fixture failed to load") }
            } else if variant.surface == .git {
                session.git.refresh()
                for _ in 0..<100 where session.git.isLoading { try await Task.sleep(for: .milliseconds(30)) }
                guard let entry = session.git.entries.first(where: { $0.path == "README.md" }) else { throw Failure(description: "Git fixture failed to index") }
                session.git.select(entry)
                for _ in 0..<100 where session.git.isLoadingDiff { try await Task.sleep(for: .milliseconds(30)) }
                guard !session.git.diff.isEmpty else { throw Failure(description: "Git fixture failed to render diff") }
            } else {
                session.command.script = "printf '%s\\n' 'SAMPLE — native project build passed'"
                session.command.start()
                for _ in 0..<100 where session.command.isRunning { try await Task.sleep(for: .milliseconds(30)) }
                guard session.command.output.contains("SAMPLE") else { throw Failure(description: "Command fixture failed") }
            }
        }
        let root = WorkspaceView()
            .environment(store)
            .environment(accounts)
            .environment(navigation)
            .environment(content)
            .environment(tools)
            .preferredColorScheme(variant.dark ? .dark : .light)
            .background(WorkspaceWindowStyle())
            .frame(width: CGFloat(variant.width), height: CGFloat(variant.height))
            .ignoresSafeArea(.container, edges: .top)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let style: NSWindow.StyleMask = variant.surface == .referenceConversation ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let outer = NSRect(x: 0, y: 0, width: variant.width, height: variant.height)
        let window = NSWindow(contentRect: NSWindow.contentRect(forFrameRect: outer, styleMask: style),
                              styleMask: style, backing: .buffered, defer: false)
        window.appearance = app.appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: variant.width, height: variant.height)
        defer { window.contentView = nil }
        // Layout runs in an unordered window. It cannot become key or move the user's pointer/focus.
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        guard abs(window.frame.width - CGFloat(variant.width)) < 1, abs(window.frame.height - CGFloat(variant.height)) < 1 else {
            throw Failure(description: "Capture window frame differs from requested output: \(window.frame)")
        }
        let captureView: NSView = variant.surface == .referenceConversation ? (host.superview ?? host) : host
        descendants(of: host).compactMap { $0 as? WorkspaceWindowStyle.ChromeView }.forEach { $0.configure() }
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
            let rect = web.convert(web.bounds, to: captureView)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = web.bounds
            configuration.afterScreenUpdates = false
            configuration.snapshotWidth = NSNumber(value: Double(web.bounds.width) * Double(variant.scale))
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
        guard let cached = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: variant.width * variant.scale, pixelsHigh: variant.height * variant.scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw Failure(description: "Native bitmap is unavailable") }
        cached.size = captureView.bounds.size
        captureView.cacheDisplay(in: captureView.bounds, to: cached)
        let native = NSImage(size: captureView.bounds.size)
        native.addRepresentation(cached)
        // WebKit remote-layer caching varies by OS version. Its cacheDisplay region may be blank or painted.
        // Replace that entire region with the opaque production background before compositing the actual
        // WK snapshot, so translucent bubbles and antialiased glyphs cannot be painted twice.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: variant.width * variant.scale, pixelsHigh: variant.height * variant.scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure(description: "Output bitmap is unavailable") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: CGFloat(variant.scale), y: CGFloat(variant.scale))
        native.draw(in: NSRect(x: 0, y: 0, width: variant.width, height: variant.height))
        for (image, rect) in webSnapshots {
            let destination = captureView.isFlipped ? NSRect(x: rect.minX, y: CGFloat(variant.height) - rect.maxY, width: rect.width, height: rect.height) : rect
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
                "height": variant.height, "scale": variant.scale, "pixelWidth": variant.width * variant.scale, "pixelHeight": variant.height * variant.scale, "appearance": variant.dark ? "dark" : "light", "web": webDiagnostics,
                "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow,
                "nativeChromeCaptured": variant.surface == .referenceConversation, "route": navigation.route.rawValue, "libraryAssets": content.assets.count,
                "subagents": WorkspaceConversationArtifacts.derive(items: store.selectedController?.items ?? [], cwd: WorkspaceFixtures.project).subagents.count,
                "nativeSubviews": descendants(of: host).count]
    }

    /// Tests the real AppKit titlebar and buttons without ordering or focusing a window.
    @MainActor static func verifyNativeChrome(output: URL) async throws -> [String: Any] {
        let (store, accounts, navigation, content) = WorkspaceFixtures.make(.empty, assets: [])
        let host = NSHostingView(rootView: WorkspaceView().environment(store).environment(accounts)
            .environment(navigation).environment(content).environment(WorkspaceToolsStore())
            .background(WorkspaceWindowStyle()).frame(width: 1566, height: 895).ignoresSafeArea(.container, edges: .top))
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let window = NSWindow(contentRect: NSWindow.contentRect(forFrameRect: NSRect(x: 0, y: 0, width: 1566, height: 895), styleMask: style),
            styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.sizingOptions = []
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 1566, height: 895)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        guard abs(window.frame.height - 895) < 1 else { throw Failure(description: "Native chrome frame height drift: \(window.frame)") }
        guard let frame = window.contentView?.superview else { throw Failure(description: "Missing native window frame") }
        let chromeViews = descendants(of: host).compactMap { $0 as? WorkspaceWindowStyle.ChromeView }
        chromeViews.forEach { $0.configure() }
        var controls: [[String: Any]] = []
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(kind), let parent = button.superview else { throw Failure(description: "Missing native control") }
            let rect = button.convert(button.bounds, to: frame)
            let top = frame.bounds.maxY - rect.midY
            controls.append(["kind": String(describing: kind), "centerX": rect.midX, "centerYFromTop": top,
                "width": rect.width, "height": rect.height, "hidden": button.isHidden,
                "withinParent": parent.bounds.contains(button.frame), "parentFrame": NSStringFromRect(parent.frame)])
            guard !button.isHidden, parent.bounds.contains(button.frame), abs(rect.midX - (23.25 + Double(index) * 23)) < 1,
                  abs(top - 23.75) < 1 else { throw Failure(description: "Native titlebar control drift: \(controls)") }
        }
        guard !window.isVisible && !window.isKeyWindow && !window.isMainWindow && NSApp.activationPolicy() == .prohibited else {
            throw Failure(description: "Native chrome host took visibility or focus")
        }
        // Metadata covers native chrome geometry; borderless visual frames remain separately identified.
        return ["controls": controls, "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow,
                "windowFrame": NSStringFromRect(window.frame), "contentFrame": NSStringFromRect(host.frame),
                "contentLayoutRect": NSStringFromRect(window.contentLayoutRect), "nativeButtons": true]
    }

    @MainActor static func makeToolProject(_ root: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) { return }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let readme = root.appendingPathComponent("README.md")
        try "# SAMPLE workspace\n\nOriginal project notes.\n".write(to: readme, atomically: true, encoding: .utf8)
        func git(_ arguments: [String]) throws {
            let result = try WorkspaceGitIO.run(arguments, root: root.path, process: WorkspaceProcess())
            guard result.exitCode == 0 else { throw Failure(description: "Synthetic Git setup: " + result.output) }
        }
        try git(["-c", "init.defaultBranch=preview", "init"])
        try git(["add", "README.md"])
        try git(["-c", "user.name=Sample", "-c", "user.email=sample@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "Synthetic UI fixture"])
        try "# SAMPLE workspace\n\nBuild, review, and continue the project here.\n\n- Native Claude Code / Codex conversations\n- File editing and Git review\n- Commands and output in the same window\n".write(to: readme, atomically: true, encoding: .utf8)
        try "SAMPLE=1\n".write(to: root.appendingPathComponent("example.env"), atomically: true, encoding: .utf8)
    }

    /// Exercise real route changes in an unordered host, without clicks or global input.
    @MainActor static func verifyDraftNavigation(assets: [WorkspaceAsset]) async throws -> [String: Any] {
        let (store, accounts, navigation, content) = WorkspaceFixtures.make(.empty, assets: assets)
        guard let controller = store.selectedController else { throw Failure(description: "Missing draft fixture") }
        let root = WorkspaceView().environment(store).environment(accounts).environment(navigation).environment(content).environment(WorkspaceToolsStore())
            .frame(width: 1200, height: 800)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        controller.composerDraft = "未发送的草稿 · offline fixture"
        let settings = controller.settings
        if let sample = assets.first { controller.attach(urls: [sample.url]) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let attachmentCount = controller.attachments.count
        guard attachmentCount == 1 else { throw Failure(description: "Synthetic draft attachment did not load") }
        navigation.visit(.library)
        try await Task.sleep(for: .milliseconds(200))
        navigation.back()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let editors = descendants(of: host).compactMap { $0 as? SubmitTextView }
        guard controller.composerDraft == "未发送的草稿 · offline fixture",
              editors.contains(where: { $0.string == controller.composerDraft }),
              controller.settings == settings, controller.attachments.count == attachmentCount,
              navigation.route == .home else {
            throw Failure(description: "Route round-trip lost draft text, attachments or engine/model")
        }
        guard !window.isVisible && !window.isKeyWindow && !window.isMainWindow else {
            throw Failure(description: "Offscreen interaction host became visible")
        }
        return ["draftRouteRoundTrip": true, "nativeEditorTextRestored": true,
                "attachmentsPreserved": true, "engineAndModelPreserved": true,
                "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow]
    }

    @MainActor static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
