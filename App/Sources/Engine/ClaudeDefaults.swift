import Foundation

/// 终端里「默认」到底是什么模型、什么强度：不自己抄 settings.json 的解析逻辑，而是问 claude 本尊。
///
/// 强度：起一个 `claude -p`，stdin 直接关掉（不会走 API），用 `--settings` 挂一个 SessionStart 钩子把
/// `$CLAUDE_EFFORT` 打到 stderr；`--verbose` 下钩子结果会以 `system/hook_response` 事件回到 stdout。
/// 实测（2.1.270）这个值只反映 settings / 环境变量解析出的默认强度，不受 `--model`、`--effort` 影响，
/// 所以只在 app 启动和 settings.json 变化时探一次，全局共用。
/// 模型：钩子拿不到模型，从 `~/.claude/settings.json` 的 `model` 读；对话跑过一轮后以 `system/init` 的 model 为准。
enum ClaudeDefaults {
    struct Resolved: Sendable, Equatable {
        var model: String? = nil    // settings.json 里的写法，如 "opus[1m]"
        var effort: String? = nil   // 如 "xhigh"
        var settingsModified: Date? = nil
    }

    static let settingsURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")

    static func settingsModifiedDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: settingsURL.path))?[.modificationDate] as? Date
    }

    private static let probeSettingsJSON =
        #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo \"claude-shell effort=$CLAUDE_EFFORT\" >&2"}]}]}}"#

    /// 阻塞，放后台线程跑；找不到 claude 或探测失败就只带 settings.json 里的模型。
    static func probe() -> Resolved {
        var r = Resolved(model: settingsModel(), settingsModified: settingsModifiedDate())
        guard let exe = ShellEnvironment.claudeExecutable() else { return r }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                          "--settings", probeSettingsJSON]
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        proc.environment = ShellEnvironment.environment()
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            let deadline = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            deadline.cancel()
            guard let text = String(data: data, encoding: .utf8) else { return r }
            for line in text.split(separator: "\n") {
                guard let v = JSONValue.parse(String(line)), v["type"]?.string == "system",
                      v["subtype"]?.string == "hook_response" else { continue }
                let blob = (v["stderr"]?.string ?? "") + "\n" + (v["output"]?.string ?? "")
                if let effort = parseEffort(blob) { r.effort = effort; break }
            }
        } catch {
            // 探不到就让界面显示「默认强度」。
        }
        return r
    }

    static func parseEffort(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "claude-shell effort=") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func settingsModel() -> String? {
        guard let data = try? Data(contentsOf: settingsURL), let v = JSONValue.parse(data) else { return nil }
        let m = v["model"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return m.isEmpty ? nil : m
    }
}
