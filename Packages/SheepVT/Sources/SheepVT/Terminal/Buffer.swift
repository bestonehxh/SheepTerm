// SheepVT — one screen: rows, cursor, margins, tab stops.
//
// The primary buffer has a scrollback (lines that leave the top of the screen
// are kept in the ring); the alternate buffer is created with scrollback 0 and
// never grows past `rows`. Scroll semantics follow xterm.js
// (`BufferService.scroll`, `InputHandler.insertLines/deleteLines`,
// `Buffer.resize`) — the one path that pushes into the scrollback is a
// full-screen scroll up on a buffer that has one; everything else moves row
// references inside the margins.

public struct Pen: Equatable, Sendable {
    /// Packed like `Cell.fg`: value + ColorSource + flags.
    public var fg: UInt32 = 0
    /// Packed like `Cell.bg`.
    public var bg: UInt32 = 0
    public var extended = ExtendedAttributes()

    public init() {}

    public var hasExtended: Bool { !extended.isDefault }

    /// The cell a printed character with this pen produces.
    /// A cell in this pen's colours. The `hasExtended` flag is deliberately
    /// NOT set here, whatever the pen carries: that flag is a promise that the
    /// row's side table holds an entry for this exact column, and only
    /// `Row.setExtended` — which writes the entry — can honestly make it.
    /// Setting it here made every caller that did not follow up with
    /// `setExtended` produce a cell that lied: the spacer half of a wide
    /// character, and every 'E' of DECALN. A lying flag reads back as nil, and
    /// worse, `Row`'s setter only clears a stale side-table entry when the
    /// incoming cell does not claim the flag — so the previous occupant's
    /// entry survived under the new one and a ⌘-click opened the old link.
    /// Both found by the invariant fuzzer.
    public func cell(code: UInt32, width: Int) -> Cell {
        var c = Cell(code: code, width: UInt32(Swift.max(width, 0)), fg: fg, bg: bg)
        c.bg &= ~Cell.BgFlag.hasExtended
        return c
    }

    /// What an erase with this pen leaves behind: no character, background
    /// colour only (BCE). Same rule as `Cell.eraseCell`.
    public var eraseCell: Cell {
        Cell(content: 1 << Cell.widthShift, fg: 0, bg: bg & (Cell.valueMask | Cell.sourceMask))
    }
}

/// DECSC / DECRC state.
public struct SavedCursor: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var pen: Pen
    /// Index of the active charset slot (G0…G3).
    public var charset: Int
    public var originMode: Bool
    public var pendingWrap: Bool

    public init(x: Int = 0, y: Int = 0, pen: Pen = Pen(), charset: Int = 0,
                originMode: Bool = false, pendingWrap: Bool = false) {
        self.x = x; self.y = y; self.pen = pen
        self.charset = charset; self.originMode = originMode; self.pendingWrap = pendingWrap
    }
}

/// The cursor (`x`/`y`) and `ybase` are read and written several times for every
/// character that lands on the grid, so the stored properties here skip dynamic
/// exclusivity enforcement — the argument for that, and what it still requires,
/// is the note at the top of `Row.swift`.
public final class Buffer {
    /// Tab stops are placed every `tabWidth` columns.
    public static let tabWidth = 8

    public let hasScrollback: Bool
    @exclusivity(unchecked) public var lines: LineRing
    @exclusivity(unchecked) public private(set) var cols: Int
    @exclusivity(unchecked) public private(set) var rows: Int
    /// How many lines of history this buffer may keep beyond the screen.
    @exclusivity(unchecked) public private(set) var scrollback: Int

    /// Absolute line index of screen row 0.
    @exclusivity(unchecked) public var ybase: Int = 0
    /// Absolute line index of the top visible row (== ybase unless scrolled back).
    @exclusivity(unchecked) public var ydisp: Int = 0

    /// Cursor in screen coordinates. `x` may equal `cols` (pending wrap).
    @exclusivity(unchecked) public var x: Int = 0
    @exclusivity(unchecked) public var y: Int = 0

    /// Scroll margins, inclusive, in screen coordinates.
    @exclusivity(unchecked) public var scrollTop: Int = 0
    @exclusivity(unchecked) public var scrollBottom: Int

    @exclusivity(unchecked) public var tabStops: [Bool]
    @exclusivity(unchecked) public var savedCursor: SavedCursor?

    /// The terminal this buffer belongs to, so the one scroll shape that
    /// reassigns line numbers can tell the holders of those numbers
    /// (`Terminal.linesRenumbered`). Weak because the terminal owns the buffer,
    /// and nil for a stand-alone buffer in a test — nothing is holding numbers
    /// into one of those.
    weak var owner: Terminal?

    public init(cols: Int, rows: Int, scrollback: Int) {
        let c = Swift.max(cols, 1)
        let r = Swift.max(rows, 1)
        self.cols = c
        self.rows = r
        self.scrollback = Swift.max(scrollback, 0)
        self.hasScrollback = self.scrollback > 0
        self.scrollBottom = r - 1
        self.lines = LineRing(maxLength: r + self.scrollback, cols: c)
        self.tabStops = [Bool](repeating: false, count: c)
        for _ in 0..<r { lines.pushBlank() }
        resetTabs()
    }

    /// Screen row → Row (created blank on first touch).
    public func row(_ screenRow: Int) -> Row {
        lines[lineIndex(screenRow)]
    }

    /// Screen row → Row only if the slot has been materialised. Readers (text
    /// dumps, the renderer) go through here so that looking at the screen never
    /// allocates the rows the ring is keeping lazily empty.
    func allocatedRow(_ screenRow: Int) -> Row? {
        lines.allocatedRow(at: lineIndex(screenRow))
    }

    @inline(__always)
    private func lineIndex(_ screenRow: Int) -> Int {
        Swift.min(Swift.max(ybase + screenRow, 0), Swift.max(lines.count - 1, 0))
    }

    /// Viewport pinned to the bottom (the user has not scrolled back).
    public var isFollowing: Bool { ydisp == ybase }

    // MARK: - scrolling

    /// Scroll [scrollTop, scrollBottom] up by `n` — content moves up, blank rows
    /// appear at the bottom. With a full-screen region on a buffer that has a
    /// scrollback the vacated top rows go into history; otherwise the rows are
    /// moved inside the region and the bottom one is cleared.
    public func scrollUp(_ n: Int, fill: Cell = .empty, wrapped: Bool = false) {
        guard n > 0 else { return }
        // xterm.js `BufferService.scroll`: a region anchored at the TOP of the
        // screen scrolls into history even when its bottom margin is above
        // the last row — the line leaving the region is what the user wants
        // to scroll back to (status-line TUIs, device pagers). Only a region
        // that starts below row 0 recycles inside itself.
        if scrollTop == 0 && hasScrollback {
            for _ in 0..<n {
                let following = isFollowing
                let didTrim = lines.pushBlank(fill: fill)
                if didTrim {
                    // Line numbers all shifted down by one: ybase stays where it
                    // is, and a user who had scrolled back keeps looking at the
                    // same text.
                    if !following { ydisp = Swift.max(ydisp - 1, 0) }
                } else {
                    ybase += 1
                    if following { ydisp += 1 }
                }
                // The blank line belongs at the bottom of the region, not at
                // the bottom of the screen: rows below the margin stay put.
                let target = ybase + scrollBottom
                if target < lines.count - 1 {
                    lines.move(from: lines.count - 1, to: target)
                    // …but "stay put" is only true of their *content*. The move
                    // slid every row from `target` down one index further, and
                    // a line number is `trimmed + index`, so rows nothing
                    // happened to just silently got renumbered — the blank now
                    // wears the number the first row below the margin had. A
                    // line number is supposed to stay glued to its text (that
                    // is what lets a selection survive streaming output), so
                    // tell whoever is holding one. Rows *above* `target` kept
                    // both their index and their number and must not move.
                    owner?.linesRenumbered(atOrAfter: lineNumber(atIndex: target), by: 1)
                }
                if wrapped, target < lines.count { lines[target].wrapped = true }
                clearWrapBelow(target)
            }
        } else {
            for _ in 0..<n {
                let top = ybase + scrollTop
                let bottom = ybase + scrollBottom
                lines.move(from: top, to: bottom)
                lines.blank(at: bottom, fill: fill)
                if wrapped { lines[bottom].wrapped = true }
                // The row now at the top of the region no longer continues
                // the row above it (same rule as `deleteLines`).
                lines.allocatedRow(at: top)?.wrapped = false
                clearWrapBelow(bottom)
            }
        }
    }

    /// The row just below a scroll region cannot go on claiming to continue the
    /// row above it once the region has moved underneath it: whatever it was
    /// wrapped from is gone (top-anchored) or has been replaced by different
    /// text (in-region). A stale flag there would join two unrelated rows into
    /// one logical line, which is what selection, copy and search all read.
    /// Only a region whose bottom margin is above the last row can have a row
    /// below it, so this is a no-op for the ordinary full-screen case.
    private func clearWrapBelow(_ bottom: Int) {
        let below = bottom + 1
        guard below < lines.count, below < ybase + rows else { return }
        lines.allocatedRow(at: below)?.wrapped = false
    }

    /// Scroll [scrollTop, scrollBottom] down by `n` — content moves down, blank
    /// rows appear at the top. Nothing ever enters the scrollback this way.
    public func scrollDown(_ n: Int, fill: Cell = .empty) {
        guard n > 0 else { return }
        for _ in 0..<n {
            let top = ybase + scrollTop
            let bottom = ybase + scrollBottom
            lines.move(from: bottom, to: top)
            lines.blank(at: top, fill: fill)
            // The block that shifted down now follows a blank row (same rule
            // as `insertLines`).
            if top + 1 <= bottom { lines.allocatedRow(at: top + 1)?.wrapped = false }
            clearWrapBelow(bottom)
        }
    }

    /// IL: `count` blank rows at `screenRow`, everything below shifts down and
    /// falls out of the region at scrollBottom. No-op outside the margins.
    public func insertLines(at screenRow: Int, count: Int, fill: Cell = .empty) {
        guard count > 0, screenRow >= scrollTop, screenRow <= scrollBottom else { return }
        let n = Swift.min(count, scrollBottom - screenRow + 1)
        for _ in 0..<n {
            lines.move(from: ybase + scrollBottom, to: ybase + screenRow)
            lines.blank(at: ybase + screenRow, fill: fill)
        }
        // The block that moved down now follows a blank row, so its first row
        // is no longer the continuation of anything.
        let after = screenRow + n
        if after <= scrollBottom { lines.allocatedRow(at: ybase + after)?.wrapped = false }
        // …and the row just below the region now follows a row that was
        // replaced (the ones that fell out of the bottom margin are gone).
        clearWrapBelow(ybase + scrollBottom)
    }

    /// DL: delete `count` rows at `screenRow`, everything below shifts up and
    /// blank rows appear at scrollBottom. No-op outside the margins.
    public func deleteLines(at screenRow: Int, count: Int, fill: Cell = .empty) {
        guard count > 0, screenRow >= scrollTop, screenRow <= scrollBottom else { return }
        let n = Swift.min(count, scrollBottom - screenRow + 1)
        for _ in 0..<n {
            lines.move(from: ybase + screenRow, to: ybase + scrollBottom)
            lines.blank(at: ybase + scrollBottom, fill: fill)
        }
        // The row that shifted up onto `screenRow` lost the row it continued.
        lines.allocatedRow(at: ybase + screenRow)?.wrapped = false
        // …and the row just below the region now follows the blank left at the
        // bottom margin, not the text it was wrapped from.
        clearWrapBelow(ybase + scrollBottom)
    }

    // MARK: - geometry

    /// Change the scrollback depth of this buffer (Terminal's `scrollback` setter).
    public func setScrollback(_ n: Int) {
        guard hasScrollback else { return }
        scrollback = Swift.max(n, 0)
        let newMax = rows + scrollback
        if lines.count > newMax {
            let drop = lines.count - newMax
            lines.trimStart(drop)
            ybase = Swift.max(ybase - drop, 0)
            ydisp = Swift.max(ydisp - drop, 0)
        }
        lines.setMaxLength(newMax)
    }

    /// Rows are added/removed at the bottom, pulling lines back out of the
    /// scrollback when growing and pushing them into it when shrinking would
    /// drop the cursor off the screen (xterm.js `Buffer.resize`); a width change
    /// on a buffer with a scrollback then rewraps the history
    /// (`Buffer+Reflow.swift`).
    ///
    /// The order is xterm's and it is load-bearing. Widening resizes every row
    /// to the new width *first*, so a wider row can absorb its continuation
    /// rows; narrowing reflows while the rows are still `oldCols` wide (the new
    /// continuation rows are created at `oldCols` too) and only cuts them down
    /// afterwards.
    public func resize(cols newCols: Int, rows newRows: Int, fill: Cell = .empty) {
        let nc = Swift.max(newCols, 1)
        let nr = Swift.max(newRows, 1)
        let oldCols = cols

        let newMax = hasScrollback ? nr + scrollback : nr
        if newMax > lines.maxLength { lines.setMaxLength(newMax) }

        // Widening: every row (including the parked ones the ring recycles) has
        // to be `nc` wide before reflow can pull anything up into it.
        if nc > oldCols { lines.resizeRows(cols: nc, fill: fill) }

        // Height changes move `ybase` by whole rows without moving any row
        // above the screen, so a reader who has scrolled back is looking at
        // an index that still points at the same text: `ydisp` stays. Only a
        // viewport pinned to the bottom follows `ybase`. xterm.js moves
        // `ydisp` with `ybase` in both branches, and that walked a
        // scrolled-back reader |Δrows| lines through the history on every
        // height change while the cursor sat on the bottom row (measured:
        // top line 0061 → 0066 for 10 → 5 rows, → 0051 for 10 → 20) — the
        // same class of drift 3.0 (56) removed for width changes.
        var addToY = 0
        if rows < nr {
            for _ in rows..<nr where lines.count < nr + ybase {
                if ybase > 0 && lines.count <= ybase + y + addToY + 1 {
                    // There is history above and nothing blank below the cursor:
                    // pull a line back down instead of adding a blank one.
                    let following = ydisp == ybase
                    ybase -= 1
                    addToY += 1
                    if following { ydisp = ybase }
                } else {
                    lines.pushBlank(fill: fill)
                }
            }
        } else if rows > nr {
            if !hasScrollback {
                while lines.count > nr { lines.pop() }
            } else {
                for _ in stride(from: rows, to: nr, by: -1) where lines.count > nr + ybase {
                    if lines.count > ybase + y + 1 {
                        lines.pop()          // a blank line below the cursor
                    } else {
                        let following = ydisp == ybase
                        ybase += 1           // the cursor's line: push one into history
                        if following { ydisp = ybase }
                    }
                }
            }
        }

        // Shrinking the ring is done last so it cuts history, not live rows.
        if newMax < lines.maxLength {
            let drop = lines.count - newMax
            if drop > 0 {
                lines.trimStart(drop)
                ybase = Swift.max(ybase - drop, 0)
                ydisp = Swift.max(ydisp - drop, 0)
            }
            lines.setMaxLength(newMax)
        }

        // Cursor and margins.
        let pendingWrap = x >= cols
        x = pendingWrap ? nc : Swift.min(x, nc - 1)
        y = Swift.min(y, nr - 1) + addToY
        y = Swift.min(Swift.max(y, 0), nr - 1)
        if var s = savedCursor {
            s.x = Swift.min(s.x, nc - 1)
            s.y = Swift.min(s.y, nr - 1)
            savedCursor = s
        }

        // Rewrap the history. A no-op without a scrollback (the alternate
        // screen) and when the width did not change.
        //
        // A reader who has scrolled back is holding a row *index*, and reflow
        // renumbers every index below the rows it inserts. Note down what they
        // are actually looking at first, and put them back on it afterwards —
        // the capture has to bracket `reflow` itself and nothing else, because
        // the blank rows this method pushes at the bottom would be counted as
        // logical lines otherwise.
        let anchor = captureViewportAnchor(oldCols: oldCols, newCols: nc)
        reflow(oldCols: oldCols, newCols: nc, newRows: nr)
        if let anchor { restoreViewportAnchor(anchor, newCols: nc) }

        // Narrowing: cut the rows down only once reflow has moved their content
        // to the rows below.
        if nc < oldCols { lines.resizeRows(cols: nc, fill: fill) }

        extendTabs(to: nc)
        cols = nc
        rows = nr
        scrollTop = 0
        scrollBottom = nr - 1

        // The screen must exist even if nothing above added rows.
        while lines.count < ybase + nr && lines.count < lines.maxLength { lines.pushBlank(fill: fill) }
        // …and ybase must leave a whole screen below it.
        ybase = Swift.max(Swift.min(ybase, lines.count - nr), 0)
        ydisp = Swift.min(Swift.max(ydisp, 0), ybase)
        y = Swift.min(y, Swift.max(lines.count - ybase - 1, 0))
    }

    /// What the top of the viewport was showing, in coordinates reflow does not
    /// invalidate: not a row index (rewrapping renumbers those) but a **logical
    /// line**, identified by how many logical lines start below it. Counting
    /// from the bottom is what makes it survivable — rewrapping changes how many
    /// rows a paragraph takes but never how many paragraphs there are, and the
    /// only lines reflow removes outright are the ones that fall off the top.
    private struct ViewportAnchor {
        /// Logical lines that start strictly below the anchored one.
        let logicalLinesBelow: Int
        /// How many rows into that line the viewport was, at `oldCols`.
        let rowOffset: Int
        /// Content cells of the anchored line ABOVE the viewport row — the
        /// rows `head..<ydisp`, each counted with `wrappedTrimmedLength`, the
        /// same measure reflow moves content by. Not `rowOffset * oldCols`:
        /// a row whose last cell is the gap a wide character left behind
        /// holds `oldCols - 1` cells of text, and at three columns of CJK
        /// that is every row, so the product overshot by half and put a
        /// reader 113 rows into the line 84 rows into the rewrapped one,
        /// looking at different characters (recheck of 3.0 (60)).
        let cellOffset: Int
        /// Content cells and rows of the whole anchored line at capture, so
        /// `restore` can tell how much of it the ring trimmed: reflow keeps
        /// every content cell, so any shortfall afterwards is the cut.
        let lineCells: Int
        let lineRows: Int
        /// The anchored line is the cursor's. Reflow never rewraps that line
        /// (both directions skip it; `resizeRows` crops or pads it instead),
        /// so its row count does not change with the width and `rowOffset`
        /// must be carried across in ROWS, not remapped as cells. Remapping
        /// put a reader five rows into a twenty-row cursor line ten rows in
        /// after halving the width — onto `ybase`, following again.
        let holdsCursor: Bool
    }

    /// Content cells of the row at `index` as a member of its logical line:
    /// `wrappedTrimmedLength` (the gap before a wide character that wrapped
    /// is not text), clamped to `cols` because on the narrowing path the rows
    /// are still the old width when `restoreViewportAnchor` runs and a row's
    /// `trimmedLength` could see cells that `resizeRows` is about to crop.
    private func contentCells(at index: Int, cols: Int) -> Int {
        guard let row = lines.allocatedRow(at: index) else { return 0 }
        let next = index + 1 < lines.count ? lines.allocatedRow(at: index + 1) : nil
        let continues = next?.wrapped == true
        return Swift.min(wrappedTrimmedLength(row, next: continues ? next : nil, cols: cols), cols)
    }

    /// Note down the anchor, or nil when there is nothing to anchor: the
    /// alternate screen, an unchanged width, or a viewport pinned to the bottom
    /// (`isFollowing`), which must STAY pinned or the next line of output would
    /// not scroll it.
    private func captureViewportAnchor(oldCols: Int, newCols: Int) -> ViewportAnchor? {
        guard hasScrollback, oldCols != newCols, oldCols > 0, newCols > 0 else { return nil }
        guard ydisp > 0, ydisp < ybase, lines.count > 0 else { return nil }

        // Row 0 of the retained history heads a line whatever its flag says:
        // whatever it continued has already been trimmed away.
        var head = Swift.min(ydisp, lines.count - 1)
        while head > 0, lines.allocatedRow(at: head)?.wrapped == true { head -= 1 }

        var below = 0
        var lineEnd = head
        var i = head + 1
        while i < lines.count {
            if lines.allocatedRow(at: i)?.wrapped != true {
                below += 1
            } else if below == 0 {
                lineEnd = i          // still inside the anchored line
            }
            i += 1
        }
        var cellOffset = 0
        var lineCells = 0
        for k in head...lineEnd {
            let cells = contentCells(at: k, cols: oldCols)
            if k < ydisp { cellOffset += cells }
            lineCells += cells
        }
        let cursorRow = ybase + y
        return ViewportAnchor(logicalLinesBelow: below, rowOffset: ydisp - head,
                              cellOffset: cellOffset, lineCells: lineCells,
                              lineRows: lineEnd - head + 1,
                              holdsCursor: cursorRow >= head && cursorRow <= lineEnd)
    }

    /// Put the viewport back on the logical line it was showing.
    ///
    /// This replaces xterm.js's rule, which `reflowNarrower`/`reflowWider` still
    /// implement for `ybase`: advance `ydisp` only while it equals `ybase`, and
    /// otherwise leave it alone. Leaving an index alone is only "no movement"
    /// while the text under it does not move, and rewrapping moves it — inserting
    /// rows above a scrolled-back reader walked them backwards through the
    /// history by roughly the number of rows the rewrap added (measured: ten rows
    /// up, resized 40 → 120 → 37 → 200 → 80, the top line drifted 52 → 62), and
    /// widening did the mirror image and could pull `ydisp` up onto `ybase`,
    /// which silently started following the output again without the reader
    /// asking. For a person reading a switch's output that is the whole point of
    /// having scrolled back, so we keep the text and let the index move.
    ///
    /// The place inside the line is carried across as a CONTENT CELL count and
    /// mapped through the rewrapped rows with the same measure reflow laid them
    /// out by (`contentCells`), so a reader parked deep inside one enormous
    /// logical line (a JSON blob `cat`ed at 80 columns is one line thousands of
    /// rows deep) lands on the row that now holds the cell they were looking at
    /// — exactly, gaps and all, not by the ratio of the widths. An offset of
    /// zero stays zero at every width, which is the ordinary case: the reader is
    /// looking at the start of a paragraph and still is.
    ///
    /// Two things the trim can do to the anchored line, and what each gets:
    ///
    ///   * **Cut** — it is the first line left and its head fell off the top.
    ///     Reflow keeps every content cell of a line it rewraps, so the cells
    ///     the line has now against the cells it had (`lineCells`) IS the cut,
    ///     and it comes off the offset; a reader whose place was in the cut
    ///     part lands on the first row that is left. (For the cursor's line,
    ///     which is cropped rather than rewrapped, the same in rows.) Without
    ///     the subtraction the reader was put past `ybase`, which turned the
    ///     scrolled-back view into a following one while the text they were
    ///     reading was still in the buffer (recheck finding 1).
    ///   * **Gone** — fewer lines survive than there were below it. Nothing of
    ///     it is left to show, so the viewport goes to the top of what is:
    ///     `ydisp = 0`, still scrolled back, never `ybase`. The old shape found
    ///     no line and applied the offset to row 0 anyway, which is a different
    ///     line — a place in the wrong paragraph is not a place.
    private func restoreViewportAnchor(_ a: ViewportAnchor, newCols: Int) {
        guard lines.count > 0 else { return }

        // The line with `logicalLinesBelow` lines under it is the
        // (logicalLinesBelow + 1)-th line counted from the bottom. Row 0 heads
        // a line whatever its flag says (see `captureViewportAnchor`).
        var head: Int?
        var seen = 0
        var i = lines.count - 1
        while i >= 0 {
            if i == 0 || lines.allocatedRow(at: i)?.wrapped != true {
                seen += 1
                if seen == a.logicalLinesBelow + 1 { head = i; break }
            }
            i -= 1
        }
        guard let head else { ydisp = 0; return }

        var lineEnd = head
        while lineEnd + 1 < lines.count, lines.allocatedRow(at: lineEnd + 1)?.wrapped == true {
            lineEnd += 1
        }
        let height = lineEnd - head + 1

        var offset = 0
        if a.holdsCursor {
            // Rows, for the one line reflow never rewraps; a shorter line than
            // captured was cut by the ring, from the top.
            let cutRows = head == 0 ? Swift.max(a.lineRows - height, 0) : 0
            offset = a.rowOffset - cutRows
        } else if a.cellOffset > 0 {
            var cells = 0
            for k in head...lineEnd { cells += contentCells(at: k, cols: newCols) }
            let cutCells = head == 0 ? Swift.max(a.lineCells - cells, 0) : 0
            let target = a.cellOffset - cutCells
            // The row holding content cell `target`: walk the rewrapped rows
            // until the next one would start past it.
            var acc = 0
            var j = head
            while j < lineEnd {
                let w = contentCells(at: j, cols: newCols)
                if acc + w > target { break }
                acc += w
                j += 1
            }
            offset = j - head
        }
        offset = Swift.min(Swift.max(offset, 0), height - 1)
        // Only the buffer's own bounds here: `resize` still has rows to push and
        // `ybase` to settle, and it clamps `ydisp` to the final `ybase` itself.
        ydisp = Swift.min(Swift.max(head + offset, 0), Swift.max(lines.count - 1, 0))
    }

    /// Tab stops every `tabWidth` columns, starting at column 0 (xterm.js
    /// `Buffer.setupTabStops`).
    public func resetTabs() {
        tabStops = [Bool](repeating: false, count: cols)
        var i = 0
        while i < cols { tabStops[i] = true; i += Buffer.tabWidth }
    }

    /// ED 3: throw away everything above the screen.
    public func clearScrollback() {
        guard ybase > 0 else { ydisp = 0; return }
        lines.trimStart(ybase)
        ybase = 0
        ydisp = 0
    }

    // MARK: - private

    /// Keep the stops that survive the width change and give the new columns
    /// the default every-8 stops (measured from column 0).
    private func extendTabs(to newCols: Int) {
        var fresh = [Bool](repeating: false, count: newCols)
        let overlap = Swift.min(newCols, tabStops.count)
        for i in 0..<overlap { fresh[i] = tabStops[i] }
        if newCols > tabStops.count {
            // The columns that just appeared get the default stops — every
            // `tabWidth` counted from column 0, never continued from whatever
            // custom stop HTS left behind.
            var j = ((tabStops.count + Buffer.tabWidth - 1) / Buffer.tabWidth) * Buffer.tabWidth
            while j < newCols { fresh[j] = true; j += Buffer.tabWidth }
        }
        tabStops = fresh
    }
}
