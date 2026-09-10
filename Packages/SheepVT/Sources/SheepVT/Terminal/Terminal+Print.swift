// SheepVT — putting characters on the grid.
//
// This is the hot path and the one fixtures beat on hardest, so the rules are
// spelled out rather than factored:
//
//  * pending wrap: after printing in the last column the cursor sits at
//    `x == cols`. Nothing is wrapped until the *next* printable arrives, so
//    a CR, a cursor move or an erase in between cancels the wrap.
//  * a wide (width 2) character that does not fit wraps first; with DECAWM
//    off it is written at `cols - 2` instead.
//  * width 0 (combining marks) attach to the cell to the left, hopping over
//    the spacer half of a wide char, and across a soft wrap to the row above.
//  * overwriting either half of a wide character clears the other half, so
//    the grid never holds a lone spacer or a lone left half.

extension Terminal {

    /// Longest grapheme we will accumulate in a cell's side table. A stream of
    /// combining marks is a classic way to make an emulator allocate forever.
    static let maxCombiningScalars = 32

    // MARK: - Single code point

    public func print(_ codePoint: UInt32) {
        // Soft hyphen: ambiguous everywhere, treated as a layout hint and
        // dropped (xterm.js does the same, and leaves the join state alone).
        if codePoint == 0x00AD { return }

        // Derived once and handed to every helper below. `buffer` is
        // `isAlternate ? alternate : primary` — three property accesses each
        // time it is asked for, and the wrap, the emptiness probe and the
        // combining path all used to ask again for the buffer we already hold.
        let b = buffer
        let nCols = cols
        var code = codePoint
        // `activeCharset` is an array subscript on a stored property; a code
        // point that no charset can translate never needs to look at it.
        if code < 127 {
            let charset = activeCharset
            if charset != .ascii { code = Charsets.translate(code, charset: charset) }
        }

        let w = UnicodeWidth.width(code)
        if w == 0 {
            attachCombining(code, b)
            lastActionWasPrint = true
            return
        }
        // A blank typed onto an empty cell is text arriving (someone typed a
        // space); a blank over a character is an erase (a pager wiping its
        // prompt) — the renderer holds a frame for the latter, never the former.
        if code > 0x20 || (code == 0x20 && cellIsEmptyAtCursor(b)) { noteVisibleGlyph() }

        // Wrap before writing.
        var leftAWrapGap = false
        if b.x + w > nCols {
            if modes.autoWrap {
                // A wide character stepping over the last column leaves that
                // cell behind as a *gap*, not as content — and leaves it looking
                // exactly like a cell an overwrite blanked. Reflow cannot tell
                // the two apart from the grid, so say which one this is (see
                // `Row.wrapGapBefore`). `b.x == nCols - 1` is the whole test:
                // one free column and a character that needs two. At `b.x ==
                // nCols` the last column holds a real character and there is no
                // gap at all.
                leftAWrapGap = w == 2 && b.x == nCols - 1
                wrapToNextLine(b)
            } else if w == 2 {
                // xterm.js: with DECAWM off a wide char that does not fit is
                // dropped; it must not overwrite the character before it.
                b.x = nCols - 1
                lastActionWasPrint = true
                return
            } else {
                b.x = Swift.max(0, nCols - w)
            }
        }

        let row = b.row(b.y)
        // The cursor is walked in a local and stored back once. Nothing between
        // here and the store reads `b.x` (the pen, the row and `markDirty` all
        // take what they need as arguments), so this is the same cursor motion
        // written with one access to the buffer instead of four.
        var x = Swift.max(0, Swift.min(b.x, nCols - 1))
        let pen = self.pen

        // We are about to land on the spacer of the wide char at x-1: kill it.
        if x > 0, row[x - 1].width == 2 {
            row[x - 1] = pen.eraseCell
        }

        if modes.insert {
            row.insertCells(at: x, count: w, fill: pen.eraseCell)
            // A wide char shifted into the last column has no room for its
            // spacer, so it cannot survive.
            if row[nCols - 1].width == 2 {
                row[nCols - 1] = pen.eraseCell
            }
        }

        row[x] = pen.cell(code: code, width: w)
        if pen.hasExtended { row.setExtended(pen.extended, at: x) }
        x += 1
        if w > 1, x < nCols {
            // No extended attributes on the spacer: only the head owns the
            // side-table entry (`Pen.cell` no longer sets the flag at all —
            // see the note there).
            row[x] = pen.cell(code: 0, width: 0)
            x += 1
        }

        // We overwrote the left half of a wide char: its spacer is now orphaned.
        if x < nCols, row[x].isSpacer {
            row[x] = pen.eraseCell
        }
        // Claimed only once the character is actually on this row's column 0:
        // `wrapToNextLine` is a no-op for a cursor parked below the bottom
        // margin, and then nothing moved and nothing was skipped.
        if leftAWrapGap, x == w, row.wrapped { row.wrapGapBefore = true }
        b.x = x

        markDirty(b.y)
        lastPrintedCode = code
        lastActionWasPrint = true
    }

    // MARK: - ASCII run

    /// True when the cell the cursor sits on holds no character (or the cursor
    /// is past the last column, so the write lands on a fresh cell after a wrap).
    private func cellIsEmptyAtCursor(_ b: Buffer) -> Bool {
        guard b.x < cols else { return true }
        guard let row = b.allocatedRow(b.y) else { return true }
        let c = row[b.x]
        return c.code == 0 && !c.isCombined
    }

    public func printRun(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !bytes.isEmpty else { return }
        guard !modes.insert, activeCharset == .ascii else {
            for byte in bytes { print(UInt32(byte)) }   // print() counts glyphs itself
            return
        }
        // A run that holds anything but blanks, or blanks landing on an empty
        // cell, counts as text.
        let b = buffer
        var visible = cellIsEmptyAtCursor(b)
        // The pen is read once for the whole run: every cell of it gets the
        // same attributes (an SGR in between would have ended the run).
        let fg = pen.fg
        let bg = pen.bg
        let ext = pen.hasExtended ? pen.extended : nil
        guard let base = bytes.baseAddress else { return }
        var i = 0
        while i < bytes.count {
            if b.x >= cols {                       // pending wrap: print() owns the wrap
                print(UInt32(bytes[i]))
                i += 1
                continue
            }
            let n = Swift.min(cols - b.x, bytes.count - i)
            let row = b.row(b.y)
            let x = b.x
            if x > 0, row[x - 1].width == 2 { row[x - 1] = pen.eraseCell }
            if !visible {
                var k = 0
                while k < n { if base[i + k] > 0x20 { visible = true; break }; k += 1 }
            }
            row.writeASCIIRun(base + i, count: n, at: x, fg: fg, bg: bg, extended: ext)
            b.x = x + n
            if b.x < cols, row[b.x].isSpacer { row[b.x] = pen.eraseCell }
            markDirty(b.y)
            lastPrintedCode = UInt32(base[i + n - 1])
            lastActionWasPrint = true
            i += n
        }
        if visible { noteVisibleGlyph() }
    }

    // MARK: - Helpers

    /// DECAWM wrap: the cursor goes to column 0 of the next row, scrolling at
    /// the bottom margin, and the row it lands on is flagged as a soft
    /// continuation of the one above.
    private func wrapToNextLine(_ b: Buffer) {
        b.x = 0
        if b.y == b.scrollBottom {
            b.scrollUp(1, fill: pen.eraseCell, wrapped: true)
            delegate?.scrolled(self, lines: 1)
            markAllDirty()
        } else if b.y < rows - 1 {
            b.y += 1
            b.row(b.y).wrapped = true
        }
        // (cursor parked below the bottom margin on the last row: it cannot
        // advance, so no row becomes a continuation — xterm.js does the same)
    }

    /// Attach a zero-width scalar to the cell that owns the previous column.
    private func attachCombining(_ code: UInt32, _ b: Buffer) {
        guard let scalar = UnicodeScalar(code) else { return }
        var row = b.row(b.y)
        var target = b.y
        var col = b.x - 1

        if b.x == 0 {
            // Only a soft wrap makes the row above a continuation of this one.
            guard b.y > 0, row.wrapped else { return }
            target = b.y - 1
            row = b.row(target)
            col = cols - 1
        }

        col = Swift.min(col, cols - 1)
        guard col >= 0 else { return }
        // Land on the character, not on the spacer half of a wide one.
        if row[col].isSpacer, col > 0 { col -= 1 }

        var text: String
        if let existing = row.combinedString(at: col) {
            text = existing
        } else if let base = UnicodeScalar(row[col].code), base.value != 0 {
            text = String(Character(base))
        } else {
            text = ""
        }
        guard text.unicodeScalars.count < Terminal.maxCombiningScalars else { return }
        text.unicodeScalars.append(scalar)
        row.setCombined(text, at: col)
        markDirty(target)
    }
}
