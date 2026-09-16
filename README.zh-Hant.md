# Claude Shell

*給你本機那個 Claude Code 套一層安靜的原生殼。*

[English](README.md) · [简体中文](README.zh-Hans.md) · **繁體中文** · [Français](README.fr.md) · [日本語](README.ja.md) · [Español](README.es.md) · [Deutsch](README.de.md)

Claude Shell 是一個小小的 macOS app，給你本機的 Claude Code 命令列套上一張 Codex 風格的臉。左邊是 `~/.claude/projects` 裡的全部工作階段，按專案分組——包括你在終端機裡開的那些。右邊是目前對話：Markdown 內文、可摺疊的思考與工具步驟、權限審批卡。底下跑的就是 `~/.local/bin/claude`，所以模型、權限模式、`CLAUDE.md`、記憶、技能、MCP、hooks，全都和你終端機裡的一模一樣。

## 它只是個殼——而這正是重點

它不重寫 Claude Code，不自帶模型用戶端，不另搞一套登入，也不複製一份你的資料。它啟動的就是你本來就信任的那個 `claude`，讀的就是它本來就在寫的工作階段檔案。app 自己只在 `~/Library/Application Support/Claude Shell/` 底下存四樣極小的東西：改過的標題、隱藏標記、每個對話的設定、你保存過的帳號清單（身分資訊在一個 JSON 裡，權杖在你的登入鑰匙圈裡）。對話內容永遠以 `~/.claude` 為準，除了命令列本來就會送的，沒有任何東西離開你的機器。

於是你得到一個真正的原生視窗——Dock 圖示、⌘N、一個像樣的輸入框——卻沒有把比命令列更寬的檔案或資料權限交給任何人。同一條信任邊界，只是換了張更好看的臉。

## 它能做什麼

- **即時跟著終端機走。** 終端機裡正在跑的工作階段帶一個綠點；點開它，Claude Shell 就 tail 工作階段檔案，那邊的每一步都在這裡即時出現。
- **把話說回終端機裡。** 在終端機裡開著的工作階段裡輸入，你這句話會經 Claude Code 自己的跨工作階段訊息投進那個工作階段——終端機裡回答，回答再同步回這裡。
- **終端機顯示什麼，這裡就顯示什麼。** recap 摘要、別的工作階段投來的訊息、插隊輸入、上下文壓縮提示、思考行上的強度。
- **模型和強度都明著寫。** 膠囊和工具列永遠顯示目前真正生效的值（`Opus 5 (1M) · xhigh`），包括 `ultracode`——不藏在「跟隨設定」後面。
- **一個對話一個行程**，保持溫熱，閒置後用 `--resume` 拉起。
- **多個帳號，一下切換。** 第二個 Claude 帳號只需新增一次（走 CLI 自己的 `claude auth login`，在瀏覽器裡登入）；之後在側欄底部選一個，或按 ⌃1…⌃9。切換會把保存的登入狀態寫回 Claude Code 自己的鑰匙圈項目，終端機也跟著換——已經開著的工作階段下一次請求就用新帳號，不用重開、不用開瀏覽器、不用重新登入。

## 跑起來

```
./scripts/build.sh            # Debug 建置到 DerivedData/
./scripts/install.sh          # Release 建置 → /Applications → 加進 Dock
./scripts/shot.sh out.png     # 截執行中的視窗
```

快捷鍵：⌘N 新對話 · ⇧⌘N 在資料夾中新建 · ⏎ 送出 · ⇧⏎ 換行 · ⌘. 停止 · ⌘R 重新整理 · ⌃1…⌃9 切換帳號。

## 底層

- Swift 6 + SwiftUI + AppKit，專案由 XcodeGen 產生，無第三方 Swift 相依。
- 內文用 `WKWebView` 渲染，marked + highlight.js 隨包內建、不連網。
- 不進沙盒（要起子行程、讀 `~/.claude`），Sign to Run Locally。
- 跨工作階段投遞、stream-json 協定、帳號切換、設計系統都寫在 `docs/` 和 `DESIGN.md` 裡。

## 結構

```
App/Sources/Engine/   子行程、stream-json → 事件、跨工作階段投遞
App/Sources/Model/    一個對話、工作階段列表、transcript 資料模型
App/Sources/UI/       側欄、對話頁、輸入卡、審批卡、佈景主題
App/Resources/web/    transcript.html / .css / .js —— 對話內文
docs/ · DESIGN.md · PRODUCT.md   協定筆記、設計系統、產品記錄
```

需要 macOS 15+ 和裝好的 Claude Code（`~/.local/bin/claude`）。
