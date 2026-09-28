# Claudex Shell 工作区

Mode: Operate
Target: App/Sources/UI/ContentView.swift
Platform: macOS 15+, SwiftUI + AppKit + local WKWebView

## 方向契约

用户要求与本机 Codex 界面一致，拒绝仅有相似风格的上一版。按 `docs/codex-ui-reference.md` 的实测静态组件数据重建默认 Codex 桌面布局。保留本产品的账号隔离、显式推送、双引擎原生会话和 Claude 接管能力；将独有能力收纳进对应菜单，减少默认界面的额外元素。

275pt 侧栏、46pt 顶部栏、768pt 含留白内容列、28pt 常规空态标题、22pt 输入框圆角。黑白灰原生界面，所有可见入口必须有真实行为。不添加伪造的语音、插件、自动化或 Git 功能。

## 证据与约束

本机参考为 ChatGPT.app / com.openai.codex 26.924.22138 的静态组件资源；没有获取用户实际窗口截图或个性化主题。不得宣称已验证逐像素相同。

最低窗口 880×560，默认 1200×800；空态、真实长度合成历史与正文分别检查浅色和深色。离屏工具只渲染真实生产视图，不访问真实账号、不启动原生引擎。

开发期间用户保留屏幕与输入控制。禁止前置、激活、移动、调整用户窗口，禁止全局键鼠，禁止 Chrome、Superpowers 与 Teacher。安装时不覆盖运行中的应用，不代替用户退出或启动新版，除非获得该次操作的明确授权。
