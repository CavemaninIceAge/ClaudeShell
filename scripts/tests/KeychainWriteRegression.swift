import Foundation

/// Synthetic raw storage only. These checks never call security or touch the system Keychain.
enum KeychainWriteRegression {
    struct Failure: Error, CustomStringConvertible { var description: String }
    private static let service = "Claudex Shell-codex-synthetic-regression"
    private static let account = "synthetic-user"

    private final class Memory {
        var values: [String: String] = [:]
        var writes: [(String, String)] = []
        var deletes: [String] = []
        var beforeWrite: ((String, String) throws -> Void)?
        var beforeRead: ((String) throws -> Void)?
        var raw: KeychainRawStore {
            KeychainRawStore(
                read: { key in
                    try self.beforeRead?(key)
                    return self.values[key]
                },
                write: { key, value in
                    self.writes.append((key, value))
                    try self.beforeWrite?(key, value)
                    self.values[key] = value
                },
                delete: { key in
                    self.deletes.append(key)
                    self.values.removeValue(forKey: key)
                }
            )
        }
        var storage: KeychainSecretStorage { KeychainSecretStorage(account: account, raw: raw) }
        func clearHistory() { writes.removeAll(); deletes.removeAll() }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }
    private static func expectFailure(_ operation: () throws -> Void) throws {
        var failed = false
        do { try operation() } catch { failed = true }
        try expect(failed, "Expected storage to reject the operation")
    }
    private static func chunks(in memory: Memory, service: String = service) throws -> [String] {
        guard let root = memory.values[service],
              let data = root.data(using: .utf8),
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (manifest["_claudex_keychain_chunks"] as? Int) == 1,
              let generation = manifest["generation"] as? String,
              UUID(uuidString: generation) != nil,
              let count = manifest["count"] as? Int, count > 0,
              let digest = manifest["sha256"] as? String, digest.count == 64 else {
            throw Failure(description: "Missing or invalid chunk manifest")
        }
        return (0..<count).map { service + "-chunk-" + generation + "-" + String($0) }
    }
    private static func seed(_ payload: String) throws -> Memory {
        let memory = Memory()
        try memory.storage.write(service: service, secret: payload)
        memory.clearHistory()
        return memory
    }

    static func run() throws {
        let object = ["tokens": [
            "access_token": String(repeating: "synthetic-访问-\\-\"-🧪", count: 4096),
            "refresh_token": String(repeating: "synthetic-refresh", count: 1024),
            "id_token": "synthetic-header.synthetic-claims.synthetic-signature"
        ]]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let payload = String(decoding: bytes, as: UTF8.self)
        let replacement = payload.replacingOccurrences(of: "synthetic-refresh", with: "synthetic-rotated")
        try expect(bytes.count > 65_536, "Fixture must exceed 64 KiB")

        let memory = Memory()
        try memory.storage.write(service: service, secret: payload)
        let firstChunks = try chunks(in: memory)
        let firstRead = try memory.storage.read(service: service)
        try expect(firstRead == payload, "Long UTF-8 credential was truncated or changed")
        try expect(memory.writes.last?.0 == service, "Root was published before its chunks")
        for (index, key) in firstChunks.enumerated() {
            guard let encoded = memory.values[key], let data = Data(base64Encoded: encoded) else {
                throw Failure(description: "Chunk is absent or not Base64")
            }
            try expect(encoded.utf8.count <= 1024 && data.count <= 768, "Chunk exceeds bounded transport size")
            if index < firstChunks.count - 1 {
                try expect(data.count == 768, "Non-final chunk has unexpected raw size")
            }
        }
        try memory.storage.write(service: service, secret: replacement)
        let secondChunks = try chunks(in: memory)
        let updated = try memory.storage.read(service: service)
        try expect(updated == replacement, "Updating a long credential lost data")
        try expect(Set(firstChunks).isDisjoint(with: secondChunks), "Update reused a published chunk generation")
        try expect(firstChunks.allSatisfy { memory.values[$0] == nil }, "Update left old generation chunks behind")

        try memory.storage.write(service: service, secret: "short synthetic value")
        try expect(memory.values[service] == "short synthetic value", "Short value was not stored inline")
        try expect(secondChunks.allSatisfy { memory.values[$0] == nil }, "Inline replacement leaked old chunks")
        try memory.storage.write(service: service, secret: "")
        let empty = try memory.storage.read(service: service)
        try expect(empty == "", "Empty value failed to round-trip")

        // Escaped command length, rather than just the unescaped payload, controls chunking.
        let escaped = String(repeating: "\\\"", count: 900)
        try memory.storage.write(service: service, secret: escaped)
        _ = try chunks(in: memory)
        let escapedRead = try memory.storage.read(service: service)
        try expect(escapedRead == escaped, "Escaped credential failed to round-trip")

        let stageFailure = try seed(payload)
        let stageBefore = stageFailure.values
        var staged = 0
        stageFailure.beforeWrite = { key, _ in
            if key != service {
                staged += 1
                if staged == 2 { throw Failure(description: "Synthetic staging failure") }
            }
        }
        try expectFailure { try stageFailure.storage.write(service: service, secret: replacement) }
        try expect(stageFailure.values == stageBefore, "Failed staging changed the root or leaked new chunks")

        let rootFailure = try seed(payload)
        let rootBefore = rootFailure.values
        rootFailure.beforeWrite = { key, _ in
            if key == service { throw Failure(description: "Synthetic root publication failure") }
        }
        try expectFailure { try rootFailure.storage.write(service: service, secret: replacement) }
        try expect(rootFailure.values == rootBefore, "Failed root publication destroyed the old value or leaked chunks")

        // A backend can commit a root and then report an error. Its referenced chunks must survive.
        let ambiguous = try seed(payload)
        ambiguous.beforeWrite = { key, value in
            if key == service {
                ambiguous.values[key] = value
                throw Failure(description: "Synthetic post-commit error")
            }
        }
        do { try ambiguous.storage.write(service: service, secret: replacement) } catch { /* The write may report its backend error. */ }
        let ambiguousChunks = try chunks(in: ambiguous)
        try expect(ambiguousChunks.allSatisfy { ambiguous.values[$0] != nil }, "Ambiguous publication deleted live chunks")
        let committed = try ambiguous.storage.read(service: service)
        try expect(committed == replacement, "Post-commit error corrupted the published value")

        // If publication cannot be checked, retain staged chunks instead of guessing they are unused.
        let unreadable = try seed(payload)
        let unreadableBefore = unreadable.values
        var rootAttempted = false
        unreadable.beforeWrite = { key, _ in
            if key == service {
                rootAttempted = true
                throw Failure(description: "Synthetic root error")
            }
        }
        unreadable.beforeRead = { key in
            if rootAttempted && key == service { throw Failure(description: "Synthetic verification read error") }
        }
        try expectFailure { try unreadable.storage.write(service: service, secret: replacement) }
        let newKeys = unreadable.writes.map { $0.0 }.filter { $0 != service && unreadableBefore[$0] == nil }
        try expect(!newKeys.isEmpty && newKeys.allSatisfy { unreadable.values[$0] != nil }, "Uncertain publication deleted staged chunks")
        try expect(unreadable.values[service] == unreadableBefore[service], "Failure changed the existing root")

        let foreign = Memory()
        try expectFailure { try foreign.storage.write(service: "external-tool-auth", secret: payload) }
        try expect(foreign.writes.isEmpty && foreign.deletes.isEmpty, "Oversized foreign credential reached raw writes")

        let damaged = try seed(payload)
        let damagedKeys = try chunks(in: damaged)
        damaged.values[damagedKeys[0]] = Data("synthetic corruption".utf8).base64EncodedString()
        try expectFailure { _ = try damaged.storage.read(service: service) }
        damaged.values.removeValue(forKey: damagedKeys[0])
        try expectFailure { _ = try damaged.storage.read(service: service) }

        let removed = try seed(payload)
        let removedKeys = try chunks(in: removed)
        try removed.storage.delete(service: service)
        try expect(removed.values[service] == nil && removedKeys.allSatisfy { removed.values[$0] == nil }, "Deletion left the current root or chunks behind")
        try expect(removed.values.isEmpty, "Deletion left synthetic secrets in storage")

        print("PASS — bounded Keychain chunks, UTF-8 round-trip, update cleanup and publication failure isolation (synthetic)")
    }
}
