import AppKit
import SwiftUI

/// 和 web/transcript.css 里的 token 一一对应；改一处要改两处。
enum Theme {
    static let columnWidth: CGFloat = 768
    static let sidebarWidth: CGFloat = 288
    static let railWidth: CGFloat = 52
    static let toolbarHeight: CGFloat = 44
    static let titlebarHeight: CGFloat = 44
    static let controlSize: CGFloat = 28

    static let sidebar = dynamic("#FBFBFB", "#181818")
    static let rail = dynamic("#F5F5F5", "#141414")
    static let toolbar = dynamic("#F3F3F3", "#141414")
    static let accent = dynamic("#347CF7", "#6BA1FF")
    static let sidebarInput = dynamic("#EEEEEE", "#242424")
    static let background = dynamic("#FFFFFF", "#181818")
    static let composerFill = dynamic("#FFFFFF", "#363636")
    static let cardFill = dynamic("#F4F4F4", "#242424")
    static let line = inkOpacity(light: 0.078, dark: 0.084)
    static let sidebarSeparator = inkOpacity(light: 0.04, dark: 0.05)
    static let hoverFill = inkOpacity(light: 0.04, dark: 0.055)
    static let selectedFill = inkOpacity(light: 0.07, dark: 0.085)
    static let textPrimary = dynamic("#1A1C1F", "#DFDFDF")
    static let textSecondary = inkOpacity(light: 0.695, dark: 0.71)
    static let textTertiary = inkOpacity(light: 0.495, dark: 0.498)
    static let placeholder = inkOpacity(light: 0.495, dark: 0.498)
    static let iconMuted = dynamic("#8A8A8A", "#8E8E8E")
    static let chipFill = dynamic("#F2F2F2", "#333333")
    static let sendFill = dynamic("#347CF7", "#6BA1FF")
    static let sendFg = dynamic("#FFFFFF", "#111111")
    static let warn = dynamic("#B45309", "#F5B453")
    static let danger = dynamic("#B91C1C", "#F87171")
    static let live = dynamic("#1F9D55", "#4ADE80")

    private static func inkOpacity(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? "#FFFFFF" : "#1A1C1F").withAlphaComponent(isDark ? dark : light)
        })
    }

    static func dynamic(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = CGFloat((v >> 16) & 0xFF) / 255
        let g = CGFloat((v >> 8) & 0xFF) / 255
        let b = CGFloat(v & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

enum ModelOption {
    static let all: [(id: String, title: String)] = [
        ("", "跟随终端设置"),
        ("fable", "Fable 5.1"),
        ("opus", "Opus 5"),
        ("opus[1m]", "Opus 5 (1M)"),
        ("sonnet", "Sonnet 5"),
        ("sonnet[1m]", "Sonnet 5 (1M)"),
        ("haiku", "Haiku 4.5"),
    ]
    static func title(for id: String?) -> String {
        all.first { $0.id == (id ?? "") }?.title ?? (id ?? "")
    }

    /// 把 CLI 报回来的 id（`claude-opus-5[1m]`、`claude-haiku-4-5-20251001`）或 settings.json 里的别名（`opus[1m]`）
    /// 变成终端里那种显示名（`Opus 5 (1M)`）。认不出的原样返回。
    static func displayName(for raw: String) -> String {
        var id = raw.trimmingCharacters(in: .whitespaces)
        var oneM = false
        if id.lowercased().hasSuffix("[1m]") { id.removeLast(4); oneM = true }
        if let known = all.first(where: { $0.id == id && !$0.id.isEmpty }) {
            return oneM ? known.title + " (1M)" : known.title
        }
        var base = id
        if id.hasPrefix("claude-") {
            // claude-<family>-<major>[-<minor>][-<日期>]
            let parts = id.dropFirst("claude-".count).split(separator: "-").map(String.init)
            if parts.count >= 2, let family = parts.first {
                let numbers = parts.dropFirst().filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) && $0.count < 8 }
                if !numbers.isEmpty {
                    base = family.prefix(1).uppercased() + family.dropFirst() + " " + numbers.joined(separator: ".")
                }
            }
        }
        return oneM ? base + " (1M)" : base
    }
}

enum PermissionModeOption {
    static let all: [(id: String, title: String)] = [
        ("auto", "自动审批"),
        ("acceptEdits", "自动接受编辑"),
        ("manual", "逐项询问"),
        ("plan", "只做计划"),
        ("bypassPermissions", "跳过全部权限"),
    ]
    static func title(for id: String) -> String {
        all.first { $0.id == id }?.title ?? id
    }
}

enum EffortOption {
    /// 和终端 `/effort` 的取值一致；ultracode = xhigh + 动态多代理工作流，需要模型支持 xhigh（haiku 会被静默降级）。
    static let ultracode = "ultracode"
    static let all: [(id: String, title: String)] = [
        ("", "默认强度"),
        ("low", "low"),
        ("medium", "medium"),
        ("high", "high"),
        ("xhigh", "xhigh"),
        ("max", "max"),
        (ultracode, "ultracode · xhigh + 多代理工作流"),
    ]
    static func title(for id: String?) -> String {
        all.first { $0.id == (id ?? "") }?.title ?? (id ?? "")
    }
}

/// 和发送键同一材料的主按钮：黑底白字（深色反过来），不引入系统强调色。
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.sendFg)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.sendFill))
            .opacity(!isEnabled ? 0.35 : (configuration.isPressed ? 0.75 : 1))
    }
}
