# Claudex Shell

一个同时接入本机 **Claude Code 与 Codex** 的原生 macOS 对话工作台，支持保存 Claude、GLM/API 提供方和 Codex 登录态。

## 怎么使用

1. 新建对话，在输入框选择 **Claude / Codex**。已经开始的对话固定使用原来的引擎，避免混用历史。
2. 在左下角账号菜单选择账号。选择只对 **Claudex Shell 内部**生效。
3. 要让本机命令行跟随时，再点 **推送至终端**。
4. 要给 Codex 桌面端使用，选择已保存的 Codex 账号，再点 **推送至 Codex App**。桌面端与 Codex CLI 共用登录缓存；已运行的客户端可能需要你重新打开。
5. **保存本机登录态**会收录本机 Claude、GLM/API 提供方和 Codex 配置。推送前保留备份，支持恢复上次推送。

要让 Claude 接手 Codex 的旧对话，在该会话右上角或侧栏右键菜单选择 **用 Claude 接管**，再输入接下来要做的事。Claudex Shell 会把此前正文整理为私有上下文文件，由新建的 Claude Code 原生会话读取；原 Codex 对话保留，并可通过「查看原对话」返回。

左侧按项目浏览与搜索两种引擎的历史，右侧统一显示 Markdown、工具步骤、审批和输入框。Claude 使用本机 stream-JSON 协议，Codex 使用官方 app-server 协议。

## 安装

需要 macOS 15+、Xcode、XcodeGen，以及要使用的 Claude/Codex CLI。

```sh
./scripts/build.sh Release
./scripts/test.sh
./scripts/install.sh
```

安装路径为 `/Applications/Claudex Shell.app`。安装脚本不打开应用、不结束当前会话、不改 Dock；如果目标应用正在运行，会保留现状并提示先退出。

升级保留旧 bundle ID 和 `~/Library/Application Support/Claude Shell/` 数据目录，不丢失原来的账号、标题和对话设置。旧的 `Claude Shell.app` 也会保留。

详细说明：[账号与推送](docs/accounts.md) · [对话协议](docs/protocol.md)
