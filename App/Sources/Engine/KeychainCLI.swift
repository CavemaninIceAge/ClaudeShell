import Foundation

/// 通过 `/usr/bin/security -i` 读写登录钥匙串里的通用密码条目。
///
/// Claude Code 自己就是用 `security` 命令存令牌的，这里走同一个工具有两个好处：条目的访问控制列表里已经有
/// `security`，app 读它不会弹「Claude Shell 想访问钥匙串里的…」；交互模式（`-i`）把命令从 stdin 喂进去，
/// 令牌不出现在进程参数里，`ps` 看不到。账户名照 Claude Code 的规则用 `$USER`。
enum KeychainCLI {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Claude Code 的账户名规则：`$USER`，缺了或含奇怪字符就用 `claude-code-user`。
    static var accountName: String {
        let name = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let legal = name.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil
        return legal && !name.isEmpty ? name : "claude-code-user"
    }

    /// Convenience for optional discovery. Shared-state mutations use readChecked instead.
    static func read(service: String) -> String? {
        try? readChecked(service: service)
    }

    /// Only a missing item is nil. A locked/unreadable vault must never be backed up as an empty login.
    static func readChecked(service: String) throws -> String? {
        try validate(service)
        let r = run(arguments: ["find-generic-password", "-s", service, "-a", accountName, "-w"])
        if r.status == 44 { return nil } // errSecItemNotFound (-25300), shell exit code
        guard r.status == 0 else {
            throw Failure(message: "读取钥匙串失败（状态 \(r.status)）。请确认登录钥匙串已解锁，原登录态未被覆盖。")
        }
        var s = r.stdout
        if s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    /// `-U` 让已有条目原地更新（保留访问控制），没有就新建。
    static func write(service: String, secret: String) throws {
        try validate(service)
        try validate(secret)
        let r = run(arguments: ["-i"], command: "add-generic-password -U -s \(quote(service)) -a \(quote(accountName)) -w \(quote(secret))")
        guard r.status == 0 else {
            // security may echo its command in stderr. Never surface a credential-bearing command.
            throw Failure(message: "写入钥匙串失败（状态 \(r.status)）。请确认登录钥匙串已解锁。")
        }
    }

    static func delete(service: String) {
        try? deleteChecked(service: service)
    }

    static func deleteChecked(service: String) throws {
        try validate(service)
        let r = run(arguments: ["delete-generic-password", "-s", service, "-a", accountName])
        guard r.status == 0 || r.status == 44 else {
            throw Failure(message: "删除钥匙串条目失败（状态 \(r.status)）。")
        }
    }

    static func validate(_ value: String) throws {
        guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            throw Failure(message: "钥匙串数据含不支持的控制字符。")
        }
    }

    /// `security -i` 的行解析认双引号，引号内 `\\` 和 `\"` 是转义（2026-09-16 实测）。
    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var stdout = Data()
        var stderr = Data()
        func set(_ data: Data, output: Bool) {
            lock.lock(); defer { lock.unlock() }
            if output { stdout = data } else { stderr = data }
        }
    }

    private static func run(arguments: [String], command: String? = nil) -> (status: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let capture = Capture(), group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            capture.set(stdout.fileHandleForReading.readDataToEndOfFile(), output: true)
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            capture.set(stderr.fileHandleForReading.readDataToEndOfFile(), output: false)
            group.leave()
        }
        if let command { try? stdin.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8)) }
        try? stdin.fileHandleForWriting.close()
        proc.waitUntilExit()
        group.wait()
        return (proc.terminationStatus,
                String(data: capture.stdout, encoding: .utf8) ?? "",
                String(data: capture.stderr, encoding: .utf8) ?? "")
    }
}
