---
name: Claude Shell
description: Codex 桌面版风格的 Claude Code 对话壳——灰白单色地、系统字、无边框正文、一张圆角输入卡
colors:
  paper: "#FFFFFF"
  paper-dark: "#212121"
  card: "#F7F7F7"
  card-dark: "#2A2A2A"
  bubble: "#F1F1F1"
  bubble-dark: "#2F2F2F"
  chip: "#F2F2F2"
  chip-dark: "#333333"
  code-ground: "#F5F5F5"
  code-ground-dark: "#181818"
  line: "#E3E3E3"
  line-dark: "#3A3A3A"
  ink: "#0D0D0D"
  ink-dark: "#ECECEC"
  ink-secondary: "#5D5D5D"
  ink-secondary-dark: "#B4B4B4"
  placeholder: "#6B6B6B"
  placeholder-dark: "#9A9A9A"
  icon-muted: "#8A8A8A"
  warn: "#B45309"
  warn-dark: "#F5B453"
  danger: "#B91C1C"
  danger-dark: "#F87171"
  live: "#1F9D55"
  live-dark: "#4ADE80"
  icon-clay: "#D97757"
typography:
  greeting:
    fontFamily: "-apple-system, SF Pro, PingFang SC, sans-serif"
    fontSize: "26pt"
    fontWeight: 500
  body:
    fontFamily: "-apple-system, SF Pro Text, PingFang SC, sans-serif"
    fontSize: "14px"
    lineHeight: 1.6
  ui:
    fontFamily: "-apple-system, SF Pro Text, PingFang SC, sans-serif"
    fontSize: "13px"
    fontWeight: 500
  chip:
    fontFamily: "-apple-system, SF Pro Text, PingFang SC, sans-serif"
    fontSize: "12px"
    fontWeight: 500
  meta:
    fontFamily: "-apple-system, SF Pro Text, PingFang SC, sans-serif"
    fontSize: "11px"
  code:
    fontFamily: "ui-monospace, SF Mono, Menlo, monospace"
    fontSize: "12.5px"
    lineHeight: 1.55
rounded:
  chip: "999px"
  control: "8px"
  code: "10px"
  card: "14px"
  composer: "16px"
  bubble: "18px"
spacing:
  xs: "6px"
  sm: "10px"
  md: "14px"
  lg: "22px"
  gutter: "24px"
  column: "780px"
components:
  composer:
    backgroundColor: "{colors.paper}"
    rounded: "{rounded.composer}"
    padding: "12px 14px 10px"
    width: "{spacing.column}"
  chip:
    backgroundColor: "{colors.chip}"
    textColor: "{colors.ink-secondary}"
    typography: "{typography.chip}"
    rounded: "{rounded.chip}"
    padding: "5px 9px"
  send-button:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    rounded: "{rounded.chip}"
    size: "30px"
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    typography: "{typography.ui}"
    rounded: "{rounded.control}"
    padding: "6px 14px"
  user-bubble:
    backgroundColor: "{colors.bubble}"
    textColor: "{colors.ink}"
    rounded: "{rounded.bubble}"
    padding: "9px 14px"
    width: "78%"
  permission-card:
    backgroundColor: "{colors.card}"
    rounded: "{rounded.card}"
    padding: "14px"
  codeblock:
    backgroundColor: "{colors.code-ground}"
    rounded: "{rounded.code}"
    padding: "10px 12px"
---

# Design System: Claude Shell

## Overview

**Creative North Star: "终端的那扇窗"**

Claude Shell 不是另一个聊天客户端，它是终端里那个 Claude Code 的窗口。视觉世界照搬 OpenAI Codex 桌面版
（用户钦定的 canon）：白 / 深灰的单色地、系统字、没有主题色，助手的话不装在气泡里，用户的话装在一块灰色圆角里，
思考和工具步骤各折成一行，底部一张 16pt 圆角的输入卡。唯一一处颜色是 Dock 图标上的陶土橙 `›_`，界面里不出现。

拒绝的东西：左右对齐的双色气泡流、任何强调色按钮、渐变、玻璃、装饰性动效、图标混用两套画法。

**Key Characteristics:**
- 两个地：内容区 `#FFFFFF / #212121`，侧栏用系统原生 `.sidebar` 材质；深浅色各一整套 token，`Theme.swift` 与 `transcript.css` 各存一份。
- 一种字：SF Pro（中文落到 PingFang SC），正文 14px/1.6，代码 SF Mono 12.5px。
- 一处动效：进行中的那一行做单色 shimmer；其余状态变化 120–160ms 缓出。
- 黑白按钮：发送键、停止键、"允许"键都是 ink 底 paper 字，深色反转。

## Colors

中性灰白，无色相；语义色只有警告、错误、"终端里在跑"的绿点三处，且只用在小字和 6pt 圆点上。

### Neutral
- **Paper** (#FFFFFF / 深色 #212121)：内容区、输入卡、代码块之外的一切底。
- **Card** (#F7F7F7 / #2A2A2A)：审批卡、表头。深色下输入卡也用它，和地拉开一档。
- **Bubble** (#F1F1F1 / #2F2F2F)：用户消息块。
- **Chip** (#F2F2F2 / #333333)：胶囊、行内代码底。
- **Code ground** (#F5F5F5 / #181818)：代码块与工具输出。
- **Line** (#E3E3E3 / #3A3A3A)：所有 1px 线——输入卡描边、代码块描边、表格网格、折叠区左侧竖线。
- **Ink** (#0D0D0D / #ECECEC)：正文、标题、按钮底。
- **Ink secondary** (#5D5D5D / #B4B4B4)：折叠行文字、步骤行、代码块头、提示行、表格里的次要文字。白底 7:1。
- **Placeholder** (#6B6B6B / #9A9A9A)：输入框占位，白底 5.3:1。
- **Icon muted** (#8A8A8A)：只给不承载文字的小图标，不给任何文字。

### Semantic
- **Warn** (#B45309 / #F5B453)、**Danger** (#B91C1C / #F87171)：系统提示行与出错的步骤标签。
- **Live** (#1F9D55 / #4ADE80)：侧栏里"终端中正在运行"的 6pt 圆点。

### Named Rules
**The No-Accent Rule.** 界面里没有主题色。主按钮、发送键、选中态全部用 Ink/Paper 的黑白反转；系统强调色（蓝）不出现在任何控件上。
**The Two-Copies Rule.** 每个颜色 token 在 `App/Sources/UI/Theme.swift` 与 `App/Resources/web/transcript.css` 各存一份，改一处必改另一处。

## Typography

**UI / Body Font:** SF Pro（系统栈 `-apple-system`，中文回落 PingFang SC）
**Code Font:** SF Mono（`ui-monospace`，回落 Menlo）

**Character:** 全系统字，靠字重和一档一档的字号分层；没有展示字体，没有斜体（中文斜体不可读）。

### Hierarchy
- **Greeting** (500, 26pt)：只在新对话空态的问候语。
- **Title** (600, 1.35em / 1.2em / 1.08em)：Markdown 里的 h1–h3，行高 1.3。
- **Body** (400, 14px, 1.6)：对话正文，列宽 780px 约等于 55 个汉字。
- **UI** (500, 13px)：侧栏行、折叠行、审批卡标题、按钮。
- **Chip** (500, 12px)：输入卡里的胶囊。
- **Meta** (400, 11px)：代码块头的语言名、工具栏右上角的「模型 · 强度 · 花费」、工具输入的小标签。
  macOS 26 会给工具栏项套玻璃胶囊，这一行用 `sharedBackgroundVisibility(.hidden)` 去掉（One Shadow Rule）。
- **Code** (400, 12.5px, 1.55)：代码块；行内代码 0.86em。

### Named Rules
**The One Family Rule.** 一个字族撑全部层级；"技术感"不靠等宽字，等宽只给代码、路径、命令。

## Layout

三栏式 macOS 窗口：原生侧栏（ideal 264pt，220–400 可拖）+ 统一工具栏（标题 = 对话标题或目录名，副标题 = 路径）+ 内容区。
内容区是一根居中的 780px 单列（`Theme.columnWidth` / `transcript.css #root`），两侧各 24px 呼吸边，正文列与输入卡严格同轴；
滚动条设为"总是显示"时两边都留 gutter。空态时问候语和输入卡（最宽 680）垂直居中略偏上（上方 1 份、下方 2 份空白）。

节奏：条目之间 22px；一个助手回合内的块之间 10px；折叠区的子列表缩进 20px 并带 2px 竖线；输入卡内 12/14/10px。
用户消息靠右、最宽 78%。

## Elevation & Depth

以平面分层为主：地、卡、块三档灰度就是深度。唯一的阴影在输入卡上：`0 4px 12px rgba(0,0,0,0.05)`，
让它"浮"在正文之上；深色模式下同一值几乎不可见，靠 Card 色和 1px Line 拉开。

### Named Rules
**The One Shadow Rule.** 只有输入卡有影；代码块、审批卡、胶囊都只用 1px 线或底色区分。

## Shapes

圆角按层级递增：胶囊与圆形按钮（999）、控件 8、代码块 10、审批卡 14、输入卡 16、用户消息 18；SwiftUI 侧一律 `.continuous`。
线全部 1px，颜色只有 Line 一种；折叠区左侧的 2px 竖线是唯一的粗线。

## Components

- **Composer（输入卡）**：Paper 底 + 1px Line + 16pt 连续圆角 + 唯一的阴影。上半是 NSTextView（⏎ 发送、⇧⏎ 换行、
  输入法组字中的回车归输入法；组字期间占位符隐藏、发送键禁用），下半一行胶囊（目录 / 模型 / 权限 / 强度，后三枚带 ▾）+ 右侧 30pt 圆形发送键；进行中发送键变停止键。
  模型与强度胶囊写的是具体生效值（`Opus 5 (1M)`、`xhigh`），不写「跟随终端设置」。
- **Chip（胶囊）**：Chip 底、Ink secondary 字、12px/500，图标 11px SF Symbol；四枚同一渲染。
- **Send / Stop / Primary button**：Ink 底 Paper 字，按下 75% 不透明；主按钮 8pt 圆角、13px/500。
- **User bubble**：Bubble 底、18px 圆角、9/14 内边距、保留换行。
- **Assistant text**：无容器，Markdown 直接落在 Paper 上；表格 1px 网格、表头 Card 底；代码块 Code ground + 1px Line + 10px 圆角，
  头部一行语言名，"复制"悬停才现。
- **Thinking row / Steps row**：`<details>` 折叠行，SF Symbols 蒙版图标 15px + 13px 文字 + 右侧 12px chevron（展开旋转 90°，160ms）；
  进行中文字做 shimmer 并默认展开，完成后折起显示"已完成 N 步 · 12 秒"。步骤子行：图标 + 动作词 + 等宽路径/命令，进行中带 10px 转圈。
- **Permission card**：Card 底 + 1px Line + 14pt 圆角，贴在输入卡上方；标题 13px/600，摘要等宽块，按钮"拒绝 / 本会话总是允许 / 允许"，
  只有"允许"是黑白主按钮。AskUserQuestion 用同一张卡，选项为单选行。
- **Sidebar**：原生 `.sidebar` List，顶部"新对话 ⌘N"行，按项目目录分组，行只有标题（一行截断），终端里在跑的带 6pt 绿点；
  未开口的草稿不进列表。
- **Working line**：正文末尾 8px 脉冲点 + 13px 状态文字，只在正文里没有任何在动的块时出现（避免同屏两个指示器）。

## Do's and Don'ts

- Do：新元素先问"Codex 桌面版有没有这件"；有就照它的位置和材料做，没有就不加。
- Do：图标一律 SF Symbols——原生侧直接用，网页侧用 `scripts/export-symbols.swift` 导出的蒙版（内嵌 data URI 的 `icons.css`；WebKit 对 file:// 的 mask-image 做 CORS 校验，外链 PNG 不显示）。
- Do：任何状态文字最小 12px 且用 Ink secondary；Icon muted 只给图标。
- Don't：给任何按钮系统强调色；给正文加气泡或边框；同屏放两个"进行中"指示；用 emoji 或手绘 SVG 当图标。
- Don't：在 `Theme.swift` 和 `transcript.css` 之外再写第三份颜色。
