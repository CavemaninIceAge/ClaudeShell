import AppKit
import SwiftUI

/// Details of the selected native conversation. Content is derived only from its loaded transcript.
struct WorkspaceInspector: View {
    @Environment(ThreadStore.self) private var threads
    @Environment(WorkspaceNavigation.self) private var navigation
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

    private let previewLimit = 2
    private let rowHeight: CGFloat = 30

    private var preferredHeight: CGFloat {
        let outputs = outputRows.isEmpty ? 20 : CGFloat(showAllOutputs ? outputRows.count : min(outputRows.count, previewLimit)) * rowHeight + (outputRows.count > previewLimit ? 20 : 0)
        let sources = sourceRows.isEmpty ? 20 : CGFloat(showAllSources ? sourceRows.count : min(sourceRows.count, previewLimit)) * rowHeight + (sourceRows.count > previewLimit ? 20 : 0)
        let statusCount = Set(artifacts.subagents.map { $0.state.rawValue }).count
        let summaryHeight: CGFloat = statusCount > 1 ? 40 : 24
        let agents = artifacts.subagents.isEmpty ? 20 : (showAgents ? CGFloat(artifacts.subagents.count) * 70 + summaryHeight + 12 : summaryHeight)
        // Three compact sections: 14pt vertical insets, a 20pt heading and an 8pt gap.
        return min(640, 170 + outputs + sources + agents + (addingSource ? 80 : 0) + (actionError != nil || content.lastError != nil ? 64 : 0))
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
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.bottom, 14)
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
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Outputs") {
                Button { content.importFiles(threadID: threads.selectedId) } label: { plusIcon }
                    .buttonStyle(.plain).help("导入本地文件").accessibilityLabel("导入本地文件")
            }
            if outputRows.isEmpty {
                empty("Create a file or site")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(showAllOutputs ? outputRows : Array(outputRows.prefix(previewLimit))) { asset in
                        Button { open(asset.url) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: asset.isImage ? "photo" : "doc").font(.system(size: 15, weight: .regular))
                                    .frame(width: 20, height: 20).foregroundStyle(Theme.textTertiary)
                                Text(asset.name).font(.system(size: 14)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(height: rowHeight).contentShape(Rectangle())
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
                    if outputRows.count > previewLimit {
                        Button { showAllOutputs.toggle() } label: {
                            viewAllLabel(expanded: showAllOutputs)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showAllOutputs ? "收起输出" : "查看全部 \(outputRows.count) 项输出")
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subagentsSection: some View {
        let snapshot = artifacts
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Subagents") { EmptyView() }
            if snapshot.subagents.isEmpty {
                empty("尚未调用子代理")
            } else {
                Button { showAgents.toggle() } label: {
                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            ForEach(Array(snapshot.subagents.prefix(4).enumerated()), id: \.element.id) { index, agent in
                                SubagentAvatar(index: index).frame(width: 17, height: 20)
                                    .accessibilityLabel(agent.name + "，" + agent.statusLabel)
                            }
                        }
                        Text(agentSummary(snapshot)).font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: showAgents ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    }
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(showAgents ? "收起子代理详情" : "展开子代理详情")
                .accessibilityValue(agentSummary(snapshot))
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
                                Image(systemName: agentSymbol(agent.state)).font(.system(size: 14))
                                    .foregroundStyle(agentColor(agent.state)).frame(width: 16, height: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.name).font(.system(size: 14)).foregroundStyle(Theme.textPrimary).lineLimit(2)
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
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Sources") {
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
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(showAllSources ? sourceRows : Array(sourceRows.prefix(previewLimit))) { source in
                        if let url = source.url {
                            Button { open(url) } label: {
                                sourceLabel(source, icon: "globe")
                            }
                            .buttonStyle(.plain).help(url.absoluteString).accessibilityLabel("打开来源：" + source.name)
                            .contextMenu {
                                Button("打开来源") { open(url) }
                                if let saved = savedSources.first(where: { $0.url == url }) {
                                    Button("移除来源", role: .destructive) { content.removeSource(id: saved.id) }
                                }
                            }
                        } else {
                            sourceLabel(source, icon: sourceSymbol(source.name))
                                .help(source.name)
                        }
                    }
                    if sourceRows.count > previewLimit {
                        Button { showAllSources.toggle() } label: {
                            viewAllLabel(expanded: showAllSources)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showAllSources ? "收起来源" : "查看全部 \(sourceRows.count) 项来源")
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var separator: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 20) }
    private var plusIcon: some View {
        Image(systemName: "plus").font(.system(size: 15, weight: .regular)).foregroundStyle(Theme.textTertiary)
            .frame(width: 20, height: 20).contentShape(Rectangle())
    }

    private func sectionHeader<Action: View>(_ title: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
            Spacer()
            action()
        }
        .frame(height: 20)
    }

    private func empty(_ title: String) -> some View {
        Text(title).font(.system(size: 14)).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 20, alignment: .leading)
    }

    private func agentSummary(_ snapshot: WorkspaceArtifactSnapshot) -> String {
        var parts: [String] = []
        if snapshot.runningCount > 0 { parts.append("\(snapshot.runningCount) running") }
        if snapshot.completedCount > 0 { parts.append("\(snapshot.completedCount) done") }
        let failed = snapshot.subagents.filter { $0.state == .failed }.count
        let unknown = snapshot.subagents.filter { $0.state == .unknown }.count
        if failed > 0 { parts.append("\(failed) failed") }
        if unknown > 0 { parts.append("\(unknown) unreported") }
        return parts.joined(separator: " · ")
    }

    private func sourceSymbol(_ name: String) -> String {
        let normalized = name.lowercased()
        if normalized.contains("web") || normalized.contains("search") || normalized.contains("browse") { return "globe" }
        if normalized.contains("app") || normalized.contains("mcp") { return "network" }
        if normalized.contains("read") || normalized.contains("file") { return "doc.text" }
        return "wrench"
    }

    private func sourceLabel(_ source: WorkspaceToolSource, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Theme.textTertiary).frame(width: 20, height: 20)
            Text(source.name).font(.system(size: 14)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
    }

    private func viewAllLabel(expanded: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: expanded ? "chevron.up" : "circle.grid.2x2")
                .font(.system(size: 14)).frame(width: 20, height: 20)
            Text(expanded ? "Show less" : "View all").font(.system(size: 14))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textTertiary)
        .frame(height: 20)
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
        navigation.open(url)
    }
}

/// Identity marks only; completion and failure continue to come from native engine state.
private struct SubagentAvatar: View {
    let index: Int
    private let colors = ["#81C779", "#4EB8A0", "#65BBD0", "#689EF0"]
    var body: some View {
        ZStack {
            ForEach(0..<(index == 1 ? 3 : index == 3 ? 4 : 7), id: \.self) { petal in
                RoundedRectangle(cornerRadius: index == 1 ? 2 : 3)
                    .fill(Theme.dynamic(colors[index % 4], colors[index % 4]))
                    .frame(width: index == 3 ? 7 : 4, height: 8)
                    .offset(y: -4)
                    .rotationEffect(.degrees(Double(petal) * 360 / Double(index == 1 ? 3 : index == 3 ? 4 : 7)))
            }
            Circle().fill(Theme.background.opacity(0.75)).frame(width: 3, height: 3)
        }
    }
}
