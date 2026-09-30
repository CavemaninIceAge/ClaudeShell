import Foundation

@MainActor
enum CodexDesktopLifecycleRegression {
    struct Failure: Error, CustomStringConvertible { var description: String }
    enum SyntheticFailure: Error { case apply, launch }

    @MainActor private final class Fixture {
        let url = URL(fileURLWithPath: "/custom/ChatGPT.app")
        var running: [CodexDesktopLifecycle.Instance] = []
        var acceptsTermination = true
        var exitsAfterPause = true
        var launchFails = false
        var now: TimeInterval = 0
        var events: [String] = []
        var launches: [(URL, CodexDesktopLifecycle.LaunchOptions)] = []
        init(running: Bool = true) {
            if running { self.running = [.init(processIdentifier: 42, applicationURL: url)] }
        }
        var dependencies: CodexDesktopLifecycle.Dependencies {
            .init(runningApplications: { self.running }, registeredApplication: { self.url },
                  requestTermination: { _ in self.events.append("stop"); return self.acceptsTermination },
                  uptime: { self.now }, pause: {
                      self.events.append("wait"); self.now += 1
                      if self.exitsAfterPause { self.running = [] }
                  }, openApplication: { url, options in
                      self.events.append("launch"); self.launches.append((url, options))
                      if self.launchFails { throw SyntheticFailure.launch }
                  })
        }
        var target: CodexDesktopLifecycle.Target { CodexDesktopLifecycle.locate(dependencies: dependencies)! }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    static func run() async throws {
        let success = Fixture()
        let result = try await CodexDesktopLifecycle.perform(target: success.target,
            environment: ["CODEX_HOME": "/synthetic/selected-codex-home", "CODEX_ELECTRON_START_IN_BACKGROUND": "0"],
            dependencies: success.dependencies) {
            try expect(success.running.isEmpty, "Credentials changed before the desktop exited")
            success.events.append("apply")
        }
        try expect(success.events == ["stop", "wait", "apply", "launch"], "Desktop handoff ordering is unsafe")
        try expect(result.wasRunning && result.launched, "Restart result lost the prior running state")
        try expect(success.launches.first?.0 == success.url, "Restart did not preserve the custom installed application URL")
        try expect(success.launches.first?.1.activates == false, "Restart requested foreground activation")
        try expect(success.launches.first?.1.environment["CODEX_ELECTRON_START_IN_BACKGROUND"] == "1", "Electron background startup flag missing")
        try expect(success.launches.first?.1.environment["CODEX_HOME"] == "/synthetic/selected-codex-home", "Restart did not use the destination whose credentials were verified")

        for refusal in [true, false] {
            let fixture = Fixture()
            fixture.acceptsTermination = !refusal
            fixture.exitsAfterPause = false
            do {
                _ = try await CodexDesktopLifecycle.perform(target: fixture.target, dependencies: fixture.dependencies) {
                    fixture.events.append("apply")
                }
                throw Failure(description: "Desktop refusal/timeout was accepted")
            } catch let error as CodexDesktopLifecycle.Failure {
                try expect(error == (refusal ? .stopRefused : .stopTimedOut), "Unexpected stop failure")
            }
            try expect(!fixture.events.contains("apply") && fixture.launches.isEmpty, "Failed stop changed credentials or launched an app")
            try expect(fixture.now <= 20, "Graceful stop exceeded its deadline")
        }

        let rollback = Fixture()
        do {
            _ = try await CodexDesktopLifecycle.perform(target: rollback.target, dependencies: rollback.dependencies) {
                rollback.events.append("apply"); throw SyntheticFailure.apply
            }
            throw Failure(description: "Failed credential apply was reported as success")
        } catch SyntheticFailure.apply {}
        try expect(rollback.events == ["stop", "wait", "apply", "launch"], "Apply failure did not restore the stopped desktop")

        let closed = Fixture(running: false)
        do {
            _ = try await CodexDesktopLifecycle.perform(target: closed.target, dependencies: closed.dependencies) {
                closed.events.append("apply"); throw SyntheticFailure.apply
            }
            throw Failure(description: "Closed app apply failure was reported as success")
        } catch SyntheticFailure.apply {}
        try expect(closed.events == ["apply"], "Failed apply launched a previously closed desktop")
        _ = try await CodexDesktopLifecycle.perform(target: closed.target, dependencies: closed.dependencies) {
            closed.events.append("apply")
        }
        try expect(closed.events == ["apply", "apply", "launch"], "Successful push failed to launch the registered closed desktop")

        let ambiguous = Fixture()
        ambiguous.running.append(.init(processIdentifier: 43, applicationURL: URL(fileURLWithPath: "/legacy/Codex.app")))
        do {
            _ = try await CodexDesktopLifecycle.perform(target: ambiguous.target, dependencies: ambiguous.dependencies) {
                ambiguous.events.append("apply")
            }
            throw Failure(description: "Multiple desktop instances were restarted")
        } catch CodexDesktopLifecycle.Failure.ambiguousInstances {}
        try expect(ambiguous.events.isEmpty, "Ambiguous instances caused side effects")

        let changed = Fixture()
        let previous = changed.target
        changed.running = [.init(processIdentifier: 99, applicationURL: changed.url)]
        do {
            _ = try await CodexDesktopLifecycle.perform(target: previous, dependencies: changed.dependencies) {
                changed.events.append("apply")
            }
            throw Failure(description: "Unconfirmed desktop instance was restarted")
        } catch CodexDesktopLifecycle.Failure.applicationChanged {}
        try expect(changed.events.isEmpty, "Changed desktop instance caused side effects")

        let reopened = Fixture()
        var published = false
        do {
            _ = try await CodexDesktopLifecycle.perform(target: reopened.target, dependencies: reopened.dependencies) {
                reopened.events.append("apply")
                published = true
                reopened.running = [.init(processIdentifier: 100, applicationURL: reopened.url)]
            }
            throw Failure(description: "Desktop reopened during apply was reported as freshly restarted")
        } catch CodexDesktopLifecycle.Failure.changedAfterPublish {}
        try expect(published && reopened.events == ["stop", "wait", "apply"] && reopened.launches.isEmpty,
                   "Reopened desktop must report already-published credentials without reusing the running instance")

        let recoveryFailure = Fixture()
        recoveryFailure.launchFails = true
        do {
            _ = try await CodexDesktopLifecycle.perform(target: recoveryFailure.target, dependencies: recoveryFailure.dependencies) {
                throw SyntheticFailure.apply
            }
            throw Failure(description: "Recovery launch failure was reported as success")
        } catch CodexDesktopLifecycle.Failure.recoveryLaunchFailed {}
        print("PASS — mock desktop graceful stop, bounded refusal/timeout, transactional ordering and background-only restart")
    }
}
