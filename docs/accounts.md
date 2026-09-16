# 多账号：保存登录态、一键切换

2026-09-16 在 Claude Code 2.1.273 上实测。代码：`App/Sources/Engine/ClaudeAuth.swift`（登录态放哪）、
`Engine/KeychainCLI.swift`（钥匙串读写）、`Model/AccountStore.swift`（清单、切换、添加账号的登录流程）、
`UI/AccountViews.swift`（侧栏底部账号行、登录面板）。

## 结论

- Claude Code 的登录态 = 钥匙串一条 `Claude Code-credentials`（账户名 `$USER`，内容是 JSON：access / refresh token、
  过期时间、订阅类型）+ `~/.claude.json` 里的 `oauthAccount`（accountUuid、邮箱、组织）。两处一起换 = 换账号。
- app 给每个账号存一份**快照**：钥匙串 `Claude Shell-account-<accountUuid>`（内容和上面那条一模一样）+
  `~/Library/Application Support/Claude Shell/accounts.json`（只有身份信息，没有令牌）。
- **切换** = 把目标账号的快照写回 `Claude Code-credentials`，把它的 `oauthAccount` 写回 `~/.claude.json`。
  **终端里已经开着的会话会自动跟着换，不用重开、不用重登**（2026-09-16 实测，见下「终端会话跟随」）；
  app 自己起的 `claude` 进程当场收掉，下次发送 `--resume` 拉起就是新账号。
- 切换前先把当前登录态同步回它自己的快照（`sync`），所以在生效期间刷新过的令牌不会丢——切走再切回来拿的是最新的。
- 终端里 `/login` 换了账号，app 下次 `sync`（启动、激活、每 90 秒）自动收录，不用在 app 里再登一次。

## 终端会话跟随（2026-09-16 实测）

测法：把一个账号的快照写进沙盒配置目录（`CLAUDE_CONFIG_DIR` = 临时目录，钥匙串条目名跟着变），在那个目录里开会话，
中途用 app 切换沙盒里的登录态，看同一个没重启的会话报回来的**服务端数据**属于哪个账号（两个账号的用量指纹差别很大）。

| 会话形态 | 切换前 | 切换后（同一进程，没重启） |
|---|---|---|
| `claude -p` 长活进程 | `rate_limit_event`：five_hour 0.20 / seven_day 0.99 | 切换后 **0.2 秒**发出的那一轮：0.05 / 0.01 —— 已经是新账号 |
| 交互式 TUI（伪终端） | `/usage`：本会话 20% / 本周 99%；`/status` 邮箱 = 旧账号 | `/status` 邮箱当场变成新账号；跑完下一轮后 `/usage` 变成 6% / 1% |

结论：**下一次请求就用新账号**，没有观察到需要等待的缓存窗口。唯一的滞后是 `/usage` 面板里的数字要等下一轮才刷新
（面板自己缓存，不是登录态没换）。正在跑的那一轮用旧令牌跑完，不会中断。

app 切完会在侧栏账号行下面说一句「终端里 N 个会话已跟着换」（N = `~/.claude/sessions` 里活着的终端会话数）。

## 添加账号（不碰当前登录态）

钥匙串条目名的规则（2.1.273 源码）：设了 `CLAUDE_CONFIG_DIR`（且没设 `CLAUDE_SECURESTORAGE_CONFIG_DIR`）时，
条目名变成 `Claude Code-credentials-<sha256(配置目录, NFC)[0..<8]>`，`.claude.json` 也搬到 `$CLAUDE_CONFIG_DIR/.claude.json`。
所以「添加账号」是：

1. 建临时目录 `~/Library/Application Support/Claude Shell/login-<uuid>/`，用 `CLAUDE_CONFIG_DIR=<它>` 起
   `claude auth login --claudeai`。新账号会写进一条独立的钥匙串条目，当前账号纹丝不动。
2. `claude auth login` 的流程是固定的「贴授权码」：打开浏览器 → 用户登录 → 页面（`platform.claude.com/oauth/code/callback`）
   给一串授权码 → 贴回 stdin（提示 `Paste code here if prompted >`）→ 退出码 0。有没有 TTY 都一样（用 `script` 包一层也不走
   localhost 回调），所以面板上就是一个「授权码」输入框。
3. 退出 0 后：读临时条目 + 临时 `.claude.json` 的 `oauthAccount` + `claude auth status --json`，写成快照，删掉临时条目和目录，
   然后直接切到新账号。
4. 登录到一半取消 / 退出 app：杀掉 `claude auth login`（它不会因为 stdin 关了自己退出），临时东西下次启动时扫掉。

## 钥匙串为什么走 `security` 命令

Claude Code 自己就是用 `/usr/bin/security` 写钥匙串的，条目的访问控制里只有 `security`。app 若用 Security.framework 直接读，
每条都会弹「Claude Shell 想访问…」。走 `security -i`（交互模式，命令从 stdin 喂）既不弹窗，令牌也不出现在进程参数里。
`add-generic-password -U` 原地更新，创建时间和访问控制都保留（实测 cdat 不变）。

## 边界

- 只支持 claude.ai 订阅账号（`--claudeai`）。Console / API key 账号（`--console`、`ANTHROPIC_API_KEY`）不在清单里，也不会被收录。
- 「移除账号」只删快照，不动本机当前登录态；正在生效的账号不能删，先切走。
- `~/.claude.json` 是整个读出来、只改 `oauthAccount`、再原子写回（0600、按键排序、缩进两格）。Claude Code 自己也频繁写这个文件，
  理论上有极小的写覆盖窗口，只影响它当时正在改的那一个键。
- 残余风险：切换的同一瞬间，某个终端会话如果正好在刷新旧账号的令牌并写回钥匙串，可能盖掉刚写进去的新账号令牌；
  下次 `sync` 会把那份令牌记到新账号名下（身份对不上）。窗口只有一次写入的宽度，实测没撞上过。
  真撞上了：把两个账号各重新添加一次。
- 沙盒验证：`open -n "Claude Shell.app" --args -testClaudeConfigDir <临时目录> -testAccountsFile <临时清单> -testSwitchAccount <id>`
  让登录态的位置整个换到临时目录（钥匙串条目名跟着变），真账号不受影响；`-testBeginLogin 1` 启动即弹登录面板。
