import Darwin
import Foundation
import Observation

struct WorkspaceFileNode: Identifiable, Sendable, Equatable {
    enum Kind: Sendable { case directory, file, symbolicLink, other }
    let path: String
    let name: String
    let kind: Kind
    let size: Int64
    var id: String { path }
}

struct WorkspaceFileSnapshot: Sendable {
    struct Identity: Sendable, Equatable {
        let device: Int32
        let inode: UInt64
        let modified: Int64
        let nanoseconds: Int64
        let size: Int64
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino
            modified = Int64(value.st_mtimespec.tv_sec); nanoseconds = Int64(value.st_mtimespec.tv_nsec)
            size = value.st_size
        }
    }
    let data: Data
    let text: String
    let identity: Identity
}

enum WorkspaceFileError: LocalizedError {
    case unsafePath, symbolicLink, notRegular, tooLarge, binary, conflict, system(String), listingLimit
    var errorDescription: String? {
        switch self {
        case .unsafePath: return "文件路径不在当前工作区内。"
        case .symbolicLink: return "为避免越过工作区边界，不打开符号链接。"
        case .notRegular: return "仅支持普通文本文件。"
        case .tooLarge: return "文件超过 2 MiB，请使用其他编辑器打开。"
        case .binary: return "此文件是二进制或非 UTF-8 文本，无法在这里编辑。"
        case .conflict: return "文件已被外部修改或替换，未覆盖磁盘内容。请重新载入后合并你的修改。"
        case .system(let message): return message
        case .listingLimit: return "此目录超过 2,000 项，请打开更具体的工作目录。"
        }
    }
}

/// Descriptor-relative operations refuse links in every path component, including a replaced
/// ancestor. Reading and saving never resolve a selected entry through a symlink.
enum WorkspaceFileIO {
    static let maximumBytes = 2 * 1024 * 1024
    static func canonicalRoot(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }
    static func components(_ path: String) throws -> [String] {
        guard !path.hasPrefix("/"), !path.contains("\0") else { throw WorkspaceFileError.unsafePath }
        if path.isEmpty { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw WorkspaceFileError.unsafePath }
        return parts
    }
    private static func systemError() -> WorkspaceFileError { .system(String(cString: strerror(errno))) }
    private static func directory(_ root: String, components: [String]) throws -> Int32 {
        var fd = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw systemError() }
        do {
            for component in components {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw errno == ELOOP ? WorkspaceFileError.symbolicLink : systemError() }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    static func list(root: String, path: String, showHidden: Bool) throws -> [WorkspaceFileNode] {
        let fd = try directory(root, components: components(path))
        guard let dir = fdopendir(fd) else { Darwin.close(fd); throw systemError() }
        defer { closedir(dir) }
        var result: [WorkspaceFileNode] = []
        while let entry = readdir(dir) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || (!showHidden && name.hasPrefix(".")) { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            let kind: WorkspaceFileNode.Kind = type == S_IFDIR ? .directory : type == S_IFREG ? .file : type == S_IFLNK ? .symbolicLink : .other
            result.append(.init(path: path.isEmpty ? name : path + "/" + name, name: name, kind: kind, size: info.st_size))
            if result.count > 2_000 { throw WorkspaceFileError.listingLimit }
        }
        return result.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private static func read(fd: Int32) throws -> WorkspaceFileSnapshot {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WorkspaceFileError.notRegular }
        guard info.st_size <= maximumBytes else { throw WorkspaceFileError.tooLarge }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw systemError() }
            bytes.append(contentsOf: buffer.prefix(count))
            if bytes.count > maximumBytes { throw WorkspaceFileError.tooLarge }
        }
        var after = stat()
        guard fstat(fd, &after) == 0 else { throw systemError() }
        guard WorkspaceFileSnapshot.Identity(info) == WorkspaceFileSnapshot.Identity(after) else { throw WorkspaceFileError.conflict }
        guard !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else { throw WorkspaceFileError.binary }
        return .init(data: bytes, text: text, identity: .init(info))
    }
    static func load(root: String, path: String) throws -> WorkspaceFileSnapshot {
        let parts = try components(path)
        guard let name = parts.last else { throw WorkspaceFileError.notRegular }
        let parent = try directory(root, components: Array(parts.dropLast()))
        defer { Darwin.close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw errno == ELOOP ? WorkspaceFileError.symbolicLink : systemError() }
        defer { Darwin.close(fd) }
        return try read(fd: fd)
    }
    static func save(root: String, path: String, text: String, original: WorkspaceFileSnapshot) throws -> WorkspaceFileSnapshot {
        let data = Data(text.utf8)
        guard data.count <= maximumBytes else { throw WorkspaceFileError.tooLarge }
        guard !data.contains(0) else { throw WorkspaceFileError.binary }
        let parts = try components(path)
        guard let name = parts.last else { throw WorkspaceFileError.notRegular }
        let parent = try directory(root, components: Array(parts.dropLast()))
        defer { Darwin.close(parent) }
        let current = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard current >= 0 else { throw WorkspaceFileError.conflict }
        defer { Darwin.close(current) }
        let existing = try read(fd: current)
        guard existing.identity == original.identity, existing.data == original.data else { throw WorkspaceFileError.conflict }
        var mode = stat()
        guard fstat(current, &mode) == 0 else { throw systemError() }
        let temporaryName = ".claudex-save-" + UUID().uuidString
        let temporary = openat(parent, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temporary >= 0 else { throw systemError() }
        defer { Darwin.close(temporary); unlinkat(parent, temporaryName, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try Task.checkCancellation()
                let count = Darwin.write(temporary, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw systemError() }
                guard count > 0 else { throw WorkspaceFileError.system("无法完整写入文件。") }
                offset += count
            }
        }
        guard fchmod(temporary, mode.st_mode & 0o777) == 0, fsync(temporary) == 0 else { throw systemError() }
        // Recheck identity immediately before the atomic replacement, never follow a changed link.
        var latest = stat()
        guard fstatat(parent, name, &latest, AT_SYMLINK_NOFOLLOW) == 0,
              WorkspaceFileSnapshot.Identity(latest) == original.identity,
              latest.st_mode & S_IFMT == S_IFREG else { throw WorkspaceFileError.conflict }
        try Task.checkCancellation()
        guard renameat(parent, temporaryName, parent, name) == 0 else { throw systemError() }
        _ = fsync(parent)
        var saved = stat()
        guard fstat(temporary, &saved) == 0 else { throw systemError() }
        return .init(data: data, text: text, identity: .init(saved))
    }
}

enum WorkspaceBackground {
    static func run<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated) { try action() }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}

@MainActor @Observable final class WorkspaceDocument: Identifiable {
    nonisolated let path: String
    nonisolated var id: String { path }
    var text: String
    private(set) var original: WorkspaceFileSnapshot
    var isSaving = false
    var error: String?
    var conflicted = false
    var isDirty: Bool { text != original.text }
    init(path: String, snapshot: WorkspaceFileSnapshot) { self.path = path; text = snapshot.text; original = snapshot }
    func saved(_ snapshot: WorkspaceFileSnapshot) { original = snapshot; error = nil; conflicted = false }
}

@MainActor @Observable final class WorkspaceFiles {
    let root: String
    private(set) var children: [String: [WorkspaceFileNode]] = [:]
    private(set) var documents: [String: WorkspaceDocument] = [:]
    var expanded: Set<String> = []
    var selectedPath: String?
    var showHidden = false
    var error: String?
    private(set) var loading: Set<String> = []
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0
    var selectedDocument: WorkspaceDocument? { selectedPath.flatMap { documents[$0] } }
    init(root: String) { self.root = root }
    func cancelOperations() {
        generation += 1
        tasks.values.forEach { $0.cancel() }; tasks.removeAll(); loading.removeAll()
        documents.values.forEach { $0.isSaving = false }
    }
    func loadDirectory(_ path: String = "", refresh: Bool = false) {
        if !refresh && children[path] != nil { return }
        let key = "directory:" + path
        guard tasks[key] == nil else { return }
        loading.insert(key); error = nil
        let token = generation, root = root, hidden = showHidden
        tasks[key] = Task { [weak self] in
            do {
                let nodes = try await WorkspaceBackground.run { try WorkspaceFileIO.list(root: root, path: path, showHidden: hidden) }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.children[path] = nodes
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            self?.tasks.removeValue(forKey: key); self?.loading.remove(key)
        }
    }
    func refresh() {
        cancelOperations(); children.removeAll()
        loadDirectory(refresh: true)
        for path in expanded { loadDirectory(path, refresh: true) }
    }
    func toggle(_ node: WorkspaceFileNode) {
        if node.kind == .directory {
            if expanded.contains(node.path) { expanded.remove(node.path) }
            else { expanded.insert(node.path); loadDirectory(node.path) }
        } else if node.kind == .file { open(node.path) }
        else { error = WorkspaceFileError.symbolicLink.localizedDescription }
    }
    func open(_ path: String, reload: Bool = false) {
        selectedPath = path
        if !reload && documents[path] != nil { return }
        let key = "file:" + path
        guard tasks[key] == nil else { return }
        loading.insert(key); error = nil
        let token = generation, root = root
        tasks[key] = Task { [weak self] in
            do {
                let snapshot = try await WorkspaceBackground.run { try WorkspaceFileIO.load(root: root, path: path) }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.documents[path] = WorkspaceDocument(path: path, snapshot: snapshot)
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            self?.tasks.removeValue(forKey: key); self?.loading.remove(key)
        }
    }
    func save(_ document: WorkspaceDocument) {
        guard document.isDirty, !document.isSaving else { return }
        let key = "save:" + document.path, token = generation, root = root
        let path = document.path, text = document.text, snapshot = document.original
        document.isSaving = true; document.error = nil
        tasks[key] = Task { [weak self, weak document] in
            do {
                let saved = try await WorkspaceBackground.run { try WorkspaceFileIO.save(root: root, path: path, text: text, original: snapshot) }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                document?.saved(saved)
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                document?.error = error.localizedDescription
                if case WorkspaceFileError.conflict = error { document?.conflicted = true }
            }
            document?.isSaving = false; self?.tasks.removeValue(forKey: key)
        }
    }
}
