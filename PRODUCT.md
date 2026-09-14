# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

（说明：Apple 原生平台，实际是 macOS 15+ 的 SwiftUI app，只出 Mac 版。结构与交互以 macOS HIG 为准：原生侧栏 + 内容区、统一工具栏、菜单栏与快捷键。ios.md 的规则按 macOS 映射使用。）

## Stack

用户指定"用 mac 原生的工具"：Swift 6 + SwiftUI + AppKit，工程由 XcodeGen 生成，无第三方 Swift 依赖。对话正文用 WKWebView 渲染 Markdown（marked + highlight.js 随包内置，不联网），侧栏、工具栏、输入框、审批卡都是原生 SwiftUI。不用 App Sandbox：app 要启动 `claude` 子进程并读 `~/.claude/projects`。

## Users

一位量化公司创始人（也是本机唯一用户），整天在 Mac 上用 Claude Code 干活。他在终端里已经用得很熟，缺的只是一个更好读 Markdown 的外壳：终端里长回答的表格、代码块、层级看着累。使用场景：Dock 里点一下，立刻出现一个像 Codex 桌面版一样的新对话页面，输入需求，看着 Claude 思考、调工具、回答；随时切到左侧另一个对话继续。

## Product Purpose

给 Claude Code 套一个 Codex 风格的桌面壳。底下跑的就是本机的 `claude` CLI（`-p --input-format stream-json --output-format stream-json`），所以模型、权限模式、CLAUDE.md、记忆、技能、MCP、hooks 都与终端一致；上面多的只是可读的排版和一个对话列表。成功的样子：用户从此更愿意在这个壳里读 Claude 的回答，而不是回终端。

## Positioning

- 不是另一个 AI 客户端，而是**终端会话本身的窗口**：左侧列出 `~/.claude/projects` 里所有会话（终端里开的也在），任何一个都能在这里续聊，反过来终端里 `claude --resume` 也能接着聊。
- 比 Claude 桌面 app 少：没有账户页、没有 Cowork、没有 Chrome 集成入口。只有对话列表、对话、输入框。
- 思考过程（thinking）、工具调用、权限审批都与终端同一套，只是渲染成折叠区块和审批卡，而不是文字流。

## Operating Context

- Claude Code 2.1.x 已安装在 `~/.local/bin/claude`；用户默认权限模式是 `auto`（见 `~/.claude/settings.json` 的 autoMode），默认模型跟随 settings.json。
- 会话文件：`~/.claude/projects/<按规则编码的 cwd>/<sessionId>.jsonl`；标题来源依次是 custom-title → ai-title → 首条用户消息。正在终端里跑的会话记在 `~/.claude/sessions/<pid>.json`。
- 协议要点（2026-09-13 实测）：`--permission-prompt-tool stdio` 才会把权限请求以 `control_request/can_use_tool` 发到 stdout，宿主回 `control_response`；`control_request/interrupt` 可打断；进程在多轮之间保持存活；`--resume <id>` 续接、`--session-id <uuid>` 指定新会话 id。
- 用户会同时开着终端里的 Claude Code 和这个 app。

## Capabilities and Constraints

- 每个对话对应一个 `claude` 子进程，切换对话不杀进程；空闲 20 分钟后回收，下次发送用 `--resume` 拉起。
- 终端里正在跑的会话不起进程：旁观（tail 会话文件同步显示）+ 投递（在这里输入的话经跨会话消息协议送进终端，那边回答）。
  用户 2026-09-13 明确要求"套壳里发消息要同步到终端里、对话同步"，不接受"那边结束后才能续聊"。
- 每对话可选：模型（跟随设置 / fable / opus / opus[1m] / sonnet / sonnet[1m] / haiku）、权限模式（auto / acceptEdits / manual / plan / bypassPermissions）、强度（默认 / low / medium / high / xhigh / max / ultracode）。改动在下一轮生效。
- 模型和强度必须明着显示（用户 2026-09-13 要求"像终端一样 explicit"）：胶囊与工具栏写具体生效值，不写"跟随设置"这种黑盒字样；来源放悬停提示。
- 新对话默认工作目录是家目录（和用户平时在终端启动的位置一致），可在发送第一条消息前换目录；会话开始后目录不可改（这是 Claude Code 的规则）。
- 不做：多窗口拖拽 diff 面板、文件树、账号管理、快捷指令面板、语音。
- UI 文案中文；日期不在当年的要带年份。
- 未决：是否要把终端里的 `/` 斜杠命令做进输入框（`-p` 模式下大部分斜杠命令不可用，先不做）。

## Brand Commitments

- 名字 **Claude Shell**，bundle id `com.skywalker.claudeshell`，仓库 `~/Developer/ClaudeShell`。
- 视觉：用户钦定"设计风格完全参考 Codex（OpenAI Codex 桌面版）"。这是一条绑定约束：左侧对话列表按项目分组、右侧居中的单列对话、底部圆角大输入框、无气泡的助手正文、灰色圆角的用户消息、折叠的"思考"与工具步骤。不加任何 Codex 没有的装饰。
- 图标：深色圆角方块上一枚陶土橙（Claude 的橙）的 `›_` 提示符，不用 Anthropic 的商标。

## Evidence on Hand

- 协议探针与实测输出：见 `docs/protocol.md`（从 scratchpad 的 probe 结果整理）。
- 用户本机没有安装 Codex 桌面版，只有 codex CLI 0.153.4；Codex 的版式依据是公开的桌面版界面记忆，没有像素级参考图。
- 没有 Codex 的字体、配色文件；一律用系统字体（SF Pro / PingFang SC）和系统语义色。

## Product Principles

1. 和终端完全同一个 Claude Code：不在壳里另做一套权限、记忆或提示词。
2. 壳只做三件事：列会话、渲染对话、收输入。功能上有疑问时选"不做"。
3. 会话文件是唯一真相：标题、历史、目录都从 `~/.claude` 读，app 自己只存标题改名和每对话设置。
4. 任何时候都能回终端：会话 id 可复制，`claude --resume` 就能接上。
5. 界面的每一处都以"熟悉 Codex 的人一眼认得"为准，不为了个性偏离。

## Accessibility & Inclusion

系统字体、系统语义色，随系统浅色/深色；正文与占位文字对比度 ≥ 4.5:1；全部操作可键盘完成（⌘N 新对话、⏎ 发送、⇧⏎ 换行、⌘. 停止）。
