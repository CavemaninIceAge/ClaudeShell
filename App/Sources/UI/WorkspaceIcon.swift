import SwiftUI

/// A consistent outline vocabulary on a 20pt grid, independent of OS symbol changes.
struct WorkspaceIcon: View {
    enum Kind { case sidebar, compose, search, folder, plus, more, history, inspector }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    var body: some View {
        iconPath.applying(CGAffineTransform(scaleX: 0.8, y: 0.8))
            .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
    private var iconPath: Path {
        Path { p in
            switch kind {
            case .sidebar:
                p.addRoundedRect(in: CGRect(x: 2.5, y: 3.5, width: 15, height: 13), cornerSize: CGSize(width: 2, height: 2))
                p.move(to: CGPoint(x: 7.5, y: 3.5)); p.addLine(to: CGPoint(x: 7.5, y: 16.5))
            case .compose:
                p.move(to: CGPoint(x: 10, y: 3.5)); p.addLine(to: CGPoint(x: 5, y: 3.5))
                p.addQuadCurve(to: CGPoint(x: 2.5, y: 6), control: CGPoint(x: 2.5, y: 3.5))
                p.addLine(to: CGPoint(x: 2.5, y: 15)); p.addQuadCurve(to: CGPoint(x: 5, y: 17.5), control: CGPoint(x: 2.5, y: 17.5))
                p.addLine(to: CGPoint(x: 14, y: 17.5)); p.addQuadCurve(to: CGPoint(x: 16.5, y: 15), control: CGPoint(x: 16.5, y: 17.5))
                p.addLine(to: CGPoint(x: 16.5, y: 10))
                p.move(to: CGPoint(x: 8, y: 12)); p.addLine(to: CGPoint(x: 9, y: 8.5)); p.addLine(to: CGPoint(x: 15.5, y: 2))
                p.addLine(to: CGPoint(x: 18, y: 4.5)); p.addLine(to: CGPoint(x: 11.5, y: 11)); p.closeSubpath()
            case .search:
                p.addEllipse(in: CGRect(x: 3, y: 2.5, width: 11.5, height: 11.5))
                p.move(to: CGPoint(x: 12.8, y: 12.5)); p.addLine(to: CGPoint(x: 17, y: 17))
            case .folder:
                p.move(to: CGPoint(x: 2, y: 6)); p.addQuadCurve(to: CGPoint(x: 4, y: 4), control: CGPoint(x: 2, y: 4))
                p.addLine(to: CGPoint(x: 8, y: 4)); p.addLine(to: CGPoint(x: 10, y: 6)); p.addLine(to: CGPoint(x: 16, y: 6))
                p.addQuadCurve(to: CGPoint(x: 18, y: 8), control: CGPoint(x: 18, y: 6)); p.addLine(to: CGPoint(x: 18, y: 15))
                p.addQuadCurve(to: CGPoint(x: 16, y: 17), control: CGPoint(x: 18, y: 17)); p.addLine(to: CGPoint(x: 4, y: 17))
                p.addQuadCurve(to: CGPoint(x: 2, y: 15), control: CGPoint(x: 2, y: 17)); p.closeSubpath()
                p.move(to: CGPoint(x: 2, y: 8)); p.addLine(to: CGPoint(x: 18, y: 8))
            case .plus:
                p.move(to: CGPoint(x: 10, y: 4)); p.addLine(to: CGPoint(x: 10, y: 16))
                p.move(to: CGPoint(x: 4, y: 10)); p.addLine(to: CGPoint(x: 16, y: 10))
            case .more:
                for x in [4.5, 10.0, 15.5] { p.addEllipse(in: CGRect(x: x - 0.6, y: 9.4, width: 1.2, height: 1.2)) }
            case .inspector:
                for y in [4.5, 10.0, 15.5] {
                    p.addEllipse(in: CGRect(x: 3, y: y - 1.5, width: 3, height: 3))
                    p.move(to: CGPoint(x: 10, y: y)); p.addLine(to: CGPoint(x: 16, y: y))
                }
            case .history:
                p.addArc(center: CGPoint(x: 10, y: 10), radius: 7, startAngle: .degrees(210), endAngle: .degrees(155), clockwise: false)
                p.move(to: CGPoint(x: 3, y: 3)); p.addLine(to: CGPoint(x: 3, y: 7)); p.addLine(to: CGPoint(x: 7, y: 7))
                p.move(to: CGPoint(x: 10, y: 6)); p.addLine(to: CGPoint(x: 10, y: 10)); p.addLine(to: CGPoint(x: 13, y: 12))
            }
        }
    }
}

struct WorkspaceIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.textSecondary)
            .frame(width: Theme.controlSize, height: Theme.controlSize)
            .background(RoundedRectangle(cornerRadius: 7).fill(configuration.isPressed ? Theme.hoverFill : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.35)
    }
}
