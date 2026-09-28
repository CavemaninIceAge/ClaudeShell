import Foundation
import Observation

struct WorkspaceGitEntry: Identifiable, Sendable, Equatable {
    let path: String
    let status: String
    let originalPath: String?
    var id: String { path }
    var isUntracked: Bool { status == "??" }
}

enum WorkspaceGitIO {
    static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_PAGER": "cat", "GIT_ATTR_NOSYSTEM": "1"]
    static func run(_ arguments: [String], root: String, process: WorkspaceProcess) throws -> WorkspaceProcessResult {
        try process.run(executable: "/usr/bin/git",
                        arguments: ["--no-pager", "--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + arguments,
                        cwd: root, environment: environment)
    }
    static func parse(_ output: String, prefix: String) -> [WorkspaceGitEntry] {
        let parts = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [WorkspaceGitEntry] = [], index = 0
        while index < parts.count {
            let record = parts[index]; index += 1
            guard record.count >= 4 else { continue }
            let status = String(record.prefix(2)), fullPath = String(record.dropFirst(3))
            var original: String?
            if status.contains("R") || status.contains("C") {
                if index < parts.count { original = parts[index]; index += 1 }
            }
            guard fullPath.hasPrefix(prefix) else { continue }
            let path = String(fullPath.dropFirst(prefix.count))
            guard !path.isEmpty, (try? WorkspaceFileIO.components(path)) != nil else { continue }
            entries.append(.init(path: path, status: status,
                                 originalPath: original.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }))
        }
        return entries
    }
    static func untrackedDiff(root: String, entry: WorkspaceGitEntry) throws -> String {
        let snapshot = try WorkspaceFileIO.load(root: root, path: entry.path)
        let lines = snapshot.text.split(separator: "\n", omittingEmptySubsequences: false)
        return "未跟踪文件 · \(entry.path)\n--- /dev/null\n+++ \(entry.path)\n" + lines.map { "+" + $0 }.joined(separator: "\n")
    }
}

@MainActor @Observable final class WorkspaceGit {
    let root: String
    private(set) var entries: [WorkspaceGitEntry] = []
    private(set) var isLoading = false
    private(set) var isLoadingDiff = false
    private(set) var diff = ""
    private(set) var diffTruncated = false
    private(set) var refreshed = false
    var selectedPath: String?
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    @ObservationIgnored private var processes: [WorkspaceProcess] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var diffGeneration = 0
    init(root: String) { self.root = root }
    func cancel() {
        generation += 1; diffGeneration += 1
        task?.cancel(); diffTask?.cancel(); processes.forEach { $0.cancel() }; processes.removeAll()
        task = nil; diffTask = nil; isLoading = false; isLoadingDiff = false
    }
    func shutdown() { processes.forEach { $0.shutdown() }; cancel() }
    func refresh() {
        cancel(); error = nil; isLoading = true; selectedPath = nil; diff = ""; diffTruncated = false
        let token = generation, root = root
        let prefixProcess = WorkspaceProcess(), statusProcess = WorkspaceProcess()
        processes = [prefixProcess, statusProcess]
        task = Task { [weak self] in
            defer { self?.processes.removeAll { $0 === prefixProcess || $0 === statusProcess } }
            do {
                let result = try await WorkspaceBackground.run {
                    let prefix = try WorkspaceGitIO.run(["rev-parse", "--show-prefix"], root: root, process: prefixProcess)
                    guard prefix.exitCode == 0 else { throw WorkspaceFileError.system("当前目录不属于 Git 仓库。\n" + prefix.output) }
                    try Task.checkCancellation()
                    let status = try WorkspaceGitIO.run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], root: root, process: statusProcess)
                    guard status.exitCode == 0 else { throw WorkspaceFileError.system(status.output) }
                    guard !status.truncated else { throw WorkspaceFileError.system("Git 状态超过 1 MiB，请缩小工作目录。") }
                    return WorkspaceGitIO.parse(status.output, prefix: prefix.output.hasSuffix("\n") ? String(prefix.output.dropLast()) : prefix.output)
                }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.entries = result; self.refreshed = true
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.entries = []; self.refreshed = true
            }
            self?.isLoading = false; self?.task = nil
        }
    }
    func select(_ entry: WorkspaceGitEntry) {
        diffGeneration += 1; diffTask?.cancel()
        // Refresh is separate; changing selected diff cancels only its own two processes.
        let token = diffGeneration, root = root
        selectedPath = entry.path; diff = ""; diffTruncated = false; error = nil; isLoadingDiff = true
        let unstaged = WorkspaceProcess(), staged = WorkspaceProcess()
        processes += [unstaged, staged]
        diffTask = Task { [weak self] in
            defer { self?.processes.removeAll { $0 === unstaged || $0 === staged } }
            do {
                let result: (String, Bool) = try await withTaskCancellationHandler(operation: {
                    try await WorkspaceBackground.run {
                        if entry.isUntracked { return (try WorkspaceGitIO.untrackedDiff(root: root, entry: entry), false) }
                        let options = ["--no-color", "--no-ext-diff", "--no-textconv", "--relative"]
                        let paths = [entry.path] + (entry.originalPath.map { [$0] } ?? [])
                        let working = try WorkspaceGitIO.run(["diff"] + options + ["--"] + paths, root: root, process: unstaged)
                        guard working.exitCode == 0 else { throw WorkspaceFileError.system(working.output) }
                        try Task.checkCancellation()
                        let index = try WorkspaceGitIO.run(["diff", "--cached"] + options + ["--"] + paths, root: root, process: staged)
                        guard index.exitCode == 0 else { throw WorkspaceFileError.system(index.output) }
                        var sections: [String] = []
                        if !working.output.isEmpty { sections.append("未暂存\n" + working.output) }
                        if !index.output.isEmpty { sections.append("已暂存\n" + index.output) }
                        return (sections.isEmpty ? "没有可显示的文本差异（可能是文件模式或子模块变更）。" : sections.joined(separator: "\n\n"), working.truncated || index.truncated)
                    }
                }, onCancel: { unstaged.cancel(); staged.cancel() })
                guard let self, self.diffGeneration == token, !Task.isCancelled else { return }
                self.diff = result.0; self.diffTruncated = result.1
            } catch {
                guard let self, self.diffGeneration == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            self?.isLoadingDiff = false; self?.diffTask = nil
        }
    }
}
