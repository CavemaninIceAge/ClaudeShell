import AppKit
import Foundation

/// The desktop keeps authentication in memory. Its confirmed account handoff must close it
/// gracefully before changing credentials, then start the same installed bundle in the background.
@MainActor
enum CodexDesktopLifecycle {
    static let bundleIdentifier = "com.openai.codex"

    struct Instance: Equatable {
        var processIdentifier: pid_t
        var applicationURL: URL
    }

    struct Target: Equatable {
        var applicationURL: URL
        var runningProcessIdentifiers: [pid_t]
        var isRunning: Bool { !runningProcessIdentifiers.isEmpty }
    }

    struct LaunchOptions: Equatable {
        var activates = false
        // Electron's own startup also needs to suppress showing/focusing its main window.
        var environment = ["CODEX_ELECTRON_START_IN_BACKGROUND": "1"]
    }

    struct Result: Equatable {
        var wasRunning: Bool
        var launched: Bool
    }

    struct Dependencies {
        var runningApplications: @MainActor () -> [Instance]
        var registeredApplication: @MainActor () -> URL?
        var requestTermination: @MainActor (Instance) -> Bool
        var uptime: @MainActor () -> TimeInterval
        var pause: @MainActor () async throws -> Void
        var openApplication: @MainActor (URL, LaunchOptions) async throws -> Void

        static var live: Dependencies {
            Dependencies(runningApplications: {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map {
                    Instance(processIdentifier: $0.processIdentifier,
                             applicationURL: $0.bundleURL ?? URL(fileURLWithPath: "/"))
                }
            }, registeredApplication: {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
                      Bundle(url: url)?.bundleIdentifier == bundleIdentifier else { return nil }
                return url
            }, requestTermination: { instance in
                guard let app = NSRunningApplication(processIdentifier: instance.processIdentifier),
                      app.bundleIdentifier == bundleIdentifier,
                      app.bundleURL?.standardizedFileURL == instance.applicationURL.standardizedFileURL else { return false }
                return app.terminate()
            }, uptime: { ProcessInfo.processInfo.systemUptime }, pause: {
                try await Task.sleep(for: .milliseconds(100))
            }, openApplication: { url, options in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = options.activates
                configuration.environment = options.environment
                let application = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSRunningApplication, Error>) in
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let application { continuation.resume(returning: application) }
                        else { continuation.resume(throwing: Failure.launchUnverified) }
                    }
                }
                guard !application.isTerminated, application.bundleIdentifier == bundleIdentifier,
                      application.bundleURL?.standardizedFileURL == url.standardizedFileURL else {
                    throw Failure.launchUnverified
                }
                // A successful Launch Services callback alone does not mean the process survived startup.
                try await Task.sleep(for: .seconds(1))
                guard !application.isTerminated, application.bundleIdentifier == bundleIdentifier,
                      application.bundleURL?.standardizedFileURL == url.standardizedFileURL else {
                    throw Failure.launchUnverified
                }
            })
        }
    }

    enum Failure: LocalizedError, Equatable {
        case ambiguousInstances, applicationChanged, stopRefused, stopTimedOut, applicationRelaunched, recoveryLaunchFailed
        case launchUnverified, changedAfterPublish
        var errorDescription: String? {
            switch self {
            case .ambiguousInstances: "检测到多个 Codex App 实例。请先保留一个实例，再重新推送；登录态尚未修改。"
            case .applicationChanged: "Codex App 的运行实例已变化。请重新确认推送；登录态尚未修改。"
            case .stopRefused: "Codex App 未接受退出请求。请在其中完成或停止当前任务后重试；登录态尚未修改。"
            case .stopTimedOut: "等待 Codex App 正常退出超时。未强制结束进程，也未修改登录态。"
            case .applicationRelaunched: "Codex App 在推送前重新启动了。请重新推送；登录态尚未修改。"
            case .recoveryLaunchFailed: "推送未完成，且未能重新启动 Codex App。请手动打开应用并重试。"
            case .launchUnverified: "无法确认 Codex App 已正常启动。请手动打开应用并检查账号。"
            case .changedAfterPublish: "登录态已写入，但 Codex App 在写入期间被重新打开，无法确认它已加载新账号。请重新推送并重启。"
            }
        }
    }

    static func locate(dependencies: Dependencies? = nil) -> Target? {
        let operations = dependencies ?? .live
        let running = operations.runningApplications().sorted { $0.processIdentifier < $1.processIdentifier }
        guard let url = running.first?.applicationURL ?? operations.registeredApplication() else { return nil }
        return Target(applicationURL: url, runningProcessIdentifiers: running.map(\.processIdentifier))
    }

    /// No force-termination fallback: a refusal, changed instance or timeout leaves credentials alone.
    @discardableResult
    static func stop(target: Target, dependencies: Dependencies? = nil) async throws -> Bool {
        let operations = dependencies ?? .live
        let running = operations.runningApplications()
        guard running.count <= 1 && target.runningProcessIdentifiers.count <= 1 else { throw Failure.ambiguousInstances }
        guard let instance = running.first else { return false }
        guard target.runningProcessIdentifiers == [instance.processIdentifier],
              target.applicationURL.standardizedFileURL == instance.applicationURL.standardizedFileURL else {
            throw Failure.applicationChanged
        }
        guard operations.requestTermination(instance) else { throw Failure.stopRefused }
        let deadline = operations.uptime() + 20
        while true {
            let remaining = operations.runningApplications()
            if remaining.isEmpty { return true }
            guard remaining == [instance] else { throw Failure.applicationChanged }
            guard operations.uptime() < deadline else { throw Failure.stopTimedOut }
            try await operations.pause()
        }
    }

    static func launch(target: Target, environment: [String: String] = [:], dependencies: Dependencies? = nil) async throws {
        let operations = dependencies ?? .live
        let backgroundEnvironment = environment.merging(["CODEX_ELECTRON_START_IN_BACKGROUND": "1"]) { _, required in required }
        try await operations.openApplication(target.applicationURL, LaunchOptions(environment: backgroundEnvironment))
    }

    /// The caller obtains explicit restart confirmation before invoking this operation.
    /// `apply` owns credential validation, backup and rollback; no credentials are handled here.
    static func perform(target: Target, environment: [String: String] = [:], dependencies: Dependencies? = nil,
                        apply: @MainActor () async throws -> Void) async throws -> Result {
        let operations = dependencies ?? .live
        let stopped = try await stop(target: target, dependencies: operations)
        guard operations.runningApplications().isEmpty else { throw Failure.applicationRelaunched }
        do {
            try Task.checkCancellation()
            try await apply()
        } catch {
            if stopped {
                do { try await launch(target: target, environment: environment, dependencies: operations) }
                catch { throw Failure.recoveryLaunchFailed }
            }
            throw error
        }
        guard operations.runningApplications().isEmpty else { throw Failure.changedAfterPublish }
        try await launch(target: target, environment: environment, dependencies: operations)
        return Result(wasRunning: stopped, launched: true)
    }
}
