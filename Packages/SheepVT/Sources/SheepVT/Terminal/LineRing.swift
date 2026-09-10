// SheepVT — the ring of rows behind one screen (viewport + scrollback).
//
// xterm.js `CircularList` with one change: slots are lazily allocated. A
// 10,000-line scrollback is 10,000 nil references (80 KB) until lines are
// actually produced, and once the ring is full the oldest row is recycled
// rather than freed and reallocated, so steady-state scrolling allocates
// nothing at all.
//
// Indexing is by absolute line number 0..<count, 0 being the oldest retained
// line. `trimmed` counts how many lines have fallen off the top since
// creation, so `trimmed + index` is a scroll-invariant line number.
//
// `subscript` runs once per printed scalar, so the five swift_beginAccess pairs
// it used to pay (`slots` twice, `start`, `count`, `maxLength`) were pure
// overhead on the hot path: see the exclusivity note at the top of `Row.swift`
// for why the enforcement is off here and what still has to hold for it.

public final class LineRing {
    @exclusivity(unchecked) private var slots: [Row?]
    @exclusivity(unchecked) private var start: Int = 0

    @exclusivity(unchecked) public private(set) var maxLength: Int
    @exclusivity(unchecked) public private(set) var count: Int = 0
    @exclusivity(unchecked) public private(set) var trimmed: Int = 0
    @exclusivity(unchecked) public private(set) var cols: Int

    public init(maxLength: Int, cols: Int) {
        let m = Swift.max(maxLength, 1)
        self.maxLength = m
        self.cols = Swift.max(cols, 0)
        self.slots = [Row?](repeating: nil, count: m)
    }

    /// The ring holds as many lines as it can.
    public var isFull: Bool { count == maxLength }

    /// How many slots actually hold a `Row` — the laziness is observable here
    /// (used by the tests; a renderer has no reason to care).
    public var allocatedRowCount: Int {
        var n = 0
        for s in slots where s != nil { n += 1 }
        return n
    }

    @inline(__always)
    private func slotIndex(_ index: Int) -> Int {
        let i = start + index
        return i < maxLength ? i : i % maxLength
    }

    /// Row at an absolute index; a blank row is created on first access.
    public subscript(index: Int) -> Row {
        precondition(index >= 0 && index < count, "LineRing index \(index) out of range 0..<\(count)")
        let s = slotIndex(index)
        if let r = slots[s] { return r }
        let r = Row(cols: cols)
        slots[s] = r
        return r
    }

    /// The row at `index` only if it has been materialised — never allocates.
    public func allocatedRow(at index: Int) -> Row? {
        guard index >= 0 && index < count else { return nil }
        return slots[slotIndex(index)]
    }

    /// Append a blank row. When the ring is full the oldest row is recycled
    /// (cleared in place, `trimmed` incremented) instead of a new one being
    /// allocated. Returns true when a line fell off the top.
    @discardableResult
    public func pushBlank(fill: Cell = .empty) -> Bool {
        if isFull {
            let s = start
            reset(slot: s, fill: fill)
            start = start + 1 == maxLength ? 0 : start + 1
            trimmed += 1
            return true
        } else {
            let s = slotIndex(count)
            reset(slot: s, fill: fill)
            count += 1
            return false
        }
    }

    /// Drop the newest line (buffer shrink). The row object is released.
    @discardableResult
    public func pop() -> Row? {
        guard count > 0 else { return nil }
        let s = slotIndex(count - 1)
        let r = slots[s]
        slots[s] = nil
        count -= 1
        return r
    }

    /// Move the row at `from` to `to`, shifting the rows in between: O(n)
    /// reference moves, no cell copies.
    public func move(from: Int, to: Int) {
        guard from != to, from >= 0, from < count, to >= 0, to < count else { return }
        let moved = slots[slotIndex(from)]
        if from < to {
            for i in from..<to { slots[slotIndex(i)] = slots[slotIndex(i + 1)] }
        } else {
            var i = from
            while i > to { slots[slotIndex(i)] = slots[slotIndex(i - 1)]; i -= 1 }
        }
        slots[slotIndex(to)] = moved
        // Every row whose index changed gets a new generation: the renderer,
        // the search engine and the highlight overlay all cache by
        // (line number, generation), and two rows written the same number of
        // times share a generation — a region scroll would otherwise serve
        // the row that used to live at that line.
        for i in Swift.min(from, to)...Swift.max(from, to) { slots[slotIndex(i)]?.bump() }
    }

    /// Change the capacity. Shrinking drops the oldest lines (and counts them
    /// as trimmed); the slot array is reallocated with `start` back at 0.
    public func setMaxLength(_ n: Int) {
        let m = Swift.max(n, 1)
        guard m != maxLength else { return }
        let keep = Swift.min(m, count)
        let drop = count - keep
        var fresh = [Row?](repeating: nil, count: m)
        for i in 0..<keep { fresh[i] = slots[slotIndex(drop + i)] }
        slots = fresh
        start = 0
        count = keep
        maxLength = m
        trimmed += drop
    }

    /// Replace the whole ring with `rows`, oldest first. `maxLength` is kept and
    /// `start` goes back to 0; when there are more rows than the ring can hold
    /// the oldest are dropped and counted in `trimmed`. Reflow builds the new
    /// line order as a plain array and hands it over in one go, so the ring
    /// never sees an intermediate state (O(n) references, no cell copies).
    public func replaceAll(_ rows: [Row?]) {
        var fresh = [Row?](repeating: nil, count: maxLength)
        let drop = Swift.max(rows.count - maxLength, 0)
        let keep = rows.count - drop
        for i in 0..<keep { fresh[i] = rows[drop + i] }
        slots = fresh
        start = 0
        count = keep
        trimmed += drop
        for r in slots { r?.bump() }   // see `move`: line numbers were reassigned
    }

    /// Convenience for callers that have no lazily-empty slots to preserve.
    public func replaceAll(_ rows: [Row]) {
        replaceAll(rows.map { Optional($0) })
    }

    /// Resize every row that has been materialised (and every recycled one still
    /// parked in the array, so the recycling keeps working after a resize).
    public func resizeRows(cols newCols: Int, fill: Cell) {
        let n = Swift.max(newCols, 0)
        cols = n
        for i in slots.indices {
            slots[i]?.resize(cols: n, fill: fill)
        }
    }

    /// Blank the row at an absolute index in place (clearing `wrapped` and the
    /// side tables) without forcing an allocation when the slot is still empty.
    public func blank(at index: Int, fill: Cell = .empty) {
        guard index >= 0 && index < count else { return }
        reset(slot: slotIndex(index), fill: fill)
    }

    /// Drop the `n` oldest lines (ED 3 / clear scrollback).
    public func trimStart(_ n: Int) {
        let k = Swift.min(Swift.max(n, 0), count)
        guard k > 0 else { return }
        for i in 0..<k { slots[slotIndex(i)] = nil }
        start = slotIndex(k)
        count -= k
        trimmed += k
    }

    /// Blank the row in `slot`, keeping its allocation when it has one. A slot
    /// that is still nil stays nil unless the fill cell carries a background
    /// colour (BCE), in which case the row has to exist to hold it.
    private func reset(slot: Int, fill: Cell) {
        if let r = slots[slot] {
            r.fill(fill)
            r.wrapped = false
        } else if fill != .empty {
            slots[slot] = Row(cols: cols, fill: fill)
        }
    }
}
