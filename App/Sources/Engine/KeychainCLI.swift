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

    /// 条目不存在或钥匙串锁着都返回 nil；调用方自己决定怎么提示。
    static func read(service: String) -> String? {
        let r = run("find-generic-password -s \(quote(service)) -a \(quote(accountName)) -w")
        guard r.status == 0 else { return nil }
        var s = r.stdout
        if s.hasSuffix("\n") { s.removeLast() }
        return s.isEmpty ? nil : s
    }

    /// `-U` 让已有条目原地更新（保留访问控制），没有就新建。
    static func write(service: String, secret: String) throws {
        guard !secret.contains("\n"), !secret.contains("\r") else {
            throw Failure(message: "令牌里有换行，无法经 security 写入")
        }
        let r = run("add-generic-password -U -s \(quote(service)) -a \(quote(accountName)) -w \(quote(secret))")
        guard r.status == 0 else {
            throw Failure(message: "写入钥匙串失败（\(service)）：\(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func delete(service: String) {
        _ = run("delete-generic-password -s \(quote(service)) -a \(quote(accountName))")
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

    private static func run(_ command: String) -> (status: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["-i"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        stdin.fileHandleForWriting.write(Data((command + "\n").utf8))
        try? stdin.fileHandleForWriting.close()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }
}
