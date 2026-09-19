# Claude Shell

*给你本机那个 Claude Code 套一层安静的原生壳。*

[English](README.md) · **简体中文** · [繁體中文](README.zh-Hant.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [Español](README.es.md) · [Deutsch](README.de.md)

Claude Shell 是一个小小的 macOS app，给你本机的 Claude Code 命令行套上一张 Codex 风格的脸。左边是 `~/.claude/projects` 里的全部会话，按项目分组——包括你在终端里开的那些。右边是当前对话：Markdown 正文、可折叠的思考与工具步骤、权限审批卡。底下跑的就是 `~/.local/bin/claude`，所以模型、权限模式、`CLAUDE.md`、记忆、技能、MCP、hooks，全都和你终端里的一模一样。

## 它只是个壳——而这正是重点

它不重写 Claude Code，不自带模型客户端，不另搞一套登录，也不复制一份你的数据。它启动的就是你本来就信任的那个 `claude`，读的就是它本来就在写的会话文件。app 自己只在 `~/Library/Application Support/Claude Shell/` 下存四样极小的东西：改的标题、隐藏标记、每个对话的设置、你保存过的账号列表（身份信息在一个 JSON 里，令牌在你的登录钥匙串里）。对话内容永远以 `~/.claude` 为准，除了命令行本来就会发的，没有任何东西离开你的机器。

于是你得到一个真正的原生窗口——Dock 图标、⌘N、一个像样的输入框——却没有把比命令行更宽的文件或数据权限交给任何人。同一条信任边界，只是换了张更好看的脸。

## 它能做什么

- **实时跟着终端走。** 终端里正在跑的会话带一个绿点；点开它，Claude Shell 就 tail 会话文件，那边的每一步都在这里实时出现。
- **把话说回终端里。** 在终端里开着的会话里输入，你这句话会经 Claude Code 自己的跨会话消息投进那个会话——终端里回答，回答再同步回这里。
- **终端显示什么，这里就显示什么。** recap 摘要、别的会话投来的消息、插队输入、上下文压缩提示、思考行上的强度。
- **拖文件、拖照片、⌘V 贴图。** 把文件、照片或整个目录拖到窗口里（或点输入框左下角的「+」、直接粘贴截图），它们挂在输入框上，随这条消息一起发。图片直接以图片块交给 Claude（HEIC 之类自动转成 JPEG、按 API 上限缩小）；文件和目录按 Claude Code 自己的 `@路径` 写法引用——文本文件和目录列表会自动附上，PDF 等由 Claude 自己去读。终端里粘贴过的图片在这里也显示成缩略图。
- **模型和强度都明着写。** 胶囊和工具栏永远显示当前真正生效的值（`Opus 5 (1M) · xhigh`），包括 `ultracode`——不藏在「跟随设置」后面。
- **一个对话一个进程**，保持温热，空闲后用 `--resume` 拉起。
- **多个账号，一下切换。** 第二个 Claude 账号只需添加一次（走 CLI 自己的 `claude auth login`，在浏览器里登录）；之后在侧栏底部选一个，或按 ⌃1…⌃9。切换会把保存的登录态写回 Claude Code 自己的钥匙串条目，终端也跟着换——已经开着的会话下一次请求就用新账号，不用重开、不用开浏览器、不用重新登录。

## 跑起来

```
./scripts/build.sh            # Debug 构建到 DerivedData/
./scripts/install.sh          # Release 构建 → /Applications → 加进 Dock
./scripts/shot.sh out.png     # 截运行中的窗口
```

快捷键：⌘N 新对话 · ⇧⌘N 在文件夹中新建 · ⏎ 发送 · ⇧⏎ 换行 · ⌘. 停止 · ⌘R 刷新 · ⌃1…⌃9 切换账号。

## 底层

- Swift 6 + SwiftUI + AppKit，工程由 XcodeGen 生成，无第三方 Swift 依赖。
- 正文用 `WKWebView` 渲染，marked + highlight.js 随包内置、不联网。
- 不进沙盒（要起子进程、读 `~/.claude`），Sign to Run Locally。
- 跨会话投递、stream-json 协议、账号切换、设计系统都写在 `docs/` 和 `DESIGN.md` 里。

## 结构

```
App/Sources/Engine/   子进程、stream-json → 事件、跨会话投递
App/Sources/Model/    一个对话、会话列表、transcript 数据模型
App/Sources/UI/       侧栏、对话页、输入卡、审批卡、主题
App/Resources/web/    transcript.html / .css / .js —— 对话正文
docs/ · DESIGN.md · PRODUCT.md   协议笔记、设计系统、产品记录
```

需要 macOS 15+ 和装好的 Claude Code（`~/.local/bin/claude`）。
