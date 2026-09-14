# Claude Shell

给本机 Claude Code 套的一个 Codex 风格 macOS 壳：左侧是 `~/.claude/projects` 里的全部会话（按项目目录分组），
右侧是当前对话——Markdown 正文、折叠的思考与工具步骤、权限审批卡，底部一张输入卡。底下跑的就是
`~/.local/bin/claude`，所以模型、权限模式、CLAUDE.md、记忆、技能、MCP、hooks 都和终端里一模一样。

- 仓库：`~/Developer/ClaudeShell`，Swift 6 + SwiftUI + AppKit，XcodeGen 生成工程，无第三方 Swift 依赖。
- 正文渲染：WKWebView + `App/Resources/web/`（marked 15 + highlight.js 11 随包内置，不联网）。
- 不进 App Sandbox（要起子进程、读 `~/.claude`），Sign to Run Locally。

## 日常

```
./scripts/build.sh            # Debug 构建到 DerivedData/
./scripts/install.sh          # Release 构建 → /Applications/Claude Shell.app → 加进 Dock
./scripts/shot.sh out.png [--dark|--light] [--restart]   # 截运行中的主窗口（改完界面必须看；窗口在别的桌面也能截）
swift scripts/web-preview/snapshot.swift scripts/web-preview/preview.html out.png [dark]   # 只看网页层：离屏渲染固定样张
swift scripts/export-symbols.swift App/Resources/web/icons   # 改了正文用的图标后重新导出
```

快捷键：⌘N 新对话、⌘⇧N 在文件夹中新建、⏎ 发送、⇧⏎ 换行、⌘. 停止、⌘R 刷新列表。

## 结构

```
App/Sources/Engine/   ClaudeProcess（子进程 + stdin/stdout）、ClaudeEvents（stream-json → 事件）、
                      ShellEnvironment（登录 shell 的 PATH、找 claude）、JSONValue
App/Sources/Model/    ConversationController（一个对话：transcript + 进程 + 审批）、ThreadStore（会话列表、草稿、设置）、
                      SessionIndex（扫描会话文件头尾出标题）、SessionLoader（整份历史回放）、Transcript（数据模型）
App/Sources/UI/       ClaudeShellApp（入口 + 方向契约）、ContentView、SidebarView、ThreadView（空态 + 对话页）、
                      ComposerView（输入卡 + NSTextView 包装）、PermissionCard、TranscriptWebView（桥）、Theme
App/Resources/web/    transcript.html / .css / .js —— 对话正文；icons.css 与 icons/ 由 scripts/export-symbols.swift 生成（SF Symbols 蒙版）
docs/protocol.md      stream-json 协议实测笔记
PRODUCT.md / DESIGN.md   impeccable 的产品记录与设计系统
```

## 关键约定

- 一个对话一个 `claude -p` 进程，切换对话不杀；空闲 20 分钟回收，下次发送 `--resume`。
- 新对话默认在家目录；发第一条消息前可换目录，之后不能换（Claude Code 的会话属性）。
- 每对话可选模型 / 权限模式 / 强度，改动下一轮生效；上次的选择成为新对话的默认。
  胶囊和工具栏右上角永远写具体生效的值（`Opus 5 (1M) · xhigh`），「跟随终端设置 / 默认强度」只是菜单里的选项：
  终端默认强度启动时问 `claude` 本尊（`ClaudeDefaults` 探测，settings.json 变了会重问），默认模型读 settings.json，
  对话跑过一轮后以 `system/init` 报的 model 为准。悬停胶囊看原始 id 和来源。
- 强度里的 `ultracode`（xhigh + 动态多代理工作流）不是 `--effort` 的取值，走 `--settings '{"ultracode":true}'`；
  需要模型支持 xhigh（haiku 会被静默降级）。
- 终端里正在跑的会话（`~/.claude/sessions/*.json`，`entrypoint == "cli"`）在列表里带绿点。选中它，app 不起自己的进程，
  而是**旁观**：每秒 tail 会话文件，终端那边的每一步（含终端里用户打的字、别的会话投来的消息）都同步显示，忙碌时底部有
  「终端里正在运行…」。在这里输入的话会**投进终端里那个会话**（跨会话消息协议，`PeerMessenger`）：终端里显示为
  `› Message from @Claude Shell: …`，那边的 Claude 在终端里回答，回答再 tail 回来。模型 / 权限 / 强度胶囊此时只看不改
  （由终端决定）。对方是 bypassPermissions 会话时终端会先弹一次「是否接收」。终端退出后，这里可以 `--resume` 续聊。
- app 自己只存两样东西（`~/Library/Application Support/Claude Shell/`）：标题改名 / 隐藏 / 每对话设置，
  以及扫描缓存。会话内容永远以 `~/.claude` 为准。
- 颜色 token 在 `Theme.swift` 和 `transcript.css` 各有一份，改一处要改两处。

## 自动化验证（不发全局键鼠事件）

```
open -n "DerivedData/Build/Products/Debug/Claude Shell.app" --args \
  -testPrompt "…"            # 启动后直接把这句话发出去
  -testModel haiku           # 配合 testPrompt；写 terminal 表示跟随终端设置
  -testMode manual           # 配合 testPrompt
  -testEffort ultracode      # 配合 testPrompt；写 terminal 表示默认强度
  -testAutoApprove 7         # 审批卡显示 7 秒后自动放行
  -testSelect <sessionId>    # 启动后选中某个已有会话（看历史回放）
  -testExpandAll 1           # 把正文里所有折叠区展开
  -testMarkedText "ciao"     # 启动 1.5 秒后在输入卡里模拟输入法组字（看占位符 / 发送键在组字期间的表现）
  -testMarkedCommit "你好"   # 配合 testMarkedText：再过 3 秒把组字上屏
  -testLog 1                 # 写 /tmp/claude-shell-test.log
```
