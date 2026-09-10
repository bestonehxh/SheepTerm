// FuzzFindingsTests.swift — SheepVT
//
// Bugs found by the fuzzers, each reduced to the shortest byte sequence that
// still shows it, so a fix has something to turn green and the fuzzer's
// suppression list (`SHEEPVT_FUZZ_SUPPRESS`) has a companion that says what is
// being suppressed and why.
//
// A finding is written as a plain failing test while it is open, and becomes an
// ordinary assertion the moment it is fixed — **both findings are now fixed**:
// finding 1 (3.0 (5x), `Pen.cell` no longer sets `hasExtended`; see the note on
// it in `Buffer.swift`) and finding 2 (`Row.wrapGapBefore` — the emulator
// records the wrap gap instead of guessing it back out of the cells; see
// `Buffer+Reflow.wrappedTrimmedLength`). `SHEEPVT_FUZZ_SUPPRESS` is not needed
// for either, and the `withKnownIssue` wrapper that used to hold finding 2 open
// is gone.

import Testing

@testable import SheepVT

// MARK: - Finding 1 — the spacer half of a wide character claims an extended
//                     attribute entry it does not have
//
// `Pen.cell(code:width:)` sets `Cell.BgFlag.hasExtended` from the pen for every
// cell it builds, and `Terminal.print` uses it for BOTH halves of a wide
// character:
//
//     row[x] = pen.cell(code: code, width: w)
//     if pen.hasExtended { row.setExtended(pen.extended, at: x) }   // head only
//     x += 1
//     if w > 1, x < nCols {
//         row[x] = pen.cell(code: 0, width: 0)                      // spacer: flag, no entry
//         x += 1
//     }
//
// The spacer therefore carries the flag with no row side-table entry behind it.
// Two consequences, both reachable from an ordinary `OSC 8` link around a CJK
// or emoji glyph:
//
//   * `TerminalView.link(at:)` reads `row.extended(at: col)` without skipping
//     spacers, so ⌘-clicking the RIGHT half of a hyperlinked wide character
//     finds nothing and the link does not open — the left half does.
//
//   * worse, `Row.subscript`'s setter only drops a stale side-table entry when
//     the incoming cell does NOT claim `hasExtended`. A spacer that claims it
//     leaves whatever was in that column before untouched, so the right half of
//     the glyph keeps the PREVIOUS occupant's hyperlink — ⌘-click opens the
//     wrong URL.
//
// Found by the fuzzer at seed 0x5eed0c0ffee12345 case 0, reduced to
// `ESC ] 8 ; ; 0 ESC \` followed by one wide character.

@Suite("SheepVT fuzz findings")
struct FuzzFindingsTests {

    @Test("1a — the spacer of a hyperlinked wide char has hasExtended but no entry")
    func spacerExtendedFlagWithoutEntry() {
        let t = Terminal(cols: 4, rows: 1, scrollback: 0)
        t.feed(Array("\u{1b}]8;;https://example.com/\u{1b}\\".utf8))
        t.feed(Array("\u{4E00}".utf8))          // one wide character
        let row = t.buffer.row(0)

        // The head is consistent…
        #expect(row[0].width == 2)
        #expect(row[0].hasExtended)
        #expect(row.extended(at: 0)?.hyperlinkID == 1)

        // …and the spacer is not: the flag says "there is an entry", there is none.
        #expect(row[1].isSpacer)
        #expect(row[1].hasExtended == (row.extended(at: 1) != nil),
                Comment(rawValue: "spacer at col 1: hasExtended=\(row[1].hasExtended) but "
                                  + "extended(at: 1) = \(String(describing: row.extended(at: 1)))"))
    }

    @Test("1b — the spacer keeps the previous occupant's hyperlink")
    func spacerKeepsStaleHyperlink() {
        let t = Terminal(cols: 4, rows: 1, scrollback: 0)

        // Column 1 gets link A.
        t.feed(Array("\u{1b}]8;;https://A/\u{1b}\\".utf8))
        t.feed(Array("ab".utf8))
        t.feed(Array("\u{1b}]8;;\u{1b}\\".utf8))            // close the link

        // Now a wide character under link B, starting at column 0, so its
        // spacer lands on column 1.
        t.feed(Array("\u{1b}[H".utf8))
        t.feed(Array("\u{1b}]8;;https://B/\u{1b}\\".utf8))
        t.feed(Array("\u{4E00}".utf8))
        t.feed(Array("\u{1b}]8;;\u{1b}\\".utf8))

        let row = t.buffer.row(0)
        let linkA = t.hyperlinks.firstIndex(of: "https://A/").map { UInt32($0 + 1) }
        let linkB = t.hyperlinks.firstIndex(of: "https://B/").map { UInt32($0 + 1) }
        #expect(linkA != nil && linkB != nil)
        #expect(row.extended(at: 0)?.hyperlinkID == linkB)

        // The right half of the glyph must not point at the link that used to
        // be in that column. (Either no entry, or link B — never link A.)
        let onSpacer = row.extended(at: 1)?.hyperlinkID
        #expect(onSpacer != linkA,
                Comment(rawValue: "the spacer at col 1 still carries the previous cell's "
                                  + "hyperlink (id \(String(describing: onSpacer)) "
                                  + "= \(String(describing: linkA)))"))
    }

    @Test("1c — the same happens for an underline colour, not just hyperlinks")
    func spacerExtendedFlagFromUnderlineColor() {
        let t = Terminal(cols: 4, rows: 1, scrollback: 0)
        t.feed(Array("\u{1b}[4:3m\u{1b}[58:5:9m".utf8))     // curly underline, red
        t.feed(Array("\u{4E00}".utf8))
        let row = t.buffer.row(0)
        #expect(row[0].hasExtended)
        #expect(row[1].isSpacer)
        #expect(row[1].hasExtended == (row.extended(at: 1) != nil),
                Comment(rawValue: "spacer at col 1: hasExtended=\(row[1].hasExtended) but "
                                  + "extended(at: 1) = \(String(describing: row.extended(at: 1)))"))
    }
}

// MARK: - Finding 2 — a reflow round trip eats a NUL that was real content
//
// `Buffer+Reflow.wrappedTrimmedLength` is xterm's `getWrappedLineTrimmedLength`:
// a row of a wrapped line is `cols` cells long, *except* when its last cell is a
// NUL and the row after it starts with a wide character — then it is `cols - 1`,
// because that NUL is the gap the printer left when the wide character did not
// fit at the right margin.
//
// The rule reads a cell and infers how it got there, and it can be wrong. A NUL
// also appears wherever a program overwrote the front of an existing row and
// left the rest of it alone (here: `k` printed over the start of a row that
// already held ` 仃`, the cursor then moved away with `CSI e`). Narrowing that
// row can leave that NUL sitting in the LAST column, in front of the wide
// character, at which point widening reads it as a wrap gap and closes it:
//
//     4 cols   "jqbl" / "k<NUL>仃"        (one logical line, cursor elsewhere)
//     2 cols   "jq" / "bl" / "k<NUL>" / "仃"
//     4 cols   "jqbl" / "k仃 "            ← the cell between k and 仃 is gone
//
// One cell of a logical line, so nothing crashes and nothing else shifts; the
// text simply reads differently after a resize round trip. Inherited from
// xterm.js, which has the same rule and the same hole.
//
// Found by `FuzzReflowTests.fuzzReflowLineOps` (the IL/DL + scroll-region
// generator) at `SHEEPVT_FUZZ_SEED=0xFFFFFFFFFFFFFFFF SHEEPVT_FUZZ_CASES=6000`,
// case 2044, and reduced from 562 bytes to the 26 below. The plain-text reflow
// fuzz never produces it: it takes an overwrite to put a NUL anywhere but the
// end of a line.
//
// FIXED, by the second of the two options the reduction named: a row records
// that the cell above it is a wrap gap (`Row.wrapGapBefore`), written by the
// three places that can make one — the wide-character wrap in `Terminal.print`
// and the two reflow directions — instead of being guessed back out of a cell
// shape that two different histories share. The cell test xterm.js uses stays
// in front of the flag as a veto. The three tests below now guard both
// directions: the overwrite NUL survives, and a real wrap gap is still closed.

@Suite("SheepVT fuzz findings — reflow gaps")
struct FuzzOpenFindingsTests {

    /// The reduced case, byte for byte.
    static let overwriteThenWide: [UInt8] = [
        0x0a, 0x62, 0x20, 0xe4, 0xbb, 0x83,           // LF, "b ", 仃
        0x1b, 0x5b, 0x72,                             // CSI r  (reset the region)
        0xba, 0x8b, 0x20, 0xe4, 0xb8, 0xa1,           // invalid UTF-8, " ", 両
        0x1b, 0x5b, 0x72,                             // CSI r
        0x6a, 0x71, 0x62, 0x6c, 0x6b,                 // "jqblk" — overwrites, leaving a NUL
        0x1b, 0x5b, 0x65,                             // CSI e  (cursor off the line)
    ]

    @Test("2 — narrowing and widening back loses the NUL in front of a wide char")
    func reflowRoundTripEatsAnOverwriteNul() {
        let t = Terminal(cols: 4, rows: 10, scrollback: 5_000)
        t.feed(FuzzOpenFindingsTests.overwriteThenWide)

        // The state the fuzzer reduced to: a two-row logical line whose second
        // row is `k`, a NUL, and a wide character.
        let row = t.buffer.row(1)
        #expect(row.wrapped)
        #expect(row[0].code == 0x6B)          // k
        #expect(row[1].code == 0)             // the NUL an overwrite left behind
        #expect(row[2].width == 2)            // 仃
        #expect(t.allLines(trimRight: false)[1] == "k \u{4EC3}")

        // Nothing here was ever a wrap gap: 仃 sits mid-row, and the NUL in
        // front of it is what an overwrite left. The round trip must be a
        // no-op.
        t.resize(cols: 2, rows: 10)
        #expect(t.allLines(trimRight: false)[2] == "k ")
        #expect(t.allLines(trimRight: false)[3] == "\u{4EC3}")
        #expect(!t.buffer.lines[3].wrapGapBefore)      // no character was pushed down

        t.resize(cols: 4, rows: 10)
        #expect(t.allLines(trimRight: false)[0] == "jqbl")
        #expect(t.allLines(trimRight: false)[1] == "k \u{4EC3}")
    }

    /// The other direction of the same rule, which the fix must not break: a
    /// blank that IS a wrap gap still costs nothing. `abc` fills three of four
    /// columns and 仃 needs two, so the printer steps over column 3 and starts
    /// the character on the next row — the logical line is `abc仃`, five cells
    /// in four columns, and a round trip must put it back exactly.
    @Test("2b — a blank that really is a wrap gap is still closed by a round trip")
    func reflowRoundTripKeepsClosingARealWrapGap() {
        let t = Terminal(cols: 4, rows: 10, scrollback: 5_000)
        t.feed(Array("abc\u{4EC3}".utf8))
        t.feed(Array("\u{1b}[9;1H".utf8))            // cursor off the logical line

        #expect(t.buffer.lines[0][3].code == 0)      // the gap
        #expect(t.buffer.lines[1].wrapped)
        #expect(t.buffer.lines[1].wrapGapBefore)     // …and it is recorded as one
        #expect(t.allLines()[0] == "abc")
        #expect(t.allLines()[1] == "\u{4EC3}")

        t.resize(cols: 6, rows: 10)
        #expect(t.allLines()[0] == "abc\u{4EC3}")    // the gap closed, as it should

        t.resize(cols: 4, rows: 10)
        #expect(t.allLines()[0] == "abc")
        #expect(t.allLines()[1] == "\u{4EC3}")
        #expect(t.buffer.lines[1].wrapGapBefore)     // and reflow re-recorded it
    }

    /// The two shapes side by side, at the same width, in the same buffer, so a
    /// regression that treats them alike fails whichever way it leans.
    ///
    ///   line A  "abc" / "仃"        — 仃 needed two columns and column 3 was
    ///                                 the only one left: column 3 is a gap.
    ///   line B  "abc␀" / "仃"       — "abcd" filled the row, 仃 wrapped with
    ///                                 nothing skipped, and 'd' was erased
    ///                                 afterwards. Column 3 is content.
    ///
    /// Cell for cell the two are the same three cells. Widening has to close A
    /// and keep B.
    @Test("2c — the two blanks look identical in the grid and reflow apart")
    func gapAndOverwriteBlankAreToldApart() {
        let t = Terminal(cols: 4, rows: 10, scrollback: 5_000)
        t.feed(Array("abc\u{4EC3}\r\n".utf8))                  // line A, rows 0–1
        t.feed(Array("abcd\u{4EC3}".utf8))                      // line B, rows 2–3
        t.feed(Array("\u{1b}[3;4H\u{1b}[1X".utf8))              // erase 'd' → a NUL
        t.feed(Array("\u{1b}[9;1H".utf8))                       // cursor off both lines

        // Identical shapes: a NUL in the last column, a wide char below.
        for head in [0, 2] {
            #expect(t.buffer.lines[head][3].code == 0)
            #expect(t.buffer.lines[head + 1].wrapped)
            #expect(t.buffer.lines[head + 1][0].width == 2)
        }
        // …told apart only by what the emulator recorded when it made them.
        #expect(t.buffer.lines[1].wrapGapBefore)
        #expect(!t.buffer.lines[3].wrapGapBefore)

        t.resize(cols: 8, rows: 10)
        #expect(t.allLines()[0] == "abc\u{4EC3}")                // A: the gap closed
        #expect(t.allLines(trimRight: false)[1] == "abc \u{4EC3}  ")   // B: the blank kept
    }
}
