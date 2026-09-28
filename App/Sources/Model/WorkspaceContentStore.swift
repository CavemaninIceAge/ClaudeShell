import AppKit
import CryptoKit
import Foundation
import Observation

struct WorkspaceAsset: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var url: URL
    var name: String
    var threadID: String?
    var addedAt: Date
    var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "avif"].contains(url.pathExtension.lowercased())
    }
}

struct WorkspaceSource: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var url: URL
    var name: String
    var threadID: String?
    var addedAt: Date
}

/// A library of references, never a copy of the user's files or a replacement for native session history.
/// Initializers are deliberately free of disk access; the app explicitly calls load().
@MainActor
@Observable
final class WorkspaceContentStore {
    private(set) var assets: [WorkspaceAsset] = []
    private(set) var sources: [WorkspaceSource] = []
    var lastError: String?
    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let snapshotMode: Bool
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var canPersist = true
    private var dismissedArtifacts: [DismissedArtifact] = []

    private struct DismissedArtifact: Codable {
        var url: URL
        var threadID: String?
    }

    private struct Library: Codable {
        var version = 1
        var assets: [WorkspaceAsset]
        var sources: [WorkspaceSource]
        var dismissedArtifacts: [DismissedArtifact]

        init(assets: [WorkspaceAsset], sources: [WorkspaceSource], dismissedArtifacts: [DismissedArtifact]) {
            self.assets = assets; self.sources = sources; self.dismissedArtifacts = dismissedArtifacts
        }

        enum CodingKeys: String, CodingKey { case version, assets, sources, dismissedArtifacts }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            guard version == 1 else { throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported library version") }
            assets = try c.decode([WorkspaceAsset].self, forKey: .assets)
            sources = try c.decodeIfPresent([WorkspaceSource].self, forKey: .sources) ?? []
            dismissedArtifacts = try c.decodeIfPresent([DismissedArtifact].self, forKey: .dismissedArtifacts) ?? []
        }
    }

    init() {
        storageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Shell/workspace-library.json")
        snapshotMode = false
    }

    /// Explicit storage injection supports isolated persistence tests without touching the real library.
    init(storageURL: URL) {
        self.storageURL = storageURL
        snapshotMode = false
    }

    init(snapshot: [WorkspaceAsset], sources: [WorkspaceSource] = []) {
        assets = snapshot
        self.sources = sources
        storageURL = URL(fileURLWithPath: "/dev/null")
        snapshotMode = true
        loaded = true
    }

    func load() {
        guard !loaded, !snapshotMode else { return }
        loaded = true
        do {
            let data: Data
            do { data = try Data(contentsOf: storageURL) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                if !assets.isEmpty || !sources.isEmpty || !dismissedArtifacts.isEmpty { persist() }
                return
            }
            let saved = try JSONDecoder.standard.decode(Library.self, from: data)
            // Metadata discovered before the root's load task is merged rather than overwriting saved entries.
            let pendingAssets = assets, pendingSources = sources, pendingDismissed = dismissedArtifacts
            dismissedArtifacts = saved.dismissedArtifacts.filter { $0.url.isFileURL }
            for item in pendingDismissed where !isDismissed(url: item.url, threadID: item.threadID) { dismissedArtifacts.append(item) }
            assets = saved.assets.filter { $0.url.isFileURL && !isDismissed(url: $0.url, threadID: $0.threadID) }
            sources = saved.sources.filter { WorkspaceConversationArtifacts.httpsURL($0.url.absoluteString) != nil }
            for asset in pendingAssets where !isDismissed(url: asset.url, threadID: asset.threadID) && !assets.contains(where: { Self.key($0.url, $0.threadID) == Self.key(asset.url, asset.threadID) }) { assets.append(asset) }
            for source in pendingSources where !sources.contains(where: { Self.key($0.url, $0.threadID) == Self.key(source.url, source.threadID) }) { sources.append(source) }
            if !pendingAssets.isEmpty || !pendingSources.isEmpty || !pendingDismissed.isEmpty { persist() }
        } catch {
            // Preserve unreadable/corrupt metadata, including when a file is temporarily inaccessible.
            canPersist = false
            lastError = "无法读取资源库，已保留原文件并暂停保存：\(error.localizedDescription)"
        }
    }

    /// Presents a chooser only in direct response to the user's + button; never used by preview/test fixtures.
    func importFiles(threadID: String?) {
        guard !snapshotMode else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "添加到资源库"
        panel.message = "只保存文件引用，不移动或修改原文件。"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url: url, threadID: threadID) }
    }

    func add(url: URL, threadID: String?) {
        guard url.isFileURL else { lastError = "资源库文件需要本地路径；网页请添加到来源。"; return }
        let canonical = url.standardizedFileURL
        dismissedArtifacts.removeAll { Self.key($0.url, $0.threadID) == Self.key(canonical, threadID) }
        guard !assets.contains(where: { Self.key($0.url, $0.threadID) == Self.key(canonical, threadID) }) else { return }
        assets.append(WorkspaceAsset(id: Self.key(canonical, threadID), url: canonical,
                                     name: canonical.lastPathComponent, threadID: threadID, addedAt: Date()))
        persist()
    }

    @discardableResult
    func addSource(url: URL, threadID: String?) -> Bool {
        guard let safe = WorkspaceConversationArtifacts.httpsURL(url.absoluteString) else {
            lastError = "请输入不含用户名或密码的有效 HTTPS 来源地址。"
            return false
        }
        guard !sources.contains(where: { Self.key($0.url, $0.threadID) == Self.key(safe, threadID) }) else { return true }
        sources.append(WorkspaceSource(id: Self.key(safe, threadID), url: safe, name: safe.host ?? safe.absoluteString,
                                       threadID: threadID, addedAt: Date()))
        persist()
        return true
    }

    func remove(id: String) {
        if let asset = assets.first(where: { $0.id == id }), !isDismissed(url: asset.url, threadID: asset.threadID) {
            dismissedArtifacts.append(DismissedArtifact(url: asset.url, threadID: asset.threadID))
        }
        assets.removeAll { $0.id == id }
        persist()
    }

    func isDismissed(url: URL, threadID: String?) -> Bool {
        dismissedArtifacts.contains { Self.key($0.url, $0.threadID) == Self.key(url, threadID) }
    }

    /// Native engines replace a draft ID once a session starts; retain its library associations.
    func reassociateThread(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        var changed = false
        for index in assets.indices where assets[index].threadID == oldID {
            assets[index].threadID = newID
            assets[index].id = Self.key(assets[index].url, newID)
            changed = true
        }
        for index in sources.indices where sources[index].threadID == oldID {
            sources[index].threadID = newID
            sources[index].id = Self.key(sources[index].url, newID)
            changed = true
        }
        for index in dismissedArtifacts.indices where dismissedArtifacts[index].threadID == oldID {
            dismissedArtifacts[index].threadID = newID
            changed = true
        }
        guard changed else { return }
        var seenAssets = Set<String>(), seenSources = Set<String>(), seenDismissed = Set<String>()
        dismissedArtifacts = dismissedArtifacts.filter { seenDismissed.insert(Self.key($0.url, $0.threadID)).inserted }
        assets = assets.sorted { $0.addedAt > $1.addedAt }.filter {
            !isDismissed(url: $0.url, threadID: $0.threadID) && seenAssets.insert(Self.key($0.url, $0.threadID)).inserted
        }
        sources = sources.sorted { $0.addedAt > $1.addedAt }.filter { seenSources.insert(Self.key($0.url, $0.threadID)).inserted }
        persist()
    }

    func removeSource(id: String) {
        sources.removeAll { $0.id == id }
        persist()
    }

    /// nil is the library overview; a conversation also sees explicitly unassigned imports.
    func assets(for threadID: String?) -> [WorkspaceAsset] {
        assets.filter { threadID == nil || $0.threadID == nil || $0.threadID == threadID }.sorted { $0.addedAt > $1.addedAt }
    }

    func sources(for threadID: String?) -> [WorkspaceSource] {
        sources.filter { threadID == nil || $0.threadID == nil || $0.threadID == threadID }.sorted { $0.addedAt > $1.addedAt }
    }

    /// Called only with the transcript already opened by the user. Read tools are never treated as generated files.
    /// No existence checks, file reads, thumbnails, or engine calls occur here.
    func recordArtifacts(items: [TranscriptItem], cwd: String, threadID: String) {
        let found = WorkspaceConversationArtifacts.derive(items: items, cwd: cwd)
        var changed = false
        for output in found.outputs {
            guard !isDismissed(url: output.url, threadID: threadID) else { continue }
            let id = Self.key(output.url, threadID)
            guard !assets.contains(where: { Self.key($0.url, $0.threadID) == id }) else { continue }
            assets.append(WorkspaceAsset(id: id, url: output.url, name: output.name, threadID: threadID, addedAt: output.date))
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        guard loaded, !snapshotMode, canPersist else { return }
        do {
            let data = try JSONEncoder.standard.encode(Library(assets: assets, sources: sources, dismissedArtifacts: dismissedArtifacts))
            let fm = FileManager.default
            try fm.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: storageURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        } catch { lastError = "资源库保存失败：\(error.localizedDescription)" }
    }

    nonisolated private static func key(_ url: URL, _ threadID: String?) -> String {
        let input = (threadID ?? "") + "|" + (url.isFileURL ? url.standardizedFileURL.path : url.absoluteString)
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct WorkspaceOutputReference: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var date: Date
    var id: String { url.path }
}

struct WorkspaceToolSource: Identifiable, Hashable, Sendable {
    var name: String
    var url: URL?
    var id: String { url?.absoluteString ?? "tool:" + name }
}

struct WorkspaceSubagent: Identifiable, Hashable, Sendable {
    enum State: String, Sendable { case running, completed, failed, unknown }
    var id: String
    var name: String
    var toolName: String
    var state: State
    var details: String
    var statusLabel: String {
        switch state {
        case .running: "运行中"
        case .completed: "已完成"
        case .failed: "失败"
        case .unknown: "状态未报告"
        }
    }
}

struct WorkspaceArtifactSnapshot: Sendable {
    var outputs: [WorkspaceOutputReference] = []
    var sources: [WorkspaceToolSource] = []
    var subagents: [WorkspaceSubagent] = []
    var runningCount: Int { subagents.filter { $0.state == .running }.count }
    var completedCount: Int { subagents.filter { $0.state == .completed }.count }
}

/// Pure derivation from already-loaded messages. It does not resolve symlinks, inspect files, or fetch links.
enum WorkspaceConversationArtifacts {
    static func derive(items: [TranscriptItem], cwd: String) -> WorkspaceArtifactSnapshot {
        var outputByPath: [String: WorkspaceOutputReference] = [:]
        var sourceByID: [String: WorkspaceToolSource] = [:]
        var agents: [String: WorkspaceSubagent] = [:]
        func addOutput(_ raw: String, name: String? = nil, date: Date) {
            guard let url = localURL(raw, cwd: cwd) else { return }
            outputByPath[url.path] = WorkspaceOutputReference(url: url, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent, date: date)
        }
        func addLinks(_ text: String, includeFiles: Bool, date: Date) {
            for (name, target) in markdownLinks(text) {
                if let url = httpsURL(target) { sourceByID[url.absoluteString] = WorkspaceToolSource(name: name.isEmpty ? (url.host ?? target) : name, url: url) }
                else if includeFiles { addOutput(target, name: name, date: date) }
            }
            for raw in matches(#"https://[^\s<>\"\]\)]+"#, in: text) {
                let candidate = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?。，；：！？"))
                if let url = httpsURL(candidate), sourceByID[url.absoluteString] == nil { sourceByID[url.absoluteString] = WorkspaceToolSource(name: url.host ?? candidate, url: url) }
            }
        }
        for item in items {
            let date = item.timestamp ?? .distantPast
            if item.kind == .assistant { addLinks(item.text, includeFiles: true, date: date) }
            for block in item.blocks {
                if block.kind == .text, item.kind == .assistant { addLinks(block.text, includeFiles: true, date: date) }
                guard let tool = block.tool else { continue }
                sourceByID["tool:" + tool.name] = WorkspaceToolSource(name: tool.name, url: nil)
                let strings = stringValues(tool.input)
                for string in strings { addLinks(string, includeFiles: false, date: date) }
                if let result = tool.result { addLinks(result, includeFiles: false, date: date) }
                if tool.done && !tool.isError && producesFiles(tool.name) {
                    for path in outputPaths(tool.input) { addOutput(path, date: date) }
                    if let result = tool.result {
                        addLinks(result, includeFiles: true, date: date)
                        if let json = JSONValue.parse(result) { for path in outputPaths(json) { addOutput(path, date: date) } }
                        if tool.name.lowercased().contains("apply_patch") {
                            for line in result.split(separator: "\n") where line.hasPrefix("A ") || line.hasPrefix("M ") { addOutput(String(line.dropFirst(2)), date: date) }
                        }
                    }
                }
                for agent in subagents(tool) {
                    if let existing = agents[agent.id], tool.name.lowercased() == "collabagenttoolcall",
                       tool.input?["tool"]?.string?.lowercased() != "spawnagent" {
                        var updated = existing
                        if agent.state != .unknown { updated.state = agent.state }
                        agents[agent.id] = updated
                    } else { agents[agent.id] = agent }
                }
                // Native wait/list calls can report statuses after spawn. Only explicit agent state data updates them.
                for (id, state) in reportedStates(tool.input) {
                    if var known = agents[id] { known.state = state; agents[id] = known }
                }
                if let result = tool.result, let json = JSONValue.parse(result) {
                    for (id, state) in reportedStates(json) {
                        if var known = agents[id] { known.state = state; agents[id] = known }
                    }
                }
            }
        }
        return WorkspaceArtifactSnapshot(outputs: outputByPath.values.sorted { $0.url.path < $1.url.path },
            sources: sourceByID.values.sorted { $0.id < $1.id }, subagents: agents.values.sorted { $0.id < $1.id })
    }

    static func httpsURL(_ raw: String) -> URL? {
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }

    static func localURL(_ raw: String, cwd: String) -> URL? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("<") && path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            return URL(fileURLWithPath: url.path).standardizedFileURL
        }
        guard !path.isEmpty, !path.hasPrefix("#"), !path.contains("://"), path.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil, !path.hasPrefix("~") else { return nil }
        path = path.replacingOccurrences(of: #"(?::\d+(?:-\d+)?)?(?:#L\d+(?:-L?\d+)?)?$"#, with: "", options: .regularExpression)
        path = path.removingPercentEncoding ?? path
        guard !path.isEmpty, !path.contains("\n"), !path.contains("\0") else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(path)
        guard !url.pathExtension.isEmpty else { return nil }
        return url.standardizedFileURL
    }

    private static func markdownLinks(_ text: String) -> [(String, String)] {
        let pattern = #"!?\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^\)]+))\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let name = Range(match.range(at: 1), in: text) else { return nil }
            let targetRange = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
            guard let target = Range(targetRange, in: text) else { return nil }
            let raw = String(text[target]).components(separatedBy: " \"")[0]
            return (String(text[name]), raw)
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func stringValues(_ value: JSONValue?) -> [String] {
        guard let value else { return [] }
        if let text = value.string { return [text] }
        if let array = value.array { return array.flatMap { stringValues($0) } }
        if let object = value.object { return object.values.flatMap { stringValues($0) } }
        return []
    }

    private static func producesFiles(_ name: String) -> Bool {
        let leaf = name.lowercased().components(separatedBy: "__").last ?? name.lowercased()
        return ["write", "edit", "multiedit", "notebookedit", "filechange", "apply_patch", "functions.apply_patch"].contains(leaf)
            || ["generate", "render", "export", "write_file", "create_document", "create_image", "imagegen"].contains(where: leaf.contains)
    }

    private static func outputPaths(_ value: JSONValue?) -> [String] {
        guard let value else { return [] }
        let keys: Set<String> = ["path", "file_path", "notebook_path", "output_path", "output_file", "output_files", "output_paths", "artifact_path", "image_path", "image_paths"]
        if let array = value.array { return array.flatMap { outputPaths($0) } }
        guard let object = value.object else { return [] }
        if ["delete", "deleted", "remove"].contains(value["kind"]?.string?.lowercased() ?? value["type"]?.string?.lowercased() ?? "") { return [] }
        return object.flatMap { key, child -> [String] in
            if keys.contains(key) { return stringValues(child) }
            if ["changes", "artifacts", "images", "outputs", "files"].contains(key) { return outputPaths(child) }
            return []
        }
    }

    private static func subagents(_ tool: ToolCall) -> [WorkspaceSubagent] {
        let leaf = tool.name.lowercased().components(separatedBy: "__").last?.components(separatedBy: ".").last ?? tool.name.lowercased()
        let syncAgent = ["task", "agent"].contains(leaf)
        let native = leaf == "collabagenttoolcall"
        guard syncAgent || ["spawn_agent", "spawnagent"].contains(leaf) || native else { return [] }
        let result = tool.result.flatMap(JSONValue.parse)
        let explicitStates = reportedStates(tool.input).merging(reportedStates(result)) { _, newer in newer }
        let receivers = tool.input?["receiverThreadIds"]?.array?.compactMap(\.string) ?? []
        let resultID = result?["agent_id"]?.string ?? result?["id"]?.string ?? result?["threadId"]?.string
        // A native wait/close call without reported receivers is not evidence of another agent.
        if native && receivers.isEmpty && resultID == nil && tool.input?["tool"]?.string?.lowercased() != "spawnagent" { return [] }
        let ids = !receivers.isEmpty ? receivers : [resultID ?? tool.id]
        return ids.map { id in
            let state: WorkspaceSubagent.State
            if let reported = explicitStates[id] { state = reported }
            else if tool.isError { state = .failed }
            else if syncAgent && tool.input?["run_in_background"]?.bool != true { state = tool.done ? .completed : .running }
            else { state = .unknown } // Spawn completion only means the child was created, not that its work finished.
            let name = tool.input?["description"]?.string ?? tool.input?["task_name"]?.string ?? tool.input?["name"]?.string ?? tool.name
            let prompt = tool.input?["prompt"]?.string ?? tool.input?["message"]?.string ?? ""
            let resultText = tool.result.map { String($0.prefix(1400)) } ?? ""
            let detail = [prompt, resultText].filter { !$0.isEmpty }.joined(separator: "\n\n")
            return WorkspaceSubagent(id: id, name: name, toolName: tool.name, state: state, details: detail)
        }
    }

    private static func reportedStates(_ value: JSONValue?) -> [String: WorkspaceSubagent.State] {
        guard let value else { return [:] }
        var states: [String: WorkspaceSubagent.State] = [:]
        for key in ["agentsStates", "agentStates", "agent_states", "statuses", "status"] {
            if let object = value[key]?.object {
                for (id, item) in object { if let state = state(item["status"]?.string ?? item.string) { states[id] = state } }
            }
        }
        for item in value["agents"]?.array ?? [] {
            if let id = item["agent_id"]?.string ?? item["id"]?.string ?? item["agent_name"]?.string,
               let state = state(item["status"]?.string ?? item["agent_status"]?.string) { states[id] = state }
        }
        return states
    }

    private static func state(_ raw: String?) -> WorkspaceSubagent.State? {
        switch raw?.lowercased() {
        case "running", "in_progress", "inprogress", "working": .running
        case "completed", "complete", "finished", "done": .completed
        case "failed", "errored", "error": .failed
        default: nil
        }
    }
}
