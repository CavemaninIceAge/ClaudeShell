import Foundation

/// 从 Dock 启动的 app 只有 `/usr/bin:/bin` 这种 PATH，而 Claude Code 及它调的工具（node、brew、python）
/// 都靠用户 shell 里的 PATH。启动时跑一次登录 shell 把 PATH 取出来，之后所有子进程都用它。
enum ShellEnvironment {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedPATH: String?
    nonisolated(unsafe) private static var cachedClaude: String?

    private static let fallbackPATH = [
        NSHomeDirectory() + "/.local/bin",
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ].joined(separator: ":")

    static func loginPATH() -> String {
        lock.lock(); defer { lock.unlock() }
        if let cachedPATH { return cachedPATH }
        var path = fallbackPATH
        // -i 是为了让 .zshrc 里的 PATH 也算进来；用哨兵行避开 rc 文件里可能 echo 出来的东西。
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-ilc", "printf '\\n__CS_PATH__=%s\\n' \"$PATH\""]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            let deadline = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: deadline)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            deadline.cancel()
            if let text = String(data: data, encoding: .utf8),
               let line = text.split(separator: "\n").last(where: { $0.hasPrefix("__CS_PATH__=") }) {
                let found = String(line.dropFirst("__CS_PATH__=".count))
                if !found.isEmpty {
                    // 把兜底目录补在后面，保证 ~/.local/bin 这种一定在。
                    let parts = found.split(separator: ":").map(String.init)
                    let extras = fallbackPATH.split(separator: ":").map(String.init).filter { !parts.contains($0) }
                    path = (parts + extras).joined(separator: ":")
                }
            }
        } catch {
            // 没有 zsh 也能跑，就用兜底 PATH。
        }
        cachedPATH = path
        return path
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPATH()
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["LANG"] = env["LANG"] ?? "zh_CN.UTF-8"
        return env
    }

    /// 找 `claude` 可执行文件；找不到返回 nil，由调用方提示用户。
    static func claudeExecutable() -> String? {
        lock.lock()
        if let cachedClaude { lock.unlock(); return cachedClaude }
        lock.unlock()
        let fm = FileManager.default
        for dir in loginPATH().split(separator: ":") {
            let candidate = String(dir) + "/claude"
            if fm.isExecutableFile(atPath: candidate) {
                lock.lock(); cachedClaude = candidate; lock.unlock()
                return candidate
            }
        }
        return nil
    }
}
