// SheepVT — reflow tests.
//
// The first two suites are the xterm.js `BufferReflow.test.ts` cases as carried
// in SwiftTerm's `ReflowPortedTests.swift` (MIT), re-expressed against our
// Buffer/Row/Cell — same names, same expectations. The third suite drives a
// real `Terminal` through the parser so the grid under test is one the emulator
// actually produced.

import Testing
@testable import SheepVT

// MARK: - helpers

private let asciiA: UInt32 = 97
private let ascii0: UInt32 = 48
private let han: UInt32 = 0x6C49          // 漢
private let yu: UInt32 = 0x8BED           // 语
private let grin: UInt32 = 0x1F601        // 😁

private let hanS = "\u{6C49}"
private let yuS = "\u{8BED}"
private let grinS = "\u{1F601}"

private func makeBuffer(cols: Int, rows: Int, scrollback: Int) -> Buffer {
    Buffer(cols: cols, rows: rows, scrollback: scrollback)
}

/// `translateBufferLineToString` — a nil (never touched) slot is a blank row, so
/// the subscript materialises it and the text is the row's own.
private func lineText(_ b: Buffer, _ index: Int, trimRight: Bool = true) -> String {
    b.lines[index].string(trimRight: trimRight)
}

private func setAscii(_ r: Row, start: UInt32, count: Int) {
    for i in 0..<Swift.min(count, r.cols) {
        r[i] = Cell(code: start + UInt32(i), width: 1, fg: 0, bg: 0)
    }
}

private func setChar(_ r: Row, _ index: Int, _ code: UInt32, width: UInt32 = 1) {
    r[index] = Cell(code: code, width: width, fg: 0, bg: 0)
}

private func setWide(_ r: Row, _ index: Int, _ code: UInt32) {
    setChar(r, index, code, width: 2)
    if index + 1 < r.cols { r[index + 1] = Cell(code: 0, width: 0, fg: 0, bg: 0) }
}

private func fillWideLine(_ r: Row, _ codes: [UInt32]) {
    var col = 0
    for code in codes {
        if col >= r.cols { break }
        setWide(r, col, code)
        col += 2
    }
}

/// Splice `count` blank rows in front of everything (xterm's test helper).
private func prependBlankLines(_ b: Buffer, count: Int) {
    var rows = [Row?](repeating: nil, count: count)
    for i in 0..<b.lines.count { rows.append(b.lines.allocatedRow(at: i)) }
    b.lines.replaceAll(rows)
}

private func assertWrappedLines(_ b: Buffer, expected: Set<Int>, sourceLocation: SourceLocation = #_sourceLocation) {
    for i in 0..<b.lines.count {
        #expect(b.lines[i].wrapped == expected.contains(i),
                "row \(i) wrapped", sourceLocation: sourceLocation)
    }
}

private func makeReflowLargerBuffer() -> Buffer {
    let b = makeBuffer(cols: 2, rows: 10, scrollback: 10)
    setChar(b.lines[0], 0, asciiA)
    setChar(b.lines[0], 1, asciiA + 1)
    setChar(b.lines[1], 0, asciiA + 2)
    setChar(b.lines[1], 1, asciiA + 3)
    b.lines[1].wrapped = true
    setChar(b.lines[2], 0, asciiA + 4)
    setChar(b.lines[2], 1, asciiA + 5)
    setChar(b.lines[3], 0, asciiA + 6)
    setChar(b.lines[3], 1, asciiA + 7)
    b.lines[3].wrapped = true
    setChar(b.lines[4], 0, asciiA + 8)
    setChar(b.lines[4], 1, asciiA + 9)
    setChar(b.lines[5], 0, asciiA + 10)
    setChar(b.lines[5], 1, asciiA + 11)
    b.lines[5].wrapped = true
    return b
}

private func makeReflowSmallerBuffer() -> Buffer {
    let b = makeBuffer(cols: 4, rows: 10, scrollback: 20)
    setAscii(b.lines[0], start: asciiA, count: 4)
    setAscii(b.lines[1], start: asciiA + 4, count: 4)
    setAscii(b.lines[2], start: asciiA + 8, count: 4)
    return b
}

private func blanks(_ n: Int) -> String { String(repeating: " ", count: n) }

// MARK: - ported: whole-buffer reflow

@Suite("Reflow — ported from xterm.js BufferReflow.test.ts")
struct ReflowPortedTests {

    @Test func testReflowDiscardWrappedLinesOutOfScrollback() {
        let b = makeBuffer(cols: 10, rows: 5, scrollback: 1)
        setAscii(b.lines[3], start: asciiA, count: 10)
        b.y = 4

        b.resize(cols: 2, rows: 5)

        #expect(b.y == 4)
        #expect(b.ybase == 1)
        #expect(b.lines.count == 6)
        #expect(lineText(b, 0, trimRight: false) == "ab")
        #expect(lineText(b, 1, trimRight: false) == "cd")
        #expect(lineText(b, 2, trimRight: false) == "ef")
        #expect(lineText(b, 3, trimRight: false) == "gh")
        #expect(lineText(b, 4, trimRight: false) == "ij")
        #expect(lineText(b, 5, trimRight: false) == "  ")

        b.resize(cols: 1, rows: 5)

        #expect(b.y == 4)
        #expect(b.ybase == 1)
        #expect(b.lines.count == 6)
        #expect(lineText(b, 0, trimRight: false) == "f")
        #expect(lineText(b, 1, trimRight: false) == "g")
        #expect(lineText(b, 2, trimRight: false) == "h")
        #expect(lineText(b, 3, trimRight: false) == "i")
        #expect(lineText(b, 4, trimRight: false) == "j")
        #expect(lineText(b, 5, trimRight: false) == " ")

        b.resize(cols: 10, rows: 5)

        #expect(b.y == 1)
        #expect(b.ybase == 0)
        #expect(b.lines.count == 5)
        #expect(lineText(b, 0, trimRight: false) == "fghij" + blanks(5))
        for i in 1..<5 { #expect(lineText(b, i, trimRight: false) == blanks(10)) }
    }

    @Test func testReflowLargerRemovesCorrectRows() {
        let b = makeBuffer(cols: 10, rows: 10, scrollback: 10)
        b.y = 2
        setAscii(b.lines[0], start: asciiA, count: 10)
        setAscii(b.lines[1], start: ascii0, count: 10)

        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: false) == "abcdefghij")
        #expect(lineText(b, 1, trimRight: false) == "0123456789")
        for i in 2..<10 { #expect(lineText(b, i, trimRight: false) == blanks(10)) }

        b.resize(cols: 2, rows: 10)

        #expect(b.ybase == 1)
        #expect(b.lines.count == 11)
        #expect(lineText(b, 0, trimRight: false) == "ab")
        #expect(lineText(b, 1, trimRight: false) == "cd")
        #expect(lineText(b, 2, trimRight: false) == "ef")
        #expect(lineText(b, 3, trimRight: false) == "gh")
        #expect(lineText(b, 4, trimRight: false) == "ij")
        #expect(lineText(b, 5, trimRight: false) == "01")
        #expect(lineText(b, 6, trimRight: false) == "23")
        #expect(lineText(b, 7, trimRight: false) == "45")
        #expect(lineText(b, 8, trimRight: false) == "67")
        #expect(lineText(b, 9, trimRight: false) == "89")
        #expect(lineText(b, 10, trimRight: false) == "  ")

        b.resize(cols: 10, rows: 10)

        #expect(b.ybase == 0)
        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: false) == "abcdefghij")
        #expect(lineText(b, 1, trimRight: false) == "0123456789")
        for i in 2..<10 { #expect(lineText(b, i, trimRight: false) == blanks(10)) }
    }

    @Test func testReflowLargerViewportNotFilledMovesCursorUp() {
        let b = makeReflowLargerBuffer()
        b.y = 6

        b.resize(cols: 4, rows: 10)

        #expect(b.y == 3)
        #expect(b.ydisp == 0)
        #expect(b.ybase == 0)
        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: false) == "abcd")
        #expect(lineText(b, 1, trimRight: false) == "efgh")
        #expect(lineText(b, 2, trimRight: false) == "ijkl")
        for i in 3..<10 { #expect(lineText(b, i, trimRight: false) == blanks(4)) }
        assertWrappedLines(b, expected: [])
    }

    @Test func testReflowLargerViewportFilledMovesCursorUp() {
        let b = makeReflowLargerBuffer()
        b.y = 9

        b.resize(cols: 4, rows: 10)

        #expect(b.y == 6)
        #expect(b.ydisp == 0)
        #expect(b.ybase == 0)
        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: false) == "abcd")
        #expect(lineText(b, 1, trimRight: false) == "efgh")
        #expect(lineText(b, 2, trimRight: false) == "ijkl")
        for i in 3..<10 { #expect(lineText(b, i, trimRight: false) == blanks(4)) }
        assertWrappedLines(b, expected: [])
    }

    @Test func testReflowLargerAdjustsViewportWhenYdispMatchesYbase() {
        let b = makeReflowLargerBuffer()
        b.y = 9
        prependBlankLines(b, count: 10)
        b.ybase = 10
        b.ydisp = 10

        b.resize(cols: 4, rows: 10)

        #expect(b.y == 9)
        #expect(b.ydisp == 7)
        #expect(b.ybase == 7)
        #expect(b.lines.count == 17)
        for i in 0..<10 { #expect(lineText(b, i, trimRight: false) == blanks(4)) }
        #expect(lineText(b, 10, trimRight: false) == "abcd")
        #expect(lineText(b, 11, trimRight: false) == "efgh")
        #expect(lineText(b, 12, trimRight: false) == "ijkl")
        for i in 13..<17 { #expect(lineText(b, i, trimRight: false) == blanks(4)) }
        assertWrappedLines(b, expected: [])
    }

    /// The widening twin, and the same note applies: `ydisp = 5` sits in the
    /// blank prepended rows, so content anchoring and xterm's "leave it alone"
    /// give the same index here.
    @Test func testReflowLargerKeepsYdispWhenYdispDiffersFromYbase() {
        let b = makeReflowLargerBuffer()
        b.y = 9
        prependBlankLines(b, count: 10)
        b.ybase = 10
        b.ydisp = 5

        b.resize(cols: 4, rows: 10)

        #expect(b.y == 9)
        #expect(b.ydisp == 5)
        #expect(b.ybase == 7)
        #expect(b.lines.count == 17)
        for i in 0..<10 { #expect(lineText(b, i, trimRight: false) == blanks(4)) }
        #expect(lineText(b, 10, trimRight: false) == "abcd")
        #expect(lineText(b, 11, trimRight: false) == "efgh")
        #expect(lineText(b, 12, trimRight: false) == "ijkl")
        for i in 13..<17 { #expect(lineText(b, i, trimRight: false) == blanks(4)) }
        assertWrappedLines(b, expected: [])
    }

    @Test func testReflowSmallerViewportNotFilledMovesCursorDown() {
        let b = makeReflowSmallerBuffer()
        b.y = 3

        b.resize(cols: 2, rows: 10)

        #expect(b.y == 6)
        #expect(b.ydisp == 0)
        #expect(b.ybase == 0)
        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: false) == "ab")
        #expect(lineText(b, 1, trimRight: false) == "cd")
        #expect(lineText(b, 2, trimRight: false) == "ef")
        #expect(lineText(b, 3, trimRight: false) == "gh")
        #expect(lineText(b, 4, trimRight: false) == "ij")
        #expect(lineText(b, 5, trimRight: false) == "kl")
        for i in 6..<10 { #expect(lineText(b, i, trimRight: false) == "  ") }
        assertWrappedLines(b, expected: [1, 3, 5])
    }

    @Test func testReflowSmallerViewportFilledTrimsTop() {
        let b = makeReflowSmallerBuffer()
        b.y = 9

        b.resize(cols: 2, rows: 10)

        #expect(b.y == 9)
        #expect(b.ydisp == 3)
        #expect(b.ybase == 3)
        #expect(b.lines.count == 13)
        #expect(lineText(b, 0, trimRight: false) == "ab")
        #expect(lineText(b, 1, trimRight: false) == "cd")
        #expect(lineText(b, 2, trimRight: false) == "ef")
        #expect(lineText(b, 3, trimRight: false) == "gh")
        #expect(lineText(b, 4, trimRight: false) == "ij")
        #expect(lineText(b, 5, trimRight: false) == "kl")
        for i in 6..<13 { #expect(lineText(b, i, trimRight: false) == "  ") }
        assertWrappedLines(b, expected: [1, 3, 5])
    }

    @Test func testReflowSmallerAdjustsViewportWhenYdispMatchesYbase() {
        let b = makeReflowSmallerBuffer()
        b.y = 9
        prependBlankLines(b, count: 10)
        b.ybase = 10
        b.ydisp = 10

        b.resize(cols: 2, rows: 10)

        #expect(b.ydisp == 13)
        #expect(b.ybase == 13)
        #expect(b.lines.count == 23)
        for i in 0..<10 { #expect(lineText(b, i, trimRight: false) == "  ") }
        #expect(lineText(b, 10, trimRight: false) == "ab")
        #expect(lineText(b, 11, trimRight: false) == "cd")
        #expect(lineText(b, 12, trimRight: false) == "ef")
        #expect(lineText(b, 13, trimRight: false) == "gh")
        #expect(lineText(b, 14, trimRight: false) == "ij")
        #expect(lineText(b, 15, trimRight: false) == "kl")
        for i in 16..<23 { #expect(lineText(b, i, trimRight: false) == "  ") }
        assertWrappedLines(b, expected: [11, 13, 15])
    }

    /// xterm.js asserts `ydisp` is left ALONE when it differs from `ybase`, and
    /// that is still the answer here — but no longer for xterm's reason. We
    /// anchor the viewport on the logical line it was showing (`Buffer`'s
    /// `restoreViewportAnchor`), and `ydisp = 5` here is inside the ten blank
    /// prepended rows, which no rewrap touches: the line the reader was on is
    /// still at index 5, so anchoring puts them back exactly where xterm's rule
    /// happened to leave them. The value below therefore agrees with xterm.js by
    /// coincidence of the fixture, not by sharing its rule — see
    /// `repeatedResizesKeepTheReaderOnTheSameLine` for a case where the two
    /// answers differ and ours is the one a reader wants.
    @Test func testReflowSmallerKeepsYdispWhenYdispDiffersFromYbase() {
        let b = makeReflowSmallerBuffer()
        b.y = 9
        prependBlankLines(b, count: 10)
        b.ybase = 10
        b.ydisp = 5

        b.resize(cols: 2, rows: 10)

        #expect(b.ydisp == 5)
        #expect(b.ybase == 13)
        #expect(b.lines.count == 23)
        for i in 0..<10 { #expect(lineText(b, i, trimRight: false) == "  ") }
        #expect(lineText(b, 10, trimRight: false) == "ab")
        #expect(lineText(b, 11, trimRight: false) == "cd")
        #expect(lineText(b, 12, trimRight: false) == "ef")
        #expect(lineText(b, 13, trimRight: false) == "gh")
        #expect(lineText(b, 14, trimRight: false) == "ij")
        #expect(lineText(b, 15, trimRight: false) == "kl")
        for i in 16..<23 { #expect(lineText(b, i, trimRight: false) == "  ") }
        assertWrappedLines(b, expected: [11, 13, 15])
    }

    @Test func testReflowSmallerTrimsWhenBufferIsFull() {
        let b = makeReflowSmallerBuffer()
        b.setScrollback(10)
        prependBlankLines(b, count: 10)
        b.ybase = 10
        b.ydisp = 10
        b.y = 13

        b.resize(cols: 2, rows: 10)

        #expect(b.ydisp == 10)
        #expect(b.ybase == 10)
        #expect(b.lines.count == 20)
        for i in 0..<7 { #expect(lineText(b, i, trimRight: false) == "  ") }
        #expect(lineText(b, 7, trimRight: false) == "ab")
        #expect(lineText(b, 8, trimRight: false) == "cd")
        #expect(lineText(b, 9, trimRight: false) == "ef")
        #expect(lineText(b, 10, trimRight: false) == "gh")
        #expect(lineText(b, 11, trimRight: false) == "ij")
        #expect(lineText(b, 12, trimRight: false) == "kl")
        for i in 13..<20 { #expect(lineText(b, i, trimRight: false) == "  ") }
        assertWrappedLines(b, expected: [8, 10, 12])
    }

    @Test func testReflowShouldNotWrapEmptyLines() {
        let b = makeBuffer(cols: 10, rows: 10, scrollback: 10)
        #expect(b.lines.count == 10)

        b.resize(cols: 5, rows: 10)

        #expect(b.lines.count == 10)
    }

    @Test func testReflowShrinksRowLength() {
        let b = makeBuffer(cols: 10, rows: 10, scrollback: 10)

        b.resize(cols: 5, rows: 10)

        #expect(b.lines.count == 10)
        for i in 0..<10 { #expect(b.lines[i].cols == 5) }
    }

    @Test func testReflowWrapAndUnwrapLines() {
        let b = makeBuffer(cols: 5, rows: 10, scrollback: 10)
        setAscii(b.lines[0], start: asciiA, count: 5)
        b.y = 1

        #expect(lineText(b, 0, trimRight: false) == "abcde")

        b.resize(cols: 1, rows: 10)

        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: false) == "a")
        #expect(lineText(b, 1, trimRight: false) == "b")
        #expect(lineText(b, 2, trimRight: false) == "c")
        #expect(lineText(b, 3, trimRight: false) == "d")
        #expect(lineText(b, 4, trimRight: false) == "e")
        for i in 5..<10 { #expect(lineText(b, i, trimRight: false) == " ") }

        b.resize(cols: 5, rows: 10)

        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: false) == "abcde")
        for i in 1..<10 { #expect(lineText(b, i, trimRight: false) == blanks(5)) }
    }

    @Test func testReflowTransfersCombinedCharData() {
        let b = makeBuffer(cols: 4, rows: 3, scrollback: 10)
        b.y = 2
        let line = b.lines[0]
        setChar(line, 0, asciiA)
        setChar(line, 1, asciiA + 1)
        setChar(line, 2, asciiA + 2)
        setChar(line, 3, grin)
        line.setCombined(grinS, at: 3)

        #expect(lineText(b, 0, trimRight: false) == "abc" + grinS)

        b.resize(cols: 2, rows: 3)

        #expect(lineText(b, 0, trimRight: false) == "ab")
        #expect(lineText(b, 1, trimRight: false) == "c" + grinS)
    }

    @Test func testReflowWrappedLinesEndingInZeroSpaceLarger() {
        let b = makeBuffer(cols: 4, rows: 10, scrollback: 10)
        b.y = 2
        setChar(b.lines[0], 0, asciiA)
        setChar(b.lines[0], 1, asciiA + 1)
        setChar(b.lines[1], 0, asciiA + 2)
        setChar(b.lines[1], 1, asciiA + 3)
        b.lines[1].wrapped = true

        b.resize(cols: 5, rows: 10)

        #expect(b.ybase == 0)
        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: true) == "ab  c")
        #expect(lineText(b, 1, trimRight: false) == "d    ")

        b.resize(cols: 6, rows: 10)

        #expect(b.ybase == 0)
        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: true) == "ab  cd")
        #expect(lineText(b, 1, trimRight: false) == blanks(6))
    }

    @Test func testReflowWrappedLinesEndingInZeroSpaceSmaller() {
        let b = makeBuffer(cols: 4, rows: 10, scrollback: 10)
        b.y = 2
        setChar(b.lines[0], 0, asciiA)
        setChar(b.lines[0], 1, asciiA + 1)
        setChar(b.lines[1], 0, asciiA + 2)
        setChar(b.lines[1], 1, asciiA + 3)
        b.lines[1].wrapped = true

        b.resize(cols: 3, rows: 10)

        #expect(b.y == 2)
        #expect(b.ybase == 0)
        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: false) == "ab ")
        #expect(lineText(b, 1, trimRight: false) == " cd")

        b.resize(cols: 2, rows: 10)

        #expect(b.y == 3)
        #expect(b.ybase == 0)
        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: false) == "ab")
        #expect(lineText(b, 1, trimRight: false) == "  ")
        #expect(lineText(b, 2, trimRight: false) == "cd")
    }

    @Test func testReflowWideCharactersLarger() {
        let b = makeBuffer(cols: 12, rows: 10, scrollback: 10)
        b.y = 2

        let pattern: [UInt32] = [han, yu, han, yu, han, yu]
        fillWideLine(b.lines[0], pattern)
        fillWideLine(b.lines[1], pattern)
        b.lines[1].wrapped = true

        let six = hanS + yuS + hanS + yuS + hanS + yuS
        #expect(lineText(b, 0, trimRight: true) == six)
        #expect(lineText(b, 1, trimRight: true) == six)

        b.resize(cols: 13, rows: 10)

        #expect(b.ybase == 0)
        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: true) == six)
        #expect(lineText(b, 0, trimRight: false) == six + " ")
        #expect(lineText(b, 1, trimRight: true) == six)
        #expect(lineText(b, 1, trimRight: false) == six + " ")

        b.resize(cols: 14, rows: 10)

        #expect(lineText(b, 0, trimRight: true) == six + hanS)
        #expect(lineText(b, 1, trimRight: true) == yuS + hanS + yuS + hanS + yuS)
    }

    @Test func testReflowWideCharactersSmaller() {
        let b = makeBuffer(cols: 12, rows: 10, scrollback: 10)
        b.y = 2

        let pattern: [UInt32] = [han, yu, han, yu, han, yu]
        fillWideLine(b.lines[0], pattern)
        fillWideLine(b.lines[1], pattern)
        b.lines[1].wrapped = true

        b.resize(cols: 11, rows: 10)
        #expect(b.ybase == 0)
        #expect(b.lines.count == 10)
        #expect(lineText(b, 0, trimRight: true) == hanS + yuS + hanS + yuS + hanS)
        #expect(lineText(b, 1, trimRight: true) == yuS + hanS + yuS + hanS + yuS)
        #expect(lineText(b, 2, trimRight: true) == hanS + yuS)

        b.resize(cols: 10, rows: 10)
        #expect(lineText(b, 0, trimRight: true) == hanS + yuS + hanS + yuS + hanS)
        #expect(lineText(b, 1, trimRight: true) == yuS + hanS + yuS + hanS + yuS)
        #expect(lineText(b, 2, trimRight: true) == hanS + yuS)

        b.resize(cols: 9, rows: 10)
        #expect(lineText(b, 0, trimRight: true) == hanS + yuS + hanS + yuS)
        #expect(lineText(b, 1, trimRight: true) == hanS + yuS + hanS + yuS)
        #expect(lineText(b, 2, trimRight: true) == hanS + yuS + hanS + yuS)

        b.resize(cols: 8, rows: 10)
        #expect(lineText(b, 0, trimRight: true) == hanS + yuS + hanS + yuS)
        #expect(lineText(b, 1, trimRight: true) == hanS + yuS + hanS + yuS)
        #expect(lineText(b, 2, trimRight: true) == hanS + yuS + hanS + yuS)

        b.resize(cols: 7, rows: 10)
        #expect(lineText(b, 0, trimRight: true) == hanS + yuS + hanS)
        #expect(lineText(b, 1, trimRight: true) == yuS + hanS + yuS)
        #expect(lineText(b, 2, trimRight: true) == hanS + yuS + hanS)
        #expect(lineText(b, 3, trimRight: true) == yuS + hanS + yuS)

        b.resize(cols: 6, rows: 10)
        #expect(lineText(b, 0, trimRight: true) == hanS + yuS + hanS)
        #expect(lineText(b, 1, trimRight: true) == yuS + hanS + yuS)
        #expect(lineText(b, 2, trimRight: true) == hanS + yuS + hanS)
        #expect(lineText(b, 3, trimRight: true) == yuS + hanS + yuS)
    }
}

// MARK: - ported: where a logical line wraps at the new width

@Suite("Reflow — new line lengths")
struct ReflowLineLengthTests {

    @Test func testGetNewLineLengthsSmallWideCharacters() {
        let b = makeBuffer(cols: 4, rows: 1, scrollback: 10)
        let line = Row(cols: 4)
        setWide(line, 0, han)
        setWide(line, 2, yu)
        #expect(line.string(trimRight: true) == hanS + yuS)
        #expect(b.newLineLengths([line], oldCols: 4, newCols: 3) == [2, 2])
        #expect(b.newLineLengths([line], oldCols: 4, newCols: 2) == [2, 2])
    }

    @Test func testGetNewLineLengthsLargeWideCharacters() {
        let b = makeBuffer(cols: 12, rows: 1, scrollback: 10)
        let line = Row(cols: 12)
        fillWideLine(line, [han, yu, han, yu, han, yu])
        #expect(line.string(trimRight: true) == hanS + yuS + hanS + yuS + hanS + yuS)
        #expect(b.newLineLengths([line], oldCols: 12, newCols: 11) == [10, 2])
        #expect(b.newLineLengths([line], oldCols: 12, newCols: 10) == [10, 2])
        #expect(b.newLineLengths([line], oldCols: 12, newCols: 9) == [8, 4])
        #expect(b.newLineLengths([line], oldCols: 12, newCols: 8) == [8, 4])
        #expect(b.newLineLengths([line], oldCols: 12, newCols: 7) == [6, 6])
        #expect(b.newLineLengths([line], oldCols: 12, newCols: 6) == [6, 6])
        #expect(b.newLineLengths([line], oldCols: 12, newCols: 5) == [4, 4, 4])
        #expect(b.newLineLengths([line], oldCols: 12, newCols: 4) == [4, 4, 4])
        #expect(b.newLineLengths([line], oldCols: 12, newCols: 3) == [2, 2, 2, 2, 2, 2])
        #expect(b.newLineLengths([line], oldCols: 12, newCols: 2) == [2, 2, 2, 2, 2, 2])
    }

    @Test func testGetNewLineLengthsWideAndSingleCharacters() {
        let b = makeBuffer(cols: 6, rows: 1, scrollback: 10)
        let line = Row(cols: 6)
        setChar(line, 0, asciiA)
        setWide(line, 1, han)
        setWide(line, 3, yu)
        setChar(line, 5, asciiA + 1)
        #expect(line.string(trimRight: true) == "a" + hanS + yuS + "b")
        #expect(b.newLineLengths([line], oldCols: 6, newCols: 5) == [5, 1])
        #expect(b.newLineLengths([line], oldCols: 6, newCols: 4) == [3, 3])
        #expect(b.newLineLengths([line], oldCols: 6, newCols: 3) == [3, 3])
        #expect(b.newLineLengths([line], oldCols: 6, newCols: 2) == [1, 2, 2, 1])
    }

    @Test func testGetNewLineLengthsWrappedWideAndSingleCharacters() {
        let b = makeBuffer(cols: 6, rows: 1, scrollback: 10)
        let line1 = Row(cols: 6)
        setChar(line1, 0, asciiA)
        setWide(line1, 1, han)
        setWide(line1, 3, yu)
        setChar(line1, 5, asciiA + 1)
        let line2 = Row(cols: 6)
        line2.wrapped = true
        setChar(line2, 0, asciiA)
        setWide(line2, 1, han)
        setWide(line2, 3, yu)
        setChar(line2, 5, asciiA + 1)
        #expect(line1.string(trimRight: true) == "a" + hanS + yuS + "b")
        #expect(line2.string(trimRight: true) == "a" + hanS + yuS + "b")
        #expect(b.newLineLengths([line1, line2], oldCols: 6, newCols: 5) == [5, 4, 3])
        #expect(b.newLineLengths([line1, line2], oldCols: 6, newCols: 4) == [3, 4, 4, 1])
        #expect(b.newLineLengths([line1, line2], oldCols: 6, newCols: 3) == [3, 3, 3, 3])
        #expect(b.newLineLengths([line1, line2], oldCols: 6, newCols: 2) == [1, 2, 2, 2, 2, 2, 1])
    }

    @Test func testGetNewLineLengthsLineEndingInNullSpace() {
        let b = makeBuffer(cols: 4, rows: 1, scrollback: 10)
        let line = Row(cols: 5)
        setWide(line, 0, han)
        setWide(line, 2, yu)
        line[4] = .empty
        #expect(line.string(trimRight: true) == hanS + yuS)
        #expect(line.string(trimRight: false) == hanS + yuS + " ")
        #expect(b.newLineLengths([line], oldCols: 4, newCols: 3) == [2, 2])
        #expect(b.newLineLengths([line], oldCols: 4, newCols: 2) == [2, 2])
    }
}

// MARK: - through the emulator

@Suite("Reflow — through the parser")
struct ReflowTerminalTests {

    private func alphabet(_ n: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return String((0..<n).map { letters[$0 % 26] })
    }

    @Test func testDoesNotCrashWhenReflowingToTinyWidth() {
        let t = Terminal(cols: 10, rows: 10, scrollback: 1)
        t.feed("1234567890\r\n")
        t.feed("ABCDEFGH\r\n")
        t.feed("abcdefghijklmnopqrstxxx\r\n")
        t.feed("\r\n")

        // Content is pushed back up and out the top of the buffer: must not trap.
        t.resize(cols: 3, rows: 10)
        #expect(t.cols == 3)
    }

    @Test("a 200-column line narrowed to 40 and widened back is byte-identical")
    func roundTripNarrowThenWiden() {
        let text = alphabet(200)
        let t = Terminal(cols: 80, rows: 25, scrollback: 1000)
        t.feed(text + "\r\n")

        let before = t.allLines()
        let beforeWrapped = (0..<t.buffer.lines.count).map { t.buffer.lines[$0].wrapped }
        #expect(beforeWrapped.prefix(4) == [false, true, true, false])

        t.resize(cols: 40, rows: 25)
        #expect(t.allLines()[0] == String(text.prefix(40)))
        #expect(t.allLines()[4] == String(text.dropFirst(160)))
        #expect((0..<5).map { t.buffer.lines[$0].wrapped } == [false, true, true, true, true])

        t.resize(cols: 80, rows: 25)
        #expect(t.allLines() == before)
        #expect((0..<t.buffer.lines.count).map { t.buffer.lines[$0].wrapped } == beforeWrapped)
    }

    @Test("a logical line stays one logical line across a resize")
    func logicalLineSurvives() {
        let text = alphabet(200)
        let t = Terminal(cols: 80, rows: 25, scrollback: 1000)
        t.feed(text + "\r\n")

        for cols in [37, 61, 13, 100, 80] {
            t.resize(cols: cols, rows: 25)
            var joined = ""
            var i = 0
            let all = t.allLines(trimRight: false)
            while i < all.count {
                joined += all[i]
                i += 1
                if i >= all.count || !t.buffer.lines[i].wrapped { break }
            }
            while joined.last == " " { joined.removeLast() }
            #expect(joined == text, "at \(cols) columns")
        }
    }

    @Test("a wide character is never split by a resize")
    func wideCharacterAtTheBoundary() {
        let t = Terminal(cols: 10, rows: 5, scrollback: 100)
        t.feed("abcdefghi" + hanS + yuS + "\r\n")

        // 漢 did not fit in the last column, so it started the next row.
        #expect(t.allLines()[0] == "abcdefghi")
        #expect(t.allLines()[1] == hanS + yuS)
        #expect(t.buffer.lines[1].wrapped)

        t.resize(cols: 6, rows: 5)
        #expect(t.allLines()[0] == "abcdef")
        #expect(t.allLines()[1] == "ghi" + hanS)
        #expect(t.allLines()[2] == yuS)
        // No row ends in the head of a wide character.
        for i in 0..<3 {
            let row = t.buffer.lines[i]
            #expect(row[row.cols - 1].width != 2)
        }
    }

    @Test("the cursor's own logical line is left for the program to redraw")
    func cursorLineIsNotReflowed() {
        let t = Terminal(cols: 20, rows: 5, scrollback: 100)
        t.feed("first line\r\n")
        t.feed(alphabet(35))                  // wraps, cursor stays on it

        #expect(t.buffer.lines[2].wrapped)
        t.resize(cols: 10, rows: 5)

        // Rows 1 and 2 were only cropped, not rewrapped.
        #expect(t.allLines()[1] == String(alphabet(35).prefix(10)))
        #expect(t.allLines()[2] == String(alphabet(35).dropFirst(20).prefix(10)))
    }

    @Test("a user who scrolled back keeps looking at the same text")
    func scrolledBackViewportIsStable() {
        let t = Terminal(cols: 80, rows: 10, scrollback: 100)
        for i in 0..<40 { t.feed("line \(i)\r\n") }
        t.scrollViewport(by: -12)
        let ydisp = t.buffer.ydisp
        let visible = (0..<10).map { t.buffer.lines[ydisp + $0].string() }
        #expect(visible[0] == "line 19")

        // Nothing is longer than 40 columns, so nothing rewraps.
        t.resize(cols: 40, rows: 10)
        #expect(t.buffer.ydisp == ydisp)
        #expect((0..<10).map { t.buffer.lines[t.buffer.ydisp + $0].string() } == visible)
        #expect(t.buffer.ydisp < t.buffer.ybase)
    }

    // MARK: - the viewport lands on a line boundary after a rewrap

    /// 80 columns of 56-character lines: nothing wraps. At 40 every one of them
    /// becomes two rows, so the row index the reader was parked on now points at
    /// the *tail* of a line — half a sentence, with no way to tell what it says.
    /// `Buffer.resize` puts the viewport back on the line they were reading.
    @Test("a rewrap never leaves the viewport looking at the tail of a line")
    func viewportLandsOnALineStartAfterNarrowing() {
        func lines(_ t: Terminal) {
            for i in 0..<80 {
                let head = "row\(i) "
                t.feed(head + String(repeating: "=", count: 56 - head.count) + "\r\n")
            }
        }
        func top(_ t: Terminal) -> (text: String, wrapped: Bool) {
            let b = t.buffer
            let line = b.lineNumber(ofViewportRow: 0)
            return (b.row(line: line)?.string() ?? "", b.row(line: line)?.wrapped ?? false)
        }

        // Widths where nothing rewraps: the reader does not move at all.
        for cols in [60, 120, 200] {
            let t = Terminal(cols: 80, rows: 24, scrollback: 5_000)
            lines(t)
            t.scrollViewport(by: -10)
            let before = top(t)
            t.resize(cols: cols, rows: 24)
            #expect(top(t).text == before.text, "80 -> \(cols) moved the viewport")
        }

        // 80 -> 40: every line becomes two rows. Three behaviours have stood
        // here, and it is worth being explicit about which one this asserts:
        //
        //   xterm.js       `ydisp` is left at its old index, so the reader ends
        //                  up looking at "================", the tail of some
        //                  OTHER line — the rows inserted above them pushed
        //                  their text down and out from under the index.
        //   3.0 (54)       the same index, then snapped up to the head of
        //                  whatever line it landed in: "row23", a head, but
        //                  still not the line the reader was reading.
        //   now            the line the reader WAS reading: "row47".
        //
        // The snap fixed the symptom (mid-paragraph) without fixing the drift,
        // which is why "row23" was the answer before and is wrong now.
        let t = Terminal(cols: 80, rows: 24, scrollback: 5_000)
        lines(t)
        t.scrollViewport(by: -10)
        #expect(top(t).text == "row47 " + String(repeating: "=", count: 50))
        #expect(t.buffer.ydisp < t.buffer.ybase)

        t.resize(cols: 40, rows: 24)

        let after = top(t)
        #expect(!after.wrapped, "viewport is parked on a continuation row: \(after.text)")
        #expect(after.text == "row47 " + String(repeating: "=", count: 34))
        #expect(t.buffer.row(line: t.buffer.lineNumber(ofViewportRow: 1))?.string()
                == String(repeating: "=", count: 16))

        // …and back again: the round trip returns the reader to the same text.
        t.resize(cols: 80, rows: 24)
        #expect(top(t).text == "row47 " + String(repeating: "=", count: 50))
    }

    /// The lead's sequence: scroll back ten rows, then resize five times. The
    /// invariant is per-step and holds for every width: while the reader is
    /// still scrolled back, the top of the viewport is the start of a line.
    /// (A viewport that has been pulled back to the bottom — `ydisp == ybase` —
    /// is exempt: it shows the live screen, whose first row may well continue
    /// the line above it, and unpinning it would stop new output scrolling.)
    /// The drift itself, which the mid-line invariant above never caught: the
    /// reader is not just on *a* line start, they are on the SAME line. Ten rows
    /// up, then the lead's resize storm. Measured on the old code the top line
    /// walked 52 -> 62 over these five steps (backwards through the history on
    /// every narrowing, forwards on every widening); now it does not move at all
    /// except where a width leaves too little history above the screen to hold
    /// the line, which pins the reader to the bottom instead.
    @Test("a resize storm leaves the reader on the same line")
    func repeatedResizesKeepTheReaderOnTheSameLine() {
        let t = Terminal(cols: 80, rows: 24, scrollback: 5_000)
        for i in 0..<80 {
            t.feed("row\(i) " + String(repeating: "=", count: 50) + "\r\n")
        }
        t.scrollViewport(by: -10)

        func topLabel() -> String {
            let b = t.buffer
            let text = b.row(line: b.lineNumber(ofViewportRow: 0))?.string() ?? ""
            return String(text.prefix(while: { $0 != " " }))
        }
        let start = topLabel()
        #expect(start == "row47")

        for cols in [40, 120, 37, 200, 80] {
            t.resize(cols: cols, rows: 24)
            guard t.buffer.ydisp < t.buffer.ybase else { continue }   // following: exempt
            #expect(topLabel() == start, "resize to \(cols) moved the reader to \(topLabel())")
        }
        #expect(topLabel() == start)
    }

    /// Widening is the mirror image of the drift and had its own consequence:
    /// removing rows above a scrolled-back reader pulled `ydisp` up until it met
    /// `ybase`, at which point the viewport was pinned to the bottom and every
    /// new line of output scrolled it — the reader was following again without
    /// having asked. Anchoring on the line keeps them where they were as long as
    /// there is history above the screen to keep them in.
    @Test("widening does not quietly put the reader back at the bottom")
    func wideningDoesNotSilentlyResumeFollowing() {
        let t = Terminal(cols: 40, rows: 10, scrollback: 5_000)
        for i in 0..<60 {
            t.feed("row\(i) " + String(repeating: "=", count: 70) + "\r\n")
        }
        t.scrollViewport(by: -30)
        #expect(t.buffer.ydisp < t.buffer.ybase)

        // Which logical line is the reader on? (They are half way down it: at 40
        // columns a 76-character line is two rows.)
        func headLabel() -> String {
            let b = t.buffer
            var i = b.ydisp
            while i > 0, b.lines.allocatedRow(at: i)?.wrapped == true { i -= 1 }
            return String((b.lines.allocatedRow(at: i)?.string() ?? "").prefix(while: { $0 != " " }))
        }
        let before = headLabel()
        #expect(before.hasPrefix("row"))

        t.resize(cols: 120, rows: 10)          // every line collapses from 2 rows to 1

        #expect(t.buffer.ydisp < t.buffer.ybase, "the reader was pulled back to the bottom")
        #expect(headLabel() == before)
    }

    @Test("repeated resizes never park the viewport mid-line")
    func repeatedResizesKeepTheViewportOnALineStart() {
        for width in [40, 56, 137] {
            let t = Terminal(cols: 80, rows: 24, scrollback: 5_000)
            for i in 0..<80 {
                let head = "row\(i) "
                let w = 20 + (i * 37) % width
                t.feed(head + String(repeating: "=", count: Swift.max(w - head.count, 1)) + "\r\n")
            }
            t.scrollViewport(by: -10)

            for cols in [40, 120, 37, 200, 80] {
                t.resize(cols: cols, rows: 24)
                let b = t.buffer
                guard b.ydisp < b.ybase else { continue }        // following: exempt
                let row = b.row(line: b.lineNumber(ofViewportRow: 0))
                #expect(row?.wrapped != true,
                        "width \(width), resize to \(cols): viewport top is a continuation row")
            }
        }
    }

    /// The case that needs the offset inside a logical line: a line taller than
    /// the screen (a JSON blob `cat`ed at 80 columns is one line thousands of
    /// rows deep). "Put the reader back on their logical line" cannot mean "on
    /// its first row" here — that would throw them 92 rows back — so the offset
    /// they were at is carried across in CELLS: half the width, twice the rows.
    ///
    /// 3.0 (54) capped a walk-to-the-head at one screen and asserted that the
    /// viewport moved by exactly `rows - 1`, i.e. that the give-up had fired.
    /// There is no give-up any more, because there is nothing to give up on:
    /// what the reader keeps is their place in the text, not a row index.
    @Test("a reader deep inside one huge logical line keeps their place in it")
    func viewportKeepsItsOffsetInsideAHugeLogicalLine() {
        let t = Terminal(cols: 80, rows: 10, scrollback: 5_000)
        t.feed(alphabet(80 * 200))                    // one logical line, 200 rows
        t.feed("\r\ntail\r\n")
        t.scrollViewport(by: -100)
        let before = t.buffer.ydisp
        let beforeText = t.buffer.row(line: t.buffer.lineNumber(ofViewportRow: 0))?.string() ?? ""
        #expect(beforeText.count == 80)
        #expect(t.buffer.row(line: t.buffer.lineNumber(ofViewportRow: 0))?.wrapped == true)

        t.resize(cols: 40, rows: 10)

        let b = t.buffer
        #expect(b.ydisp >= 0 && b.ydisp <= b.ybase)
        // Twice as many rows into the same paragraph, showing the same cells:
        // the first half of what the 80-column row showed.
        #expect(b.ydisp == before * 2)
        #expect(b.row(line: b.lineNumber(ofViewportRow: 0))?.string()
                == String(beforeText.prefix(40)))
        #expect(b.row(line: b.lineNumber(ofViewportRow: 0))?.wrapped == true)

        // Back to 80 and the reader is exactly where they started.
        t.resize(cols: 80, rows: 10)
        #expect(t.buffer.ydisp == before)
        #expect(t.buffer.row(line: t.buffer.lineNumber(ofViewportRow: 0))?.string() == beforeText)
    }

    @Test("the alternate screen never reflows")
    func alternateScreenIsCroppedNotReflowed() {
        let t = Terminal(cols: 20, rows: 5, scrollback: 100)
        t.feed("\u{1b}[?1049h")               // alternate screen
        #expect(t.isAlternate)
        t.feed(alphabet(35))
        t.feed("\u{1b}[H")                    // cursor home, off the wrapped line's end
        #expect(t.buffer.lines.count == 5)

        t.resize(cols: 10, rows: 5)
        #expect(t.buffer.lines.count == 5)    // no rows added
        #expect(t.buffer.ybase == 0)
        #expect(t.screenLines()[0] == String(alphabet(35).prefix(10)))
        #expect(t.screenLines()[1] == String(alphabet(35).dropFirst(20).prefix(10)))
    }

    @Test("colours and combining marks travel with their cells")
    func attributesSurviveReflow() {
        let t = Terminal(cols: 8, rows: 4, scrollback: 100)
        t.feed("\u{1b}[31mabcdef\u{1b}[0mgh")     // red a–f, then g h
        t.feed("e\u{301}xyz\r\n")                  // é as a combining sequence
        let redCell = t.buffer.lines[0][0]
        #expect(redCell.fgSource == .palette16)

        t.resize(cols: 4, rows: 4)

        #expect(t.allLines()[0] == "abcd")
        #expect(t.allLines()[1] == "ef" + "gh")
        #expect(t.allLines()[2] == "e\u{301}xyz".prefix(4))
        #expect(t.buffer.lines[0][0].fgSource == .palette16)
        #expect(t.buffer.lines[1][0].fgSource == .palette16)   // 'e' is still red
        #expect(t.buffer.lines[1][2].fgSource == .default)     // 'g' is not
    }

    @Test("random resize storms keep the buffer well-formed",
          arguments: [0x5EE9_17E7, 0x0BAD_C0DE, 0x1234_5678, 0xFEED_FACE,
                      0x00_00_00_01, 0x7FFF_FFFF] as [UInt64])
    func resizeFuzz(_ start: UInt64) {
        // Deterministic LCG so a failure is reproducible from its seed.
        var seed = start
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }

        let t = Terminal(cols: 80, rows: 24, scrollback: 200)
        for i in 0..<300 {
            switch i % 5 {
            case 0: t.feed("\u{1b}[3\(i % 8)mline \(i) " + alphabet(40 + i % 130) + "\r\n")
            case 1: t.feed(String(repeating: hanS + yuS, count: 20 + i % 30) + "\r\n")
            case 2: t.feed("a" + String(repeating: "e\u{301}", count: 30) + "\r\n")
            case 3: t.feed("short \(i)\r\n")
            default: t.feed(alphabet(200) + hanS + "\r\n")
            }
        }

        for _ in 0..<400 {
            let cols = 1 + next(140)
            let rows = 1 + next(60)
            t.resize(cols: cols, rows: rows)
            if next(4) == 0 { t.scrollViewport(by: next(41) - 20) }
            if next(6) == 0 { t.feed(alphabet(1 + next(300)) + "\r\n") }

            let b = t.buffer
            #expect(b.cols == t.cols)
            #expect(b.lines.cols == t.cols)
            #expect(b.lines.count >= t.rows)
            #expect(b.lines.count <= b.lines.maxLength)
            #expect(b.ybase >= 0 && b.ybase + t.rows <= b.lines.count)
            #expect(b.ydisp >= 0 && b.ydisp <= b.ybase)
            #expect(b.y >= 0 && b.y < t.rows)
            #expect(b.x >= 0 && b.x <= t.cols)
            for i in 0..<b.lines.count {
                if let r = b.lines.allocatedRow(at: i) { #expect(r.cols == t.cols) }
            }
            // Row 0 of the retained history can never continue anything that is
            // still reachable, but a row that claims a spacer must have a head.
            for i in 0..<b.lines.count {
                guard let r = b.lines.allocatedRow(at: i), r.cols > 0 else { continue }
                #expect(r[r.cols - 1].width != 2, "row \(i) ends in a wide head")
            }
        }
    }

    @Test("Row.copyCells clamps and carries the side tables")
    func copyCellsCarriesSideTables() {
        let src = Row(cols: 6)
        for i in 0..<6 { src[i] = Cell(code: asciiA + UInt32(i), width: 1, fg: 0, bg: 0) }
        src.setCombined("e\u{301}", at: 4)
        var ext = ExtendedAttributes()
        ext.underlineStyle = .curly
        src.setExtended(ext, at: 5)

        let dst = Row(cols: 4)
        dst.copyCells(from: src, srcCol: 3, dstCol: 0, count: 99)   // clamped to 3
        #expect(dst.string(trimRight: false) == "d" + "e\u{301}" + "f ")
        #expect(dst.combinedString(at: 1) == "e\u{301}")
        #expect(dst.extended(at: 2)?.underlineStyle == .curly)
        #expect(dst[3].code == 0)

        // Overlapping in-place shift keeps the side-table entries aligned.
        let same = Row(cols: 6)
        for i in 0..<6 { same[i] = Cell(code: asciiA + UInt32(i), width: 1, fg: 0, bg: 0) }
        same.setCombined("e\u{301}", at: 0)
        same.copyCells(from: same, srcCol: 0, dstCol: 2, count: 4)
        #expect(same.string(trimRight: false) == "e\u{301}" + "b" + "e\u{301}" + "bcd")
        #expect(same.combinedString(at: 2) == "e\u{301}")
        #expect(same.combinedString(at: 0) == "e\u{301}")
    }

    @Test("LineRing.replaceAll keeps the cap and counts what falls off")
    func replaceAllDropsOldest() {
        let ring = LineRing(maxLength: 4, cols: 3)
        for _ in 0..<4 { ring.pushBlank() }
        #expect(ring.trimmed == 0)

        var rows: [Row?] = []
        for i in 0..<6 {
            let r = Row(cols: 3)
            r[0] = Cell(code: ascii0 + UInt32(i), width: 1, fg: 0, bg: 0)
            rows.append(r)
        }
        ring.replaceAll(rows)

        #expect(ring.maxLength == 4)
        #expect(ring.count == 4)
        #expect(ring.trimmed == 2)
        #expect(ring[0].string() == "2")
        #expect(ring[3].string() == "5")

        // A short list leaves the rest of the ring lazily empty.
        ring.replaceAll([Row?](repeating: nil, count: 2))
        #expect(ring.count == 2)
        #expect(ring.allocatedRowCount == 0)
        #expect(ring.trimmed == 2)
    }
}
