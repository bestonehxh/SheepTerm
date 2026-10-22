import SwiftUI

/// The status bar sheep, drawn (`SheepGlyph`: the same shapes Windows and Linux paint, so no emoji font decides what
/// it looks like), placed in its slot by `SheepGlyph.slotX` / `slotWidth`. The glyph faces right; the pose's `mirrored` means "heading right" (the old
/// emoji faced left), so a sheep heading left is the one that is flipped.
struct SheepGlyphView: View {
    let pose: SheepPose
    var time: Double = 0
    var windowActive = true

    /// Room on each side of the slot: the walk and the sleeping sheep's z's reach past the slot, and a Canvas clips to its frame.
    private static let overhang = 16.0

    var body: some View {
        Canvas { ctx, size in
            var dx = 0.0, flip = false
            if case .walking(let x, _, let mirrored) = pose { dx = x; flip = !mirrored }
            let s = SheepGlyph.scale
            ctx.translateBy(x: (Self.overhang + SheepGlyph.slotX(pose) + dx).rounded(),
                            y: ((size.height - SheepGlyph.height * s) / 2).rounded())
            ctx.scaleBy(x: s, y: s)
            if flip { ctx.translateBy(x: SheepGlyph.width, y: 0); ctx.scaleBy(x: -1, y: 1) }
            SheepPaint.draw(SheepGlyph.shapes(pose, time: time, windowActive: windowActive), in: ctx)
        }
        .frame(width: SheepGlyph.slotWidth(pose) + 2 * Self.overhang, height: SheepGlyph.slotHeight)
        .frame(width: SheepGlyph.slotWidth(pose), height: SheepGlyph.slotHeight)      // lays out as the slot, draws past it
        .allowsHitTesting(false)
    }
}

/// `SheepGlyph.Shape` through a SwiftUI `GraphicsContext`, in design units (Linux `SheepPaint` is the reference:
/// fill then outline per shape, polylines with round caps, `clipAbove` … `endClip` = paint only above that y).
enum SheepPaint {
    static func draw(_ shapes: [SheepGlyph.Shape], in base: GraphicsContext) {
        var stack = [base]                       // .clipAbove pushes a clipped copy, .endClip pops it
        for shape in shapes {
            let ctx = stack[stack.count - 1]
            switch shape {
            case .circle(let cx, let cy, let r, let p):
                paint(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)), p, ctx)
            case .ellipse(let cx, let cy, let rx, let ry, let rotation, let p):
                let path = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry))
                paint(path.applying(turn(rotation, cx, cy)), p, ctx)
            case .roundedRect(let x, let y, let w, let h, let radius, let p):
                paint(rounded(CGRect(x: x, y: y, width: w, height: h), radius), p, ctx)
            case .leg(let hipX, let hipY, let w, let h, let rotation, let p):
                paint(rounded(CGRect(x: -w / 2, y: 0, width: w, height: h), w / 2).applying(turn(rotation, hipX, hipY)), p, ctx)
            case .polyline(let points, let width, let rgb, let alpha):
                guard points.count >= 4, alpha > 0 else { continue }
                var path = Path()
                path.move(to: CGPoint(x: points[0], y: points[1]))
                for k in stride(from: 2, to: points.count - 1, by: 2) { path.addLine(to: CGPoint(x: points[k], y: points[k + 1])) }
                ctx.stroke(path, with: .color(color(rgb, alpha)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            case .clipAbove(let y):
                var clipped = ctx
                clipped.clip(to: Path(CGRect(x: -1000, y: -1000, width: 2000, height: 1000 + y)))
                stack.append(clipped)
            case .endClip:
                if stack.count > 1 { stack.removeLast() }
            }
        }
    }

    private static func paint(_ path: Path, _ p: SheepGlyph.Paint, _ ctx: GraphicsContext) {
        if let f = p.fill { ctx.fill(path, with: .color(color(f, p.alpha))) }
        if let st = p.stroke, p.strokeWidth > 0 {
            ctx.stroke(path, with: .color(color(st, p.alpha)), style: StrokeStyle(lineWidth: p.strokeWidth, lineJoin: .round))
        }
    }

    /// Rotate by `degrees` (clockwise, y down) about the origin, then move to (x, y).
    private static func turn(_ degrees: Double, _ x: Double, _ y: Double) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: degrees * .pi / 180).concatenating(CGAffineTransform(translationX: x, y: y))
    }

    private static func rounded(_ r: CGRect, _ radius: Double) -> Path {
        let c = min(radius, r.width / 2, r.height / 2)
        return c > 0 ? Path(roundedRect: r, cornerRadius: c, style: .circular) : Path(r)
    }

    private static func color(_ rgb: UInt32, _ alpha: Double) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255, opacity: alpha)
    }
}
