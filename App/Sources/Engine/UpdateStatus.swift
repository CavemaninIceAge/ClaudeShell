import Foundation

/// Claude Code 每次尝试自更新后把结果写到 `~/.claude/.last-update-result.json`；失败时终端会在底部挂一条
/// 「✗ Auto-update failed · Run claude doctor」。这里读同一个文件，把失败态搬到 app 里。
enum UpdateStatus {
    struct Result: Sendable, Equatable {
        var failed: Bool
        var versionFrom: String?
        var status: String?     // 如 install_failed
    }

    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/.last-update-result.json")

    static func read() -> Result {
        guard let data = try? Data(contentsOf: url), let v = JSONValue.parse(data) else {
            return Result(failed: false)
        }
        let failed = v["outcome"]?.string == "failed"
        return Result(failed: failed, versionFrom: v["version_from"]?.string, status: v["status"]?.string)
    }
}
