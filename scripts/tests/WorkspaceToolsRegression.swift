import Darwin
import Foundation

enum WorkspaceToolsRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    private static func rejects(_ body: () throws -> Void, _ message: String) throws {
        do { try body() } catch { return }
        throw Failure(description: message)
    }
    @MainActor private static func wait(_ condition: () -> Bool, _ message: String, seconds: Double = 8) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        try expect(condition(), message)
    }
    @MainActor static func run() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("claudex-workspace-" + UUID().uuidString)
        let root = container.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try fileSafety(root: root, container: container)
        try await commandSafety(root: root)
        try await gitSafety(root: root)
        try await stateIsolation(root: root, other: container.appendingPathComponent("other"))
        print("PASS — workspace file conflicts/links/limits, git helpers, process cancellation, directory isolation")
    }
    private static func fileSafety(root: URL, container: URL) throws {
        let fm = FileManager.default
        let file = root.appendingPathComponent("README.md")
        try Data("# fixture\n".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let snapshot = try WorkspaceFileIO.load(root: root.path, path: "README.md")
        let saved = try WorkspaceFileIO.save(root: root.path, path: "README.md", text: "# updated\n", original: snapshot)
        try expect(saved.text == "# updated\n", "Text save failed")
        let savedPermissions = try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        try expect(savedPermissions == 0o755, "Save lost executable mode")
        try Data("external\n".utf8).write(to: file)
        try rejects({ _ = try WorkspaceFileIO.save(root: root.path, path: "README.md", text: "overwrite", original: saved) }, "External change overwritten")
        let externalContents = try Data(contentsOf: file)
        try expect(String(data: externalContents, encoding: .utf8) == "external\n", "Conflict changed external contents")
        let again = try WorkspaceFileIO.load(root: root.path, path: "README.md")
        try Data("external\n".utf8).write(to: file, options: .atomic)
        try rejects({ _ = try WorkspaceFileIO.save(root: root.path, path: "README.md", text: "overwrite", original: again) }, "Same-content inode replacement not detected")
        let outside = container.appendingPathComponent("outside.txt")
        try Data("outside sentinel".utf8).write(to: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: container)
        try rejects({ _ = try WorkspaceFileIO.load(root: root.path, path: "link.txt") }, "Followed file symlink")
        try rejects({ _ = try WorkspaceFileIO.load(root: root.path, path: "outside/outside.txt") }, "Followed directory symlink")
        try rejects({ _ = try WorkspaceFileIO.load(root: root.path, path: "../outside.txt") }, "Accepted parent traversal")
        try rejects({ _ = try WorkspaceFileIO.load(root: root.path, path: outside.path) }, "Accepted absolute path")
        let beforeLink = try WorkspaceFileIO.load(root: root.path, path: "README.md")
        try fm.removeItem(at: file); try fm.createSymbolicLink(at: file, withDestinationURL: outside)
        try rejects({ _ = try WorkspaceFileIO.save(root: root.path, path: "README.md", text: "escape", original: beforeLink) }, "Saved through replaced link")
        let outsideContents = try Data(contentsOf: outside)
        try expect(String(data: outsideContents, encoding: .utf8) == "outside sentinel", "Escaped workspace write")
        try fm.removeItem(at: file); try Data("# restored fixture\n".utf8).write(to: file)
        try Data([0x61, 0, 0x62]).write(to: root.appendingPathComponent("binary.bin"))
        try Data([0xff, 0xfe]).write(to: root.appendingPathComponent("invalid.txt"))
        try Data(repeating: 0x61, count: WorkspaceFileIO.maximumBytes + 1).write(to: root.appendingPathComponent("large.txt"))
        for path in ["binary.bin", "invalid.txt", "large.txt"] {
            try rejects({ _ = try WorkspaceFileIO.load(root: root.path, path: path) }, "Accepted unsupported file \(path)")
        }
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
        let nodes = try WorkspaceFileIO.list(root: root.path, path: "", showHidden: false)
        try expect(!nodes.contains { $0.name == ".hidden" }, "Hidden filtering failed")
        try expect(nodes.first { $0.name == "link.txt" }?.kind == .symbolicLink, "Link type lost")
    }
    @MainActor private static func commandSafety(root: URL) async throws {
        let command = WorkspaceCommand(root: root.path, environmentProvider: { environment })
        defer { command.shutdown() }
        command.script = "printf '\\344\\270\\255\\346\\226\\207\\n'; printf 'stderr\\n' >&2; exit 7"
        command.start()
        try await wait({ !command.isRunning }, "Command failed to finish")
        try expect(command.phase == .finished(7), "Exit code lost")
        try expect(command.output.contains("中文") && command.output.contains("stderr"), "UTF8 or stderr lost")
        let runner = WorkspaceProcess()
        let long = try await WorkspaceBackground.run {
            try runner.run(executable: "/bin/sh", arguments: ["-c", "yes fixture | head -c 200000"], cwd: root.path, environment: environment, maximumBytes: 2048)
        }
        try expect(long.truncated && long.output.utf8.count == 2048, "Output limit failed")
        // Cancellation during environment preparation must recover from .stopping without launching.
        let entered = Signal(), release = DispatchSemaphore(value: 0)
        let preparing = WorkspaceCommand(root: root.path, environmentProvider: {
            entered.set(); release.wait(); return environment
        })
        defer { release.signal(); preparing.shutdown() }
        preparing.script = "printf SHOULD_NOT_RUN"
        preparing.start()
        try await wait({ entered.get() }, "Environment preparation did not start")
        preparing.stop(); release.signal()
        try await wait({ !preparing.isRunning }, "Cancelled preparation stuck in stopping")
        try expect(preparing.output.isEmpty && preparing.stopped, "Cancelled preparation launched a command")
        // TERM-resistant shell and child verify the timed process-group stop path.
        let resistant = WorkspaceCommand(root: root.path, environmentProvider: { environment })
        defer { resistant.shutdown() }
        resistant.script = "trap '' TERM; /bin/sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait"
        resistant.start()
        try await wait({ Int32(resistant.output.trimmingCharacters(in: .whitespacesAndNewlines)) != nil }, "Child PID not emitted")
        let child = Int32(resistant.output.trimmingCharacters(in: .whitespacesAndNewlines))!
        resistant.stop()
        try await wait({ !resistant.isRunning }, "Process tree did not stop")
        try await wait({ Darwin.kill(child, 0) != 0 }, "Child remained alive after stop")
        try expect(resistant.stopped, "Stop state lost")
        // Cancelling a completed runner must be a no-op, not signal a stale process group.
        runner.cancel(); runner.shutdown()
    }
    private static func git(_ args: [String], root: URL) throws -> WorkspaceProcessResult {
        let result = try WorkspaceProcess().run(executable: "/usr/bin/git", arguments: args, cwd: root.path, environment: environment)
        guard result.exitCode == 0 else { throw Failure(description: "Fixture git failed: " + result.output) }
        return result
    }
    @MainActor private static func gitSafety(root: URL) async throws {
        _ = try git(["init", "-q"], root: root)
        try Data("old\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("literal old\n".utf8).write(to: root.appendingPathComponent("[ab].txt"))
        try Data("unrelated old\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("*.txt diff=fixture\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        _ = try git(["--literal-pathspecs", "add", "--", "tracked.txt", "[ab].txt", "a.txt", ".gitattributes"], root: root)
        _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], root: root)
        let marker = root.appendingPathComponent("HELPER_EXECUTED"), helper = root.appendingPathComponent("git-helper")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        for key in ["diff.external", "diff.fixture.textconv", "core.fsmonitor"] { _ = try git(["config", key, helper.path], root: root) }
        try Data("new\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("literal new\n".utf8).write(to: root.appendingPathComponent("[ab].txt"))
        try Data("unrelated new\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("new file\n".utf8).write(to: root.appendingPathComponent("new 文件.md"))
        let model = WorkspaceGit(root: root.path)
        model.refresh(); try await wait({ !model.isLoading }, "Git status timeout")
        try expect(model.error == nil, "Git status failed: \(model.error ?? "")")
        guard let tracked = model.entries.first(where: { $0.path == "tracked.txt" }), let untracked = model.entries.first(where: { $0.path == "new 文件.md" }) else { throw Failure(description: "Tracked/untracked entries missing") }
        model.select(tracked); try await wait({ !model.isLoadingDiff }, "Git diff timeout")
        try expect(model.diff.contains("-old") && model.diff.contains("+new"), "Tracked diff incorrect")
        model.select(untracked); try await wait({ !model.isLoadingDiff }, "Untracked diff timeout")
        try expect(model.diff.contains("+new file"), "Untracked content absent")
        guard let literal = model.entries.first(where: { $0.path == "[ab].txt" }) else { throw Failure(description: "Literal filename missing") }
        model.select(literal); try await wait({ !model.isLoadingDiff }, "Literal path diff timeout")
        try expect(model.diff.contains("+literal new") && !model.diff.contains("unrelated new"), "Git interpreted filename as wildcard pathspec")
        try expect(!FileManager.default.fileExists(atPath: marker.path), "Read-only Git invoked project helper")
        let parsed = WorkspaceGitIO.parse("R  sub/new name\0sub/old name\0?? sub/new.md\0 M other/outside\0", prefix: "sub/")
        try expect(parsed.count == 2 && parsed.first?.originalPath == "old name", "Rename or subdirectory prefix parser wrong")
        model.shutdown()
    }
    @MainActor private static func stateIsolation(root: URL, other: URL) async throws {
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: other.appendingPathComponent("README.md"))
        let tools = WorkspaceToolsStore(environmentProvider: { environment })
        defer { tools.shutdown() }
        let first = tools.activate(cwd: root.path)
        first.files.open("README.md")
        try await wait({ first.files.selectedDocument != nil }, "File did not open")
        first.files.selectedDocument?.text = "unsaved draft"
        first.command.script = "sleep 30"
        first.command.start(); try await wait({ first.command.phase == .running }, "Command did not start")
        let second = tools.activate(cwd: other.path)
        try await wait({ !first.command.isRunning }, "Directory change did not stop previous command")
        second.files.open("README.md"); try await wait({ second.files.selectedDocument != nil }, "Second file did not open")
        try expect(second.files.selectedDocument?.text == "other", "File buffers crossed directories")
        let restored = tools.activate(cwd: root.path)
        try expect(restored === first && restored.files.selectedDocument?.text == "unsaved draft", "Directory draft was lost")
        restored.command.script = "sleep 30"; restored.command.start()
        try await wait({ restored.command.phase == .running }, "Shutdown fixture did not start")
        tools.shutdown(); try await wait({ !restored.command.isRunning }, "Shutdown left a command running")
    }
}
