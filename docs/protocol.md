# Claude Code stream-json 协议要点

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
 "message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/cc-socks/<pid>.sock\" from-name=\"Claude Shell\" from-mode=\"prompting\">\n正文\n</cross-session-message>"}}
```

- 信封属性顺序固定 `from, from-session, hop-chain, from-name, from-mode`，开闭标签各带一个换行，正文里的
  `</cross-session-message` 要换成 `<\`。`type` 不是 `user` 会被静默丢弃。
- `from-mode="prompting"`：对方是 auto / acceptEdits / 逐项询问类会话就直接送达；对方 bypassPermissions 时终端弹一次
  「是否接收」。不写 from-mode 的话对方 bypass 时也会弹。
- `from` 用 app 自己的 pid；我们不真的监听那个套接字，所以对方回信（SendMessage 回 from 地址）会失败——正文末尾附了一句
  说明"这是用户本人、请直接在对话里答、别回信"（`PeerMessenger.userNote`），对方就会在终端里正常回答。
- 终端那边空闲时消息直接开一轮；忙着时在两次工具调用之间送到（`absorbed_mid_turn`，见上面的 `attachment`）。
  终端里显示为一行 `› Message from @Claude Shell: 首行…`，ctrl+o 看全文。
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

自动化验证（都不发全局键鼠事件，窗口在别的桌面上也能跑）：

```
open -n "Claude Shell.app" --args -testLog 1 -testCwd <scratchpad 目录> -testModel haiku \
  -testDropFiles "/a.heic:/b.txt:/dir"  # 进程内造 NSDraggingInfo 喂给输入框（draggingEntered → performDragOperation）
  -testDropImage /x.png                  # 图片字节拖进输入框（浏览器拖图那种）
  -testPasteFiles "/a:/b" -testPasteImage /x.png   # ⌘V 路径，用私有剪贴板，不动用户剪贴板
  -testProviderDrop "/a:/b"             # SwiftUI onDrop 那条 NSItemProvider 路径（窗口正文区）
  -testAttach "/a:/b"                    # 直接 controller.attach
  -testPrompt "…" -testPromptDelay 6     # 等附件挂好再发
  -testWebSnapshot /out.png [-testScrollTo ".att-image"]   # 网页层自截图：窗口不在当前桌面时 WebKit 不往窗口画，
                                                            # screencapture 拿到的正文是空白，只有 takeSnapshot 靠得住
  -testAppearance dark                   # 只改本进程外观
```
