# Claudex Shell 账号与推送

## 应用内选择

默认的账号选择只写 Claudex Shell 的选择记录和私有运行配置，不改本机终端或 Codex App 的登录态。

- Claude：每个订阅账号使用私有 `CLAUDE_CONFIG_DIR` 和独立的 Claude Code Keychain 条目。
- GLM / API：通过 Claude 引擎运行；每个提供方有独立配置，密钥由 Keychain helper 提供。
- Codex：每个账号使用私有 `CODEX_HOME`；其 `auth.json` 权限为 0600，目录为 0700。保存的完整认证快照在 Keychain。

独立的**认证配置**与原生**会话存储**分开：运行目录引用 CLI 自己的会话目录，新建与恢复仍由 Claude Code / Codex 引擎完成。应用只读索引和展示记录，不改写 rollout 或自行模拟引擎。

Claude 的全局 `CLAUDE.md`、Codex 的 `AGENTS.md` / `AGENTS.override.md` 与各自规则目录继续引用本机原文件。Codex 的顶层模型、推理强度和上下文相关默认值同步至运行配置；认证路由仍固定为所选账号，不整体复制提供方、插件、MCP 或技能配置。

当前正在生成的回复继续使用启动它的账号；应用内换号后，下一个回合重建进程并使用新选择。运行在外部终端的 Claude 会话仍由那个终端的账号处理，输入框会注明这一点。

## 保存本机登录态

「保存本机登录态（Claude / GLM / Codex）」读取本机配置：

- Claude 的 `oauthAccount` 与 Claude Code Keychain 登录态；
- 已存在的 GLM/API 提供方配置，或本机的兼容 API 地址、静态密钥、可识别的只读 Keychain helper；
- Codex 的 `auth.json`，支持 ChatGPT OAuth 和 API key 文件登录。

不会执行任意 `apiKeyHelper` shell 脚本来获取密钥。未知 helper 需要通过「添加 GLM / API 提供方」手动保存。

Codex 若配置为 `keyring`、`auto` 或 `ephemeral`，此版本会明确拒绝文件导入/推送，避免改了 `auth.json` 却假报成功；需要先用其原生登录功能创建 file 模式缓存。当前本机使用默认 file 模式。

保存时比较已知刷新时间，避免旧快照覆盖更新后的令牌。读取错误不作为“空登录态”写回。JWT 内容只用作显示账号标签，不作为登录成功的验证。

0.4.2 对较长的应用内凭据采用钥匙串分段快照：各段完成写入和校验后才更新索引，读取时校验完整性，避免 `security -i` 的输入行长度上限截断 OAuth 登录态。完整数据仍只在本机钥匙串中，旧格式可继续读取。外部工具拥有的共享凭据若超出可安全写入的长度，会在写入前拒绝操作。

## 显式推送

| 动作 | 影响范围 | 生效方式 |
|---|---|---|
| 切换 Claude / GLM / Codex 账号 | Claudex Shell | 后续应用内回合 |
| 推送 Claude / GLM 至终端 | 本机 Claude Code 的共享配置 | 建议新开 CLI 会话；已有 shell 环境变量仍可能覆盖配置 |
| 推送 Codex 至终端 | Codex CLI 登录文件 | 核验所选身份；新 CLI 进程读取，运行中的桌面端不切换 |
| 推送并重启 Codex App | 本机 Codex / ChatGPT 桌面端及 Codex CLI | 确认中断任务后，正常退出桌面端、写入并核验、后台重新启动 |
| 撤回上次推送 | 恢复上次推送前的目标文件和凭据 | 如目标在推送后被改过，拒绝盲目覆盖 |

0.4.3 将 CLI 文件推送与桌面端切换分开。旧版只写 `auth.json`，运行中的桌面端继续持有旧账号缓存，因此不能把文件写入报告成桌面端已切换。

桌面端操作先展示所选账号和中断任务提示；确认后正常退出 `com.openai.codex` 对应的 Codex / ChatGPT 应用。退出超时、拒绝退出或多个实例不明确时停止，不强杀，不改写账号。退出后重新读取最新凭据，避免客户端退出时的刷新覆盖推送；校验完成后以 `activates=false` 和 `CODEX_ELECTRON_START_IN_BACKGROUND=1` 后台重新启动。终端窗口不受控制。

推送计划保留所选账号在钥匙串、私有运行目录、本机文件中的最新已知登录态；另一账号的凭据不会混入。计划记录原文件内容，发现并发变化就停止。写入后再次验证文件中的账号身份。状态分别说明“文件已核验”和“桌面端已重启”；桌面端头像中的实际身份仍需核对，不冒充热切换或界面验收。

撤回仍恢复认证文件，不自动重启外部客户端；撤回后需重新打开客户端载入原账号。

## 备份与错误恢复

推送事务先将原值和计划写入的摘要保存至独立 Keychain 备份，再执行写入。磁盘标记只保存编号和标签；待完成事务与最近成功事务分别记录。新推送失败时保留上一次成功推送的撤销记录；中断或部分恢复失败后，可以再次点击撤销继续恢复。

撤回时接受原值或本次计划写入的值。如果用户或原生 CLI 随后改过文件、刷新过凭据，则保留这些更新并提示备份仍在。读取备份失败不会被当成不存在的凭据覆盖回去。

配置写入保留无关设置；合法软链接写到其原目标。损坏的元数据在建立新清单前另存备份。原有 provider backup 迁移至 Keychain，迁移成功后才移除旧清单中的备份。

## 兼容旧版与位置

显示名改为 **Claudex Shell**，保留：

- bundle ID：`com.skywalker.claudeshell`；
- 元数据根：`~/Library/Application Support/Claude Shell/`；
- 旧 Claude 账号条目：`Claude Shell-account-<id>`；
- 旧 API 提供方条目：`Claude Shell-provider-<id>`，外部条目如 `zhipu-api-key` 继续引用。

新数据包括 `codex-accounts.json`、`runtime/claude/`、`runtime/codex/` 和不含秘密的推送标记。

## 验证

`scripts/test.sh` 用临时文件和内存凭据存储验证：隔离登录目录、原生会话目录引用、刷新凭据保留、错误配置保护、事务恢复、撤回冲突与凭据不落入清单。测试不访问真实 Keychain，不更改当前账号，也不发送推理请求。

参考：[Codex authentication](https://learn.chatgpt.com/docs/auth)、[Codex App Server](https://learn.chatgpt.com/docs/app-server)。
