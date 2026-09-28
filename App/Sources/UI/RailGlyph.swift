import SwiftUI

/// The reference rail uses a small, rounded 20pt icon family rather than SF Symbols.
/// These geometries keep their silhouette and stroke weight in either appearance.
struct RailGlyph: View {
    let route: WorkspaceRoute
    var selected = false
    private let stroke = StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)

    var body: some View {
        ZStack {
            if route == .home && selected {
                home.fill(style: FillStyle(eoFill: true))
            } else if route == .images && selected {
                outline.fill(style: FillStyle(eoFill: true))
                frontImage.fill()
                imageDetail.fill(Theme.rail)
            } else {
                outline.stroke(style: stroke)
                if route == .images {
                    imageDetail.fill()
                }
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private var home: Path {
        Path { p in
            p.move(to: CGPoint(x: 1.8, y: 8.2))
            p.addLine(to: CGPoint(x: 8.5, y: 2.9))
            p.addQuadCurve(to: CGPoint(x: 11.5, y: 2.9), control: CGPoint(x: 10, y: 1.7))
            p.addLine(to: CGPoint(x: 18.2, y: 8.2))
            p.addQuadCurve(to: CGPoint(x: 17.5, y: 10), control: CGPoint(x: 19.4, y: 9.4))
            p.addLine(to: CGPoint(x: 16.7, y: 10))
            p.addLine(to: CGPoint(x: 16.7, y: 16.1))
            p.addQuadCurve(to: CGPoint(x: 15.2, y: 17.6), control: CGPoint(x: 16.7, y: 17.6))
            p.addLine(to: CGPoint(x: 4.8, y: 17.6))
            p.addQuadCurve(to: CGPoint(x: 3.3, y: 16.1), control: CGPoint(x: 3.3, y: 17.6))
            p.addLine(to: CGPoint(x: 3.3, y: 10))
            p.addLine(to: CGPoint(x: 2.5, y: 10))
            p.addQuadCurve(to: CGPoint(x: 1.8, y: 8.2), control: CGPoint(x: 0.6, y: 9.4))
            p.closeSubpath()
            p.addRoundedRect(in: CGRect(x: 8, y: 11, width: 4, height: 7), cornerSize: CGSize(width: 1, height: 1))
        }
    }

    private var outline: Path {
        Path { p in
            switch route {
            case .home:
                p.move(to: CGPoint(x: 1.8, y: 8.8))
                p.addLine(to: CGPoint(x: 8.7, y: 3.1))
                p.addQuadCurve(to: CGPoint(x: 11.3, y: 3.1), control: CGPoint(x: 10, y: 2.1))
                p.addLine(to: CGPoint(x: 18.2, y: 8.8))
                p.move(to: CGPoint(x: 3.8, y: 7.3))
                p.addLine(to: CGPoint(x: 3.8, y: 16.2))
                p.addQuadCurve(to: CGPoint(x: 5.1, y: 17.3), control: CGPoint(x: 3.8, y: 17.3))
                p.addLine(to: CGPoint(x: 8, y: 17.3))
                p.addLine(to: CGPoint(x: 8, y: 12.8))
                p.addQuadCurve(to: CGPoint(x: 9, y: 11.8), control: CGPoint(x: 8, y: 11.8))
                p.addLine(to: CGPoint(x: 11, y: 11.8))
                p.addQuadCurve(to: CGPoint(x: 12, y: 12.8), control: CGPoint(x: 12, y: 11.8))
                p.addLine(to: CGPoint(x: 12, y: 17.3))
                p.addLine(to: CGPoint(x: 14.9, y: 17.3))
                p.addQuadCurve(to: CGPoint(x: 16.2, y: 16.2), control: CGPoint(x: 16.2, y: 17.3))
                p.addLine(to: CGPoint(x: 16.2, y: 7.3))
            case .history:
                p.addEllipse(in: CGRect(x: 2.1, y: 2.1, width: 15.8, height: 15.8))
                p.move(to: CGPoint(x: 10, y: 5.2)); p.addLine(to: CGPoint(x: 10, y: 10.2))
                p.addLine(to: CGPoint(x: 7.1, y: 12.2))
            case .library:
                p.addRoundedRect(in: CGRect(x: 2.2, y: 3.3, width: 4.5, height: 13.4), cornerSize: CGSize(width: 1.4, height: 1.4))
                p.addRoundedRect(in: CGRect(x: 6.8, y: 3.3, width: 4.5, height: 13.4), cornerSize: CGSize(width: 1.4, height: 1.4))
                let book = Path(roundedRect: CGRect(x: 12.2, y: 3.3, width: 4.5, height: 13.4), cornerRadius: 1.4)
                p.addPath(book, transform: CGAffineTransform(translationX: -14.45, y: -10)
                    .concatenating(CGAffineTransform(rotationAngle: -.pi / 18))
                    .concatenating(CGAffineTransform(translationX: 14.45, y: 10)))
            case .images:
                let back = Path(roundedRect: CGRect(x: 7.2, y: 2.6, width: 10.5, height: 12.3), cornerRadius: 2.1)
                p.addPath(back, transform: CGAffineTransform(translationX: -12.45, y: -8.75)
                    .concatenating(CGAffineTransform(rotationAngle: .pi / 15))
                    .concatenating(CGAffineTransform(translationX: 12.45, y: 8.75)))
                p.addPath(frontImage)
            case .apps:
                p.move(to: CGPoint(x: 14.7, y: 16.2))
                p.addCurve(to: CGPoint(x: 2.5, y: 9.7), control1: CGPoint(x: 7.8, y: 21), control2: CGPoint(x: 1.9, y: 16.1))
                p.addCurve(to: CGPoint(x: 10.3, y: 2.5), control1: CGPoint(x: 2.8, y: 5.3), control2: CGPoint(x: 6, y: 2.1))
                p.addCurve(to: CGPoint(x: 17.5, y: 10), control1: CGPoint(x: 15.3, y: 2.8), control2: CGPoint(x: 17.7, y: 5.8))
                p.addCurve(to: CGPoint(x: 12.8, y: 12.4), control1: CGPoint(x: 17.3, y: 13), control2: CGPoint(x: 15.1, y: 14.1))
                p.move(to: CGPoint(x: 6.9, y: 10.8)); p.addLine(to: CGPoint(x: 10.8, y: 6.9))
                p.addLine(to: CGPoint(x: 12.7, y: 8.8))
                p.addCurve(to: CGPoint(x: 8.8, y: 12.7), control1: CGPoint(x: 15.2, y: 11.2), control2: CGPoint(x: 11.2, y: 15.2))
                p.closeSubpath()
                p.move(to: CGPoint(x: 7.7, y: 9.8)); p.addLine(to: CGPoint(x: 6.3, y: 8.4))
                p.move(to: CGPoint(x: 9.8, y: 7.7)); p.addLine(to: CGPoint(x: 8.4, y: 6.3))
            case .settings: break
            }
        }
    }

    private var frontImage: Path {
        Path(roundedRect: CGRect(x: 2.5, y: 6, width: 11, height: 11.3), cornerRadius: 2)
            .applying(CGAffineTransform(translationX: -8, y: -11.65)
                .concatenating(CGAffineTransform(rotationAngle: -.pi / 18))
                .concatenating(CGAffineTransform(translationX: 8, y: 11.65)))
    }
    private var imageDetail: Path {
        Path { p in
            p.addEllipse(in: CGRect(x: 8.6, y: 8, width: 2.3, height: 2.3))
            p.move(to: CGPoint(x: 3.2, y: 14.4)); p.addLine(to: CGPoint(x: 5.6, y: 11.8))
            p.addQuadCurve(to: CGPoint(x: 7, y: 11.7), control: CGPoint(x: 6.2, y: 11.1))
            p.addLine(to: CGPoint(x: 11.3, y: 15.9)); p.addLine(to: CGPoint(x: 4, y: 17))
            p.closeSubpath()
        }
    }
}
