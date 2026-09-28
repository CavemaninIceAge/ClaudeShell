---
name: Claudex Shell
description: A native SwiftUI reconstruction of the installed Codex desktop workspace
colors:
  main: "#FFFFFF"
  main-dark: "#181818"
  sidebar: "#F6F6F6"
  sidebar-dark: "#141414"
  composer: "#FFFFFF"
  composer-dark: "#363636"
  ink: "#1A1C1F"
  ink-dark: "#DFDFDF"
typography:
  ui: "SF Pro / PingFang SC, 13pt; section headings 14pt medium"
  hero: "28pt regular"
  body: "System sans 14px / 1.625"
  code: "SF Mono / Menlo 12px / 20px"
spacing:
  sidebar: "275pt default, 240–520pt resizable"
  toolbar: "46pt"
  column: "768pt including 16pt horizontal gutters; content 736pt"
  sidebar-row: "30pt, horizontal inset 8pt, icon 16pt"
rounded:
  sidebar-cell: "10pt"
  composer: "22pt"
  user-message: "22px"
  code: "20px"
---

# Codex 桌面界面复刻

用户明确要求与 Codex 界面一致。本次以本机 `com.openai.codex` 26.924.22138 的静态样式、组件结构与中文文案作为依据，采用原生 SwiftUI / AppKit 重新实现。详细测量及出处记录在 [参考规格](docs/codex-ui-reference.md)。不复制 Codex 的程序代码或品牌资产，不读取实际聊天、账号主题配置或私有数据库。

## 窗口与侧栏

取消 `NavigationSplitView` 的系统玻璃工具栏；内容延伸至透明标题栏下，保留系统原生窗口按钮。工作区顶部为 46pt 单行：左侧标题与项目、右侧打开目录及会话操作菜单。标题栏拖动仅响应用户自己的操作。

侧栏默认 275pt，最小 240pt、最大 520pt，并为主区保留至少 320pt。分隔线可拖动，侧栏可收起，⌃⌘S 切换显示。导航是两条 30pt 普通行：「新聊天」和「搜索对话」。搜索可通过 ⌘K 打开。

「已固定」「最近」「项目」使用并列分区；没有固定项时不显示空分区。对话行 13pt，尾部为 12pt 相对时间，选中和悬停使用中性灰底；项目可折叠，保留引擎和接管右键操作。固定信息只存在本应用的界面偏好中，不改写原生会话。底部账号菜单采用 18pt 圆形头像与 14pt 单行名称；仅在操作中或有回执时增加状态行。

## 新聊天和输入框

空态标题使用 Codex 中文「我们要构建什么？」；有目录时显示带下划线项目名称的对应文案。28pt 常规字重。标题区域最小高 112pt，与下一部分间距 24pt。输入区锚定窗口高度约 42% 的位置。

正文与输入区共同使用 768pt 外列宽，其中左右各 16pt 留白，实际最大内容宽 736pt。输入框圆角 22pt，编辑区最小高 44pt、行高 20pt、水平留白 12pt。普通控件与发送按钮 28pt，禁用发送按钮为 50% 不透明度。浅色按原始多层细阴影实现；深色使用 #363636 背景与细微内侧亮边。

左侧为附件和权限，右侧为模型/思考强度菜单及发送/停止。双引擎切换放在模型菜单内，保留新会话才能换引擎的约束。Codex 空态的工作目录工具行位于输入框上方；已有对话位于下方。保留原 NSTextView 输入法、回车发送、Shift–回车换行、附件与拖放逻辑；离屏或非活动窗口不会主动取得输入焦点。

## 正文

14px 系统字，行高 1.625；相邻段落间距 14px。助手正文无气泡，用户消息在右侧，最大宽 70%，22px 圆角，垂直 10px、水平 16px 留白。代码块为 20px 圆角、细边与灰底，工具栏高 48px，等宽字体 12px / 20px，复制按钮为 36px 圆形、16px 图标。表格仅使用横向分隔线并允许水平滚动。思考与工具步骤继续沿用可折叠的原生会话展示。

## 功能边界

账号选择、推送至终端、推送至 Codex App、撤回推送仍在账号菜单中；应用内选择与外部推送的语义不变。Claude 接管 Codex 对话移入会话操作菜单和侧栏右键菜单。接管来源条保留。没有加入无实现的语音、插件、自动化或 Git 按钮。

## 验证

`scripts/ui-preview/render.sh` 通过纯内存 snapshot 初始化器渲染实际 `WorkspaceView`，覆盖空态和已有对话、1200×800 与 880×560、浅色与深色。图片写入 `.impeccable/review/workspace/`，附布局和不可见窗口状态记录。该工具不启动真实应用、不加载登录态、不调用引擎、不显示或激活任何窗口。WebKit 快照与其原生视图的实际位置合成，不另写替代界面。

参考来源是安装包静态资源，没有读取用户当前窗口的截图或主题设置。因此可以验证默认布局参数和渲染质量，不把结果描述成已验证的逐像素一致；系统窗口材质与 SF 字形渲染可能和 Electron 有差异。
