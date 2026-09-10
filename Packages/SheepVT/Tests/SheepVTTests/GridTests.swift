// SheepVT — grid layer unit tests (agent B's contract: Cell layout,
// UnicodeWidth, Row, LineRing, Buffer).

import Testing
@testable import SheepVT

// MARK: - helpers

private func wide(_ code: UInt32) -> Cell { Cell(code: code, width: 2, fg: 0, bg: 0) }
private func spacer() -> Cell { Cell(code: 0, width: 0, fg: 0, bg: 0) }
private func ascii(_ ch: Character) -> Cell {
    Cell(code: ch.unicodeScalars.first!.value, width: 1, fg: 0, bg: 0)
}
private func row(_ text: String, cols: Int) -> Row {
    let r = Row(cols: cols)
    for (i, ch) in text.unicodeScalars.enumerated() where i < cols {
        r[i] = Cell(code: ch.value, width: 1, fg: 0, bg: 0)
    }
    return r
}
private let redBg = Cell(content: 1 << Cell.widthShift, fg: 0,
                         bg: Cell.colorWord(source: .palette16, value: 1))

// MARK: - Cell layout

@Suite("Cell layout")
struct CellLayoutTests {
    @Test("a cell is exactly 12 bytes")
    func stride() {
        #expect(MemoryLayout<Cell>.stride == 12)
        #expect(MemoryLayout<Cell>.size == 12)
    }

    @Test("empty cell is width 1, no code")
    func empty() {
        #expect(Cell.empty.width == 1)
        #expect(Cell.empty.code == 0)
        #expect(Cell.empty.isEmpty)
        #expect(!Cell.empty.isSpacer)
    }
}

// MARK: - UnicodeWidth

@Suite("UnicodeWidth")
struct UnicodeWidthTests {
    @Test("ASCII and controls")
    func ascii() {
        #expect(UnicodeWidth.width(0x61) == 1)          // a
        #expect(UnicodeWidth.width(0x20) == 1)          // space
        #expect(UnicodeWidth.width(0x7E) == 1)          // ~
        #expect(UnicodeWidth.width(0x00) == 0)
        #expect(UnicodeWidth.width(0x07) == 0)          // BEL
        #expect(UnicodeWidth.width(0x1B) == 0)          // ESC
        #expect(UnicodeWidth.width(0x7F) == 0)          // DEL
        #expect(UnicodeWidth.width(0x9B) == 0)          // C1 CSI
        #expect(UnicodeWidth.width(0xA0) == 1)          // NBSP is drawn
    }

    @Test("latin, combining marks, soft hyphen")
    func latin() {
        #expect(UnicodeWidth.width(0xE9) == 1)          // é
        #expect(UnicodeWidth.width(0x0301) == 0)        // combining acute
        #expect(UnicodeWidth.width(0x0951) == 0)        // devanagari stress mark (Mn)
        #expect(UnicodeWidth.width(0x00AD) == 1)        // SOFT HYPHEN is the Cf exception
        #expect(UnicodeWidth.width(0x0600) == 0)        // ARABIC NUMBER SIGN (Cf)
    }

    @Test("zero-width and format ranges")
    func zeroWidth() {
        #expect(UnicodeWidth.width(0x200B) == 0)        // ZWSP
        #expect(UnicodeWidth.width(0x200C) == 0)        // ZWNJ
        #expect(UnicodeWidth.width(0x200D) == 0)        // ZWJ
        #expect(UnicodeWidth.width(0x200F) == 0)        // RLM
        #expect(UnicodeWidth.width(0x2028) == 0)
        #expect(UnicodeWidth.width(0x202E) == 0)
        #expect(UnicodeWidth.width(0x2060) == 0)
        #expect(UnicodeWidth.width(0x2064) == 0)
        #expect(UnicodeWidth.width(0x2010) == 1)        // hyphen, just past the ZW range
    }

    @Test("wide: CJK, Hangul, emoji")
    func widths() {
        #expect(UnicodeWidth.width(0x4E2D) == 2)        // 中
        #expect(UnicodeWidth.width(0x3042) == 2)        // あ
        #expect(UnicodeWidth.width(0xFF21) == 2)        // fullwidth A
        #expect(UnicodeWidth.width(0xAC00) == 2)        // 가
        #expect(UnicodeWidth.width(0x1100) == 2)        // hangul leading jamo
        #expect(UnicodeWidth.width(0x1161) == 0)        // hangul medial jamo composes
        #expect(UnicodeWidth.width(0x1F600) == 2)       // 😀
        #expect(UnicodeWidth.width(0x1F1E6) == 1 || UnicodeWidth.width(0x1F1E6) == 2)
    }

    @Test("a ZWJ emoji sequence measures 2 + 0 + 2")
    func zwjSequence() {
        // 👨‍👩‍👧 = MAN ZWJ WOMAN ZWJ GIRL
        #expect(UnicodeWidth.width(0x1F468) == 2)
        #expect(UnicodeWidth.width(0x200D) == 0)
        #expect(UnicodeWidth.width(0x1F469) == 2)
        #expect(UnicodeWidth.width(0x1F467) == 2)
        // Skin-tone modifiers follow their base and must not add a column of
        // their own beyond what the renderer already reserved.
        #expect(UnicodeWidth.width(0xFE0F) == 0)        // VS16 (Mn)
    }

    @Test("surrogates and out-of-range values fall back to one column")
    func invalid() {
        #expect(UnicodeWidth.width(0xD800) == 0 || UnicodeWidth.width(0xD800) == 1)
        #expect(UnicodeWidth.width(0x110000) == 1)
        #expect(UnicodeWidth.width(0xFFFD) == 1)        // replacement character
    }

    @Test("the low-plane table agrees with the computed path")
    func tableMatchesCompute() {
        for cp in stride(from: UInt32(0), to: UnicodeWidth.tableLimit, by: 7) {
            #expect(UnicodeWidth.width(cp) == UnicodeWidth.compute(cp), "U+\(String(cp, radix: 16))")
        }
    }
}

// MARK: - Row

@Suite("Row")
struct RowTests {
    @Test("generation bumps on every public mutation")
    func generation() {
        let r = Row(cols: 10)
        let g0 = r.generation
        r[0] = ascii("a")
        #expect(r.generation > g0)
        let g1 = r.generation
        r.wrapped = true
        #expect(r.generation > g1)
        let g2 = r.generation
        r.wrapped = true                     // unchanged → no bump
        #expect(r.generation == g2)
        r.fill(.empty)
        #expect(r.generation > g2)
    }

    @Test("side tables stay nil until used and are pruned back")
    func sideTables() {
        let r = Row(cols: 8)
        #expect(r.combined == nil)
        #expect(r.extended == nil)

        r[2] = ascii("e")
        r.setCombined("e\u{0301}", at: 2)
        #expect(r.combined?.count == 1)
        #expect(r[2].isCombined)
        #expect(r.combinedString(at: 2) == "e\u{0301}")

        var ext = ExtendedAttributes()
        ext.underlineStyle = .curly
        r.setExtended(ext, at: 2)
        #expect(r[2].hasExtended)
        #expect(r.extended(at: 2)?.underlineStyle == .curly)

        // Writing a plain cell over the column drops both entries.
        r[2] = ascii("x")
        #expect(r.combined == nil)
        #expect(r.extended == nil)
        #expect(!r[2].isCombined)
        #expect(!r[2].hasExtended)
    }

    @Test("setExtended with default attributes removes the entry")
    func extendedDefault() {
        let r = Row(cols: 4)
        var ext = ExtendedAttributes()
        ext.hyperlinkID = 7
        r.setExtended(ext, at: 1)
        #expect(r.extended?.count == 1)
        r.setExtended(ExtendedAttributes(), at: 1)
        #expect(r.extended == nil)
        #expect(!r[1].hasExtended)
    }

    @Test("string(): spacers skipped, zero code is a space, combined used")
    func stringOutput() {
        let r = Row(cols: 8)
        r[0] = ascii("a")
        r[1] = wide(0x4E2D)                  // 中
        r[2] = spacer()
        r[3] = ascii("b")
        r.setCombined("e\u{0301}", at: 3)
        #expect(r.string(trimRight: true) == "a\u{4E2D}e\u{0301}")
        #expect(r.string(trimRight: false) == "a\u{4E2D}e\u{0301}    ")
        #expect(r.trimmedLength == 4)
    }

    @Test("string() renders empty cells as spaces in the middle")
    func stringGaps() {
        let r = Row(cols: 6)
        r[0] = ascii("a")
        r[3] = ascii("b")
        #expect(r.string() == "a  b")
    }

    @Test("insertCells shifts right and drops the overflow")
    func insertCells() {
        let r = row("abcdef", cols: 6)
        r.insertCells(at: 2, count: 2, fill: .empty)
        #expect(r.string(trimRight: false) == "ab  cd")
    }

    @Test("insertCells past the end blanks the tail")
    func insertCellsOverflow() {
        let r = row("abcdef", cols: 6)
        r.insertCells(at: 4, count: 10, fill: .empty)
        #expect(r.string() == "abcd")
    }

    @Test("insertCells never splits a wide char")
    func insertCellsWide() {
        // a 中 b …  with 中 at column 1/2
        let r = Row(cols: 6)
        r[0] = ascii("a")
        r[1] = wide(0x4E2D)
        r[2] = spacer()
        r[3] = ascii("b")

        // Inserting at column 2 would separate 中 from its spacer: both halves go.
        r.insertCells(at: 2, count: 1, fill: .empty)
        #expect(r[1].code == 0)              // head cleared
        #expect(r[1].width == 1)
        #expect(r[3].width == 1)             // the shifted spacer is no longer one
        #expect(r.string(trimRight: false) == "a   b ")
        #expect(r[4].code == UInt32(0x62))
    }

    @Test("insertCells clears a wide head pushed half off the right edge")
    func insertCellsWideAtEnd() {
        let r = Row(cols: 6)
        r[0] = ascii("a")
        r[3] = wide(0x4E2D)
        r[4] = spacer()
        r.insertCells(at: 1, count: 1, fill: .empty)
        // 中 moved to 4/5 → the spacer at 5 is fine, but check the last cell is
        // not a lone head after a bigger shift.
        r.insertCells(at: 1, count: 1, fill: .empty)
        #expect(r[5].width != 2)
    }

    @Test("deleteCells shifts left and pads at the end")
    func deleteCells() {
        let r = row("abcdef", cols: 6)
        r.deleteCells(at: 1, count: 2, fill: .empty)
        #expect(r.string() == "adef")
        #expect(r.string(trimRight: false) == "adef  ")
    }

    @Test("deleteCells past the end blanks the tail")
    func deleteCellsOverflow() {
        let r = row("abcdef", cols: 6)
        r.deleteCells(at: 3, count: 99, fill: .empty)
        #expect(r.string() == "abc")
    }

    @Test("deleteCells clears an orphaned wide head and an orphaned spacer")
    func deleteCellsWide() {
        // a 中(1,2) b c d
        let r = Row(cols: 6)
        r[0] = ascii("a")
        r[1] = wide(0x4E2D)
        r[2] = spacer()
        r[3] = ascii("b")
        r[4] = ascii("c")
        r[5] = ascii("d")

        r.deleteCells(at: 2, count: 1, fill: .empty)   // eats the spacer
        #expect(r[1].width == 1)
        #expect(r[1].code == 0)
        #expect(r.string() == "a bcd")

        // now an orphaned spacer: put a wide char at 2/3 and delete cell 2
        let s = Row(cols: 6)
        s[0] = ascii("a")
        s[2] = wide(0x4E2D)
        s[3] = spacer()
        s[4] = ascii("z")
        s.deleteCells(at: 2, count: 1, fill: .empty)   // head gone, spacer lands at 2
        #expect(s[2].width == 1)
        #expect(s.string() == "a  z")
    }

    @Test("insert/delete carry the side tables with the cells")
    func sideTablesMove() {
        let r = row("abcdef", cols: 6)
        r.setCombined("a\u{0301}", at: 0)
        var ext = ExtendedAttributes()
        ext.hyperlinkID = 3
        r.setExtended(ext, at: 1)

        r.insertCells(at: 0, count: 2, fill: .empty)
        #expect(r.combinedString(at: 0) == nil)
        #expect(r.combinedString(at: 2) == "a\u{0301}")
        #expect(r.extended(at: 3)?.hyperlinkID == 3)
        #expect(r.extended(at: 1) == nil)

        r.deleteCells(at: 0, count: 2, fill: .empty)
        #expect(r.combinedString(at: 0) == "a\u{0301}")
        #expect(r.extended(at: 1)?.hyperlinkID == 3)
    }

    @Test("fill clears the side tables in its range only")
    func fillRange() {
        let r = row("abcdef", cols: 6)
        r.setCombined("a\u{0301}", at: 0)
        r.setCombined("e\u{0301}", at: 4)
        r.fill(.empty, from: 0, to: 3)
        #expect(r.combinedString(at: 0) == nil)
        #expect(r.combinedString(at: 4) == "e\u{0301}")
        r.fill(.empty)
        #expect(r.combined == nil)
        #expect(r.string() == "")
    }

    @Test("resize pads, truncates, drops cut-off side tables")
    func resize() {
        let r = row("abcdef", cols: 6)
        r.setCombined("e\u{0301}", at: 4)
        r.resize(cols: 3, fill: .empty)
        #expect(r.cols == 3)
        #expect(r.cells.count == 3)
        #expect(r.string() == "abc")
        #expect(r.combined == nil)

        r.resize(cols: 8, fill: .empty)
        #expect(r.cols == 8)
        #expect(r.string(trimRight: false) == "abc     ")
    }

    @Test("resize truncating inside a wide char clears its head")
    func resizeWide() {
        let r = Row(cols: 6)
        r[0] = ascii("a")
        r[1] = wide(0x4E2D)
        r[2] = spacer()
        r.resize(cols: 2, fill: .empty)
        #expect(r[1].width == 1)
        #expect(r[1].code == 0)
        #expect(r.string() == "a")
    }

    @Test("copy takes cells, side tables and the wrapped flag")
    func copy() {
        let a = row("abcdef", cols: 6)
        a.setCombined("a\u{0301}", at: 0)
        a.wrapped = true
        let b = Row(cols: 6)
        b.copy(from: a)
        #expect(b.string() == a.string())
        #expect(b.wrapped)
        #expect(b.combinedString(at: 0) == "a\u{0301}")
    }
}

// MARK: - LineRing

@Suite("LineRing")
struct LineRingTests {
    @Test("slots are nil until touched")
    func lazyAllocation() {
        let ring = LineRing(maxLength: 100, cols: 80)
        for _ in 0..<50 { ring.pushBlank() }
        #expect(ring.count == 50)
        #expect(ring.allocatedRowCount == 0)

        ring[10][0] = ascii("x")
        #expect(ring.allocatedRowCount == 1)
        _ = ring[10]
        #expect(ring.allocatedRowCount == 1)
        _ = ring[11]
        #expect(ring.allocatedRowCount == 2)
    }

    @Test("a coloured fill has to materialise the row")
    func lazyWithBce() {
        let ring = LineRing(maxLength: 10, cols: 4)
        ring.pushBlank(fill: redBg)
        #expect(ring.allocatedRowCount == 1)
        #expect(ring[0][0].bgValue == 1)
    }

    @Test("pushBlank recycles the oldest row once full and counts trims")
    func recycle() {
        let ring = LineRing(maxLength: 4, cols: 4)
        for i in 0..<4 {
            #expect(ring.pushBlank() == false)
            ring[i][0] = ascii(Character(UnicodeScalar(UInt8(0x61 + i))))
        }
        #expect(ring.count == 4)
        #expect(ring.trimmed == 0)
        #expect(ring.isFull)
        #expect(ring[0].string() == "a")

        let oldest = ring[0]
        let oldGeneration = oldest.generation
        #expect(ring.pushBlank() == true)
        #expect(ring.trimmed == 1)
        #expect(ring.count == 4)
        #expect(ring.allocatedRowCount == 4)          // no new allocation
        #expect(ring[0].string() == "b")              // 'a' fell off the top
        #expect(ring[3] === oldest)                   // recycled to the end
        #expect(ring[3].string() == "")
        #expect(oldest.generation > oldGeneration)
    }

    @Test("a recycled row loses wrapped and its side tables")
    func recycleClears() {
        let ring = LineRing(maxLength: 2, cols: 4)
        ring.pushBlank(); ring.pushBlank()
        let r = ring[0]
        r[0] = ascii("a")
        r.setCombined("a\u{0301}", at: 0)
        r.wrapped = true
        ring.pushBlank()
        #expect(ring[1] === r)
        #expect(!r.wrapped)
        #expect(r.combined == nil)
        #expect(r.string() == "")
    }

    @Test("move shifts references, downwards and upwards")
    func move() {
        let ring = LineRing(maxLength: 8, cols: 4)
        for i in 0..<5 { ring.pushBlank(); ring[i][0] = ascii(Character(UnicodeScalar(UInt8(0x61 + i)))) }
        #expect((0..<5).map { ring[$0].string() } == ["a", "b", "c", "d", "e"])

        ring.move(from: 0, to: 4)                     // a to the bottom
        #expect((0..<5).map { ring[$0].string() } == ["b", "c", "d", "e", "a"])

        ring.move(from: 4, to: 1)                     // a back up to index 1
        #expect((0..<5).map { ring[$0].string() } == ["b", "a", "c", "d", "e"])

        ring.move(from: 2, to: 2)                     // no-op
        #expect(ring[2].string() == "c")
    }

    @Test("move works across the wrap point")
    func moveWrapped() {
        let ring = LineRing(maxLength: 4, cols: 4)
        for i in 0..<4 { ring.pushBlank(); ring[i][0] = ascii(Character(UnicodeScalar(UInt8(0x61 + i)))) }
        ring.pushBlank()                              // start now at slot 1
        ring[3][0] = ascii("e")
        #expect((0..<4).map { ring[$0].string() } == ["b", "c", "d", "e"])
        ring.move(from: 0, to: 3)
        #expect((0..<4).map { ring[$0].string() } == ["c", "d", "e", "b"])
    }

    @Test("setMaxLength drops the oldest when shrinking and keeps rows when growing")
    func setMaxLength() {
        let ring = LineRing(maxLength: 6, cols: 4)
        for i in 0..<6 { ring.pushBlank(); ring[i][0] = ascii(Character(UnicodeScalar(UInt8(0x61 + i)))) }

        ring.setMaxLength(3)
        #expect(ring.maxLength == 3)
        #expect(ring.count == 3)
        #expect(ring.trimmed == 3)
        #expect((0..<3).map { ring[$0].string() } == ["d", "e", "f"])

        ring.setMaxLength(8)
        #expect(ring.maxLength == 8)
        #expect(ring.count == 3)
        #expect((0..<3).map { ring[$0].string() } == ["d", "e", "f"])
        ring.pushBlank()
        #expect(ring.count == 4)
        #expect(ring.trimmed == 3)
    }

    @Test("trimStart drops from the top and counts as trimmed")
    func trimStart() {
        let ring = LineRing(maxLength: 8, cols: 4)
        for i in 0..<5 { ring.pushBlank(); ring[i][0] = ascii(Character(UnicodeScalar(UInt8(0x61 + i)))) }
        ring.trimStart(2)
        #expect(ring.count == 3)
        #expect(ring.trimmed == 2)
        #expect((0..<3).map { ring[$0].string() } == ["c", "d", "e"])
        ring.trimStart(99)
        #expect(ring.count == 0)
        #expect(ring.trimmed == 5)
        #expect(ring.allocatedRowCount == 0)
    }

    @Test("resizeRows resizes every materialised row")
    func resizeRows() {
        let ring = LineRing(maxLength: 4, cols: 6)
        for i in 0..<3 { ring.pushBlank(); ring[i][0] = ascii("x") }
        ring.resizeRows(cols: 3, fill: .empty)
        #expect(ring.cols == 3)
        for i in 0..<3 { #expect(ring[i].cols == 3) }
        ring.pushBlank()
        #expect(ring[3].cols == 3)
    }
}

// MARK: - Buffer

@Suite("Buffer")
struct BufferTests {
    private func line(_ b: Buffer, _ screenRow: Int) -> String { b.row(screenRow).string() }
    private func write(_ b: Buffer, _ screenRow: Int, _ text: String) {
        let r = b.row(screenRow)
        for (i, ch) in text.unicodeScalars.enumerated() where i < b.cols {
            r[i] = Cell(code: ch.value, width: 1, fg: 0, bg: 0)
        }
    }

    @Test("a fresh buffer has a full screen of lines")
    func initialState() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 100)
        #expect(b.lines.count == 5)
        #expect(b.lines.maxLength == 105)
        #expect(b.hasScrollback)
        #expect(b.ybase == 0 && b.ydisp == 0)
        #expect(b.scrollTop == 0 && b.scrollBottom == 4)
        #expect(b.isFollowing)
        #expect(b.lines.allocatedRowCount == 0)

        let alt = Buffer(cols: 10, rows: 5, scrollback: 0)
        #expect(!alt.hasScrollback)
        #expect(alt.lines.maxLength == 5)
    }

    @Test("tab stops every 8 columns")
    func tabs() {
        let b = Buffer(cols: 20, rows: 3, scrollback: 0)
        #expect(b.tabStops.count == 20)
        #expect(b.tabStops[0] && b.tabStops[8] && b.tabStops[16])
        #expect(!b.tabStops[1] && !b.tabStops[7] && !b.tabStops[9])
    }

    @Test("full-screen scrollUp with scrollback grows ybase")
    func scrollUpWithScrollback() {
        let b = Buffer(cols: 10, rows: 3, scrollback: 10)
        for i in 0..<3 { write(b, i, "line\(i)") }

        b.scrollUp(1)
        #expect(b.lines.count == 4)
        #expect(b.ybase == 1)
        #expect(b.ydisp == 1)
        #expect(b.lines.trimmed == 0)
        #expect(line(b, 0) == "line1")
        #expect(line(b, 1) == "line2")
        #expect(line(b, 2) == "")
        #expect(b.lines[0].string() == "line0")     // in the scrollback now
    }

    @Test("once the ring is full ybase stops and lines are trimmed")
    func scrollUpFull() {
        let b = Buffer(cols: 10, rows: 3, scrollback: 2)   // maxLength 5
        for i in 0..<3 { write(b, i, "\(i)") }
        b.scrollUp(1); write(b, 2, "3")
        b.scrollUp(1); write(b, 2, "4")
        #expect(b.lines.count == 5)
        #expect(b.ybase == 2)
        #expect(b.lines.trimmed == 0)

        b.scrollUp(1)                                      // now it has to trim
        #expect(b.lines.count == 5)
        #expect(b.ybase == 2)
        #expect(b.ydisp == 2)
        #expect(b.lines.trimmed == 1)
        #expect(b.lines[0].string() == "1")
        #expect(line(b, 0) == "3")
        #expect(line(b, 2) == "")
    }

    @Test("ydisp only follows ybase when the user is at the bottom")
    func scrollUpUserScrolled() {
        let b = Buffer(cols: 10, rows: 3, scrollback: 10)
        b.scrollUp(3)
        #expect(b.ybase == 3 && b.ydisp == 3)
        b.ydisp = 1                                        // user scrolled back
        b.scrollUp(1)
        #expect(b.ybase == 4)
        #expect(b.ydisp == 1)                              // text stayed put
    }

    @Test("scrollUp marks the new bottom row as wrapped when asked")
    func scrollUpWrapped() {
        let b = Buffer(cols: 10, rows: 3, scrollback: 10)
        b.scrollUp(1, fill: .empty, wrapped: true)
        #expect(b.row(2).wrapped)
        b.scrollUp(1)
        #expect(!b.row(2).wrapped)
    }

    @Test("scrollUp with a region moves rows and never touches the scrollback")
    func scrollUpRegion() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 10)
        for i in 0..<5 { write(b, i, "\(i)") }
        b.scrollTop = 1
        b.scrollBottom = 3

        b.scrollUp(1)
        #expect(b.lines.count == 5)
        #expect(b.ybase == 0)
        #expect((0..<5).map { line(b, $0) } == ["0", "2", "3", "", "4"])
    }

    @Test("alt-style buffer scrolls in place")
    func scrollUpNoScrollback() {
        let b = Buffer(cols: 10, rows: 3, scrollback: 0)
        for i in 0..<3 { write(b, i, "\(i)") }
        b.scrollUp(1)
        #expect(b.lines.count == 3)
        #expect(b.ybase == 0)
        #expect((0..<3).map { line(b, $0) } == ["1", "2", ""])
    }

    @Test("scrollDown moves content down inside the region")
    func scrollDown() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 10)
        for i in 0..<5 { write(b, i, "\(i)") }
        b.scrollDown(1)
        #expect(b.lines.count == 5)
        #expect((0..<5).map { line(b, $0) } == ["", "0", "1", "2", "3"])

        b.scrollTop = 2; b.scrollBottom = 4
        b.scrollDown(1)
        #expect((0..<5).map { line(b, $0) } == ["", "0", "", "1", "2"])
    }

    @Test("insertLines pushes rows out of the bottom of the region")
    func insertLines() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 10)
        for i in 0..<5 { write(b, i, "\(i)") }
        b.insertLines(at: 1, count: 2)
        #expect((0..<5).map { line(b, $0) } == ["0", "", "", "1", "2"])
        #expect(b.lines.count == 5)
    }

    @Test("insertLines respects the margins and is a no-op outside them")
    func insertLinesRegion() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 10)
        for i in 0..<5 { write(b, i, "\(i)") }
        b.scrollTop = 1; b.scrollBottom = 3

        b.insertLines(at: 1, count: 1)
        #expect((0..<5).map { line(b, $0) } == ["0", "", "1", "2", "4"])

        b.insertLines(at: 4, count: 1)          // below scrollBottom
        #expect((0..<5).map { line(b, $0) } == ["0", "", "1", "2", "4"])
        b.insertLines(at: 0, count: 1)          // above scrollTop
        #expect((0..<5).map { line(b, $0) } == ["0", "", "1", "2", "4"])
    }

    @Test("insertLines at the bottom edge clears exactly one row")
    func insertLinesAtBottom() {
        let b = Buffer(cols: 10, rows: 4, scrollback: 10)
        for i in 0..<4 { write(b, i, "\(i)") }
        b.insertLines(at: 3, count: 3)          // clamped to the region
        #expect((0..<4).map { line(b, $0) } == ["0", "1", "2", ""])
    }

    @Test("deleteLines pulls rows up and blanks the bottom of the region")
    func deleteLines() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 10)
        for i in 0..<5 { write(b, i, "\(i)") }
        b.deleteLines(at: 1, count: 2)
        #expect((0..<5).map { line(b, $0) } == ["0", "3", "4", "", ""])
        #expect(b.lines.count == 5)
        #expect(b.ybase == 0)
    }

    @Test("deleteLines respects the margins")
    func deleteLinesRegion() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 10)
        for i in 0..<5 { write(b, i, "\(i)") }
        b.scrollTop = 1; b.scrollBottom = 3
        b.deleteLines(at: 1, count: 1)
        #expect((0..<5).map { line(b, $0) } == ["0", "2", "3", "", "4"])
        b.deleteLines(at: 0, count: 1)
        #expect((0..<5).map { line(b, $0) } == ["0", "2", "3", "", "4"])
    }

    // The row just below the bottom margin follows a row that IL/DL replaced,
    // so a `wrapped` flag left there joins two unrelated rows into one logical
    // line — and a logical line is what search, copy and reflow read.
    @Test("insertLines clears wrapped on the row below the bottom margin")
    func insertLinesClearsWrapBelowMargin() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 10)
        for i in 0..<5 { write(b, i, "\(i)") }
        for i in 1..<5 { b.row(i).wrapped = true }        // one long logical line
        b.scrollTop = 1; b.scrollBottom = 3

        b.insertLines(at: 1, count: 1)
        #expect((0..<5).map { line(b, $0) } == ["0", "", "1", "2", "4"])
        #expect(!b.row(1).wrapped)                        // the blank starts fresh
        #expect(!b.row(2).wrapped)                        // and so does the block
        #expect(b.row(3).wrapped)                         // still inside the block
        #expect(!b.row(4).wrapped)                        // "3" is gone: "4" stands alone
        #expect(b.logicalLine(containing: 4) == 4...4)
    }

    @Test("deleteLines clears wrapped on the row below the bottom margin")
    func deleteLinesClearsWrapBelowMargin() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 10)
        for i in 0..<5 { write(b, i, "\(i)") }
        for i in 1..<5 { b.row(i).wrapped = true }
        b.scrollTop = 1; b.scrollBottom = 3

        b.deleteLines(at: 1, count: 1)
        #expect((0..<5).map { line(b, $0) } == ["0", "2", "3", "", "4"])
        #expect(!b.row(1).wrapped)                        // "2" lost the row above it
        #expect(!b.row(3).wrapped)                        // the blank at the margin
        #expect(!b.row(4).wrapped)                        // "4" follows a blank now
        #expect(b.logicalLine(containing: 4) == 4...4)
    }

    // The audit's repro, through the real parser: a 4x4 screen of one wrapped
    // logical line, then DECSTBM + IL. "DDDD" below the margin must not keep
    // continuing the row above it.
    @Test("IL/DL below a margin do not leave a wrapped row for search to join")
    func insertDeleteWrapBelowMarginEndToEnd() {
        for op in ["L", "M"] {
            let t = Terminal(cols: 4, rows: 4, scrollback: 10)
            t.feed("AAAABBBBCCCCDDDD")
            #expect((0..<4).map { t.buffer.row($0).string() } == ["AAAA", "BBBB", "CCCC", "DDDD"])
            #expect(t.buffer.logicalLine(containing: 3) == 0...3)

            t.feed("\u{1B}[1;3r\u{1B}[2;1H\u{1B}[1\(op)")
            let last = t.buffer.lineNumber(ofScreenRow: 3)
            #expect(!t.buffer.row(3).wrapped)
            #expect(t.buffer.logicalLine(containing: last) == last...last)
        }
    }

    @Test("insert then delete at the same row is the identity for the rest")
    func insertDeleteRoundTrip() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 10)
        for i in 0..<5 { write(b, i, "\(i)") }
        b.insertLines(at: 2, count: 1)
        b.deleteLines(at: 2, count: 1)
        #expect((0..<5).map { line(b, $0) } == ["0", "1", "2", "3", ""])
    }

    @Test("clearScrollback drops the history and rebases")
    func clearScrollback() {
        let b = Buffer(cols: 10, rows: 3, scrollback: 10)
        for i in 0..<3 { write(b, i, "\(i)") }
        b.scrollUp(2)
        #expect(b.ybase == 2)
        b.clearScrollback()
        #expect(b.ybase == 0)
        #expect(b.ydisp == 0)
        #expect(b.lines.count == 3)
        #expect(line(b, 0) == "2")
    }

    @Test("resize wider/narrower resizes every row")
    func resizeCols() {
        let b = Buffer(cols: 10, rows: 3, scrollback: 10)
        write(b, 0, "abcdefghij")
        b.resize(cols: 5, rows: 3)
        #expect(b.cols == 5)
        #expect(b.lines.cols == 5)
        #expect(b.row(0).cols == 5)
        #expect(line(b, 0) == "abcde")
        #expect(b.tabStops.count == 5)

        b.resize(cols: 12, rows: 3)
        #expect(b.cols == 12)
        #expect(b.row(0).cols == 12)
        #expect(line(b, 0) == "abcde")          // no reflow in phase 1
        #expect(b.tabStops.count == 12)
        #expect(b.tabStops[8])
    }

    @Test("growing rows pulls lines back out of the scrollback")
    func resizeGrowFromScrollback() {
        let b = Buffer(cols: 10, rows: 3, scrollback: 10)
        for i in 0..<3 { write(b, i, "\(i)") }
        b.scrollUp(1); write(b, 2, "3")
        b.scrollUp(1); write(b, 2, "4")
        #expect(b.ybase == 2)
        b.y = 2

        b.resize(cols: 10, rows: 5)
        #expect(b.rows == 5)
        #expect(b.ybase == 0)
        #expect(b.ydisp == 0)
        #expect(b.y == 4)                        // cursor stayed on its line
        #expect((0..<5).map { line(b, $0) } == ["0", "1", "2", "3", "4"])
        #expect(b.lines.count == 5)
        #expect(b.lines.maxLength == 15)
    }

    @Test("growing rows with no history adds blank lines at the bottom")
    func resizeGrowBlank() {
        let b = Buffer(cols: 10, rows: 3, scrollback: 10)
        for i in 0..<3 { write(b, i, "\(i)") }
        b.y = 0
        b.resize(cols: 10, rows: 5)
        #expect(b.lines.count == 5)
        #expect(b.ybase == 0)
        #expect(b.y == 0)
        #expect((0..<5).map { line(b, $0) } == ["0", "1", "2", "", ""])
    }

    @Test("shrinking rows drops blank lines below the cursor first")
    func resizeShrinkBlank() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 10)
        write(b, 0, "0"); write(b, 1, "1")
        b.y = 1
        b.resize(cols: 10, rows: 3)
        #expect(b.rows == 3)
        #expect(b.lines.count == 3)
        #expect(b.ybase == 0)
        #expect(b.y == 1)
        #expect((0..<3).map { line(b, $0) } == ["0", "1", ""])
    }

    @Test("shrinking rows pushes the cursor's lines into the scrollback")
    func resizeShrinkToScrollback() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 10)
        for i in 0..<5 { write(b, i, "\(i)") }
        b.y = 4
        b.resize(cols: 10, rows: 3)
        #expect(b.rows == 3)
        #expect(b.ybase == 2)
        #expect(b.lines.count == 5)
        #expect(b.y == 2)
        #expect((0..<3).map { line(b, $0) } == ["2", "3", "4"])
        #expect(b.lines[0].string() == "0")
        #expect(b.lines.maxLength == 13)
    }

    @Test("an alt-style buffer just truncates when it shrinks")
    func resizeShrinkNoScrollback() {
        let b = Buffer(cols: 10, rows: 5, scrollback: 0)
        for i in 0..<5 { write(b, i, "\(i)") }
        b.y = 4
        b.resize(cols: 10, rows: 3)
        #expect(b.lines.count == 3)
        #expect(b.lines.maxLength == 3)
        #expect(b.ybase == 0)
        #expect(b.y == 2)
        #expect((0..<3).map { line(b, $0) } == ["0", "1", "2"])
    }

    @Test("resize resets the margins and clamps the cursor")
    func resizeResetsMargins() {
        let b = Buffer(cols: 10, rows: 6, scrollback: 10)
        b.scrollTop = 2; b.scrollBottom = 4
        b.x = 9; b.y = 5
        b.resize(cols: 4, rows: 4)
        #expect(b.scrollTop == 0)
        #expect(b.scrollBottom == 3)
        #expect(b.x == 3)
        #expect(b.y <= 3)
    }

    @Test("setScrollback shrinks the history in place")
    func setScrollback() {
        let b = Buffer(cols: 10, rows: 3, scrollback: 10)
        for i in 0..<3 { write(b, i, "\(i)") }
        for i in 3..<8 { b.scrollUp(1); write(b, 2, "\(i)") }
        #expect(b.lines.count == 8)
        #expect(b.ybase == 5)

        b.setScrollback(2)
        #expect(b.lines.maxLength == 5)
        #expect(b.lines.count == 5)
        #expect(b.ybase == 2)
        #expect((0..<3).map { line(b, $0) } == ["5", "6", "7"])
    }

    @Test("Pen builds print cells and BCE erase cells")
    func pen() {
        var p = Pen()
        p.bg = Cell.colorWord(source: .palette256, value: 34)
        p.fg = Cell.colorWord(source: .rgb, value: 0x112233, flags: Cell.FgFlag.bold)

        let c = p.cell(code: 0x41, width: 1)
        #expect(c.code == 0x41)
        #expect(c.width == 1)
        #expect(c.bgSource == .palette256)
        #expect(c.bgValue == 34)
        #expect(c.fgFlags & Cell.FgFlag.bold != 0)
        #expect(!c.hasExtended)

        let e = p.eraseCell
        #expect(e.code == 0)
        #expect(e.width == 1)
        #expect(e.bgSource == .palette256)
        #expect(e.bgValue == 34)
        #expect(e.fg == 0)

        p.extended.underlineStyle = .double
        #expect(p.hasExtended)
        // The pen carries extended attributes, but a cell it builds must NOT
        // claim the flag: that flag promises a side-table entry at this exact
        // column, and only `Row.setExtended` — the one call that writes the
        // entry — may set it. This test used to assert the opposite, which is
        // what let DECALN fill a screen with cells claiming entries nobody
        // ever wrote.
        #expect(!p.cell(code: 0x42, width: 1).hasExtended)
    }

    @Test("DECALN fills the screen without claiming extended entries")
    func decalnDoesNotForgeExtendedFlags() {
        let t = Terminal(cols: 8, rows: 3, scrollback: 10)
        t.feed(Array("\u{1B}]8;;https://example.com\u{1B}\\".utf8))  // pen now carries a hyperlink
        t.feed(Array("\u{1B}#8".utf8))                                  // DECALN
        for y in 0..<3 {
            let row = t.buffer.row(y)
            for x in 0..<8 {
                #expect(row[x].code == 0x45)
                #expect(row[x].hasExtended == (row.extended(at: x) != nil))
            }
        }
    }

    @Test("erasing with a coloured pen fills the row with that background")
    func bceFill() {
        let b = Buffer(cols: 6, rows: 3, scrollback: 5)
        var p = Pen()
        p.bg = Cell.colorWord(source: .palette16, value: 4)
        b.scrollUp(1, fill: p.eraseCell)
        #expect(b.row(2)[0].bgValue == 4)
        #expect(b.row(2)[5].bgSource == .palette16)
    }

    @Test("SavedCursor round-trips")
    func savedCursor() {
        var p = Pen()
        p.fg = 7
        let s = SavedCursor(x: 3, y: 4, pen: p, charset: 1, originMode: true, pendingWrap: true)
        #expect(s == SavedCursor(x: 3, y: 4, pen: p, charset: 1, originMode: true, pendingWrap: true))
        #expect(s != SavedCursor())
    }
}
