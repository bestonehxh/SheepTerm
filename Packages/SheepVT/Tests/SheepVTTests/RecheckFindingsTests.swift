import Testing
@testable import SheepVT

/// The second recheck of 3.0 (56) ran the package objects themselves and found
/// two things the previous round's tests had not covered. Both reproducers are
/// kept here as they were reported, so the next change to reflow or search
/// has to keep them passing rather than re-derive them.
@Suite("recheck findings after 3.0 (56)")
struct RecheckFindingsTests {
    private func top(_ t: Terminal) -> String {
        let b = t.buffer
        return String((b.row(line: b.lineNumber(ofViewportRow: 0))?.string() ?? "").prefix(4))
    }

    /// One 180-row paragraph (no hard newline) in a 210-row ring, read 50 rows
    /// up. Narrowing to 40 columns makes it 360 rows, so 152 of them fall off
    /// the top — and the reader's offset into the paragraph was counted from a
    /// head that is now gone. Measured before the fix: the top row became 0176
    /// and `ydisp` landed on `ybase`, i.e. the view quietly started following
    /// the output while 0122 was still in the buffer at index 92.
    @Test("a reader keeps their place when narrowing trims the head of their own paragraph")
    func anchorSurvivesTrimOfItsOwnLine() {
        let t = Terminal(cols: 80, rows: 10, scrollback: 200)
        for i in 0..<180 {
            let head = String(format: "%04d", i)
            t.feed(head + String(repeating: ".", count: 80 - head.count))
        }
        t.feed("\r\ntail\r\n")
        t.scrollViewport(by: -50)
        #expect(top(t) == "0122")
        let trimmedBefore = t.buffer.lines.trimmed

        t.resize(cols: 40, rows: 10)

        let b = t.buffer
        #expect(b.lines.trimmed - trimmedBefore == 152, "the cut this test is about did not happen")
        #expect(top(t) == "0122")
        #expect(b.ydisp < b.ybase, "the reader was pulled back to following the output")
        #expect(b.ydisp == 92)

        // Back out again: the cut rows are gone for good, the place is not.
        t.resize(cols: 80, rows: 10)
        #expect(top(t) == "0122")
        #expect(t.buffer.ydisp < t.buffer.ybase)
    }

    /// The other thing a trim can do: take the whole line the reader was on.
    /// Twenty short lines, then a 120-row paragraph; the reader is on L010.
    /// Narrowing makes the paragraph 240 rows, so every short line and the
    /// first 32 rows of the paragraph are dropped. Nothing of L010 is left to
    /// show, so the viewport goes to the top of what is — still scrolled back,
    /// not following, and not "row 0 plus an offset that belonged to L010".
    @Test("a reader whose line fell off the top lands on the top of what is left")
    func anchorGoneGoesToTheTopOfWhatRemains() {
        let t = Terminal(cols: 80, rows: 10, scrollback: 200)
        for i in 0..<20 { t.feed(String(format: "L%03d", i) + "\r\n") }
        for i in 0..<120 {
            let head = String(format: "%04d", i)
            t.feed(head + String(repeating: ".", count: 80 - head.count))
        }
        t.feed("\r\ntail\r\n")
        let b = t.buffer
        t.scrollViewport(by: -(b.ybase - 10))
        #expect(top(t) == "L010")
        let trimmedBefore = b.lines.trimmed

        t.resize(cols: 40, rows: 10)

        #expect(b.lines.trimmed - trimmedBefore == 52)
        #expect(b.ydisp == 0)
        #expect(b.ydisp < b.ybase)
        #expect(top(t) == "0016")          // row 32 of the paragraph at 40 columns
    }

    /// The one logical line reflow never rewraps is the cursor's: both
    /// directions skip it and `resizeRows` crops or pads it. Its row count
    /// therefore does not change with the width, and a reader parked inside
    /// it keeps a ROW offset, not a cell offset. Rescaling put a reader five
    /// rows into a twenty-row cursor line ten rows in after halving the width
    /// — onto `ybase`, following again (found by the recheck of 3.0 (58)).
    @Test("a reader inside the cursor's own line keeps their row when the width changes")
    func readerInsideTheCursorLineKeepsTheirRow() {
        let t = Terminal(cols: 80, rows: 10, scrollback: 500)
        for i in 0..<100 { t.feed(String(format: "L%03d", i) + "\r\n") }
        for i in 0..<20 {                         // one 20-row line, cursor at its end
            let head = String(format: "C%03d", i)
            t.feed(head + String(repeating: ".", count: 80 - head.count))
        }
        t.scrollViewport(by: -5)
        #expect(top(t) == "C005")
        let b = t.buffer
        #expect(b.ybase + b.y >= 100, "the cursor is inside the anchored line")

        t.resize(cols: 40, rows: 10)
        #expect(top(t) == "C005")
        #expect(b.ydisp < b.ybase, "narrowing put the reader back to following")

        t.resize(cols: 80, rows: 10)
        #expect(top(t) == "C005")
        #expect(b.ydisp < b.ybase)
    }

    /// Height changes move `ybase` by whole rows and no row above the screen
    /// moves, so a scrolled-back reader's index still points at their text.
    /// xterm.js moved `ydisp` with `ybase` (cursor on the bottom row, so the
    /// height change pulls history down or pushes the cursor line up), which
    /// walked the reader |Δrows| lines through the history per resize:
    /// measured 0061 → 0066 (10 → 5), → 0051 (10 → 20), → 0068 (10 → 3).
    @Test("a height change does not move a scrolled-back reader")
    func heightChangeKeepsTheReader() {
        let t = Terminal(cols: 80, rows: 10, scrollback: 500)
        for i in 0..<100 { t.feed(String(format: "%04d line", i) + "\r\n") }
        t.scrollViewport(by: -30)
        #expect(top(t) == "0061")
        let b = t.buffer
        #expect(b.y == 9, "the cursor sits on the bottom row, the case that moved")

        for rows in [5, 20, 3, 15, 10] {
            t.resize(cols: 80, rows: rows)
            #expect(top(t) == "0061", "rows \(rows) moved the reader to \(top(t))")
            #expect(b.ydisp < b.ybase, "rows \(rows) put the reader back to following")
        }
        // …and a viewport pinned to the bottom still follows `ybase`.
        t.scrollViewport(by: 1_000)
        #expect(b.ydisp == b.ybase)
        t.resize(cols: 80, rows: 5)
        #expect(b.ydisp == b.ybase)
        t.resize(cols: 80, rows: 20)
        #expect(b.ydisp == b.ybase)
    }

    /// `ab界界` on a 4-column screen wraps the second 界 to the next row and
    /// leaves the last cell of row 0 empty — as a wrap gap. Overwriting that
    /// row with `c` at column 3 leaves the very same shape (NUL last cell, next
    /// row starts wide) but the empty cell is now a real space. Search used to
    /// guess from the shape and dropped the space: `c 界` found nothing, `c界`
    /// matched, and a resize that changed no text made both right again.
    @Test("search reads the wrap gap the emulator recorded, not the shape of the cells")
    func searchDoesNotMistakeAnOverwriteForAWrapGap() {
        let t = Terminal(cols: 4, rows: 4, scrollback: 100)
        t.feed("ab界界\r\nTAIL\u{1b}[1;3Hc\u{1b}[4;1H")
        #expect(t.buffer.lines[0].string(trimRight: false) == "abc ")
        #expect(t.buffer.lines[1].string(trimRight: false) == "界  ")
        #expect(t.buffer.lines[1].wrapped)
        #expect(!t.buffer.lines[1].wrapGapBefore)

        let e = SearchEngine(terminal: t)
        e.term = "c 界"
        #expect(e.findAll().count == 1)
        e.term = "c界"
        #expect(e.findAll().isEmpty)

        // A resize that changes no text changes no answer.
        t.resize(cols: 8, rows: 4)
        e.term = "c 界"
        #expect(e.findAll().count == 1)
        e.term = "c界"
        #expect(e.findAll().isEmpty)
    }

    /// The real gap, and the two ways it changes under a warm engine: it is
    /// made after a search has cached the row, and it is vetoed by an overwrite
    /// after a search has cached the gap. Both must show up on the next search
    /// without the engine being told — the row that changed is the row whose
    /// generation moved.
    @Test("a real wrap gap is not text, and a warm search sees it come and go")
    func searchSeesAWrapGapAppearAndBeOverwritten() {
        let t = Terminal(cols: 4, rows: 4, scrollback: 100)
        t.feed("abc")
        let e = SearchEngine(terminal: t)
        e.term = "c"
        #expect(e.findAll().count == 1)               // the row is cached now

        t.feed("界")                                   // does not fit: gap at (0,3), 界 at (1,0)
        #expect(t.buffer.lines[1].wrapped)
        #expect(t.buffer.lines[1].wrapGapBefore)
        e.term = "c界"
        #expect(e.findAll().count == 1, "the gap is not a space")
        e.term = "c 界"
        #expect(e.findAll().isEmpty)

        t.feed("\u{1b}[1;4Hd")                         // real content in the gap cell
        #expect(t.buffer.lines[1].wrapGapBefore, "the flag stays; the cell test vetoes it")
        e.term = "d界"
        #expect(e.findAll().count == 1)
        e.term = "c界"
        #expect(e.findAll().isEmpty)

        // A cold engine agrees with the warm one, so the cache is not the reason.
        let cold = SearchEngine(terminal: t)
        cold.term = "d界"
        #expect(cold.findAll().count == 1)
        cold.term = "c界"
        #expect(cold.findAll().isEmpty)
    }
}
