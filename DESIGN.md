---
name: Claudex Shell
description: macOS 原生的 Claude / Codex 工作区，采用 Codex 的中性侧栏、居中对话与任务输入框
colors:
  paper: "#FFFFFF"
  paper-dark: "#212121"
  sidebar: "#F7F7F7"
  sidebar-dark: "#191919"
  sidebar-input: "#EEEEEE"
  sidebar-input-dark: "#242424"
  card: "#F7F7F7"
  card-dark: "#2A2A2A"
  ink: "#0D0D0D"
  ink-dark: "#ECECEC"
  secondary: "#5D5D5D"
  secondary-dark: "#B4B4B4"
  line: "#E3E3E3"
  line-dark: "#3A3A3A"
  chip: "#F2F2F2"
  chip-dark: "#333333"
typography:
  ui: "SF Pro / PingFang SC, 12–13pt"
  start-title: "SF Pro / PingFang SC, 28pt medium, -0.6pt tracking"
  body: "SF Pro / PingFang SC, 14px / 1.65"
  code: "SF Mono / Menlo, 12.5px / 1.55"
rounded:
  control: "8pt"
  permission: "14pt"
  message: "18px"
  composer: "20pt"
spacing:
  sidebar: "260pt ideal; 230–360pt resizable"
  transcript: "780pt column + 24pt gutters"
  start-composer: "720pt maximum; 32pt outer gutters"
  turn-gap: "28px"
---

# Claudex Shell 设计系统

用户指定视觉参考为 Codex 桌面工作区。此次实现沿用原生 macOS 分栏、系统字体和单色灰阶，强化相同的信息层级与操作位置。没有取得 Codex 的像素级参考截图，因此不宣称已完成像素级一致性。

## 工作区结构

- 原生 `NavigationSplitView`：侧栏默认 260pt，主区为居中单列。浅色侧栏略灰，深色侧栏比主区更暗；不添加装饰性玻璃、渐变或彩色品牌区。
- 侧栏从上至下为「新对话」及引擎菜单、搜索输入框、「项目 / 最近」视图切换、对话列表、账号菜单。刷新使用真实扫描状态。
- 项目视图按目录分组，可折叠；项目的右键菜单分别新建 Claude 或 Codex 对话。最近视图合并所有项目并按更新时间排序。搜索同时匹配标题和路径。
- 对话行使用统一 SF Symbols：`sparkle` 表示 Claude，`terminal` 表示 Codex。终端中运行的 Claude 对话保留绿点。
- 标题和路径在原生工具栏显示；模型、引擎、强度与已知花费在右侧显示。界面不出现无功能的自动化、技能、Git 或设置导航。

## 新对话与输入

新对话由「今天想做些什么？」和真正可用的输入框构成，整体垂直居中略偏上。相同 `ComposerView` 用于新对话和已有对话，支持输入法、附件、拖放、粘贴、停止和键盘快捷键。

输入框只有一条中性描边，没有叠加阴影。内部 16pt 水平留白、20pt 连续圆角；输入区域下方为附件按钮、引擎、模型与 32pt 圆形发送按钮。工作目录、权限和强度放在卡片外的独立控制行，避免最小窗口宽度下过长的一排胶囊。

引擎可在第一条消息发送前切换，历史对话固定引擎。模型来自已知 Claude 列表或 Codex 的 `model/list`，允许填写自定义模型 ID。未连接 Codex 时明确显示「Codex 默认模型」，不虚构一个已选模型。

工作中的发送键变为停止键。没有可发送内容时发送键禁用。拖放只增强输入框描边。终端中正在运行的对话必须显示「此对话由终端运行，使用终端当前账号；应用内账号选择不改变它。」

## 账号与推送

账号菜单是原生菜单，固定在左下角；头像由当前引擎所选账号的首字母生成。菜单顶部明确「切换账号 · 仅在 Claudex Shell 内生效」。Claude、GLM / API、Codex 分组显示，各自选中态保留。

- 「保存本机登录态（Claude / GLM / Codex）」用于保存当前机器的登录信息。
- 「推送至终端」子菜单分别列出 Claude Code 与 Codex CLI，包含选中账号名称。Codex CLI 和 Codex App 共用本机 Codex 登录态，这一关系写在菜单里。
- 「推送至 Codex App」显示具体 Codex 账号，并注明 App 可能需要重新启动；工具不会替用户重启应用。
- 推送前保存旧状态，存在备份时显示「撤回上次推送」。错误用原生 alert 呈现，操作回执显示在账号行，完整回执可悬停查看。
- 添加 API 提供方的说明只陈述本机钥匙串和 App 内生效范围；不得再声称普通切换会修改终端。

## 跨引擎接管

已有 Codex 对话的工具栏与侧栏右键菜单提供「用 Claude 接管」。源对话正在生成、加载历史或已经在准备接管时禁用操作。接管建立新的 Claude 原生会话，并带入原对话的可移植上下文；不假装 Claude 能原生恢复 Codex 的会话 ID。

接管后的对话顶部保留单行来源条：「接管自 Codex · 原标题」及「查看原对话」。草稿标题为「继续这段对话」，输入占位为「告诉 Claude 接下来做什么…」，引擎固定为 Claude。没有自动发送用户尚未输入的续接任务。原 Codex 对话保留，来源关系持久化；错误通过工作区原生 alert 展示。

## 对话排版

助手正文无气泡，用户消息为右对齐灰底圆角块。Markdown 使用 14px / 1.65 系统字，代码采用 SF Mono。思考、工具步骤可折叠；折叠层级只用 1px 竖线。

正文与原生输入框共享 780pt 列宽。代码和表格可横向滚动；狭窄窗口的用户消息最大宽度为 90%。键盘焦点、选区、滚动条和降低动态效果均有对应样式。语义色限于错误、警告、运行状态及代码语法高亮。

## 原生交互和验证边界

`NSTextView` 保留输入法组字、撤销、拖放与附件处理。回车发送，Shift–回车换行；⌘N 新建、⌘R 刷新、⌘. 停止，账号快捷键沿用 ⌃1…⌃9。目录、附件和登录交互仅由用户主动操作触发。

开发验证不得打开或前置用户窗口、控制鼠标键盘或使用 Chrome。离屏原生视图和 `WKWebView` 快照必须设置 `.prohibited` 激活策略，不对窗口执行 order/front/key 操作，不执行实际账号同步。没有原生屏幕参考时，布局截图只能证明本应用渲染质量，不能证明与 Codex 像素一致。
