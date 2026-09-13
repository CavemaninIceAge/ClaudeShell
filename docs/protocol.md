# Claude Code stream-json 协议要点

2026-09-13 在 Claude Code 2.1.270 上实测（探针脚本当时放在 scratchpad，结论都在这里）。app 里的解析在
`App/Sources/Engine/ClaudeEvents.swift`，进程管理在 `ClaudeProcess.swift`。

## 启动参数

```
claude -p --input-format stream-json --output-format stream-json --verbose \
       --include-partial-messages --permission-prompt-tool stdio \
       --permission-mode <auto|acceptEdits|manual|plan|bypassPermissions> \
       (--session-id <uuid> | --resume <id>) [--model x] [--effort y]
```

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

- `system/init`：session_id、model、permissionMode、tools、slash_commands…
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
- `permission-mode`、`mode`、`file-history-snapshot`、`cost-state`、`system/turn_duration` 等：忽略。

正在跑的会话登记在 `~/.claude/sessions/<pid>.json`：`sessionId, cwd, status(busy|idle), kind, entrypoint(cli|sdk-cli)`。
只有 `entrypoint == "cli"` 才是终端里开着的（本 app 起的 -p 进程是 `sdk-cli`）。
