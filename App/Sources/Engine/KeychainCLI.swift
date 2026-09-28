import CryptoKit
import Foundation

/// Keep the system `security` tool's existing Keychain access identity. Large app-owned snapshots
/// use verified generations of small encrypted Keychain records: `security -i` has a 4095-byte line limit.
/// Credentials never appear in process arguments or plaintext temporary files.
enum KeychainCLI {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static var accountName: String {
        let name = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let legal = name.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil
        return legal && !name.isEmpty ? name : "claude-code-user"
    }
    private static var storage: KeychainSecretStorage {
        KeychainSecretStorage(account: accountName, raw: KeychainRawStore(
            read: readRaw, write: writeRaw, delete: deleteRaw))
    }
    static func read(service: String) -> String? { try? readChecked(service: service) }
    static func readChecked(service: String) throws -> String? { try storage.read(service: service) }
    static func write(service: String, secret: String) throws { try storage.write(service: service, secret: secret) }
    static func delete(service: String) { try? deleteChecked(service: service) }
    static func deleteChecked(service: String) throws { try storage.delete(service: service) }

    private static func readRaw(service: String) throws -> String? {
        try validate(service)
        let result = run(arguments: ["find-generic-password", "-s", service, "-a", accountName, "-w"])
        if result.status == 44 { return nil }
        guard result.status == 0 else { throw Failure(message: "读取钥匙串失败（状态 \(result.status)）。请确认登录钥匙串已解锁。") }
        var value = result.stdout
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }
    private static func writeRaw(service: String, secret: String) throws {
        try validate(service); try validate(secret)
        let command = writeCommand(service: service, account: accountName, secret: secret)
        // Include the terminating newline; never let security split one command into two.
        guard command.utf8.count + 1 <= 4095 else { throw Failure(message: "登录态超过钥匙串命令的长度限制，未写入。") }
        let result = run(arguments: ["-i"], command: command)
        guard result.status == 0 else { throw Failure(message: "写入钥匙串失败（状态 \(result.status)）。请确认登录钥匙串已解锁。") }
    }
    private static func deleteRaw(service: String) throws {
        try validate(service)
        let result = run(arguments: ["delete-generic-password", "-s", service, "-a", accountName])
        guard result.status == 0 || result.status == 44 else { throw Failure(message: "删除钥匙串条目失败（状态 \(result.status)）。") }
    }
    static func validate(_ value: String) throws {
        guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            throw Failure(message: "钥匙串数据含不支持的控制字符。")
        }
    }
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func writeCommand(service: String, account: String, secret: String) -> String {
        "add-generic-password -U -s \(quote(service)) -a \(quote(account)) -w \(quote(secret))"
    }
    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var stdout = Data(), stderr = Data()
        func set(_ data: Data, output: Bool) {
            lock.lock(); defer { lock.unlock() }
            if output { stdout = data } else { stderr = data }
        }
    }
    private static func run(arguments: [String], command: String? = nil) -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        do { try process.run() } catch { return (-1, "") }
        let capture = Capture(), group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { capture.set(output.fileHandleForReading.readDataToEndOfFile(), output: true); group.leave() }
        group.enter()
        DispatchQueue.global().async { capture.set(error.fileHandleForReading.readDataToEndOfFile(), output: false); group.leave() }
        if let command { try? input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8)) }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit(); group.wait()
        // security can echo command text on stderr. Never expose that credential-bearing output.
        return (process.terminationStatus, String(data: capture.stdout, encoding: .utf8) ?? "")
    }
}

/// Tests inject an in-memory raw store. Production records all remain in the user's Keychain.
struct KeychainRawStore {
    var read: (String) throws -> String?
    var write: (String, String) throws -> Void
    var delete: (String) throws -> Void
}

struct KeychainSecretStorage {
    let account: String
    let raw: KeychainRawStore
    private static let lock = NSRecursiveLock()
    private struct Manifest: Codable {
        let _claudex_keychain_chunks: Int
        let generation: String
        let count: Int
        let sha256: String
        func service(_ root: String, _ index: Int) -> String { root + "-chunk-" + generation + "-" + String(index) }
    }
    private func owned(_ service: String) -> Bool {
        service.hasPrefix("Claude Shell-") || service.hasPrefix("Claudex Shell-")
    }
    private func failure(_ message: String) -> KeychainCLI.Failure { .init(message: message) }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func manifest(_ value: String, service: String) throws -> Manifest? {
        guard owned(service), let data = value.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["_claudex_keychain_chunks"] != nil else { return nil }
        guard let parsed = try? JSONDecoder().decode(Manifest.self, from: data),
              parsed._claudex_keychain_chunks == 1, UUID(uuidString: parsed.generation)?.uuidString == parsed.generation,
              (1...16_384).contains(parsed.count), parsed.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw failure("保存的登录态索引损坏，请重新导入；原条目未删除。")
        }
        return parsed
    }
    func read(service: String) throws -> String? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try KeychainCLI.validate(service)
        guard let root = try raw.read(service) else { return nil }
        guard let manifest = try manifest(root, service: service) else { return root }
        var result = Data()
        for index in 0..<manifest.count {
            guard let encoded = try raw.read(manifest.service(service, index)), encoded.utf8.count <= 1024,
                  let bytes = Data(base64Encoded: encoded) else { throw failure("保存的登录态不完整，请重新导入。") }
            result.append(bytes)
        }
        guard digest(result) == manifest.sha256, let value = String(data: result, encoding: .utf8) else {
            throw failure("保存的登录态校验失败，请重新导入。")
        }
        return value
    }
    private func verifiedWrite(_ service: String, _ value: String) throws {
        guard KeychainCLI.writeCommand(service: service, account: account, secret: value).utf8.count + 1 <= 4095 else {
            throw failure("登录态超过钥匙串命令的长度限制，未写入。")
        }
        try raw.write(service, value)
        guard try raw.read(service) == value else { throw failure("钥匙串写入校验失败；未确认保存成功。") }
    }
    private func cleanup(_ manifest: Manifest?, service: String) {
        guard let manifest else { return }
        for index in 0..<manifest.count { try? raw.delete(manifest.service(service, index)) }
    }
    func write(service: String, secret: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try KeychainCLI.validate(service); try KeychainCLI.validate(account); try KeychainCLI.validate(secret)
        let commandLength = KeychainCLI.writeCommand(service: service, account: account, secret: secret).utf8.count + 1
        if !owned(service) && commandLength > 4095 {
            throw failure("本机共享登录态超过安全写入长度，未改写；请在对应引擎中登录。应用内仍可保存此账号。")
        }
        let previous = try raw.read(service)
        let oldManifest = previous.flatMap { try? manifest($0, service: service) }
        if commandLength <= 3000 || !owned(service) {
            try verifiedWrite(service, secret)
            cleanup(oldManifest, service: service)
            return
        }
        let bytes = Data(secret.utf8)
        let count = (bytes.count + 767) / 768
        guard count <= 16_384 else { throw failure("登录态过大，未写入钥匙串。") }
        let staged = Manifest(_claudex_keychain_chunks: 1, generation: UUID().uuidString, count: count, sha256: digest(bytes))
        let root = String(decoding: try JSONEncoder().encode(staged), as: UTF8.self)
        var commitAttempted = false
        do {
            for index in 0..<count {
                let part = bytes.subdata(in: (index * 768)..<min((index + 1) * 768, bytes.count))
                try verifiedWrite(staged.service(service, index), part.base64EncodedString())
            }
            commitAttempted = true
            try verifiedWrite(service, root)
        } catch {
            if !commitAttempted {
                cleanup(staged, service: service)
            } else {
                // A write can have succeeded even if its readback failed. Keep that generation unless
                // a successful read proves the root does not reference it; never leave a dangling root.
                do { if try raw.read(service) != root { cleanup(staged, service: service) } } catch { }
            }
            throw error
        }
        cleanup(oldManifest, service: service)
    }
    func delete(service: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try KeychainCLI.validate(service)
        let previous = try raw.read(service)
        let oldManifest = previous.flatMap { try? manifest($0, service: service) }
        try raw.delete(service)
        cleanup(oldManifest, service: service)
    }
}
