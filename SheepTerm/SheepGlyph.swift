// The status bar sheep, DRAWN (the owner's design, 2026-10-22) — no longer the 🐑 emoji, which every OS draws from its
// own font (Apple Color Emoji, Segoe UI Emoji, Noto Color Emoji — or a box where there is none). One shape list, pure
// functions of the pose and the clock, so the Mac, Windows and Linux painters put the same sheep on screen.
//
// A chibi lamb with a dark-brown outline (it has to read at 16 pt on the dark status bar):
//   * walking (connecting) — side view facing RIGHT, a balanced fleece of equal cloud lobes (three over three, one at
//     each side) shaded darker underneath, a round head with a wool cap, both ears, open eyes, blush; four stubby legs
//     whose pairs swing in opposition, and the pose's bob;
//   * asleep (connected) — head on the LEFT resting its chin on the ground, the body a loaf lying FLAT on the ground
//     (wool lumps only on its back), a tucked hoof, closed eyes; the fleece breathes from the ground up, and three z's
//     sit on a rising staircase above the head — small, medium, large — appearing one after another, then fading;
//   * closed — the walking sheep, still and dimmed.
// Asleep, every colour is `sleepBrightness` darker (it must not outshine the bar).
// Units are the design canvas, 44 × 32; a painter scales by `scale` (0.5: 22 × 16 pt), puts the canvas `slotX(pose)` pt
// from the left edge of the `slotWidth(pose)` × 16 slot and vertically centred, moves by the pose's `x` and mirrors the canvas about its centre for a sheep heading LEFT (the pose's `mirrored` is
// "heading right"). Vertically nothing leaves the canvas, z's included; the walking sheep's rump and ear overhang
// it by up to 1 pt at the sides, which the 36 pt slot has room for. A window that is not active has a still sheep.
import Foundation

public enum SheepGlyph {
    public static let width = 44.0, height = 32.0
    /// Design units → points in the status bar.
    public static let scale = 0.5
    /// The slot the bar gives the sheep (pt), 12 pt from the bar's left edge on every platform; `slotWidth(pose)` wide.
    public static let slotWidth = 36.0, slotHeight = 16.0
    /// Asleep the slot is narrower: the lying sheep ends 22 pt in, and the 7 pt after it are the walking sheep's at rest,
    /// so the family badge keeps the same gap from the sheep in both poses (the owner, 2026-10-22).
    public static let sleepingSlotWidth = 29.0
    public static func slotWidth(_ pose: SheepPose) -> Double {
        if case .sleeping = pose { return sleepingSlotWidth }
        return slotWidth
    }

    /// Where the canvas's left edge sits, in pt from the slot's left edge. The walking (and closed) sheep is centred in
    /// the slot; the sleeping sheep moves left until its largest z starts exactly at the slot's edge — 12 pt from the
    /// bar's left edge, the same gap as the clock keeps from the right edge (the owner, 2026-10-22).
    public static func slotX(_ pose: SheepPose) -> Double {
        if case .sleeping = pose { let z = zSlots[2]; return -(z.x - z.width / 2) * scale }
        return (slotWidth - width * scale) / 2
    }

    /// Fill and/or outline of a closed shape.
    public struct Paint: Equatable, Sendable {
        public var fill: UInt32?
        public var stroke: UInt32?
        public var strokeWidth: Double
        public var alpha: Double
        public init(fill: UInt32? = nil, stroke: UInt32? = nil, strokeWidth: Double = 0, alpha: Double = 1) {
            self.fill = fill; self.stroke = stroke; self.strokeWidth = strokeWidth; self.alpha = alpha
        }
    }

    /// One thing to paint, in design units. Rotations are degrees, clockwise (the y axis points down). Paint the list in
    /// order: for each shape the fill, then its outline.
    public enum Shape: Equatable, Sendable {
        case circle(cx: Double, cy: Double, r: Double, paint: Paint)
        case ellipse(cx: Double, cy: Double, rx: Double, ry: Double, rotation: Double, paint: Paint)
        case roundedRect(x: Double, y: Double, w: Double, h: Double, radius: Double, paint: Paint)
        /// A leg: a bar of `w × h` with round ends, hanging from (`hipX`, `hipY`) — the middle of its top — and turned by
        /// `rotation` about that point.
        case leg(hipX: Double, hipY: Double, w: Double, h: Double, rotation: Double, paint: Paint)
        /// An open polyline with round caps and joins (a closed eye, the mouth, the ground, a z): x0, y0, x1, y1, …
        case polyline(points: [Double], width: Double, rgb: UInt32, alpha: Double)
        /// Until `endClip`, paint only ABOVE `y` (the sleeping sheep's ground).
        case clipAbove(y: Double)
        case endClip
    }

    public enum Palette {
        public static let outline: UInt32 = 0x4A3B35
        public static let wool: UInt32 = 0xFFFCF6, woolShade: UInt32 = 0xEDE3D3
        public static let face: UInt32 = 0xF3DCC6, earInner: UInt32 = 0xF2B4AA, blush: UInt32 = 0xF4A9A0
        public static let eye: UInt32 = 0x3A2C27, nose: UInt32 = 0x7A4A44
        public static let legNear: UInt32 = 0x6B5A52, legFar: UInt32 = 0x4F423B
        public static let z: UInt32 = 0xF0E6D6
    }

    // MARK: motion

    /// One stride: each leg pair swings forward and back once.
    public static let stridePeriod = 0.4, legSwing = 18.0
    public static let breathPeriod = 3.0, breath = 0.05
    /// The z's cycle: each appears at its `zAppear` fraction, all hold, all fade out together.
    public static let zPeriod = 3.2
    public static let zAppear: [Double] = [0, 0.18, 0.38]
    public static let closedAlpha = 0.25
    /// The sleeping sheep (z's included) is drawn this much darker than the awake one: asleep it stood out too much on the
    /// bar (the owner, 2026-10-22). Colours, not alpha — a translucent sheep would show its outline lobes through the wool.
    public static let sleepBrightness = 0.8

    /// The shapes for `pose` at `time` (seconds, any clock), in paint order.
    public static func shapes(_ pose: SheepPose, time: Double, windowActive: Bool = true) -> [Shape] {
        switch pose {
        case .walking(_, let bob, _):
            let swing = windowActive ? legSwing * sin(2 * .pi * time / stridePeriod) : 0
            return standing(swing: swing, bob: windowActive ? bob : 0, alpha: 1)
        case .closed:
            return standing(swing: 0, bob: 0, alpha: closedAlpha)
        case .sleeping:
            let lift = windowActive ? breath * (1 - cos(2 * .pi * time / breathPeriod)) / 2 : 0
            return (lying(breathe: lift) + zs(time: time, moving: windowActive)).map { darker($0, by: sleepBrightness) }
        }
    }

    /// `shape` with every colour scaled by `k` (0…1) towards black.
    static func darker(_ shape: Shape, by k: Double) -> Shape {
        func c(_ rgb: UInt32) -> UInt32 {
            let ch = [rgb >> 16, rgb >> 8, rgb].map { UInt32((Double($0 & 255) * k).rounded()) }
            return ch[0] << 16 | ch[1] << 8 | ch[2]
        }
        func p(_ paint: Paint) -> Paint { Paint(fill: paint.fill.map(c), stroke: paint.stroke.map(c), strokeWidth: paint.strokeWidth, alpha: paint.alpha) }
        switch shape {
        case .circle(let cx, let cy, let r, let paint): return .circle(cx: cx, cy: cy, r: r, paint: p(paint))
        case .ellipse(let cx, let cy, let rx, let ry, let rot, let paint): return .ellipse(cx: cx, cy: cy, rx: rx, ry: ry, rotation: rot, paint: p(paint))
        case .roundedRect(let x, let y, let w, let h, let r, let paint): return .roundedRect(x: x, y: y, w: w, h: h, radius: r, paint: p(paint))
        case .leg(let hx, let hy, let w, let h, let rot, let paint): return .leg(hipX: hx, hipY: hy, w: w, h: h, rotation: rot, paint: p(paint))
        case .polyline(let pts, let width, let rgb, let alpha): return .polyline(points: pts, width: width, rgb: c(rgb), alpha: alpha)
        case .clipAbove, .endClip: return shape
        }
    }

    // MARK: walking

    static func standing(swing: Double, bob: Double, alpha: Double) -> [Shape] {
        let o = Palette.outline
        func p(_ fill: UInt32?, stroke: UInt32? = nil, _ w: Double = 0) -> Paint { Paint(fill: fill, stroke: stroke, strokeWidth: w, alpha: alpha) }
        // The legs first, under the fleece: far pair darker, each pair swinging against the other.
        var s: [Shape] = [
            .leg(hipX: 11.5, hipY: 21.4, w: 3.4, h: 7.8, rotation: -swing, paint: p(Palette.legFar, stroke: o, 0.9)),
            .leg(hipX: 23.5, hipY: 21.4, w: 3.4, h: 7.8, rotation: swing, paint: p(Palette.legFar, stroke: o, 0.9)),
            .leg(hipX: 8.5, hipY: 21.8, w: 3.4, h: 7.8, rotation: swing, paint: p(Palette.legNear, stroke: o, 0.9)),
            .leg(hipX: 20.5, hipY: 21.8, w: 3.4, h: 7.8, rotation: -swing, paint: p(Palette.legNear, stroke: o, 0.9)),
        ]
        let b = bob
        // The fleece: equal lobes, three over three and one at each side — the back lobe IS the round rump (a small tail
        // puff on it read as a point at 16 pt). Outline = the same lobes 0.9 larger in the outline colour, under the
        // fills, so only the union's edge shows.
        let lobes: [(Double, Double)] = [(9.5, 10.6), (15.5, 9.6), (21.5, 10.6), (9.5, 20.9), (15.5, 21.9), (21.5, 20.9),
                                         (5, 15.75), (26, 15.75)]
        s += lobes.map { .circle(cx: $0.0, cy: $0.1 + b, r: 5.9, paint: p(o)) }
        // the shaded underside and sides
        s += lobes[3...].map { .circle(cx: $0.0, cy: $0.1 + b, r: 5, paint: p(Palette.woolShade)) }
        // the light top and middle
        let light: [(Double, Double, Double)] = [(15.5, 15.75, 7.6), (9.5, 10.6, 5), (15.5, 9.6, 5), (21.5, 10.6, 5),
                                                 (6.2, 15.2, 3.7), (24.8, 15.2, 3.7), (9.9, 19.4, 3.6), (15.5, 20.2, 3.6),
                                                 (21.1, 19.4, 3.6)]
        s += light.map { .circle(cx: $0.0, cy: $0.1 + b, r: $0.2, paint: p(Palette.wool)) }
        // the head: both ears out to the sides, a round face, the wool cap
        s += [
            .ellipse(cx: 24.4, cy: 13.4 + b, rx: 3.6, ry: 1.9, rotation: -24, paint: p(Palette.face, stroke: o, 0.9)),
            .ellipse(cx: 24.7, cy: 13.3 + b, rx: 2, ry: 0.85, rotation: -24, paint: p(Palette.earInner)),
            .ellipse(cx: 39.6, cy: 13.4 + b, rx: 3.6, ry: 1.9, rotation: 24, paint: p(Palette.face, stroke: o, 0.9)),
            .ellipse(cx: 39.3, cy: 13.3 + b, rx: 2, ry: 0.85, rotation: 24, paint: p(Palette.earInner)),
            .circle(cx: 32, cy: 14.4 + b, r: 7.4, paint: p(Palette.face, stroke: o, 0.9)),
            .circle(cx: 28.4, cy: 8.2 + b, r: 3.3, paint: p(o)),
            .circle(cx: 32, cy: 6.9 + b, r: 3.7, paint: p(o)),
            .circle(cx: 35.6, cy: 8.2 + b, r: 3.3, paint: p(o)),
            .circle(cx: 28.4, cy: 8.2 + b, r: 2.4, paint: p(Palette.wool)),
            .circle(cx: 32, cy: 6.9 + b, r: 2.8, paint: p(Palette.wool)),
            .circle(cx: 35.6, cy: 8.2 + b, r: 2.4, paint: p(Palette.wool)),
            .roundedRect(x: 27.4, y: 7.8 + b, w: 9.2, h: 2.8, radius: 0, paint: p(Palette.wool)),
            // eyes with a catch-light, cheeks, a small smile
            .circle(cx: 29.3, cy: 14.6 + b, r: 1.15, paint: p(Palette.eye)),
            .circle(cx: 34.7, cy: 14.6 + b, r: 1.15, paint: p(Palette.eye)),
            .circle(cx: 29.7, cy: 14.2 + b, r: 0.42, paint: p(0xFFFFFF)),
            .circle(cx: 35.1, cy: 14.2 + b, r: 0.42, paint: p(0xFFFFFF)),
            .ellipse(cx: 27.7, cy: 17.3 + b, rx: 1.4, ry: 0.7, rotation: 0, paint: p(Palette.blush)),
            .ellipse(cx: 36.3, cy: 17.3 + b, rx: 1.4, ry: 0.7, rotation: 0, paint: p(Palette.blush)),
            .polyline(points: arc(31.1, 17.6, 32, 18.5, 32.9, 17.6, dy: b), width: 0.8, rgb: o, alpha: alpha),
        ]
        return s
    }

    // MARK: asleep

    /// The sleeping sheep is drawn at 0.84 and moved right and down (`sleepOrigin`), which leaves the top-left of the
    /// canvas free for the z's; `ground` is where its belly and chin rest, before that placement.
    public static let sleepScale = 0.84, sleepOrigin = (x: 6.0, y: 4.0), ground = 29.5
    /// The ground in canvas units (after the placement).
    public static var canvasGround: Double { sleepOrigin.y + ground * sleepScale }

    static func lying(breathe: Double) -> [Shape] {
        let o = Palette.outline, k = sleepScale
        func X(_ x: Double) -> Double { sleepOrigin.x + x * k }
        func Y(_ y: Double) -> Double { sleepOrigin.y + y * k }
        func L(_ v: Double) -> Double { v * k }
        func p(_ fill: UInt32?, stroke: UInt32? = nil, _ w: Double = 0) -> Paint { Paint(fill: fill, stroke: stroke, strokeWidth: L(w), alpha: 1) }
        // The body breathes from the ground up: its y is stretched about the ground by `1 + breathe`.
        let lift = 1 + breathe
        func BY(_ y: Double) -> Double { Y(ground + (y - ground) * lift) }
        func BL(_ v: Double) -> Double { L(v) * lift }
        var s: [Shape] = [.clipAbove(y: canvasGround)]
        s.append(.roundedRect(x: X(14.1), y: BY(12.6), w: L(29.8), h: BL(17.8), radius: L(8.9), paint: p(o)))
        let bumps: [(Double, Double, Double)] = [(21, 15, 3.5), (27, 12.8, 4), (33.4, 13.4, 3.7), (39, 16.4, 3.1), (42.4, 19, 2.3)]
        s += bumps.map { .circle(cx: X($0.0), cy: BY($0.1), r: L($0.2 + 0.9), paint: p(o)) }
        s.append(.roundedRect(x: X(15), y: BY(13.5), w: L(28), h: BL(16), radius: L(8), paint: p(Palette.wool)))
        s += bumps.map { .circle(cx: X($0.0), cy: BY($0.1), r: L($0.2), paint: p(Palette.wool)) }
        s.append(.endClip)
        s += [
            .polyline(points: [X(14), Y(ground), X(42), Y(ground)], width: L(0.9), rgb: o, alpha: 1),
            .roundedRect(x: X(17.4), y: Y(25.2), w: L(5.4), h: L(4.3), radius: L(2.1), paint: p(Palette.legNear, stroke: o, 0.9)),
            .ellipse(cx: X(3.9), cy: Y(18.6), rx: L(3.9), ry: L(2), rotation: -22, paint: p(Palette.face, stroke: o, 0.9)),
            .ellipse(cx: X(4.2), cy: Y(18.6), rx: L(2.2), ry: L(0.9), rotation: -22, paint: p(Palette.earInner)),
            .ellipse(cx: X(22.3), cy: Y(18.6), rx: L(3.9), ry: L(2), rotation: 22, paint: p(Palette.face, stroke: o, 0.9)),
            .ellipse(cx: X(22), cy: Y(18.6), rx: L(2.2), ry: L(0.9), rotation: 22, paint: p(Palette.earInner)),
            .clipAbove(y: canvasGround),
            .ellipse(cx: X(13), cy: Y(21.5), rx: L(8.6), ry: L(8.3), rotation: 0, paint: p(Palette.face, stroke: o, 0.9)),
            .endClip,
            .polyline(points: [X(4.6), Y(ground), X(21.4), Y(ground)], width: L(0.9), rgb: o, alpha: 1),
            .circle(cx: X(8), cy: Y(13.6), r: L(3.5), paint: p(o)),
            .circle(cx: X(12.6), cy: Y(12), r: L(3.9), paint: p(o)),
            .circle(cx: X(17.6), cy: Y(13.4), r: L(3.5), paint: p(o)),
            .circle(cx: X(8), cy: Y(13.6), r: L(2.6), paint: p(Palette.wool)),
            .circle(cx: X(12.6), cy: Y(12), r: L(3), paint: p(Palette.wool)),
            .circle(cx: X(17.6), cy: Y(13.4), r: L(2.6), paint: p(Palette.wool)),
            .roundedRect(x: X(7), y: Y(13), w: L(11.4), h: L(3), radius: 0, paint: p(Palette.wool)),
            .polyline(points: arc(X(7.6), Y(20.4), X(9.2), Y(21.9), X(10.8), Y(20.4)), width: L(0.9), rgb: o, alpha: 1),
            .polyline(points: arc(X(15.2), Y(20.4), X(16.8), Y(21.9), X(18.4), Y(20.4)), width: L(0.9), rgb: o, alpha: 1),
            .ellipse(cx: X(7), cy: Y(23.6), rx: L(1.6), ry: L(0.8), rotation: 0, paint: p(Palette.blush)),
            .ellipse(cx: X(19), cy: Y(23.6), rx: L(1.6), ry: L(0.8), rotation: 0, paint: p(Palette.blush)),
            .ellipse(cx: X(13), cy: Y(24.6), rx: L(0.85), ry: L(1.05), rotation: 0, paint: p(Palette.nose, stroke: o, 0.5)),
        ]
        return s
    }

    /// A smile/closed-eye curve: the quadratic from (x0, y0) through control (cx, cy) to (x1, y1), as five points.
    static func arc(_ x0: Double, _ y0: Double, _ cx: Double, _ cy: Double, _ x1: Double, _ y1: Double, dy: Double = 0) -> [Double] {
        (0...4).flatMap { i -> [Double] in
            let t = Double(i) / 4, u = 1 - t
            return [u * u * x0 + 2 * u * t * cx + t * t * x1, u * u * y0 + 2 * u * t * cy + t * t * y1 + dy]
        }
    }

    // MARK: the z's

    /// Small, medium, large on a staircase rising up-left from the head (canvas units: origin, letter size, stroke).
    public static let zSlots: [(x: Double, y: Double, size: Double, width: Double)] = [
        (10.6, 10.4, 1.9, 0.8), (6.0, 6.0, 2.7, 0.95), (0.8, 1.6, 3.6, 1.1),   // 0.8 down: room for the drift up
    ]

    /// The z's at `time`. Still window: all three, steady.
    static func zs(time: Double, moving: Bool) -> [Shape] {
        let t = moving ? (time / zPeriod).truncatingRemainder(dividingBy: 1) : 0.6
        return zSlots.indices.map { i in
            let (alpha, dy) = zState(t, appear: zAppear[i])
            let z = zSlots[i], w = z.size, h = z.size * 1.06
            let pts = [z.x, z.y + dy, z.x + w, z.y + dy, z.x, z.y + h + dy, z.x + w, z.y + h + dy]
            return .polyline(points: pts, width: z.width, rgb: Palette.z, alpha: alpha)
        }
    }

    /// One z through the cycle: in over 0.08 from `appear` (rising 0.6 into place), hold to 0.8 (drifting up 0.6),
    /// out by 0.92, gone until the cycle starts again.
    public static func zState(_ t: Double, appear: Double) -> (alpha: Double, dy: Double) {
        if t < appear { return (0, 0.6) }
        if t < appear + 0.08 { let f = (t - appear) / 0.08; return (f, 0.6 * (1 - f)) }
        if t < 0.8 { return (1, -0.6 * (t - appear - 0.08) / max(0.0001, 0.8 - appear - 0.08)) }
        if t < 0.92 { let f = (t - 0.8) / 0.12; return (1 - f, -0.6 - 0.2 * f) }
        return (0, -0.8)
    }
}
