import SwiftUI

/// Group icons (6.1, the user: "minimal, designed for the app"): our own line
/// art — no SF Symbols — on a 16-unit grid, drawn with the ≡ glyph's stroke
/// (round caps and joins, 1.4 units). One colour: the group's level bar's,
/// so a group reads the same with or without an icon. Optional per group;
/// nil = the bar alone, as before.
nonisolated enum GroupIcon: String, CaseIterable, Codable, Identifiable, Sendable {
    case building, house, store, rack, chip, network, globe, cloud
    case antenna, wifi, plug, disk, shield, lock, terminal, lab
    case box, briefcase, flag, star, bolt, people

    var id: String { rawValue }

    /// The art in a 16 × 16 box.
    func path() -> Path {
        var p = Path()
        func line(_ pts: [(CGFloat, CGFloat)]) {
            guard let first = pts.first else { return }
            p.move(to: CGPoint(x: first.0, y: first.1))
            for pt in pts.dropFirst() { p.addLine(to: CGPoint(x: pt.0, y: pt.1)) }
        }
        func closed(_ pts: [(CGFloat, CGFloat)]) { line(pts); p.closeSubpath() }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
            p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
        }
        func ring(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            p.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        func arc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ from: Double, _ to: Double) {
            p.move(to: CGPoint(x: x + r * cos(from * .pi / 180), y: y + r * sin(from * .pi / 180)))
            p.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
        }
        switch self {
        case .building:
            box(3.5, 2.5, 9, 11, 1.2)
            line([(6, 5.5), (6.6, 5.5)]); line([(9.4, 5.5), (10, 5.5)])
            line([(6, 8.3), (6.6, 8.3)]); line([(9.4, 8.3), (10, 8.3)])
            line([(7, 13.5), (7, 11), (9, 11), (9, 13.5)])
        case .house:
            line([(2, 8), (8, 2.5), (14, 8)])
            line([(3.8, 6.5), (3.8, 13.5), (12.2, 13.5), (12.2, 6.5)])
            line([(6.8, 13.5), (6.8, 10), (9.2, 10), (9.2, 13.5)])
        case .store:
            line([(2.5, 6), (3.6, 2.5), (12.4, 2.5), (13.5, 6), (2.5, 6)])
            line([(3.6, 6), (3.6, 13.5), (12.4, 13.5), (12.4, 6)])
            line([(6.8, 13.5), (6.8, 10), (9.2, 10), (9.2, 13.5)])
        case .rack:
            box(2.5, 2.5, 11, 4.6, 1.3); box(2.5, 8.9, 11, 4.6, 1.3)
            line([(5, 4.8), (5.2, 4.8)]); line([(8.5, 4.8), (11, 4.8)])
            line([(5, 11.2), (5.2, 11.2)]); line([(8.5, 11.2), (11, 11.2)])
        case .chip:
            box(4.5, 4.5, 7, 7, 1.3)
            for v: CGFloat in [6.5, 9.5] {
                line([(v, 2), (v, 4.5)]); line([(v, 11.5), (v, 14)])
                line([(2, v), (4.5, v)]); line([(11.5, v), (14, v)])
            }
        case .network:
            ring(8, 3.6, 1.6); ring(3.6, 12.2, 1.6); ring(12.4, 12.2, 1.6)
            line([(7.2, 5), (4.4, 10.8)]); line([(8.8, 5), (11.6, 10.8)]); line([(5.2, 12.2), (10.8, 12.2)])
        case .globe:
            ring(8, 8, 5.6)
            p.addEllipse(in: CGRect(x: 5.4, y: 2.4, width: 5.2, height: 11.2))
            line([(2.4, 8), (13.6, 8)])
        case .cloud:
            p.move(to: CGPoint(x: 4.6, y: 12.5))
            p.addLine(to: CGPoint(x: 11.6, y: 12.5))
            p.addArc(center: CGPoint(x: 11.4, y: 9.6), radius: 2.9, startAngle: .degrees(86), endAngle: .degrees(-60), clockwise: true)
            p.addArc(center: CGPoint(x: 7.8, y: 7.6), radius: 3.6, startAngle: .degrees(-22), endAngle: .degrees(-168), clockwise: true)
            p.addArc(center: CGPoint(x: 4.6, y: 10), radius: 2.5, startAngle: .degrees(-128), endAngle: .degrees(90), clockwise: true)
        case .antenna:
            ring(8, 6, 1.2); line([(8, 7.2), (8, 13.6)])
            arc(8, 6, 3.4, 140, 220); arc(8, 6, 3.4, -40, 40)
            arc(8, 6, 5.8, 145, 215); arc(8, 6, 5.8, -35, 35)
        case .wifi:
            arc(8, 12.6, 3, 225, 315); arc(8, 12.6, 6, 225, 315); arc(8, 12.6, 9, 228, 312)
            ring(8, 12.6, 0.5)
        case .plug:
            line([(6.2, 2.4), (6.2, 5)]); line([(9.8, 2.4), (9.8, 5)])
            box(4, 5, 8, 4.6, 1.6)
            line([(8, 9.6), (8, 13.6)])
        case .disk:
            box(2.4, 4.6, 11.2, 7, 2)
            line([(2.4, 8.6), (13.6, 8.6)])
            line([(10.6, 10.1), (11, 10.1)])
        case .shield:
            p.move(to: CGPoint(x: 8, y: 2.2))
            p.addLine(to: CGPoint(x: 13, y: 4)); p.addLine(to: CGPoint(x: 13, y: 7.8))
            p.addQuadCurve(to: CGPoint(x: 8, y: 13.9), control: CGPoint(x: 12.6, y: 12.2))
            p.addQuadCurve(to: CGPoint(x: 3, y: 7.8), control: CGPoint(x: 3.4, y: 12.2))
            p.addLine(to: CGPoint(x: 3, y: 4)); p.closeSubpath()
        case .lock:
            box(3.4, 7.2, 9.2, 6.4, 1.6)
            arc(8, 7.2, 2.8, 180, 360)
            line([(8, 9.6), (8, 11.2)])
        case .terminal:
            box(2.4, 3, 11.2, 10, 1.6)
            line([(5, 6.4), (7, 8), (5, 9.6)]); line([(8.6, 10), (11, 10)])
        case .lab:
            line([(6, 2.5), (10, 2.5)])
            line([(6.8, 2.5), (6.8, 6.6), (3.2, 12.4), (3.6, 13.5), (12.4, 13.5), (12.8, 12.4), (9.2, 6.6), (9.2, 2.5)])
            line([(4.8, 10), (11.2, 10)])
        case .box:
            closed([(8, 2.4), (13.2, 5), (13.2, 11), (8, 13.6), (2.8, 11), (2.8, 5)])
            line([(2.8, 5), (8, 7.6), (13.2, 5)]); line([(8, 7.6), (8, 13.6)])
        case .briefcase:
            box(2.4, 5, 11.2, 8.4, 1.6)
            line([(6, 5), (6, 3.2), (10, 3.2), (10, 5)])
            line([(2.4, 8.8), (13.6, 8.8)])
        case .flag:
            line([(4, 2.4), (4, 13.6)])
            line([(4, 3), (12.4, 3), (10.2, 5.6), (12.4, 8.2), (4, 8.2)])
        case .star:
            closed([(8, 2.2), (9.7, 5.9), (13.6, 6.3), (10.7, 9), (11.5, 13), (8, 11), (4.5, 13), (5.3, 9), (2.4, 6.3), (6.3, 5.9)])
        case .bolt:
            closed([(9.2, 2), (4, 9), (7.8, 9), (6.8, 14), (12, 7), (8.2, 7)])
        case .people:
            ring(6.2, 5.4, 2.2)
            arc(6.2, 13.6, 4.2, 200, 340)
            ring(11.2, 6, 1.7)
            arc(11.6, 13.4, 3.2, 230, 330)
        }
        return p
    }
}

/// The icon's colour (6.1): the user picks, but only from these — the badge
/// and level-bar family, so every choice sits in the app's tone. Hex values
/// match `Theme.badgeColor` / `GroupTree.levelColors`.
nonisolated enum GroupIconColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case blue, teal, violet, mint, sky, orange, amber, rose, slate
    var id: String { rawValue }
    var rgb: UInt32 {
        switch self {
        case .blue: return 0x4F9CF7
        case .teal: return 0x3FB6A8
        case .violet: return 0xA78BFA
        case .mint: return 0x4FD1B5
        case .sky: return 0x7DD3FC
        case .orange: return 0xF0A05A
        case .amber: return 0xF2C14E
        case .rose: return 0xF08BB4
        case .slate: return 0xA3AEC2
        }
    }
}

extension GroupIcon {
    /// For AppKit (the sidebar's cells): the art scaled to `size` points.
    func cgPath(size: CGFloat) -> CGPath {
        path().applying(CGAffineTransform(scaleX: size / 16, y: size / 16)).cgPath
    }
}

/// The icon drawn at `size` points in `color`, the ≡ glyph's stroke.
struct GroupIconView: View {
    let icon: GroupIcon
    var size: CGFloat = 14
    var color: Color

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 16
            let path = icon.path().applying(CGAffineTransform(scaleX: scale, y: scale))
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.4 * scale, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

