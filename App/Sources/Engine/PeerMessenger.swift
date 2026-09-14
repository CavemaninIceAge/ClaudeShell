import Foundation

/// 把一句话投进终端里正在跑的那个 Claude Code 会话——走它自己的跨会话消息协议（docs/protocol.md「跨会话投递」）。
///
/// 每个交互式会话在 `/tmp/cc-socks/<pid>.sock` 收信，`~/.claude/sessions/<pid>.json` 登记 sessionId 和套接字路径。
/// 一次连接写一行 JSON（user 帧）就关；macOS 上不需要 auth 行，对方靠内核报的连接方 pid 认人。对方不在这条连接上回话：
/// 消息会出现在终端的对话里（"› Message from @Claude Shell: …"），回答照常落进会话文件，app 靠 tail 会话文件同步。
enum PeerMessenger {
    static let senderName = "Claude Shell"
    /// 附在正文后面给对方 Claude 看的说明：它会被告知"这是别的会话发来的"，不说清是用户本人，它会试着用 SendMessage 回信。
    static let userNote = "（这句话是用户本人在 Claude Shell 里输入的，请像回答用户一样直接在本对话里回答；不要用 SendMessage 回信，那个地址收不到。）"

    static func body(forUserText text: String) -> String { text + "\n\n" + userNote }

    static func stripUserNote(_ body: String) -> String {
        guard body.hasSuffix(userNote) else { return body }
        return String(body.dropLast(userNote.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Target: Sendable {
        var pid: Int
        var socketPath: String
    }

    enum SendError: LocalizedError {
        case notFound, connectFailed(String), writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .notFound: return "终端里的那个会话找不到了（可能刚退出），刷新一下列表再试。"
            case .connectFailed(let s): return "连不上终端会话的收信口：\(s)"
            case .writeFailed(let s): return "发给终端会话失败：\(s)"
            }
        }
    }

    /// 我们自己没有收信口，但 from 必须是个合法的 uds 地址；用 app 自己的 pid，对方核对内核报的连接方 pid 时是一致的。
    static var ownAddress: String { "uds:/tmp/cc-socks/\(ProcessInfo.processInfo.processIdentifier).sock" }

    /// 在会话登记表里找到 sessionId 对应的、进程还活着的终端会话。
    static func target(forSessionId sessionId: String) -> Target? {
        let dir = SessionIndex.sessionsDir
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let v = JSONValue.parse(data),
                  v["sessionId"]?.string == sessionId,
                  let pid = v["pid"]?.int, kill(pid_t(pid), 0) == 0,
                  let sock = v["messagingSocketPath"]?.string, !sock.isEmpty else { continue }
            return Target(pid: pid, socketPath: sock)
        }
        return nil
    }

    /// 阻塞，放后台线程跑。
    static func send(_ body: String, to target: Target) throws {
        let frame: JSONValue = .object([
            "msgV": .number(1),
            "msg_id": .string(UUID().uuidString.lowercased()),
            "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .string(envelope(body: body))]),
            "priority": .string("next"),
            "from": .string(ownAddress),
        ])
        let payload = Data((frame.serialized() + "\n").utf8)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SendError.connectFailed(String(cString: strerror(errno))) }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(target.socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw SendError.connectFailed("套接字路径太长") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard rc == 0 else { throw SendError.connectFailed(String(cString: strerror(errno))) }
        var written = 0
        try payload.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            while written < buf.count {
                let n = write(fd, buf.baseAddress! + written, buf.count - written)
                if n < 0 { throw SendError.writeFailed(String(cString: strerror(errno))) }
                written += n
            }
        }
        // 对方读到整行才处理，写完稍等再关，别让它读到半截。
        usleep(150_000)
    }

    /// 信封格式（属性顺序不能变：from, from-session, hop-chain, from-name, from-mode）。
    /// from-mode 报 prompting：对方是逐项询问 / auto 类的会话就直接送达；对方 bypassPermissions 时会在终端弹一次确认。
    static func envelope(body: String) -> String {
        let escaped = body.replacingOccurrences(of: "</cross-session-message", with: "<\\")
        return "<cross-session-message from=\"\(ownAddress)\" from-name=\"\(senderName)\" from-mode=\"prompting\">\n\(escaped)\n</cross-session-message>"
    }

    /// 从会话文件里的信封拆出发信人和正文；不是跨会话消息返回 nil。
    static func unwrap(_ content: String) -> (name: String?, body: String)? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.range(of: "<cross-session-message"),
              let headEnd = trimmed.range(of: ">\n", range: open.upperBound..<trimmed.endIndex),
              let close = trimmed.range(of: "\n</cross-session-message>", options: .backwards),
              headEnd.upperBound <= close.lowerBound else { return nil }
        let head = trimmed[open.upperBound..<headEnd.lowerBound]
        var name: String? = nil
        if let n = head.range(of: "from-name=\""), let end = head.range(of: "\"", range: n.upperBound..<head.endIndex) {
            name = String(head[n.upperBound..<end.lowerBound])
        }
        return (name, String(trimmed[headEnd.upperBound..<close.lowerBound]))
    }
}
