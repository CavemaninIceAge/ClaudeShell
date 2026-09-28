# Claudex Shell 原生引擎接入

创建、恢复、生成、工具调用、审批、停止和持久化由 Claude Code / Codex 原生引擎执行。应用仅维护 UI 选择、标题、隐藏状态、账号选择及接管来源等元数据，不模拟另一个 Agent 引擎。

## Claude Code stream-json 协议要点

2026-09-13 在 Claude Code 2.1.270 上实测（探针脚本当时放在 scratchpad，结论都在这里）。app 里的解析在
`App/Sources/Engine/ClaudeEvents.swift`，进程管理在 `ClaudeProcess.swift`。

## 启动参数

```
claude -p --input-format stream-json --output-format stream-json --verbose \
       --include-partial-messages --permission-prompt-tool stdio \
       --permission-mode <auto|acceptEdits|manual|plan|bypassPermissions> \
       (--session-id <uuid> | --resume <id>) [--model x] [--effort y | --settings '{"ultracode":true}']
```

- `ultracode` 不是 `--effort` 的合法取值（那里只认 low/medium/high/xhigh/max），它是会话级设置：
  `--settings '{"ultracode":true}'`（JSON 字符串或文件路径都行），效果 = xhigh + 常驻动态多代理工作流。
  模型不支持 xhigh（haiku）时静默降级，不报错。

- `--permission-prompt-tool stdio` 是关键：没有它，需要审批的工具会直接被拒（stdout 出一条
  `system/permission_denied`），不会问宿主。`--permission-prompts host` 单独用没有效果。
- `--session-id` 新会话可以自己指定 UUID，文件会落在 `~/.claude/projects/<cwd 编码>/<uuid>.jsonl`；
  `--resume <id>` 续接时 cwd 必须和当初一样（CLI 按 cwd 找项目目录）。
- stdin 不关，进程就一直活着，可以连续喂多轮；每轮开头都会再发一次 `system/init`。
- 从 GUI 启动时 PATH 只有 `/usr/bin:/bin`，要先跑一次 `zsh -ilc` 把用户的 PATH 取出来
  （`ShellEnvironment.swift`），否则 `claude` 找不到，它调的 node/brew 也找不到。

## stdin → CLI

| 目的 | 行 |
|---|---|
| 发一句话 | `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"…"}]}}` |
| 批准工具 | `{"type":"control_response","response":{"subtype":"success","request_id":"<id>","response":{"behavior":"allow","updatedInput":{…原 input…},"updatedPermissions":[…可选…]}}}` |
| 拒绝工具 | 同上，`"response":{"behavior":"deny","message":"…"}` |
| 打断 | `{"type":"control_request","request_id":"任意","request":{"subtype":"interrupt"}}` |
| 不支持的 control_request | `{"type":"control_response","response":{"subtype":"error","request_id":"<id>","error":"…"}}` |

AskUserQuestion 也走 can_use_tool：放行时把答案塞进 `updatedInput.answers`（{问题文本: 选项 label}）。

## CLI → stdout（每行一个 JSON）

- `system/init`：session_id、model、permissionMode、tools、slash_commands…（没有 effort；只在每轮开头发，进程刚起时不发）
- `system/hook_started` / `system/hook_response`：`--verbose` 下 SessionStart 钩子的执行结果，`hook_response` 带
  `stdout / stderr / output / exit_code`。app 用它探终端默认强度：`--settings` 挂一个
  `echo "claude-shell effort=$CLAUDE_EFFORT" >&2` 的 SessionStart 钩子，stdin 直接关掉，进程不走 API、0.8 秒退出。
  实测这个 `$CLAUDE_EFFORT` 只反映 settings / 环境变量解析出的默认值，`--model`、`--effort` 都不影响它；
  UserPromptSubmit 等其他钩子的结果不会出现在 stream-json 里。
- `system/status`：`status: "requesting"`（正在请求 API）或 null。
- `system/thinking_tokens`：思考 token 计数，忽略。
- `stream_event`：Anthropic 流事件原样透传，带 `parent_tool_use_id`（子代理的流非空，主对话忽略）。
  顺序是 `message_start` → `content_block_start(index, content_block)` → 若干 `content_block_delta`
  （`text_delta` / `thinking_delta` / `input_json_delta` / `signature_delta`）→ **`assistant`**（整块的最终版）
  → `content_block_stop` → … → `message_delta` → `message_stop`。
- `assistant`：`message.content` 里通常只有一个块，就是刚流完的那块；`tool_use` 的完整 `input` 只有在这里才有。
- `user`：工具结果 `content:[{type:"tool_result", tool_use_id, content, is_error}]`，另带 `tool_use_result`
  （结构化：Bash 有 stdout/stderr）。打断后会出一条纯文本 `"[Request interrupted by user]"`。
- `control_request` / `can_use_tool`：`request_id, tool_name, display_name, input, description, permission_suggestions
  ([{type:"setMode", mode:"acceptEdits", destination:"session"}] 之类), tool_use_id`。CLI 会一直等到宿主回复。
- `control_response`：对宿主 control_request 的回执，打断时是 `{"still_queued":[]}`。
- `result`：一轮结束。`subtype: success | error_during_execution | …`，`is_error`，`duration_ms`，
  `total_cost_usd`（**会话累计**，不是本轮），`num_turns`，`stop_reason`，`result`（最终文本）。
- `rate_limit_event`：`rate_limit_info.unifiedWindows.five_hour.utilization` 等。

打断实测：发 interrupt 后先收 `control_response`，然后 `assistant`（截断的文本）、`user`（"[Request interrupted…]"）、
`result`（`error_during_execution`, `is_error: true`），进程继续活着，可以直接发下一句。

## 会话文件（侧栏数据来源）

`~/.claude/projects/<编码后的 cwd>/<sessionId>.jsonl`，cwd 编码规则：每个非 ASCII 字母数字的字符换成 `-`
（`/Users/x/量化` → `-Users-x---`）。每行一条记录：

- `user` / `assistant`：消息本体（`message.content` 是字符串或块数组）；`isMeta: true` 的是命令回显，
  `isSidechain: true` 的是子代理；`cwd`、`timestamp`、`uuid`、`parentUuid`。
- `custom-title`（`customTitle`）、`ai-title`（`aiTitle`）、`last-prompt`（`lastPrompt`）：标题来源，优先级
  custom > ai > 首条用户消息。`-p` 模式一轮结束后也会写 ai-title。
- `attachment`：`attachment.type == "queued_command"` 是一轮进行中插进来的话（终端里用户在 Claude 干活时打的字，或别的
  会话投来的消息），只记在这里、**没有**对应的 `user` 记录；`attachment.prompt` 是原文，`attachment.origin.kind` 是
  `human` / `peer`。其他 attachment（environment、skill_listing…）忽略。
- 跨会话消息（见下）落成 `user` 记录时带 `isMeta: true`、`promptSource: "system"`、
  `origin: {kind: "peer", name, from, fromMode, body, verifiedPeerPid}`，正文取 `origin.body`（`message.content` 是带信封的）。
  之前还会有 `queue-operation`（enqueue / dequeue / remove reason=absorbed_mid_turn），忽略。
- `assistant` 记录的 `message.model` 是这一条实际用的模型（`claude-opus-5` 这种 API id，没有 `[1m]`）。
- `system/away_summary`：终端里离开 5 分钟以上回来时那条「※ recap:」，正文在 `content`。app 渲染成一条左标线的 recap 摘要块
  （`note` 的 `recap` level）。
- `permission-mode`、`mode`、`file-history-snapshot`、`cost-state`、`system/turn_duration`、`system/stop_hook_summary` 等：忽略。

正在跑的会话登记在 `~/.claude/sessions/<pid>.json`：`sessionId, cwd, status(busy|idle), kind, entrypoint(cli|sdk-cli),
messagingSocketPath, name`。只有 `entrypoint == "cli"` 才是终端里开着的（本 app 起的 -p 进程是 `sdk-cli`）。
文件常常留着不删，`kill(pid, 0)` 成功才算活着。

## 跨会话投递（往终端里正在跑的会话发话）

官方文档：https://code.claude.com/docs/en/cross-session-messaging（「The session's inbox socket」一节说明脚本可以直接投）；
帧格式参考 ExaDev/cc-peer 的 docs/PROTOCOL.md。2026-09-13 对 2.1.270 实测通过（app 投进本机一个正在跑的终端会话）。

- 收信口：登记表里的 `messagingSocketPath`（`/tmp/cc-socks/<pid>.sock`，0600，同 uid 才连得上）。
- 一次连接写一行 JSON 就关（写完等 150 ms 再关，对方读整行才处理）；对方不在这条连接上回任何东西。
  macOS 上不需要 auth 行（对方靠内核报的连接方 pid 认人），所以 app 不碰 `~/.claude/sessions/*.key`。

```json
{"msgV":1,"msg_id":"<uuid>","type":"user","priority":"next","from":"uds:/tmp/cc-socks/<本进程 pid>.sock",
 "message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/cc-socks/<pid>.sock\" from-name=\"Claudex Shell\" from-mode=\"prompting\">\n正文\n</cross-session-message>"}}
```

- 信封属性顺序固定 `from, from-session, hop-chain, from-name, from-mode`，开闭标签各带一个换行，正文里的
  `</cross-session-message` 要换成 `<\`。`type` 不是 `user` 会被静默丢弃。
- `from-mode="prompting"`：对方是 auto / acceptEdits / 逐项询问类会话就直接送达；对方 bypassPermissions 时终端弹一次
  「是否接收」。不写 from-mode 的话对方 bypass 时也会弹。
- `from` 用 app 自己的 pid；我们不真的监听那个套接字，所以对方回信（SendMessage 回 from 地址）会失败——正文末尾附了一句
  说明"这是用户本人、请直接在对话里答、别回信"（`PeerMessenger.userNote`），对方就会在终端里正常回答。
- 终端那边空闲时消息直接开一轮；忙着时在两次工具调用之间送到（`absorbed_mid_turn`，见上面的 `attachment`）。
  终端里显示为一行 `› Message from @Claudex Shell: 首行…`，ctrl+o 看全文。
- 同一会话短时间连发有限流（桶 30、每秒回 0.5），30 秒内完全相同的正文会被当重复丢掉。

## 附件：图片 / 文件 / 目录（2026-09-19 在 2.1.273 上实测）

app 里的组装在 `App/Sources/Model/Attachments.swift`（`OutgoingMessage` 发、`UserMessageParser` 回放）。

- **图片**：stream-json 的 user 消息 content 里跟 `{"type":"image","source":{"type":"base64","media_type":"image/png","data":"…"}}`
  块即可，CLI 原样交给模型（haiku 能认出图里的字）。会话文件里这条 `user` 记录带 `imagePasteIds`（CLI 自己的编号，不是我们写的
  `#N`），后面还跟一条 `isMeta: true, turnCompanion: true` 的记录（`[Image: source: …/images/3.png]`），回放时按 isMeta 跳过。
  终端里粘贴图片的记录格式一样：text 块里是 `[Image #22] 这是啥`，image 块跟在后面。
- **`@` 引用**：正文里写 `@"绝对路径"`（带引号；空格用反斜杠转义不行），CLI 会在会话文件里落一条 `attachment.type == "file"`
  （文本文件 `content.type == "text"`；图片 `content.type == "image"`，也能给模型看）或 `"directory"`（目录列表）。
  PDF、二进制文件不附、也不报错，模型只看到路径，自己用 Read 去读。位置随意（行首、行中、末尾另起一行都认）。
  **消息里一旦带了 image 块，`@` 引用整个不处理**——所以图片和文件混发时，文件只剩路径，Claude 得多一次 Read。
- **投进终端的会话**（跨会话消息）只能带文字，图片也按 `@"路径"` 引用；没有路径的（剪贴板贴的）先写到
  `~/Library/Caches/Claude Shell/pasted/<id>.png`。这条路径没有实测过（会打扰用户正在跑的终端会话）。
- **侧栏索引**：`SessionIndex.parse` 原来只读文件头 512 KB，首条消息带图片时一行就有 1 MB 以上，截不到完整的一行，整个会话不进列表。
  现在按 512 KB 一块往下读到首条真正的用户消息为止（上限 16 MB）；这一改让用户已有的 5 个终端会话（首条就贴了图）也进了列表。
- **已有对话里拖到正文上（2026-09-20 修）**：09-19 只验了输入框和 SwiftUI onDrop 两条路，漏了正文是 WKWebView 的情况。
  WKWebView 一出生就登记了 17 种拖放类型（`NSFilenamesPboardType`、`public.png`、TIFF、URL……），AppKit 派拖放的规则是
  「落点下面最深的、登记过的视图接」，所以已有对话里拖到正文那一大片，WebKit 接了又回「不收」（draggingEntered 回 copy，
  draggingUpdated 回 none），光标变禁止号、松手什么也不发生；新对话没有正文才显得能用。ThreadView 上那条 SwiftUI onDrop
  根本轮不到（它没在任何 NSView 上登记类型，只能接没被子视图截走的拖放）。
  修法：`TranscriptWKWebView`（TranscriptWebView.swift）自己接文件 / 图片（和输入框 `SubmitTextView` 用同一套
  `PasteboardAttachments` 判断，AttachmentStrip.swift），挂到附件条并让输入框亮边；其他类型照旧交给 WebKit。
  验证：`-testWindowDrop` 在正文正中投递，修前 `entered=1 updated=0 attachments=0`，修后 `entered=1 updated=1 attachments=1`，
  接着 `-testPrompt` 把图发进已有对话，haiku 答「兔子」，`-testWebSnapshot` 里图和回答都在。

## 当前验证方式

运行 `./scripts/test.sh`，使用内存凭据、临时目录、模拟 app-server。网页与原生视图在 `.prohibited` 激活策略下离屏渲染，不打开窗口，不切换系统外观，不使用屏幕录制或全局输入。历史的 `-testPrompt` 等钩子不在自动回归中运行，它们会发送真实请求。

## Codex app-server

使用安装在本机的 `codex app-server --listen stdio://`，协议依据其生成的 schema 与[官方文档](https://learn.chatgpt.com/docs/app-server)。

- `initialize` / `initialized` 建立连接；每个请求带独立 ID、超时和进程结束处理。
- `thread/start` 创建；`thread/resume` 以原线程 ID 与原路径恢复。`CODEX_HOME` 中会话目录指向原生存储，登录态独立。
- `turn/start` 发送文本与图片；`turn/interrupt` 停止。模型使用 `model/list` 返回的选项，也允许手动填写模型 ID。
- `item/*` 与 `turn/*` 通知适配到只负责显示的 transcript；真正工具调用始终在 Codex 内执行。
- 命令、文件、权限审批与 `requestUserInput` 由应用渲染，结果回传原始 RPC ID。未支持的交互明确拒绝并提示，避免挂起。
- 本地 rollout 索引只读，用于启动前发现历史和显示内容；不修改原文件、不编造引擎消息或重放工具。

安装版本的 app-server 部分字段为实验性协议。缺失引擎、请求错误、进程退出和超时均展示在会话中。

## Claude 接管 Codex 会话

1. 用户选择「用 Claude 接管」，读取已结束源会话的可见内容。
2. 在私有目录生成 0600 Markdown 上下文文件：保留完整用户/助手正文和附件引用。内嵌图片原样导出为 0600 文件，本地图片保留路径，远程图片只保留引用，不自动下载；纯图片消息也保留。工具结果保留最多4000字符摘要并明确标注截断；不导出系统指令、隐藏推理或认证配置。
3. 创建一个不同 ID 的 Claude 原生草稿，保存来源信息；不修改原 Codex 历史。
4. 用户发送下一步要求时，首条原生 Claude 消息包含上下文文件路径，指示 Claude 使用自己的文件工具读取。后续回复、工具与权限由 Claude Code 自身处理。
5. 消息成功写入原生 stdin 后标记上下文已交接；失败则保留待交接状态。如果写入成功后应用意外退出，下次通过原生会话中的交接标记去重。来源栏始终可回到原对话。

这是显式的跨引擎上下文交接，不把 Codex 的内部状态、系统权限、隐藏推理或原始会话 ID 冒充 Claude 的会话。
