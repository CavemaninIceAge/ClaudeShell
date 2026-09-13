import AppKit
import SwiftUI

/// 和 web/transcript.css 里的 token 一一对应；改一处要改两处。
enum Theme {
    static let columnWidth: CGFloat = 780

    static let background = dynamic("#FFFFFF", "#212121")
    static let composerFill = dynamic("#FFFFFF", "#2A2A2A")
    static let cardFill = dynamic("#F7F7F7", "#2A2A2A")
    static let line = dynamic("#E3E3E3", "#3A3A3A")
    static let textPrimary = dynamic("#0D0D0D", "#ECECEC")
    static let textSecondary = dynamic("#5D5D5D", "#B4B4B4")
    static let placeholder = dynamic("#6B6B6B", "#9A9A9A")
    static let iconMuted = dynamic("#8A8A8A", "#8E8E8E")
    static let chipFill = dynamic("#F2F2F2", "#333333")
    static let sendFill = dynamic("#0D0D0D", "#ECECEC")
    static let sendFg = dynamic("#FFFFFF", "#0D0D0D")
    static let warn = dynamic("#B45309", "#F5B453")
    static let danger = dynamic("#B91C1C", "#F87171")
    static let live = dynamic("#1F9D55", "#4ADE80")

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
        ("sonnet", "Sonnet 5"),
        ("haiku", "Haiku 4.5"),
    ]
    static func title(for id: String?) -> String {
        all.first { $0.id == (id ?? "") }?.title ?? (id ?? "")
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
    static let all: [(id: String, title: String)] = [
        ("", "默认强度"),
        ("low", "low"),
        ("medium", "medium"),
        ("high", "high"),
        ("xhigh", "xhigh"),
        ("max", "max"),
    ]
    static func title(for id: String?) -> String {
        all.first { $0.id == (id ?? "") }?.title ?? (id ?? "")
    }
}

/// 和发送键同一材料的主按钮：黑底白字（深色反过来），不引入系统强调色。
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.sendFg)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.sendFill))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
