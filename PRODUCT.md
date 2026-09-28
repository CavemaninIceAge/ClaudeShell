# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

Apple 原生平台；实际交付是 macOS 15+ 的 SwiftUI / AppKit 应用，遵循 macOS 窗口、菜单和快捷键习惯。

## Stack

Swift 6、SwiftUI、AppKit、XcodeGen，无第三方 Swift 依赖。Markdown 正文使用离线 WKWebView。Claude 使用 stream-JSON；Codex 使用本机 app-server JSON-RPC stdio。应用需要启动 CLI 和读取本机会话，未使用 App Sandbox。

## Users

熟悉 Claude Code 与 Codex 的 Mac 用户，希望在同一个清晰的工作台查看和继续本机对话，保存多种账号，并明确决定何时影响终端或桌面端。

## Product Purpose

Claudex Shell 是 Claude Code + Codex 的原生工作台。成功标准：两种引擎可新建、恢复、流式对话；Claude / GLM / Codex 登录态可保存；应用内切换与向外推送有明确边界。

## Positioning

- 以 Codex 桌面工作台为视觉与操作参照，保留原生窗口、紧凑项目侧栏、正文单列、折叠工具与输入框。
- 新对话选择引擎，已有对话固定引擎；引擎与账号是两个独立选择。
- 账号选择默认只影响本应用。推送至终端、推送至 Codex App 是单独操作。
- Codex CLI 与桌面端共用本机登录缓存，推送明确说明这一点和重启生效的可能性。

## Operating Context

- 本机 `claude` 和 `codex` CLI 通过登录 PATH 发现，不强制重装。
- 读取原来的 Claude 会话和本机 Codex rollout；原生会话目录共享，恢复直接交给原引擎，不复制或改写原始会话。
- 保留旧 bundle ID `com.skywalker.claudeshell` 与 `~/Library/Application Support/Claude Shell/` 元数据，改名不清空原数据。
- GLM 作为兼容 Anthropic 协议的提供方，通过 Claude 引擎运行。

## Capabilities and Constraints

- 保留 Claude Markdown、附件、工具流、审批、停止、终端会话旁观与消息投递。
- 外部终端会话始终由终端自身的账号执行，应用内选择不会替它换号，界面明确提示。
- Codex 接入基于安装版本支持的官方 app-server；本地历史包含用户可访问的 rollout 文件，不承诺云端 ChatGPT 历史同步。
- 保存登录态使用 Keychain；CLI 必需的私有运行文件使用 0700 目录和 0600 文件。清单不保存令牌。
- 向共享登录态推送前备份，写入失败尝试恢复；用户之后改过的配置不能被撤回操作盲目覆盖。
- Codex 会话可通过「用 Claude 接管」生成一个带来源链接的新 Claude Code 原生会话；完整可见正文和工具摘要作为私有上下文附件交给 Claude，原会话保留。
- 不通过重启其他应用实现账号推送。

## Development and Verification

- 用户始终保有屏幕与输入控制。构建、fixture 测试和离屏渲染在后台进行。
- 不启动可见窗口，不切换系统外观，不重启 Dock，不发送全局键鼠输入。
- 不使用 Chrome、Superpowers 或 Teacher。
- 测试使用临时目录、假凭据和模拟 app-server；不会真实推送本机账号，也不会发送付费模型请求。
