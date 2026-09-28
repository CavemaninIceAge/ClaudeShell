import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Full-height destinations use the same content surface as conversations. These
/// views only perform file, account, or engine operations in response to a click.
struct WorkspaceHistoryPage: View {
    @Environment(ThreadStore.self) private var store
    @Environment(WorkspaceNavigation.self) private var navigation
    @State private var query = ""
    @State private var engine = "all"
    @State private var renaming: ThreadSummary?
    @State private var renameText = ""
    @State private var hiding: ThreadSummary?

    private var threads: [ThreadSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.groups.flatMap(\.threads).filter {
            (engine == "all" || $0.engine.rawValue == engine) &&
            (needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle) || $0.cwd.localizedCaseInsensitiveContains(needle))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var sections: [(title: String, threads: [ThreadSummary])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? yesterday
        let month = calendar.date(byAdding: .day, value: -30, to: today) ?? week
        var buckets = [[ThreadSummary]](repeating: [], count: 5)
        for thread in threads {
            let date = thread.updatedAt
            let index = date >= today ? 0 : date >= yesterday ? 1 : date >= week ? 2 : date >= month ? 3 : 4
            buckets[index].append(thread)
        }
        return zip(["今天", "昨天", "过去 7 天", "过去 30 天", "更早"], buckets)
            .filter { !$0.1.isEmpty }.map { (title: $0.0, threads: $0.1) }
    }

    var body: some View {
        WorkspacePageSurface {
            WorkspacePageHeading("历史记录", subtitle: "继续 Claude Code 与 Codex 的本机会话。") {
                Button {
                    let id = store.newThread()
                    navigation.visit(.home, threadID: id)
                } label: { Label("新聊天", systemImage: "square.and.pencil") }
                    .buttonStyle(WorkspacePageButtonStyle(prominent: true))
            }
            HStack(spacing: 12) {
                WorkspacePageSearch(text: $query, placeholder: "搜索对话或项目")
                Picker("引擎", selection: $engine) {
                    Text("所有引擎").tag("all")
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                }.labelsHidden().frame(width: 120)
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 18, height: 18)
                }.buttonStyle(WorkspacePageButtonStyle()).disabled(store.isScanning)
                    .help("刷新原生会话列表").accessibilityLabel("刷新对话")
            }
            if threads.isEmpty {
                WorkspacePageEmpty(icon: "clock", title: query.isEmpty ? "还没有会话" : "没有匹配的会话",
                                   message: query.isEmpty ? "新建一个聊天，或刷新以读取本机 Claude Code 和 Codex 的会话。" : "试试其他关键词或切换引擎筛选。")
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 12)
                            ForEach(section.threads) { thread in historyRow(thread) }
                        }
                    }
                }
            }
        }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $renameText)
            Button("保存") {
                if let thread = renaming { store.rename(thread.id, to: renameText) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("隐藏这个对话？", isPresented: Binding(get: { hiding != nil }, set: { if !$0 { hiding = nil } }), titleVisibility: .visible) {
            Button("隐藏对话") { if let thread = hiding { store.hide(thread.id) }; hiding = nil }
        } message: { Text("将从 Claudex Shell 列表中隐藏，原生会话文件会保留。") }
    }

    private func historyRow(_ thread: ThreadSummary) -> some View {
        HStack(spacing: 12) {
            Button {
                store.selectedId = thread.id
                navigation.visit(.home, threadID: thread.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left").font(.system(size: 17)).foregroundStyle(Theme.textTertiary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(thread.title).font(.system(size: 14)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text("\(thread.engine.displayName) · \(ThreadStore.displayName(for: thread.cwd))")
                            .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Text(thread.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button("打开对话") { store.selectedId = thread.id; navigation.visit(.home, threadID: thread.id) }
                Button("重命名…") { renaming = thread; renameText = thread.title }
                if thread.engine == .codex {
                    Button("用 Claude 接管") {
                        Task { await store.takeoverWithClaude(thread.id); if store.takeoverError == nil { navigation.visit(.home, threadID: store.selectedId) } }
                    }.disabled(store.takingOverId != nil)
                }
                Divider()
                Button("隐藏对话…") { hiding = thread }
                    .disabled(store.controllers[thread.id]?.isWorking == true)
            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(thread.title) 的选项")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(store.selectedId == thread.id ? Theme.selectedFill : Color.clear))
    }
}

struct WorkspaceLibraryPage: View {
    @Environment(WorkspaceContentStore.self) private var content
    @Environment(ThreadStore.self) private var store
    @Environment(WorkspaceNavigation.self) private var navigation
    @State private var query = ""
    @State private var kind = "all"
    @State private var failure: String?

    private var assets: [WorkspaceAsset] {
        content.assets.filter {
            (kind == "all" || (kind == "images" ? $0.isImage : !$0.isImage)) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }.sorted { $0.addedAt > $1.addedAt }
    }

    var body: some View {
        WorkspacePageSurface {
            WorkspacePageHeading("资料库", subtitle: "保存导入文件与会话产物，在一个地方再次打开。") {
                Button { content.importFiles(threadID: nil) } label: { Label("添加文件", systemImage: "plus") }
                    .buttonStyle(WorkspacePageButtonStyle(prominent: true))
            }
            HStack(spacing: 12) {
                WorkspacePageSearch(text: $query, placeholder: "搜索文件")
                Picker("类型", selection: $kind) {
                    Text("所有文件").tag("all")
                    Text("文档与其他").tag("documents")
                    Text("图片").tag("images")
                }.labelsHidden().frame(width: 125)
            }
            if assets.isEmpty {
                WorkspacePageEmpty(icon: "books.vertical", title: query.isEmpty ? "文件都在这里" : "没有匹配的文件",
                                   message: query.isEmpty ? "添加本机文件，或把聊天产物保存到资料库。文件保留在原位置。" : "试试其他文件名或更改类型筛选。")
            } else {
                VStack(spacing: 0) {
                    ForEach(assets) { asset in
                        libraryRow(asset)
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 48)
                    }
                }
            }
        }
        .alert("无法打开文件", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func libraryRow(_ asset: WorkspaceAsset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: asset.isImage ? "photo" : "doc.text").font(.system(size: 21)).foregroundStyle(Theme.textTertiary)
                .frame(width: 30, height: 38)
            Button { open(asset) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(asset.name).font(.system(size: 14)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(sourceLabel(asset)).font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(asset.addedAt, format: .dateTime.month(.abbreviated).day())
                .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            Menu {
                Button("打开") { open(asset) }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([asset.url]) }
                if let id = asset.threadID, store.summary(for: id) != nil {
                    Button("打开来源对话") { store.selectedId = id; navigation.visit(.home, threadID: id) }
                }
                Divider()
                Button("从资料库移除") { content.remove(id: asset.id) }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(asset.name) 的选项")
        }.padding(.vertical, 12).padding(.horizontal, 4)
    }

    private func sourceLabel(_ asset: WorkspaceAsset) -> String {
        if let id = asset.threadID, let thread = store.summary(for: id) { return thread.title }
        return ThreadStore.displayPath(for: asset.url.deletingLastPathComponent().path)
    }

    private func open(_ asset: WorkspaceAsset) {
        guard FileManager.default.fileExists(atPath: asset.url.path), NSWorkspace.shared.open(asset.url) else {
            failure = "文件可能已移动或删除：\(asset.name)。你可以从资料库移除记录，再添加新的文件位置。"
            return
        }
    }
}

struct WorkspaceImagesPage: View {
    @Environment(WorkspaceContentStore.self) private var content
    @Environment(ThreadStore.self) private var store
    @Environment(WorkspaceNavigation.self) private var navigation
    @State private var query = ""
    @State private var failure: String?
    private var images: [WorkspaceAsset] {
        content.assets.filter { $0.isImage && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.addedAt > $1.addedAt }
    }

    var body: some View {
        WorkspacePageSurface {
            WorkspacePageHeading("图片", subtitle: "你的图片与视觉创作。") {
                Button(action: importImages) { Label("添加图片", systemImage: "plus") }
                    .buttonStyle(WorkspacePageButtonStyle())
                Menu {
                    Button("用 Codex 开始") { newImageConversation(.codex) }.disabled(store.codexMissing)
                    Button("用 Claude 开始") { newImageConversation(.claude) }.disabled(store.claudeMissing)
                } label: { Text("开始创作") }
                    .menuStyle(.borderlessButton).fixedSize().buttonStyle(WorkspacePageButtonStyle(prominent: true))
            }
            WorkspacePageSearch(text: $query, placeholder: "搜索图片")
            if images.isEmpty {
                WorkspacePageEmpty(icon: "photo.on.rectangle.angled", title: query.isEmpty ? "从一张图片开始" : "没有匹配的图片",
                                   message: query.isEmpty ? "添加本机图片，或在对话中使用引擎已连接的图像工具创作。" : "试试其他图片名称。")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 360), spacing: 18)], spacing: 22) {
                    ForEach(images) { asset in
                        VStack(alignment: .leading, spacing: 9) {
                            Button {
                                if !NSWorkspace.shared.open(asset.url) { failure = "无法打开 \(asset.name)，文件可能已移动或删除。" }
                            } label: { WorkspaceAssetThumbnail(url: asset.url).frame(height: 180).frame(maxWidth: .infinity) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([asset.url]) }
                                    Button("从资料库移除") { content.remove(id: asset.id) }
                                }
                            Text(asset.name).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").padding(.top, 1)
                Text("图片生成由对话引擎已连接的工具提供；此页面整理本机图片，不包含独立的云端图像服务。")
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(.top, 8)
        }
        .alert("无法打开图片", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func newImageConversation(_ engine: ConversationEngine) {
        let id = store.newThread(engine: engine)
        navigation.visit(.home, threadID: id)
    }

    private func importImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加图片"
        panel.message = "只保存图片引用，原文件保留在原位置。"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { content.add(url: url, threadID: nil) }
    }
}

/// Loading is limited to the explicitly catalogued URL, never a filesystem scan.
private struct WorkspaceAssetThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Theme.cardFill)
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(6)
            } else {
                Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(Theme.textTertiary)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 14))
            .task(id: url) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 640,
                      ] as CFDictionary) else { image = nil; return }
                image = NSImage(cgImage: thumbnail, size: .zero)
            }
            .accessibilityLabel(url.lastPathComponent)
    }
}

struct WorkspaceAppsPage: View {
    @Environment(ThreadStore.self) private var store
    @Environment(AccountStore.self) private var accounts
    @Environment(WorkspaceNavigation.self) private var navigation

    var body: some View {
        WorkspacePageSurface {
            WorkspacePageHeading("应用", subtitle: "连接本机引擎，管理在 Claudex Shell 中使用的账号。") {
                Menu { AccountMenuItems() } label: { Label("管理连接", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            WorkspacePageSection("对话引擎") {
                engineRow(.codex, name: "Codex", subtitle: "使用原生 Codex 会话、工具调用与审批。", missing: store.codexMissing)
                WorkspacePageSeparator()
                engineRow(.claude, name: "Claude Code", subtitle: "使用原生 Claude Code 会话，并支持 GLM / API 提供方。", missing: store.claudeMissing)
            }
            WorkspacePageSection("已保存的账号") {
                if accounts.accounts.isEmpty && accounts.codexAccounts.isEmpty && accounts.providers.isEmpty {
                    Text("尚未保存账号。可以导入本机登录态，或添加 Claude / API 账号。")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).padding(.vertical, 12)
                }
                ForEach(accounts.codexAccounts) { account in
                    accountRow(name: account.email, provider: "Codex", detail: account.planLabel, selected: account.id == accounts.activeCodexId) {
                        Task { await accounts.switchToCodex(account.id) }
                    }
                }
                ForEach(accounts.accounts) { account in
                    accountRow(name: account.email, provider: "Claude", detail: account.planLabel,
                               selected: accounts.activeProviderId == nil && account.id == accounts.activeId) {
                        Task { await accounts.switchTo(account.id) }
                    }
                }
                ForEach(accounts.providers) { provider in
                    accountRow(name: provider.name, provider: "GLM / API", detail: provider.model ?? provider.host,
                               selected: provider.id == accounts.activeProviderId) {
                        Task { await accounts.switchToProvider(provider.id) }
                    }
                }
                HStack(spacing: 10) {
                    Button("保存本机登录态") { Task { await accounts.importLocalAccounts() } }
                        .buttonStyle(WorkspacePageButtonStyle()).disabled(accounts.busy != nil)
                    Menu("添加账号") {
                        Button("Claude 账号…") { accounts.beginLogin() }
                        Button("GLM / API 提供方…") { accounts.addingProvider = true }
                    }.menuStyle(.borderlessButton).fixedSize()
                        .disabled(accounts.busy != nil || accounts.loginSession != nil || accounts.addingProvider)
                }.padding(.top, 10)
                if let note = accounts.switchNote { Text(note).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.top, 8) }
            }
            WorkspacePageSection("更多应用与工具") {
                Text("工具和 MCP 连接沿用所选引擎的本机配置。ChatGPT 云端应用目录与授权不由本机 CLI 提供，无法在这里直接复制连接。")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Button("在对话中使用已配置的工具") {
                    let id = store.newThread()
                    navigation.visit(.home, threadID: id)
                }.buttonStyle(WorkspacePageButtonStyle()).padding(.top, 12)
            }
        }
    }

    private func engineRow(_ engine: ConversationEngine, name: String, subtitle: String, missing: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: engine == .codex ? "terminal" : "asterisk")
                .font(.system(size: 23, weight: .medium)).frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.chipFill))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 15, weight: .medium))
                    Text(missing ? "未检测到" : "可用").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                Text(missing ? "请先在本机安装 \(name)，然后刷新检测。" : subtitle)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if missing {
                Button("重新检测") { Task { await store.refreshEngineAvailability() } }.buttonStyle(WorkspacePageButtonStyle())
                    .disabled(store.isScanning)
            } else {
                Button("开始聊天") {
                    let id = store.newThread(engine: engine)
                    navigation.visit(.home, threadID: id)
                }.buttonStyle(WorkspacePageButtonStyle())
            }
        }.padding(.vertical, 14)
    }

    private func accountRow(name: String, provider: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(String(name.prefix(1)).uppercased()).font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32).background(Circle().fill(Theme.chipFill))
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                Text(detail.map { "\(provider) · \($0)" } ?? provider).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if selected {
                Label("正在使用", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            } else {
                Button("使用", action: action).buttonStyle(WorkspacePageButtonStyle()).disabled(accounts.busy != nil)
            }
        }.padding(.vertical, 10)
    }
}

struct WorkspaceSettingsPage: View {
    @Environment(ThreadStore.self) private var store
    @Environment(AccountStore.self) private var accounts
    @Environment(WorkspaceNavigation.self) private var navigation
    @AppStorage("workspaceAppearance") private var appearance = "system"
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }

    var body: some View {
        WorkspacePageSurface {
            WorkspacePageHeading("设置", subtitle: nil) { EmptyView() }
            WorkspacePageSection("通用") {
                HStack(spacing: 20) {
                    settingDescription("外观", detail: "选择浅色、深色，或跟随系统。")
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }.labelsHidden().frame(width: 140)
                }.padding(.vertical, 16)
                WorkspacePageSeparator()
                HStack(spacing: 20) {
                    settingDescription("默认对话引擎", detail: "用于之后的新聊天，已有对话保持原引擎。")
                    Picker("默认引擎", selection: Binding(get: { store.defaultSettings.engine }, set: { setDefaultEngine($0) })) {
                        Text("Codex").tag(ConversationEngine.codex)
                        Text("Claude").tag(ConversationEngine.claude)
                    }.labelsHidden().frame(width: 140)
                }.padding(.vertical, 16)
            }
            WorkspacePageSection("账号与登录态") {
                HStack(alignment: .center, spacing: 20) {
                    settingDescription("管理账号", detail: "保存、切换 Claude、GLM 与 Codex 账号。")
                    Button("管理") { navigation.visit(.apps) }.buttonStyle(WorkspacePageButtonStyle())
                }.padding(.vertical, 16)
                WorkspacePageSeparator()
                HStack(alignment: .center, spacing: 20) {
                    settingDescription("推送登录态", detail: "应用内切换只影响 Claudex Shell。通过此菜单推送到终端或 Codex App。")
                    Menu { AccountMenuItems() } label: { Text("账号与推送") }
                        .menuStyle(.borderlessButton).fixedSize()
                }.padding(.vertical, 16)
            }
            WorkspacePageSection("关于") {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Claudex Shell").font(.system(size: 15, weight: .medium))
                        Text("版本 \(version)（\(build)）").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }.padding(.vertical, 14)
                Text("原生 Claude Code 与 Codex 引擎；本机账号、会话和资料库。")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func settingDescription(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 14))
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setDefaultEngine(_ engine: ConversationEngine) {
        guard engine != store.defaultSettings.engine else { return }
        // The setting applies to the next conversation; do not mutate or create a
        // controller merely to persist a preference. A different engine gets its
        // own default model rather than inheriting an incompatible model ID.
        var settings = ThreadSettings(engine: engine)
        settings.permissionMode = store.defaultSettings.permissionMode
        store.defaultSettings = settings
        if let data = try? JSONEncoder.standard.encode(settings) {
            UserDefaults.standard.set(data, forKey: "defaultThreadSettings")
        }
    }
}

private struct WorkspacePageSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { content }
                .padding(.horizontal, 40).padding(.top, 44).padding(.bottom, 48)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }.background(Theme.background).foregroundStyle(Theme.textPrimary)
    }
}

private struct WorkspacePageHeading<Actions: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var actions: Actions
    init(_ title: String, subtitle: String?, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.subtitle = subtitle; self.actions = actions()
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) { heading; Spacer(minLength: 8); HStack(spacing: 10) { actions } }
            VStack(alignment: .leading, spacing: 18) { heading; HStack(spacing: 10) { actions } }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 28, weight: .regular))
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct WorkspacePageSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary).padding(.bottom, 12)
            WorkspacePageSeparator()
            content
        }
    }
}

private struct WorkspacePageSeparator: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

private struct WorkspacePageSearch: View {
    @Binding var text: String
    let placeholder: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 13))
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }.padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.chipFill))
    }
}

private struct WorkspacePageEmpty: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 32, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text(title).font(.system(size: 20))
            Text(message).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }.frame(maxWidth: .infinity).padding(.vertical, 76)
    }
}

private struct WorkspacePageButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Theme.sendFg : Theme.textPrimary)
            .padding(.horizontal, 13).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(prominent ? Theme.sendFill : configuration.isPressed ? Theme.selectedFill : Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(prominent ? Color.clear : Theme.line, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}
