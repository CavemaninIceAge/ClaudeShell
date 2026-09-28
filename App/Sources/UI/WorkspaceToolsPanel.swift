import SwiftUI

struct WorkspaceToolsPanel: View {
    let cwd: String
    var initialTab: WorkspaceToolTab
    var onClose: (() -> Void)?
    var onAttachFile: ((URL) -> Void)?
    @Environment(WorkspaceToolsStore.self) private var tools
    @State private var selectedTab: WorkspaceToolTab
    @State private var session: WorkspaceToolSession?

    init(cwd: String, initialTab: WorkspaceToolTab = .files, onClose: (() -> Void)? = nil, onAttachFile: ((URL) -> Void)? = nil) {
        self.cwd = cwd; self.initialTab = initialTab; self.onClose = onClose; self.onAttachFile = onAttachFile
        _selectedTab = State(initialValue: initialTab)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("工作区工具", selection: $selectedTab) {
                    ForEach(WorkspaceToolTab.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("收起工作区工具").accessibilityLabel("收起工作区工具")
                }
            }.padding(12)
            Text(session?.root ?? cwd).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 10)
                .help(session?.root ?? cwd)
            Divider().overlay(Theme.line)
            if let session {
                switch selectedTab {
                case .files: WorkspaceFilesView(files: session.files, onAttachFile: onAttachFile)
                case .git: WorkspaceGitView(git: session.git)
                case .command: WorkspaceCommandView(command: session.command)
                }
            } else { Spacer() }
        }
        .background(Theme.background).foregroundStyle(Theme.textPrimary)
        .task(id: cwd) {
            session = tools.activate(cwd: cwd)
            loadSelectedTab()
        }
        .onChange(of: initialTab) { _, tab in selectedTab = tab }
        .onChange(of: selectedTab) { _, _ in loadSelectedTab() }
    }
    private func loadSelectedTab() {
        guard let session else { return }
        if selectedTab == .files { session.files.loadDirectory() }
        if selectedTab == .git && !session.git.refreshed { session.git.refresh() }
    }
}

private struct WorkspaceFilesView: View {
    let files: WorkspaceFiles
    var onAttachFile: ((URL) -> Void)?
    @State private var treeVisible = true
    @State private var confirmReload = false
    private var document: WorkspaceDocument? { files.selectedDocument }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { treeVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help(treeVisible ? "收起文件树" : "显示文件树")
                Toggle("隐藏文件", isOn: Binding(get: { files.showHidden }, set: { files.showHidden = $0; files.refresh() }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Spacer(minLength: 4)
                Button { files.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新文件树")
            }.buttonStyle(.plain).padding(10)
            if let error = files.error { WorkspaceToolNotice(message: error, isError: true) }
            HStack(spacing: 0) {
                if treeVisible {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            WorkspaceFileTree(files: files, parent: "", depth: 0)
                            if files.loading.contains("directory:") { ProgressView().controlSize(.small).padding(12) }
                            if files.children[""]?.isEmpty == true { Text("目录为空").font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(12) }
                        }
                    }.frame(width: 150).background(Theme.sidebar)
                    Divider()
                }
                VStack(alignment: .leading, spacing: 0) {
                    if let document {
                        documentHeader(document)
                        if let error = document.error { WorkspaceToolNotice(message: error, isError: true) }
                        TextEditor(text: Binding(get: { document.text }, set: { document.text = $0 }))
                            .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                            .padding(6).accessibilityLabel("编辑 \(document.path)")
                        HStack {
                            Text(document.isDirty ? "未保存" : "已保存").foregroundStyle(document.isDirty ? Theme.warn : Theme.textTertiary)
                            Spacer()
                            Text("UTF-8 · \(document.text.utf8.count) B").foregroundStyle(Theme.textTertiary)
                        }.font(.system(size: 11)).padding(10)
                    } else if files.loading.contains(where: { $0.hasPrefix("file:") }) {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "doc.text").font(.system(size: 24)).foregroundStyle(Theme.textTertiary)
                            Text("选择文件查看或编辑").font(.system(size: 13))
                            Text("支持 2 MiB 以内的 UTF-8 文本。修改后点击保存。").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog("重新载入会丢弃此文件未保存的修改。", isPresented: $confirmReload) {
            Button("丢弃修改并重新载入", role: .destructive) { if let document { files.open(document.path, reload: true) } }
            Button("取消", role: .cancel) { }
        }
    }
    private func documentHeader(_ document: WorkspaceDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.path).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).help(document.path)
            HStack(spacing: 10) {
                Button("保存") { files.save(document) }
                    .disabled(!document.isDirty || document.isSaving)
                    .keyboardShortcut("s", modifiers: .command)
                Button("重新载入") {
                    if document.isDirty { confirmReload = true } else { files.open(document.path, reload: true) }
                }.disabled(document.isSaving)
                Spacer(minLength: 0)
                if document.isSaving { ProgressView().controlSize(.mini) }
                if let onAttachFile {
                    Button {
                        onAttachFile(URL(fileURLWithPath: files.root).appendingPathComponent(document.path))
                    } label: { Image(systemName: "paperclip") }
                    .help(document.isDirty ? "保存后可添加到当前对话" : "添加到当前对话")
                    .accessibilityLabel("添加到当前对话")
                    .disabled(document.isDirty || document.isSaving)
                }
            }.font(.system(size: 12)).buttonStyle(.borderless)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.sidebar)
    }
}

private struct WorkspaceFileTree: View {
    let files: WorkspaceFiles
    let parent: String
    let depth: Int
    var body: some View {
        ForEach(files.children[parent] ?? []) { node in
            VStack(alignment: .leading, spacing: 0) {
                Button { files.toggle(node) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: node.kind == .directory ? (files.expanded.contains(node.path) ? "chevron.down" : "chevron.right") : "circle.fill")
                            .font(.system(size: node.kind == .directory ? 8 : 2)).frame(width: 8)
                            .opacity(node.kind == .directory ? 1 : 0)
                        Image(systemName: node.kind == .directory ? "folder" : node.kind == .symbolicLink ? "link" : "doc")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        Text(node.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if files.documents[node.path]?.isDirty == true { Circle().fill(Theme.warn).frame(width: 4, height: 4) }
                    }
                    .padding(.leading, CGFloat(min(depth, 10) * 12 + 6)).padding(.trailing, 6).frame(height: 27)
                    .background(files.selectedPath == node.path ? Theme.selectedFill : .clear).contentShape(Rectangle())
                }.buttonStyle(.plain).help(node.kind == .symbolicLink ? "符号链接不会被打开" : node.path)
                if node.kind == .directory && files.expanded.contains(node.path) {
                    WorkspaceFileTree(files: files, parent: node.path, depth: depth + 1)
                }
            }
        }
    }
}

private struct WorkspaceGitView: View {
    let git: WorkspaceGit
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(git.entries.count) 个变更").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Spacer()
                if git.isLoading { ProgressView().controlSize(.mini) }
                Button("刷新") { git.refresh() }.disabled(git.isLoading)
            }.padding(10)
            if let error = git.error { WorkspaceToolNotice(message: error, isError: true) }
            if git.entries.isEmpty && git.refreshed && git.error == nil {
                Text("工作区没有未提交的变更").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(git.entries) { entry in
                            Button { git.select(entry) } label: {
                                HStack(spacing: 8) {
                                    Text(entry.status).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).frame(width: 22)
                                    Text(entry.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 10).frame(height: 29)
                                    .background(git.selectedPath == entry.path ? Theme.selectedFill : .clear).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(entry.path)
                        }
                    }
                }.frame(maxHeight: 160)
                Divider()
                if git.isLoadingDiff { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            Text(git.diff.isEmpty ? "选择变更查看差异" : git.diff)
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                                .frame(minWidth: max(0, geometry.size.width - 24), minHeight: max(0, geometry.size.height - 24), alignment: .topLeading).padding(12)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if git.diffTruncated { WorkspaceToolNotice(message: "差异输出超过上限，已截断。", isError: false) }
            }
        }
    }
}

private struct WorkspaceCommandView: View {
    let command: WorkspaceCommand
    private var status: String {
        switch command.phase {
        case .idle: return command.stopped ? "已停止" : "等待运行"
        case .preparing: return "正在准备登录 PATH…"
        case .running: return "运行中"
        case .stopping: return "正在停止…"
        case .finished(let code): return command.stopped ? "已停止 · 退出码 \(code)" : "已结束 · 退出码 \(code)"
        case .failed(let message): return "运行失败：\(message)"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("命令在当前目录运行；不提供交互式终端或标准输入。同组后台进程随命令结束停止。").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            TextEditor(text: Binding(get: { command.script }, set: { command.script = $0 }))
                .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                .frame(height: 74).padding(5).background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebar))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
                .accessibilityLabel("待运行的命令")
            HStack(spacing: 12) {
                Button("运行") { command.start() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(command.isRunning || command.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("停止") { command.stop() }.disabled(!command.isRunning)
                Spacer()
                Button("清空输出") { command.clear() }.disabled(command.isRunning)
            }.font(.system(size: 12))
            Text(status).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            if command.truncated { WorkspaceToolNotice(message: "输出超过 1 MiB，后续内容已省略；命令仍正常运行。", isError: false) }
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Text(command.output.isEmpty ? "运行后，输出会显示在这里。" : command.output)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(minWidth: max(0, geometry.size.width - 20), minHeight: max(0, geometry.size.height - 20), alignment: .topLeading).padding(10)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.sidebar)
        }.padding(12)
    }
}

private struct WorkspaceToolNotice: View {
    let message: String
    let isError: Bool
    var body: some View {
        Text(message).font(.system(size: 12)).foregroundStyle(isError ? Theme.danger : Theme.textSecondary)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
}
