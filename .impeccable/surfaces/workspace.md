# Claudex Shell 工作区

Mode: Operate
Target: App/Sources/UI/ContentView.swift
Platform: macOS 15+, SwiftUI + AppKit; local WKWebView transcript

## 方向契约

用户把 Codex 作为明确的视觉和操作参考，委托自主设计，不需要风格访谈。保留原生侧栏与统一标题栏；项目、最近对话、居中工作输入和账号管理构成工作区。所有可见入口必须具有真实行为。

首屏要证明三个事实：Claude 与 Codex 共用一套对话界面；账号选择仅影响本 App；向终端 / Codex App 推送是独立动作。

灰白双色阶、系统字体、原生菜单与 SF Symbols，不添加产品营销、装饰卡片、虚构导航或自行生成的供应商标志。品牌改为 Claudex Shell，保留旧数据兼容。

最低支持窗口为 880 × 560；目标默认 1200 × 800。浅色、深色与最小宽度均需检查。未取得 Codex 实际参考图，不把「近似布局」描述为「像素级复刻」。

## 约束

不读或操作 Chrome。验证不抢占用户屏幕、键盘、鼠标或焦点。只允许从不显示窗口的离屏渲染，并且禁止 bootstrap 真实账号 / 发送真实模型请求。

## Codex → Claude 接管补充

用户明确要求 Claude 接管原 Codex 对话。可见操作为原会话工具栏 / 侧栏菜单「用 Claude 接管」；新 Claude 对话带持久来源条和回到原会话的操作。接管只传递历史上下文，运行逻辑继续交给 Claude Code 原生会话；不伪装跨引擎的同 ID resume。
