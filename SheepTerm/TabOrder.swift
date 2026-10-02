/// The index arithmetic of moving a tab, kept pure so the harness tests the
/// real function (the tab strip and the Move Tab menu items both call it).
///
/// A drag lands in a GAP, not on a tab: gap `g` is "before the tab that is at
/// index g right now", and `count` is "after the last one". The gap is counted
/// in the order BEFORE the dragged tab is removed — the same convention as the
/// sidebar's group reorder, whose index-past-the-end crash (ARCHITECTURE §11)
/// is why every input here is clamped instead of trusted.
enum TabOrder {
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

    /// The drop gap for a drag. The strip measures only the OTHER chips (the
    /// dragged one's frame travels with the pointer): `othersLeft` of them
    /// lie left of the pointer, which is a gap in the array WITHOUT the
    /// dragged tab — one at or past its old slot is one further along in the
    /// array that still has it.
    static func dragGap(othersLeftOfPointer othersLeft: Int, from: Int) -> Int {
        othersLeft >= from ? othersLeft + 1 : othersLeft
    }

    /// The gap a keyboard "move left/right by one" means: left is the gap
    /// before the left neighbour, right the gap after the right neighbour.
    /// Nil at either end — Move Tab does not wrap around.
    static func gap(movingOneStep from: Int, right: Bool, count: Int) -> Int? {
        guard (0..<count).contains(from) else { return nil }
        if right { return from + 1 < count ? from + 2 : nil }
        return from > 0 ? from - 1 : nil
    }
}
