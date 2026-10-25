import CoreGraphics
import Foundation

/// The index arithmetic of moving a tab, kept pure so the harness tests the
/// real function (the tab strip and the Move Tab menu items both call it).
///
/// A drag lands in a GAP, not on a tab: gap `g` is "before the tab that is at
/// index g right now", and `count` is "after the last one". The gap is counted
/// in the order BEFORE the dragged tab is removed — the same convention as the
/// sidebar's group reorder, whose index-past-the-end crash (ARCHITECTURE §11)
/// is why every input here is clamped instead of trusted.
nonisolated enum TabOrder {
    /// The index the moved element ends up at, or nil when the move is a
    /// no-op (dropped into either gap that touches its own position, or a
    /// `from` that is not in range).
    static func destination(from: Int, toGap gap: Int, count: Int) -> Int? {
        guard count > 1, (0..<count).contains(from) else { return nil }
        let gap = min(max(gap, 0), count)
        // Removing `from` first shifts every later gap one to the left.
        let target = gap > from ? gap - 1 : gap
        return target == from ? nil : target
    }

    /// `array` with the element at `from` moved into gap `gap`; unchanged when
    /// `destination` says the move is a no-op.
    static func moved<T>(_ array: [T], from: Int, toGap gap: Int) -> [T] {
        guard let target = destination(from: from, toGap: gap, count: array.count) else { return array }
        var result = array
        let element = result.remove(at: from)
        result.insert(element, at: target)
        return result
    }

    /// Where a dragged tab would land — its index once the move is done —
    /// from the frames measured when the drag BEGAN and how far it has
    /// travelled (SheepText's `TabDragGeometry`, 4.2 (1)). A neighbour
    /// counts as passed once the dragged chip's leading edge crosses its
    /// midpoint: the right edge for chips to the right, the left edge for
    /// chips to the left. A chip with no frame is off screen on the side its
    /// index says. Nil when the dragged tab is unknown or unmeasured.
    static func dragTarget(order: [UUID], frames: [UUID: CGRect], dragged: UUID,
                           translation: CGFloat) -> Int? {
        guard let source = frames[dragged], order.contains(dragged) else { return nil }
        let minX = source.minX + translation
        let maxX = source.maxX + translation
        let firstMeasured = order.firstIndex { frames[$0] != nil } ?? 0
        var target = 0
        for (index, other) in order.enumerated() where other != dragged {
            let passed: Bool
            if let frame = frames[other] {
                passed = frame.midX > source.midX ? maxX >= frame.midX : minX > frame.midX
            } else {
                passed = index < firstMeasured
            }
            if passed { target += 1 }
        }
        return target
    }

    /// The gap (`moved`'s convention) that puts the tab at `index` from `from`.
    static func gap(forFinalIndex index: Int, from: Int) -> Int {
        index > from ? index + 1 : index
    }

    /// The gap a keyboard "move left/right by one" means: left is the gap
    /// before the left neighbour, right the gap after the right neighbour.
    /// Nil at either end — Move Tab does not wrap around.
    static func gap(movingOneStep from: Int, right: Bool, count: Int) -> Int? {
        guard (0..<count).contains(from) else { return nil }
        if right { return from + 1 < count ? from + 2 : nil }
        return from > 0 ? from - 1 : nil
    }

    /// What the pointer is over while a pane header is dragged across the
    /// tab strip (6.0 (3)).
    enum StripHit: Equatable {
        /// The middle of chip `index`: join that tab.
        case chip(Int)
        /// Gap `index` (this enum's convention): a tab of its own there.
        case gap(Int)
    }

    /// `frames` are the chips' laid-out frames in order (before any shift);
    /// while gap `open` shows its ghost, every chip from `open` on is drawn
    /// `shift` further right, and the ghost fills the hole. The outer
    /// `edge` share of a chip on either side is the gap beside it, the rest
    /// is the chip; left of every chip = gap 0, right of every chip = the
    /// end. Only x counts: the strip is one row.
    static func stripHit(x: CGFloat, frames: [CGRect], open: Int?, shift: CGFloat,
                         spacing: CGFloat, edge: CGFloat = 0.25) -> StripHit {
        guard !frames.isEmpty else { return .gap(0) }
        let open = open.map { min(max($0, 0), frames.count) }
        func visual(_ index: Int) -> CGRect {
            guard let open, index >= open else { return frames[index] }
            return frames[index].offsetBy(dx: shift, dy: 0)
        }
        if let open {
            let start = open < frames.count ? frames[open].minX : frames[frames.count - 1].maxX + spacing
            if x >= start, x < start + shift { return .gap(open) }
        }
        for index in frames.indices {
            let frame = visual(index)
            guard x >= frame.minX, x <= frame.maxX, frame.width > 0 else { continue }
            let share = (x - frame.minX) / frame.width
            if share < edge { return .gap(index) }
            if share > 1 - edge { return .gap(index + 1) }
            return .chip(index)
        }
        return x < visual(0).minX ? .gap(0) : .gap(frames.count)
    }
}
