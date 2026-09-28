import Foundation

/// A native thread ID can exist before Codex writes its first rollout. Only that never-persisted
/// allocation may be replaced after a failed first send; an established history must never be recreated.
struct CodexResumeState: Sendable {
    private(set) var established: Bool
    init(existingHistory: Bool) { established = existingHistory }

    @discardableResult
    mutating func observePersistence(at path: String?) -> Bool {
        let exists = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
        if exists { established = true }
        return exists
    }

    mutating func recordCompletedTurn() { established = true }

    mutating func shouldStartFresh(at path: String?) -> Bool {
        guard let path, !established else { return false }
        return !observePersistence(at: path)
    }
}
