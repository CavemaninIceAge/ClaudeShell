import AppKit
import SwiftUI

/// Details of the selected native conversation. Content is derived only from its loaded transcript.
struct WorkspaceInspector: View {
    @Environment(ThreadStore.self) private var threads
    @Environment(WorkspaceContentStore.self) private var content
    @State private var addingSource = false
    @State private var sourceAddress = ""
    @State private var actionError: String?
    @State private var showAllOutputs = false
    @State private var showAllSources = false
    @State private var showAgents = false

    private var artifacts: WorkspaceArtifactSnapshot {
        guard let controller = threads.selectedController else { return WorkspaceArtifactSnapshot() }
        return WorkspaceConversationArtifacts.derive(items: controller.items, cwd: controller.cwd)
    }

    private var savedAssets: [WorkspaceAsset] {
        guard let id = threads.selectedId else { return content.assets.filter { $0.threadID == nil } }
        return content.assets(for: id)
    }

    private var outputRows: [WorkspaceAsset] {
        var result = savedAssets
        for output in artifacts.outputs where !content.isDismissed(url: output.url, threadID: threads.selectedId) && !result.contains(where: { $0.url == output.url }) {
            result.append(WorkspaceAsset(id: "derived:" + output.id, url: output.url, name: output.name,
                                         threadID: threads.selectedId, addedAt: output.date))
        }
        return result
    }

    private var savedSources: [WorkspaceSource] {
        guard let id = threads.selectedId else { return content.sources.filter { $0.threadID == nil } }
        return content.sources(for: id)
    }

    private var sourceRows: [WorkspaceToolSource] {
        var result = savedSources.map { WorkspaceToolSource(name: $0.name, url: $0.url) }
        for source in artifacts.sources where !result.contains(where: { $0.id == source.id }) { result.append(source) }
        return result
    }

    private var preferredHeight: CGFloat {
        let outputs = outputRows.isEmpty ? 22 : CGFloat(showAllOutputs ? outputRows.count : min(outputRows.count, 3)) * 53 + (outputRows.count > 3 ? 26 : 0)
        let sources = sourceRows.isEmpty ? 22 : CGFloat(showAllSources ? sourceRows.count : min(sourceRows.count, 3)) * 47 + (sourceRows.count > 3 ? 26 : 0)
        let agents = artifacts.subagents.isEmpty ? 22 : (showAgents ? CGFloat(artifacts.subagents.count) * 82 + 32 : 28)
        return min(640, 228 + outputs + sources + agents + (addingSource ? 80 : 0) + (actionError != nil || content.lastError != nil ? 64 : 0))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                outputsSection
                separator
                subagentsSection
                separator
                sourcesSection
                if let error = actionError ?? content.lastError {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 24).padding(.bottom, 24)
                        .accessibilityLabel("操作失败：" + error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 300)
        .frame(minHeight: 0, idealHeight: preferredHeight, maxHeight: preferredHeight, alignment: .top)
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("对话详情")
    }

    private var outputsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("输出", count: outputRows.count) {
                Button { content.importFiles(threadID: threads.selectedId) } label: { plusIcon }
                    .buttonStyle(.plain).help("导入本地文件").accessibilityLabel("导入本地文件")
            }
            if outputRows.isEmpty {
                empty("还没有输出")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(showAllOutputs ? outputRows : Array(outputRows.prefix(3))) { asset in
                        Button { open(asset.url) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: asset.isImage ? "photo" : "doc").font(.system(size: 17, weight: .regular))
                                    .frame(width: 20, height: 24).foregroundStyle(Theme.textSecondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(asset.name).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                                    Text(asset.url.pathExtension.isEmpty ? "本地文件" : asset.url.pathExtension.uppercased())
                                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 7).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(asset.url.path).accessibilityLabel("打开文件：" + asset.name)
                        .contextMenu {
                            Button("打开文件") { open(asset.url) }
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([asset.url]) }
                            if savedAssets.contains(where: { $0.id == asset.id }) {
                                Divider()
                                Button("从资源库移除", role: .destructive) { content.remove(id: asset.id) }
                            }
                        }
                    }
                }
                if outputRows.count > 3 {
                    Button(showAllOutputs ? "收起" : "查看全部 \(outputRows.count) 项") { showAllOutputs.toggle() }
                        .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(24)
    }

    private var subagentsSection: some View {
        let snapshot = artifacts
        return VStack(alignment: .leading, spacing: 14) {
            sectionHeader("子代理", count: snapshot.subagents.count) { EmptyView() }
            if snapshot.subagents.isEmpty {
                empty("尚未调用子代理")
            } else {
                Button { showAgents.toggle() } label: {
                    HStack(spacing: 6) {
                        HStack(spacing: -4) {
                            ForEach(Array(snapshot.subagents.prefix(4))) { agent in
                                Image(systemName: agentSymbol(agent.state)).font(.system(size: 13))
                                    .foregroundStyle(agentColor(agent.state)).frame(width: 21, height: 22)
                                    .background(Theme.background, in: Circle())
                            }
                        }
                        Text(agentSummary(snapshot)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                        Image(systemName: showAgents ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(showAgents ? "收起子代理详情" : "展开子代理详情")
                if showAgents { VStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.subagents) { agent in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(agent.toolName).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                                Text(agent.details.isEmpty ? "引擎尚未提供任务详情。" : agent.details)
                                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: agentSymbol(agent.state)).font(.system(size: 13))
                                    .foregroundStyle(agentColor(agent.state)).frame(width: 16, height: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.name).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                                    Text(agent.statusLabel).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .tint(Theme.textTertiary)
                    }
                } }
            }
        }
        .padding(24)
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("来源", count: sourceRows.count) {
                Button { addingSource.toggle(); actionError = nil } label: { plusIcon }
                    .buttonStyle(.plain).help("添加来源链接").accessibilityLabel("添加来源链接")
            }
            if addingSource {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://example.com", text: $sourceAddress)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .accessibilityLabel("HTTPS 来源地址").onSubmit(addSource)
                    HStack {
                        Button("取消") { addingSource = false; sourceAddress = "" }
                        Spacer()
                        Button("添加", action: addSource)
                            .disabled(WorkspaceConversationArtifacts.httpsURL(sourceAddress) == nil)
                    }
                    .controlSize(.small)
                }
            }
            if sourceRows.isEmpty {
                empty("还没有来源")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(showAllSources ? sourceRows : Array(sourceRows.prefix(3))) { source in
                        if let url = source.url {
                            Button { open(url) } label: {
                                sourceLabel(source, icon: "link", detail: url.host ?? "HTTPS")
                            }
                            .buttonStyle(.plain).help(url.absoluteString).accessibilityLabel("打开来源：" + source.name)
                            .contextMenu {
                                Button("打开来源") { open(url) }
                                if let saved = savedSources.first(where: { $0.url == url }) {
                                    Button("移除来源", role: .destructive) { content.removeSource(id: saved.id) }
                                }
                            }
                        } else {
                            sourceLabel(source, icon: "wrench.and.screwdriver", detail: "对话中调用的工具")
                                .help(source.name)
                        }
                    }
                }
                if sourceRows.count > 3 {
                    Button(showAllSources ? "收起" : "查看全部 \(sourceRows.count) 项") { showAllSources.toggle() }
                        .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(24)
    }

    private var separator: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 24) }
    private var plusIcon: some View {
        Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
            .frame(width: 24, height: 24).contentShape(Rectangle())
    }

    private func sectionHeader<Action: View>(_ title: String, count: Int, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
            if count > 0 { Text("\(count)").font(.system(size: 12)).foregroundStyle(Theme.textTertiary) }
            Spacer()
            action()
        }
        .frame(minHeight: 24)
    }

    private func empty(_ title: String) -> some View {
        Text(title).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func agentSummary(_ snapshot: WorkspaceArtifactSnapshot) -> String {
        var parts: [String] = []
        if snapshot.runningCount > 0 { parts.append("\(snapshot.runningCount) 个运行中") }
        if snapshot.completedCount > 0 { parts.append("\(snapshot.completedCount) 个已完成") }
        let failed = snapshot.subagents.filter { $0.state == .failed }.count
        let unknown = snapshot.subagents.filter { $0.state == .unknown }.count
        if failed > 0 { parts.append("\(failed) 个失败") }
        if unknown > 0 { parts.append("\(unknown) 个状态未报告") }
        return parts.joined(separator: " · ")
    }

    private func sourceLabel(_ source: WorkspaceToolSource, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Theme.textSecondary).frame(width: 18, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func agentSymbol(_ state: WorkspaceSubagent.State) -> String {
        switch state {
        case .running: "circle.dotted"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .unknown: "circle.dashed"
        }
    }

    private func agentColor(_ state: WorkspaceSubagent.State) -> Color {
        switch state {
        case .running: Theme.accent
        case .completed: Theme.live
        case .failed: Theme.danger
        case .unknown: Theme.textTertiary
        }
    }

    private func addSource() {
        guard let url = WorkspaceConversationArtifacts.httpsURL(sourceAddress) else {
            actionError = "请输入有效的 HTTPS 来源地址。"
            return
        }
        if content.addSource(url: url, threadID: threads.selectedId) {
            addingSource = false; sourceAddress = ""; actionError = nil
        }
    }

    private func open(_ url: URL) {
        // Called exclusively by the user's file/source action; rendering never opens or reads targets.
        guard url.isFileURL || WorkspaceConversationArtifacts.httpsURL(url.absoluteString) != nil else { return }
        if !NSWorkspace.shared.open(url) { actionError = "无法打开此项目，请确认文件仍在原位置或链接可用。" }
    }
}
