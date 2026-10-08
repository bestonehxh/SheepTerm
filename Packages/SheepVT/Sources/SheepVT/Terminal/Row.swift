// SheepVT — one line of the grid.
//
// A flat `UnsafeMutableBufferPointer<Cell>` owned by the row (12 bytes per
// cell, no per-cell heap object) plus two side tables that stay nil until a
// cell actually needs them: `combined` for grapheme clusters longer than one
// scalar, `extended` for underline style/colour and hyperlinks. Every public
// mutator bumps `generation` so a renderer or the highlighter can cache on it.
//
// Wide-character invariant: a width-2 cell is always followed by a width-0
// spacer. Anything that shifts cells sideways (ICH/DCH) or cuts the row short
// must never leave half a wide character behind — the orphan half is replaced
// by the fill cell. The rules mirror xterm.js `BufferLine` (MIT).
//
// -- Why the grid's stored properties are `@exclusivity(unchecked)` --
//
// Every `var` stored on a class costs a swift_beginAccess/endAccess pair: a
// thread-local lookup plus an insert into and a removal from that thread's set
// of open accesses. Printing one scalar touches ~58 of them across Terminal,
// Buffer, LineRing and Row, and a profile of the Unicode workload put 57% of
// all samples inside that machinery (AccessSet::insert, SwiftTLSContext::get,
// swift_beginAccess). Compiling the identical source with
// `-enforce-exclusivity=unchecked` runs 2.8x faster on ASCII and 2.6x on
// Unicode — that check *is* the whole gap, not bounds checks or preconditions.
//
// Dropping it here is sound because of what dynamic enforcement actually
// catches: two overlapping *formal* accesses to the same property on the same
// thread. Its access set is thread-local, so it never saw a cross-thread race
// to begin with — the grid classes are non-Sendable, which is what keeps them
// on one isolation domain, and that is a static guarantee the attribute does
// not touch. What is left is the single-threaded overlap, and it needs a
// property to be open across a call that reaches the same property again: an
// `inout` argument, a `modify` coroutine yielded across user code, or a
// mutating method re-entered on the same object. None of the annotated
// properties is ever passed `inout` (grep for `&` on them: no hits), none is
// yielded to a caller (all are read or assigned whole, or subscripted, inside
// the class's own methods), and no method of Row, LineRing or Buffer calls back
// out to anything that can re-enter that same object — `Row.resize` and
// `Row.fill` are leaves, and `LineRing.move`/`replaceAll` only touch `Row`.
// The two dictionaries are the closest call, and the code already takes them
// out of the property before mutating (see `writeASCIIRun`), which is the same
// discipline written by hand.
//
// Bounds checks, the wide-pair preconditions and copy-on-write all stay: this
// removes the exclusivity bookkeeping only. `Buffer.swift`, `LineRing.swift` and
// `Terminal.swift` carry the same annotation for the same reason and point back
// here; `Terminal.swift` has its own note, because it is the one class the
// delegate can re-enter.
//
// The claim above is true today and nothing in the compiler keeps it true: the
// annotation is precisely the loss of `-enforce-exclusivity=checked` as an
// audit. `./Tests/run.sh vt-exclusivity` gives that back — it copies the package
// to a scratch tree, strips every annotation from the copy (printing the count
// per file, so you can see it happened), and runs the whole suite there in Debug
// with enforcement on, where every access marker is still dynamic. An
// overlapping access traps and names itself. Run it after adding a property to
// the annotated set, and after any change that makes one of these classes call
// out to something that could reach back in.

public final class Row {
    /// Cells owned by this row, exactly `cols` of them.
    public var cells: UnsafeMutableBufferPointer<Cell> {
        UnsafeMutableBufferPointer(start: storage, count: cols)
    }

    @exclusivity(unchecked) public private(set) var cols: Int

    /// Soft-wrapped: this row continues the previous one (xterm.js `isWrapped`).
    @exclusivity(unchecked) public var wrapped: Bool = false {
        didSet {
            if wrapped != oldValue {
                // A row that stops continuing anything has no row above it to
                // own a gap for, so the claim below goes with it. That one line
                // is what makes the flag survivable: every path that re-parents
                // a row (IL/DL, a scroll region, `LineRing.reset`) already
                // clears `wrapped`, so none of them has to know about the gap.
                if !wrapped { wrapGapBefore = false }
                bump()
            }
        }
    }

    /// Only meaningful while `wrapped`: the last cell of the row ABOVE this one
    /// is not content — it is the gap left when this row's first character, a
    /// wide one, did not fit at the right margin and was pushed down here.
    ///
    /// Reflow needs to know that (a logical line is one cell shorter than it
    /// looks), and xterm.js infers it from the cells: last cell NUL + next row
    /// starts wide. The inference is wrong, because an overwrite leaves exactly
    /// the same shape with no gap anywhere — see `Buffer+Reflow`'s
    /// `wrappedTrimmedLength` and fuzz finding 2. The two shapes are
    /// indistinguishable from the cells, so the emulator records which one it
    /// made, at the three places that can make a gap: the wide-character wrap in
    /// `Terminal.print`, and the two reflow directions.
    ///
    /// It is deliberately NOT cleared when column 0 is rewritten. The flag is a
    /// statement about the row *above*, and that row's last cell is untouched by
    /// anything written here; a new character at column 0 either is wide (the
    /// gap above is still exactly as wide as it needs to be) or is not, in which
    /// case `wrappedTrimmedLength`'s cell test vetoes the flag anyway. Keeping
    /// it out of the subscript setter keeps the hot path a store and two loads.
    ///
    /// No `bump()`: nothing painted changes when this flips.
    @exclusivity(unchecked) public var wrapGapBefore: Bool = false

    /// Bumped on every mutation through the public API.
    @exclusivity(unchecked) public private(set) var generation: UInt64 = 0

    /// Full grapheme string for cells with `isCombined` (col → string). nil when none.
    @exclusivity(unchecked) public private(set) var combined: [Int: String]?

    /// Extended attributes for cells with `hasExtended` (col → attrs). nil when none.
    @exclusivity(unchecked) public private(set) var extended: [Int: ExtendedAttributes]?

    /// Conservative membership filters over the two side tables: bit `col & 63`
    /// is set whenever a column congruent to `col` mod 64 **may** hold an
    /// entry. Every key of `combined` has its bit set in `combinedMask` (same
    /// for `extended`), so a clear bit is a proof of absence — which is what
    /// the hot write path needs: overwriting a cell has to drop a stale entry,
    /// and without the filter that is a hashed dictionary probe on every single
    /// cell of every row that holds one grapheme cluster anywhere. A set bit
    /// proves nothing and simply falls through to the dictionary, so the filter
    /// is never load-bearing for correctness: bits are only ever added (and
    /// cleared wholesale when a table goes back to nil).
    ///
    /// `writeASCIIRun` and `fill` lean on the same proof for a whole range at a
    /// time (`maskBits`), which is why a range of 64 columns or more has to
    /// collapse to "every bit set" rather than wrap around and clear one.
    @exclusivity(unchecked) private var combinedMask: UInt64 = 0
    @exclusivity(unchecked) private var extendedMask: UInt64 = 0

    @inline(__always)
    private static func maskBit(_ col: Int) -> UInt64 { 1 &<< UInt64(col & 63) }

    /// Bits for `[col, col + count)` — a circular run of `count` bits starting
    /// at `col & 63`, or every bit once the run is 64 wide.
    @inline(__always)
    private static func maskBits(_ col: Int, _ count: Int) -> UInt64 {
        if count >= 64 { return ~0 }
        let run: UInt64 = (1 &<< UInt64(count)) &- 1
        let s = UInt64(col & 63)
        if s == 0 { return run }
        return (run &<< s) | (run &>> (64 &- s))
    }

    /// Backing allocation. `capacity >= cols`; shrinking keeps the allocation so
    /// a later grow back to the old width costs nothing (xterm.js does the same
    /// with a subarray view).
    @exclusivity(unchecked) private var storage: UnsafeMutablePointer<Cell>
    @exclusivity(unchecked) private var capacity: Int

    public init(cols: Int, fill: Cell = .empty) {
        let n = Swift.max(cols, 0)
        self.cols = n
        self.capacity = Swift.max(n, 1)
        self.storage = UnsafeMutablePointer<Cell>.allocate(capacity: capacity)
        self.storage.initialize(repeating: fill, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Explicit generation bump for callers that mutate `cells` directly.
    public func bump() { generation &+= 1 }

    // MARK: - single cells

    public subscript(col: Int) -> Cell {
        get {
            precondition(col >= 0 && col < cols, "Row column \(col) out of range 0..<\(cols)")
            return storage[col]
        }
        set {
            precondition(col >= 0 && col < cols, "Row column \(col) out of range 0..<\(cols)")
            storage[col] = newValue
            // The unconditional `combined?[col] = nil` this replaced was a
            // *modify* access on a class stored property, so it cost a
            // swift_beginAccess/endAccess pair (plus a hashed probe once the
            // table existed) on every cell of every row — the single biggest
            // item in a profile of the print path. Two trivial loads and a bit
            // test say "no entry here" for almost every cell instead.
            if (combinedMask | extendedMask) & Row.maskBit(col) != 0 {
                dropSideEntries(at: col, keeping: newValue)
            }
            generation &+= 1
        }
    }

    /// The cold half of the subscript setter: at least one side table exists,
    /// so the entry for `col` has to be reconciled with the cell just written.
    /// Kept out of line so the hot setter stays a store plus two loads.
    @inline(never)
    private func dropSideEntries(at col: Int, keeping cell: Cell) {
        if !cell.isCombined { combined?[col] = nil }
        if !cell.hasExtended { extended?[col] = nil }
        prune()
    }

    /// Alias of the subscript getter.
    @inline(__always)
    public func cell(at col: Int) -> Cell {
        precondition(col >= 0 && col < cols, "Row column \(col) out of range 0..<\(cols)")
        return storage[col]
    }

    /// Attach the full grapheme cluster for `col` (sets `Cell.combinedBit`).
    public func setCombined(_ s: String, at col: Int) {
        guard col >= 0 && col < cols else { return }
        if combined == nil { combined = [:] }
        combined![col] = s
        combinedMask |= Row.maskBit(col)
        storage[col].isCombined = true
        bump()
    }

    public func setExtended(_ e: ExtendedAttributes, at col: Int) {
        guard col >= 0 && col < cols else { return }
        if e.isDefault {
            extended?[col] = nil
            storage[col].bg &= ~Cell.BgFlag.hasExtended
            prune()
        } else {
            if extended == nil { extended = [:] }
            extended![col] = e
            extendedMask |= Row.maskBit(col)
            storage[col].bg |= Cell.BgFlag.hasExtended
        }
        bump()
    }

    public func extended(at col: Int) -> ExtendedAttributes? { extended?[col] }

    public func combinedString(at col: Int) -> String? { combined?[col] }

    // MARK: - bulk edits

    /// Write `count` printable-ASCII bytes as width-1 cells into
    /// `[col, col + count)`, all carrying `fg`/`bg` (and `ext`, when it is not
    /// nil). This is the bulk form of
    ///
    ///     for i in 0..<count {
    ///         self[col + i] = Cell(code: p[i], width: 1, fg: fg, bg: bg)
    ///         if let ext { setExtended(ext, at: col + i) }
    ///     }
    ///
    /// and is observably identical to it, except that the generation is bumped
    /// **once** for the whole run instead of once per cell (still at least once,
    /// which is all the renderer/search/highlight caches need) and the two side
    /// tables are reconciled once rather than per cell. The bytes must all be in
    /// 0x20…0x7E: nothing here is a wide character, a spacer or a combining
    /// mark, so the wide-pair invariant cannot be broken from inside the run —
    /// its two edges (a wide head at `col - 1`, an orphan spacer at
    /// `col + count`) stay the caller's business, exactly as before.
    public func writeASCIIRun(_ p: UnsafePointer<UInt8>, count: Int, at col: Int,
                              fg: UInt32, bg: UInt32, extended ext: ExtendedAttributes?) {
        precondition(col >= 0 && count >= 0 && col + count <= cols,
                     "Row run \(col)..<\(col + count) out of range 0..<\(cols)")
        guard count > 0 else { return }

        var bgWord = bg & ~Cell.BgFlag.hasExtended
        if ext != nil { bgWord |= Cell.BgFlag.hasExtended }
        let widthBits: UInt32 = 1 << Cell.widthShift
        let dst = storage + col
        for i in 0..<count {
            dst[i] = Cell(content: (UInt32(p[i]) & Cell.codeMask) | widthBits, fg: fg, bg: bgWord)
        }

        // Side tables, once. Taking the dictionary out of the property first
        // makes the storage uniquely referenced, so the writes below are in
        // place rather than a copy — and it costs one modify access instead of
        // one per cell.
        // The membership filter guards the removals as well as the setter does:
        // a run of blanks between two words lands on columns that never held a
        // cluster, and without this every one of them was a hashed probe on a
        // row that has a cluster anywhere at all.
        if var c = combined, combinedMask & Row.maskBits(col, count) != 0 {
            combined = nil
            for i in col..<(col + count) { c[i] = nil }
            if c.isEmpty { combined = nil; combinedMask = 0 } else { combined = c }
        }
        if let ext {
            var e = extended ?? [:]
            extended = nil
            for i in col..<(col + count) { e[i] = ext }
            extended = e
            extendedMask |= Row.maskBits(col, count)
        } else if var e = extended, extendedMask & Row.maskBits(col, count) != 0 {
            extended = nil
            for i in col..<(col + count) { e[i] = nil }
            if e.isEmpty { extended = nil; extendedMask = 0 } else { extended = e }
        }

        generation &+= 1
    }

    /// Fill `[from, to)` with `cell`, dropping any side-table entries in the range.
    public func fill(_ cell: Cell, from: Int = 0, to: Int? = nil) {
        let lo = Swift.max(from, 0)
        let hi = Swift.min(to ?? cols, cols)
        guard lo < hi else { return }
        for i in lo..<hi { storage[i] = cell }

        // Anything that blanks column 0 has taken away the wide character the
        // gap above was made for. (`LineRing.reset` recycles a row this way.)
        if lo == 0 { wrapGapBefore = false }

        if lo == 0 && hi == cols {
            // The whole row goes: no key can survive, so drop the tables rather
            // than asking the dictionary about each column in turn. This is the
            // recycling path — `LineRing.reset` blanks a row for every line that
            // scrolls — and on a screen carrying grapheme clusters those
            // per-column removals were the largest item under `Buffer.scrollUp`.
            combined = nil; combinedMask = 0
            extended = nil; extendedMask = 0
        } else {
            // Same trick as `writeASCIIRun`: take the dictionary out of the
            // property so the removals below are in place on a uniquely
            // referenced buffer instead of one modify access per column.
            if var c = combined, combinedMask & Row.maskBits(lo, hi - lo) != 0 {
                combined = nil
                for i in lo..<hi { c[i] = nil }
                if c.isEmpty { combinedMask = 0 } else { combined = c }
            }
            if var e = extended, extendedMask & Row.maskBits(lo, hi - lo) != 0 {
                extended = nil
                for i in lo..<hi { e[i] = nil }
                if e.isEmpty { extendedMask = 0 } else { extended = e }
            }
        }
        bump()
    }

    /// ICH: shift the cells at `col` and beyond right by `count`, dropping what
    /// falls off the end and filling the gap with `fill`.
    public func insertCells(at col: Int, count: Int, fill: Cell) {
        guard cols > 0, count > 0, col >= 0, col < cols else { return }
        // Everything past the right edge falls off anyway, and an unclamped
        // `col + count` overflows.
        let count = Swift.min(count, cols - col)

        // A wide char whose spacer is about to be pushed away loses its head.
        if col > 0 && storage[col - 1].width == 2 { setPlain(col - 1, fill) }

        if count < cols - col {
            var i = cols - col - count - 1
            while i >= 0 {
                moveCell(from: col + i, to: col + count + i)
                i -= 1
            }
            for i in 0..<count { setPlain(col + i, fill) }
        } else {
            for i in col..<cols { setPlain(i, fill) }
        }

        // The first shifted cell may be a spacer whose head stayed behind (and
        // was just cleared above) — that half is orphaned too.
        let firstShifted = col + count
        if firstShifted < cols, storage[firstShifted].width == 0,
           storage[firstShifted].code == 0, !storage[firstShifted].isCombined {
            setPlain(firstShifted, fill)
        }

        // A wide char pushed half off the right edge loses its head.
        if storage[cols - 1].width == 2 { setPlain(cols - 1, fill) }

        prune()
        bump()
    }

    /// DCH: shift the cells after `col + count` left onto `col`, padding the end
    /// of the row with `fill`.
    public func deleteCells(at col: Int, count: Int, fill: Cell) {
        guard cols > 0, count > 0, col >= 0, col < cols else { return }
        let count = Swift.min(count, cols - col)

        if count < cols - col {
            for i in 0..<(cols - col - count) { moveCell(from: col + count + i, to: col + i) }
            for i in (cols - count)..<cols { setPlain(i, fill) }
        } else {
            for i in col..<cols { setPlain(i, fill) }
        }

        // The cell left of `col` may have lost its spacer …
        if col > 0 && storage[col - 1].width == 2 { setPlain(col - 1, fill) }
        // … and the cell now at `col` may be a spacer whose head is gone.
        if storage[col].width == 0 && storage[col].code == 0 && !storage[col].isCombined {
            setPlain(col, fill)
        }

        prune()
        bump()
    }

    /// Copy `count` cells — and their side-table entries — from `src[srcCol...]`
    /// onto `self[dstCol...]`. Both ranges are clamped to the two rows, so a
    /// caller that asks for more than fits simply gets less. `src` may be
    /// `self` and the ranges may overlap (reflow shifts a row onto itself).
    public func copyCells(from src: Row, srcCol: Int, dstCol: Int, count: Int) {
        guard count > 0, srcCol >= 0, dstCol >= 0 else { return }
        let n = Swift.min(count, Swift.min(src.cols - srcCol, cols - dstCol))
        guard n > 0 else { return }

        // The side tables are read before anything moves: with `src === self`
        // and overlapping ranges a straight per-cell copy would read entries it
        // had already overwritten.
        var comb: [String?]? = src.combined == nil ? nil : (0..<n).map { src.combined?[srcCol + $0] }
        let ext: [ExtendedAttributes?]? = src.extended == nil ? nil : (0..<n).map { src.extended?[srcCol + $0] }

        if src === self && dstCol > srcCol {
            var i = n - 1
            while i >= 0 { storage[dstCol + i] = src.storage[srcCol + i]; i -= 1 }
        } else {
            for i in 0..<n { storage[dstCol + i] = src.storage[srcCol + i] }
        }

        if comb != nil || combined != nil {
            if comb == nil { comb = [String?](repeating: nil, count: n) }
            for i in 0..<n {
                if let s = comb![i] {
                    if combined == nil { combined = [:] }
                    combined![dstCol + i] = s
                    combinedMask |= Row.maskBit(dstCol + i)
                } else {
                    combined?[dstCol + i] = nil
                }
            }
        }
        if ext != nil || extended != nil {
            for i in 0..<n {
                if let e = ext?[i] {
                    if extended == nil { extended = [:] }
                    extended![dstCol + i] = e
                    extendedMask |= Row.maskBit(dstCol + i)
                } else {
                    extended?[dstCol + i] = nil
                }
            }
        }
        prune()
        bump()
    }

    /// Replace this row's contents with `other`'s. Both rows must have the same width.
    public func copy(from other: Row) {
        precondition(cols == other.cols, "Row.copy needs equal widths (\(cols) vs \(other.cols))")
        if cols > 0 { storage.update(from: other.storage, count: cols) }
        combined = other.combined
        extended = other.extended
        combinedMask = other.combinedMask
        extendedMask = other.extendedMask
        wrapped = other.wrapped
        wrapGapBefore = other.wrapGapBefore     // after `wrapped`: its didSet can clear this
        bump()
    }

    /// Grow (padding with `fill`) or shrink the row. Truncating in the middle of
    /// a wide character clears its head; side-table entries past the new end go.
    public func resize(cols newCols: Int, fill: Cell) {
        let n = Swift.max(newCols, 0)
        guard n != cols else { return }

        if n > cols {
            if n > capacity {
                let fresh = UnsafeMutablePointer<Cell>.allocate(capacity: n)
                fresh.initialize(repeating: fill, count: n)
                if cols > 0 { fresh.update(from: storage, count: cols) }
                storage.deinitialize(count: capacity)
                storage.deallocate()
                storage = fresh
                capacity = n
            } else {
                for i in cols..<n { storage[i] = fill }
            }
            cols = n
        } else {
            cols = n
            if combined != nil { for k in combined!.keys where k >= n { combined![k] = nil } }
            if extended != nil { for k in extended!.keys where k >= n { extended![k] = nil } }
            // The last surviving cell must not be the head of a wide char whose
            // spacer was cut off.
            if n > 0 && storage[n - 1].width == 2 { setPlain(n - 1, fill) }
            prune()
        }
        bump()
    }

    // MARK: - reading

    /// Index after the last cell holding a character (0 for a blank row).
    public var trimmedLength: Int {
        var i = cols - 1
        while i >= 0 {
            let c = storage[i]
            if c.code != 0 || c.isCombined { return Swift.min(i + Swift.max(c.width, 1), cols) }
            i -= 1
        }
        return 0
    }

    /// Text of the row: code 0 → " ", spacer cells skipped, combined cells use
    /// the side-table string. `trimRight` drops the trailing blank cells (and
    /// any trailing spaces they were printed as).
    public func string(trimRight: Bool = true) -> String {
        var end = cols
        if trimRight { end = Swift.min(end, trimmedLength) }
        var out = String()
        out.reserveCapacity(end)
        var i = 0
        while i < end {
            let c = storage[i]
            if c.isCombined, let s = combined?[i] {
                out += s
            } else if c.code == 0 {
                out.append(" ")
            } else {
                out.unicodeScalars.append(Unicode.Scalar(c.code) ?? "\u{FFFD}")
            }
            i += Swift.max(c.width, 1)
        }
        if trimRight {
            while out.last == " " { out.removeLast() }
        }
        return out
    }

    // MARK: - private

    /// Write a plain cell (no side-table entries) without bumping — the callers
    /// above bump once at the end.
    @inline(__always)
    private func setPlain(_ col: Int, _ cell: Cell) {
        storage[col] = cell
        if !cell.isCombined { combined?[col] = nil }
        if !cell.hasExtended { extended?[col] = nil }
    }

    /// Move a cell and its side-table entries. Never bumps.
    @inline(__always)
    private func moveCell(from src: Int, to dst: Int) {
        storage[dst] = storage[src]
        if combined != nil { combined![dst] = combined![src]; combinedMask |= Row.maskBit(dst) }
        if extended != nil { extended![dst] = extended![src]; extendedMask |= Row.maskBit(dst) }
    }

    /// Drop empty side tables so a row that never needed them costs nothing.
    @inline(__always)
    private func prune() {
        if let c = combined, c.isEmpty { combined = nil; combinedMask = 0 }
        if let e = extended, e.isEmpty { extended = nil; extendedMask = 0 }
    }
}
