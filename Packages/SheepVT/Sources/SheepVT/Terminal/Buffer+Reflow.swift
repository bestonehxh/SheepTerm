// SheepVT — reflow: rewrapping the scrollback when the width changes.
//
// A port of xterm.js `BufferReflow.ts` + `Buffer.resize` (MIT) as carried in
// SwiftTerm's `Buffer.swift` (`getWrappedLineTrimmedLength`, `getLinesToRemove`,
// `reflowWider`, `getNewLineLengths`, `reflowNarrower`, `rearrange`). The
// algorithm is xterm's; the data model is ours, and there are exactly two
// deliberate departures from xterm's behaviour, both recorded in
// ARCHITECTURE.md §5.6 and argued at their call sites:
//
//   1. A wrap gap is RECORDED (`Row.wrapGapBefore`), not inferred back out of
//      the cells — xterm's inference cannot tell a gap from a blank an
//      overwrite left, and closes the wrong one (fuzz finding 2).
//   2. A scrolled-back viewport is anchored on the logical line it was showing
//      (`Buffer.captureViewportAnchor`), not on its row index — xterm leaves
//      `ydisp` alone, which walks the reader through the history as the rewrap
//      inserts rows above them.
//
// The data model:
//
//   * xterm's `BufferLine` is our `Row` (flat cells + `wrapped` + side tables);
//     `CharData.Null` is `Cell.empty`, `hasContent` is `code != 0 || isCombined`,
//     `getWidth(i)` is `row[i].width`.
//   * `LineRing` allocates lazily, so the whole pass works on a `[Row?]`
//     snapshot: a nil slot is a blank, unwrapped row and is skipped while
//     scanning; it is only materialised when something is copied into it.
//   * xterm's in-place `rearrange` (which writes back into the circular list
//     while reading from a copy of it) becomes "build the new order, hand it to
//     `LineRing.replaceAll` once". Rows that no longer fit fall off the top
//     there, which is where xterm loses them too.
//
// Only a buffer with a scrollback reflows (xterm.js `_hasScrollback`): the
// alternate screen keeps the plain crop/pad behaviour. Logical lines holding
// the cursor are left alone — the program redraws its own line.

extension Buffer {

    /// A batch of blank continuation rows to splice in at `start` (xterm's
    /// `InsertionSet`; the "null" member is an absent optional here).
    struct InsertionSet {
        var lines: [Row]
        var start: Int
    }

    // MARK: - entry point

    /// Rewrap everything but the cursor's logical line for a width change.
    /// Called from `Buffer.resize` while the rows are still `oldCols` wide on
    /// the narrowing path, and already `newCols` wide on the widening one.
    ///
    /// Nothing is reported back about the trim: the viewport anchor works out
    /// what the ring cut from its line by counting content cells before and
    /// after (`Buffer.restoreViewportAnchor`), which is exact for wide
    /// characters where a row count was not.
    func reflow(oldCols: Int, newCols: Int, newRows: Int) {
        guard hasScrollback, oldCols != newCols, lines.count > 0 else { return }
        if newCols > oldCols {
            reflowWider(oldCols: oldCols, newCols: newCols, newRows: newRows)
        } else {
            reflowNarrower(oldCols: oldCols, newCols: newCols, newRows: newRows)
        }
    }

    // MARK: - trimmed length of one row of a logical line

    /// xterm's `getWrappedLineTrimmedLength`. Only the *last* row of a logical
    /// line has a meaningful trimmed length; the rows before it are full by
    /// definition — except when the last column holds a blank because a wide
    /// character did not fit and moved to the next row, which costs one cell.
    ///
    /// xterm.js decides that from the cells alone — last cell NUL, next row
    /// starts wide — and that is the hole fuzz finding 2 walked through: an
    /// overwrite leaves the very same shape with no gap anywhere, so a narrow →
    /// wide round trip closed a cell that was really there. The two shapes are
    /// genuinely indistinguishable in the grid, so the gap is no longer inferred
    /// but **recorded**, by whoever made it, on the row that holds the wide
    /// character (`Row.wrapGapBefore`; set in `Terminal.print` and in both
    /// directions below). The cell test stays in front of it as a veto: a last
    /// column that has since been given real content is not a gap whatever any
    /// flag says.
    ///
    /// **Every caller that joins rows into a logical line comes through here.**
    /// Reflow is not the only one: `SearchEngine.appendSegment` builds the
    /// scalars of a logical line and needs the same answer. It carried its own
    /// copy of xterm's guess until the guess and this function disagreed — the
    /// resize that changed no text changed the search results — so there is one
    /// function now. A new consumer joins this list; it does not start a fourth
    /// copy of the heuristic.
    func wrappedTrimmedLength(_ line: Row, next: Row?, cols: Int) -> Int {
        guard let next else { return line.trimmedLength }
        guard next.wrapGapBefore else { return cols }
        var endsInNull = false
        let last = cols - 1
        if last >= 0 && last < line.cols {
            let c = line[last]
            endsInNull = c.code == 0 && !c.isCombined && c.width == 1
        }
        let followingStartsWide = next.cols > 0 && next[0].width == 2
        return (endsInNull && followingStartsWide) ? cols - 1 : cols
    }

    func wrappedTrimmedLength(_ rows: [Row], _ index: Int, _ cols: Int) -> Int {
        wrappedTrimmedLength(rows[index],
                             next: index == rows.count - 1 ? nil : rows[index + 1],
                             cols: cols)
    }

    // MARK: - widening

    /// xterm's `reflowLargerGetLinesToRemove`: pull every continuation row up
    /// into the wider row above it and report which rows became redundant, as
    /// flat (startIndex, count) pairs.
    func linesToRemove(_ rows: inout [Row?], oldCols: Int, newCols: Int, absoluteY: Int) -> [Int] {
        var toRemove: [Int] = []
        let nullCell = Cell.empty

        var y = 0
        while y < rows.count - 1 {
            defer { y += 1 }
            var i = y + 1
            guard rows[i]?.wrapped == true else { continue }

            // How far does this logical line run?
            var group: [Row] = [materialise(&rows, y)]
            while i < rows.count, rows[i]?.wrapped == true {
                group.append(materialise(&rows, i))
                i += 1
            }

            // The cursor's line belongs to the program, not to us.
            if absoluteY >= y && absoluteY < i {
                y += group.count - 1
                continue
            }

            var destLineIndex = 0
            var destCol = wrappedTrimmedLength(group, 0, oldCols)
            var srcLineIndex = 1
            var srcCol = 0
            // Rows whose first cell is a wide head this pass had to push down;
            // applied after the loop, so a flag written now cannot change a
            // `wrappedTrimmedLength` the loop has not read yet.
            var gapRows: [Int] = []
            while srcLineIndex < group.count {
                let srcTrimmed = wrappedTrimmedLength(group, srcLineIndex, oldCols)
                let cellsToCopy = Swift.min(srcTrimmed - srcCol, newCols - destCol)

                if destLineIndex < group.count, cellsToCopy > 0 {
                    group[destLineIndex].copyCells(from: group[srcLineIndex],
                                                   srcCol: srcCol, dstCol: destCol,
                                                   count: cellsToCopy)
                }

                destCol += cellsToCopy
                if destCol == newCols { destLineIndex += 1; destCol = 0 }

                srcCol += cellsToCopy
                if srcCol == srcTrimmed { srcLineIndex += 1; srcCol = 0 }

                // A wide character must not be left straddling the boundary:
                // move its head down to the row that will hold its spacer.
                if destCol == 0, destLineIndex != 0, destLineIndex < group.count,
                   newCols - 1 < group[destLineIndex - 1].cols,
                   group[destLineIndex - 1][newCols - 1].width == 2 {
                    group[destLineIndex].copyCells(from: group[destLineIndex - 1],
                                                   srcCol: newCols - 1, dstCol: destCol, count: 1)
                    destCol += 1
                    group[destLineIndex - 1].fill(nullCell, from: newCols - 1, to: newCols)
                    gapRows.append(destLineIndex)
                }
            }

            // Whatever is left in the last destination row is a fragment.
            if destLineIndex < group.count {
                group[destLineIndex].fill(nullCell, from: destCol, to: newCols)
            }

            // The old wrapping is gone, so every continuation row's claim about
            // the row above it is restated from this pass, never inherited.
            if group.count > 1 {
                for j in 1..<group.count { group[j].wrapGapBefore = false }
                for j in gapRows where j >= 1 && j < group.count { group[j].wrapGapBefore = true }
            }

            // Count the rows at the end that hold nothing any more.
            var countToRemove = 0
            var ix = group.count - 1
            while ix > 0 {
                if ix > destLineIndex || group[ix].trimmedLength == 0 {
                    countToRemove += 1
                } else {
                    break
                }
                ix -= 1
            }
            if countToRemove > 0 {
                toRemove.append(y + group.count - countToRemove)
                toRemove.append(countToRemove)
            }

            y += group.count - 1
        }

        return toRemove
    }

    private func reflowWider(oldCols: Int, newCols: Int, newRows: Int) {
        var rows = snapshotRows()
        let toRemove = linesToRemove(&rows, oldCols: oldCols, newCols: newCols,
                                     absoluteY: ybase + y)
        guard !toRemove.isEmpty else {
            // Nothing to drop, but rows may have been materialised in place.
            lines.replaceAll(rows)
            return
        }

        // Walk the removal pairs once and keep every index they do not cover.
        var layout: [Int] = []
        layout.reserveCapacity(rows.count)
        var nextToRemoveIndex = 0
        var nextToRemoveStart = toRemove[0]
        var countRemovedSoFar = 0
        var i = 0
        while i < rows.count {
            if nextToRemoveStart == i {
                nextToRemoveIndex += 1
                let countToRemove = toRemove[nextToRemoveIndex]
                i += countToRemove - 1
                countRemovedSoFar += countToRemove
                nextToRemoveStart = Int.max
                if nextToRemoveIndex < toRemove.count - 1 {
                    nextToRemoveIndex += 1
                    nextToRemoveStart = toRemove[nextToRemoveIndex]
                }
            } else {
                layout.append(i)
            }
            i += 1
        }

        var kept: [Row?] = layout.map { rows[$0] }

        // Every removed line pulls the viewport up by one.
        var adjustments = countRemovedSoFar
        while adjustments > 0 {
            adjustments -= 1
            if ybase == 0 {
                if y > 0 { y -= 1 }
                if kept.count < newRows { kept.append(nil) }
            } else {
                if ydisp == ybase { ydisp -= 1 }
                ybase -= 1
            }
        }
        if var saved = savedCursor {
            saved.y = Swift.max(saved.y - countRemovedSoFar, 0)
            savedCursor = saved
        }

        lines.replaceAll(kept)
    }

    // MARK: - narrowing

    /// xterm's `getNewLineLengths`: where the logical line wraps at the new
    /// width. Every entry is `newCols`, or `newCols - 1` when that row would
    /// otherwise end in the head of a wide character, except the last, which
    /// holds the remainder.
    func newLineLengths(_ group: [Row], oldCols: Int, newCols: Int) -> [Int] {
        guard newCols > 0, !group.isEmpty else { return [] }
        var lengths: [Int] = []

        var cellsNeeded = 0
        for i in 0..<group.count { cellsNeeded += wrappedTrimmedLength(group, i, oldCols) }

        var srcCol = 0
        var srcLine = 0
        var cellsAvailable = 0
        while cellsAvailable < cellsNeeded {
            if cellsNeeded - cellsAvailable < newCols {
                lengths.append(cellsNeeded - cellsAvailable)
                break
            }

            srcCol += newCols
            let oldTrimmed = srcLine < group.count ? wrappedTrimmedLength(group, srcLine, oldCols) : 0
            if srcCol > oldTrimmed {
                srcCol -= oldTrimmed
                srcLine += 1
            }

            var endsWithWide = false
            if srcLine < group.count, srcCol - 1 >= 0, srcCol - 1 < group[srcLine].cols {
                endsWithWide = group[srcLine][srcCol - 1].width == 2
            }
            if endsWithWide { srcCol -= 1 }

            // `newCols == 1` with a wide character would give a zero-length row
            // and spin forever; splitting the character is the lesser evil.
            let lineLength = Swift.max(endsWithWide ? newCols - 1 : newCols, 1)
            lengths.append(lineLength)
            cellsAvailable += lineLength
        }

        return lengths
    }

    private func reflowNarrower(oldCols: Int, newCols: Int, newRows: Int) {
        var rows = snapshotRows()
        var toInsert: [InsertionSet] = []
        var countToInsert = 0
        let maxLength = lines.maxLength

        // Backwards, so rows that are about to be trimmed are never considered.
        var y = rows.count - 1
        while y >= 0 {
            defer { y -= 1 }
            guard y < rows.count else { continue }

            let bottom = rows[y]
            let lineLength = bottom?.trimmedLength ?? 0
            if !(bottom?.wrapped ?? false) && lineLength <= newCols { continue }

            // Walk up to the first row of the logical line. Collected bottom-up
            // and reversed once: xterm's `unshift` per row made this quadratic
            // in the height of one logical line — a 200,000-row ring that is a
            // single `cat`ed blob cost 2.5 s per column of a window drag, a
            // 100,000-row one 0.7 s, against 34 ms for the same rows as short
            // lines. Harmless at the default 10,000-line scrollback (~6 ms);
            // `scrollbackLines` goes to 200,000.
            var current = materialise(&rows, y)
            var group: [Row] = [current]
            while current.wrapped && y > 0 {
                y -= 1
                current = materialise(&rows, y)
                group.append(current)
            }
            group.reverse()

            let absoluteY = ybase + self.y
            if absoluteY >= y && absoluteY < y + group.count { continue }

            let lastLineLength = group[group.count - 1].trimmedLength
            let destLineLengths = newLineLengths(group, oldCols: oldCols, newCols: newCols)
            if destLineLengths.isEmpty { continue }
            let linesToAdd = destLineLengths.count - group.count

            // How many rows will fall off the top once the new ones are spliced
            // in — the viewport must not chase them.
            let trimmedLines: Int
            if ybase == 0 && self.y != rows.count - 1 {
                trimmedLines = Swift.max(0, self.y - maxLength + linesToAdd)
            } else {
                trimmedLines = Swift.max(0, rows.count - maxLength + linesToAdd)
            }

            var newLines: [Row] = []
            if linesToAdd > 0 {
                for _ in 0..<linesToAdd {
                    let r = Row(cols: lines.cols)
                    r.wrapped = true
                    newLines.append(r)
                }
            }
            if !newLines.isEmpty {
                toInsert.append(InsertionSet(lines: newLines,
                                             start: y + group.count + countToInsert))
                countToInsert += newLines.count
            }
            group.append(contentsOf: newLines)

            // Copy backwards so the rows can be rewritten in place.
            let limit = Swift.min(group.count, destLineLengths.count)
            var destLineIndex = destLineLengths.count - 1
            var destCol = destLineLengths[destLineIndex]
            if destCol == 0 {
                destLineIndex -= 1
                destCol = destLineIndex >= 0 ? destLineLengths[destLineIndex] : 0
            }

            var srcLineIndex = group.count - Swift.max(linesToAdd, 0) - 1
            var srcCol = lastLineLength
            while srcLineIndex >= 0 && destLineIndex >= 0 {
                let cellsToCopy = Swift.min(srcCol, destCol)
                if cellsToCopy > 0, destLineIndex < group.count {
                    group[destLineIndex].copyCells(from: group[srcLineIndex],
                                                   srcCol: srcCol - cellsToCopy,
                                                   dstCol: destCol - cellsToCopy,
                                                   count: cellsToCopy)
                }
                destCol -= cellsToCopy
                if destCol == 0 {
                    destLineIndex -= 1
                    if destLineIndex >= 0 { destCol = destLineLengths[destLineIndex] }
                }

                srcCol -= cellsToCopy
                if srcCol == 0 {
                    srcLineIndex -= 1
                    srcCol = wrappedTrimmedLength(group, Swift.max(srcLineIndex, 0), oldCols)
                }
            }

            // A wide character that moved to the next row leaves a hole behind.
            for i in 0..<limit where destLineLengths[i] < newCols {
                if destLineLengths[i] < group[i].cols { group[i][destLineLengths[i]] = Cell.empty }
            }

            // …and the row that character landed on is the one that remembers
            // it, so the hole is never read back as content (finding 2). A row
            // short of `newCols` is a wrap gap only when another row follows it:
            // the last entry is the remainder of the line, not a gap. Restated
            // for the whole group, because these rows carried the old wrapping's
            // flags a moment ago.
            if group.count > 1 {
                for i in 1..<group.count { group[i].wrapGapBefore = false }
                for i in 0..<(destLineLengths.count - 1)
                where destLineLengths[i] < newCols && i + 1 < group.count {
                    group[i + 1].wrapGapBefore = true
                }
            }

            var viewportAdjustments = linesToAdd - trimmedLines
            while viewportAdjustments > 0 {
                viewportAdjustments -= 1
                if ybase == 0 {
                    if self.y < newRows - 1 {
                        self.y += 1
                        if !rows.isEmpty { rows.removeLast() }
                    } else {
                        ybase += 1
                        ydisp += 1
                    }
                } else if ybase < Swift.min(maxLength, rows.count + countToInsert) - newRows {
                    if ybase == ydisp { ydisp += 1 }
                    ybase += 1
                }
            }

            if var saved = savedCursor {
                saved.y = Swift.min(saved.y + linesToAdd, newRows - 1)
                savedCursor = saved
            }
        }

        rearrange(&rows, toInsert, countToInsert)
        lines.replaceAll(rows)
    }

    /// xterm's `rearrange`, as one pass that builds the merged order instead of
    /// writing back into the live list. Rows past the ring's capacity are left
    /// to `LineRing.replaceAll`, which drops the oldest and counts them.
    private func rearrange(_ rows: inout [Row?], _ toInsert: [InsertionSet], _ countToInsert: Int) {
        guard !toInsert.isEmpty else { return }
        let original = rows
        let originalLength = original.count
        let total = originalLength + countToInsert
        var out = [Row?](repeating: nil, count: total)

        var originalLineIndex = originalLength - 1
        var nextToInsertIndex = 0
        var nextToInsert: InsertionSet? = toInsert[0]
        var countInsertedSoFar = 0
        var i = total - 1
        while i >= 0 {
            if let ins = nextToInsert, ins.start > originalLineIndex + countInsertedSoFar {
                var n = ins.lines.count - 1
                while n >= 0 {
                    if i < 0 { break }
                    out[i] = ins.lines[n]
                    i -= 1
                    n -= 1
                }
                i += 1
                countInsertedSoFar += ins.lines.count
                if nextToInsertIndex < toInsert.count - 1 {
                    nextToInsertIndex += 1
                    nextToInsert = toInsert[nextToInsertIndex]
                } else {
                    nextToInsert = nil
                }
            } else {
                if originalLineIndex >= 0 { out[i] = original[originalLineIndex] }
                originalLineIndex -= 1
            }
            i -= 1
        }
        rows = out
    }

    // MARK: - private

    /// The ring as a plain array, keeping the laziness: a slot that was never
    /// touched stays nil rather than being allocated just to be scanned.
    private func snapshotRows() -> [Row?] {
        var out = [Row?]()
        out.reserveCapacity(lines.count)
        for i in 0..<lines.count { out.append(lines.allocatedRow(at: i)) }
        return out
    }

    /// The row at `index`, allocating it only now that something is going to be
    /// written into it.
    private func materialise(_ rows: inout [Row?], _ index: Int) -> Row {
        if let r = rows[index] { return r }
        let r = Row(cols: lines.cols)
        rows[index] = r
        return r
    }
}
