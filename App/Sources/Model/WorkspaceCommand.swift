import Darwin
import Foundation
import Observation

struct WorkspaceProcessResult: Sendable {
    let output: String
    let exitCode: Int32
    let truncated: Bool
    let cancelled: Bool
}

/// A bounded, pipe-based Process. It has no PTY and its stdin is closed.
/// Foundation creates a new process group on macOS; we verify that invariant before
/// signalling a group, and never send a signal to the app's own process group.
final class WorkspaceProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var group: Int32?
    private var cancelled = false
    private var finished = false
    private var killScheduled = false

    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        cancelled = true
        let process = process, group = group
        let shouldSchedule = !killScheduled && !finished && process != nil
        if shouldSchedule { killScheduled = true }
        lock.unlock()
        if let group, group != getpgrp() { _ = Darwin.kill(-group, SIGTERM) }
        else if let process, process.isRunning { process.terminate() }
        if shouldSchedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in self?.forceStop() }
        }
    }
    private func forceStop() {
        lock.lock(); defer { lock.unlock() }
        guard cancelled, !finished else { return }
        if let group, group != getpgrp() { _ = Darwin.kill(-group, SIGKILL) }
        else if let process, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }
    /// App termination cannot wait for the graceful deadline.
    func shutdown() { cancel(); forceStop() }

    func run(executable: String, arguments: [String], cwd: String, environment: [String: String],
             maximumBytes: Int = 1_048_576,
             onOutput: (@Sendable (String, Bool) -> Void)? = nil) throws -> WorkspaceProcessResult {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        self.process = process
        do { try process.run() } catch { self.process = nil; finished = true; lock.unlock(); throw error }
        let pid = process.processIdentifier
        if getpgid(pid) == pid, pid != getpgrp() { group = pid }
        lock.unlock()
        // Parent must not retain a writer: EOF should reflect only the launched command tree.
        try? output.fileHandleForWriting.close()
        var bytes = Data(), truncated = false
        var lastEmission = Date.distantPast
        var readingError: Error?
        do {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                // FileHandle.read(upToCount:) can wait to fill its requested count. POSIX read
                // returns currently available pipe bytes so a quiet long-running job streams too.
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw WorkspaceFileError.system(String(cString: strerror(errno)))
                }
                let chunk = Data(buffer.prefix(count))
                let available = max(0, maximumBytes - bytes.count)
                if chunk.count > available { truncated = true }
                if available > 0 { bytes.append(chunk.prefix(available)) }
                if Date().timeIntervalSince(lastEmission) >= 0.08 {
                    onOutput?(String(decoding: bytes, as: UTF8.self), truncated)
                    lastEmission = Date()
                }
            }
        } catch { readingError = error; cancel() }
        try? output.fileHandleForReading.close()
        process.waitUntilExit()
        lock.lock()
        // A pipe runner does not own persistent background jobs. Reap the remaining
        // process group when its shell exits, including children that redirected output.
        if let group, group != getpgrp() { _ = Darwin.kill(-group, SIGKILL) }
        let wasCancelled = cancelled
        finished = true; self.process = nil; group = nil
        lock.unlock()
        let text = String(decoding: bytes, as: UTF8.self)
        onOutput?(text, truncated)
        if let readingError, !wasCancelled { throw readingError }
        return .init(output: text, exitCode: process.terminationStatus, truncated: truncated, cancelled: wasCancelled)
    }
}

@MainActor @Observable final class WorkspaceCommand {
    enum Phase: Equatable { case idle, preparing, running, stopping, finished(Int32), failed(String) }
    let root: String
    var script = ""
    private(set) var output = ""
    private(set) var lastScript = ""
    private(set) var phase: Phase = .idle
    private(set) var truncated = false
    private(set) var stopped = false
    var isRunning: Bool { phase == .preparing || phase == .running || phase == .stopping }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var process: WorkspaceProcess?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let environmentProvider: @Sendable () -> [String: String]

    init(root: String, environmentProvider: @escaping @Sendable () -> [String: String] = { ShellEnvironment.environment() }) {
        self.root = root; self.environmentProvider = environmentProvider
    }
    /// Called only by explicit user submission, never by loading or activating a workspace.
    func start() {
        guard !isRunning, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        generation += 1
        let token = generation, root = root, command = script, environmentProvider = environmentProvider
        let runner = WorkspaceProcess()
        process = runner; output = ""; truncated = false; stopped = false; lastScript = command; phase = .preparing
        task = Task { [weak self] in
            do {
                var env = try await WorkspaceBackground.run { environmentProvider() }
                guard let self, self.generation == token else { return }
                try Task.checkCancellation()
                env["TERM"] = "dumb"; env["NO_COLOR"] = "1"
                self.phase = .running
                let environment = env
                let result = try await withTaskCancellationHandler(operation: {
                    try await WorkspaceBackground.run {
                        try runner.run(executable: "/bin/zsh", arguments: ["-f", "-c", command], cwd: root, environment: environment) { [weak self] text, truncated in
                            Task { @MainActor [weak self] in
                                guard let self, self.generation == token, self.isRunning else { return }
                                self.output = text; self.truncated = truncated
                            }
                        }
                    }
                }, onCancel: { runner.cancel() })
                guard self.generation == token else { return }
                self.output = result.output; self.truncated = result.truncated; self.stopped = result.cancelled
                self.phase = .finished(result.exitCode); self.process = nil; self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.stopped = error is CancellationError
                self.phase = error is CancellationError ? .idle : .failed(error.localizedDescription)
                self.process = nil; self.task = nil
            }
        }
    }
    func stop() {
        guard isRunning else { return }
        stopped = true; phase = .stopping
        process?.cancel(); task?.cancel()
    }
    func shutdown() { process?.shutdown(); task?.cancel() }
    func clear() { if !isRunning { output = ""; truncated = false; phase = .idle } }
}
