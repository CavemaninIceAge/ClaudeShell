import Foundation
import Observation

enum WorkspaceToolTab: String, CaseIterable, Sendable {
    case files, git, command
    var title: String {
        switch self { case .files: return "文件"; case .git: return "Git 变更"; case .command: return "命令" }
    }
}

@MainActor @Observable final class WorkspaceToolSession {
    let root: String
    let files: WorkspaceFiles
    let git: WorkspaceGit
    let command: WorkspaceCommand
    init(root: String, environmentProvider: @escaping @Sendable () -> [String: String]) {
        self.root = root
        files = WorkspaceFiles(root: root); git = WorkspaceGit(root: root)
        command = WorkspaceCommand(root: root, environmentProvider: environmentProvider)
    }
    func deactivate() { files.cancelOperations(); git.cancel(); command.stop() }
    func shutdown() { files.cancelOperations(); git.shutdown(); command.shutdown() }
}

/// Keep one instance at the window root. Closing the panel is presentation-only; switching
/// directories cancels old work while retaining each directory's drafts and command output.
@MainActor @Observable final class WorkspaceToolsStore {
    private(set) var sessions: [String: WorkspaceToolSession] = [:]
    private(set) var activeRoot: String?
    @ObservationIgnored private let environmentProvider: @Sendable () -> [String: String]
    init(environmentProvider: @escaping @Sendable () -> [String: String] = { ShellEnvironment.environment() }) {
        self.environmentProvider = environmentProvider
    }
    @discardableResult func activate(cwd: String) -> WorkspaceToolSession {
        let root = WorkspaceFileIO.canonicalRoot(cwd)
        if activeRoot != root {
            if let activeRoot { sessions[activeRoot]?.deactivate() }
            activeRoot = root
        }
        if let existing = sessions[root] { return existing }
        let session = WorkspaceToolSession(root: root, environmentProvider: environmentProvider)
        sessions[root] = session
        return session
    }
    func shutdown() { sessions.values.forEach { $0.shutdown() } }
}
