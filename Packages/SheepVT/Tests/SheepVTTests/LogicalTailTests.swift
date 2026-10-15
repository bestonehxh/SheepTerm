import Testing
@testable import SheepVT

// `Terminal.logicalTail` — logical lines with ABSOLUTE start rows that keep
// counting after the scrollback ring trims (the AI panel's "new output" mark).
struct LogicalTailTests {
    @Test func rowsAreAbsoluteAcrossTrimming() {
        let t = Terminal(cols: 20, rows: 4, scrollback: 5)
        for i in 0..<5 { t.feed("l\(i)\r\n") }
        let first = t.logicalTail()
        #expect(first.lines.first == "l0")
        let mark = first.startRows.last!
        // The ring trims its oldest line, yet the mark still names the same line.
        for i in 5..<9 { t.feed("l\(i)\r\n") }
        #expect(t.buffer.lines.trimmed > 0)
        let later = t.logicalTail(fromRow: mark)
        #expect(later.lines.first == "l4")
        #expect(later.lines.last == "l8")
        #expect(later.startRows.first == mark)
        #expect(zip(later.startRows, later.startRows.dropFirst()).allSatisfy { $1 == $0 + 1 })
        // A mark trimmed away entirely: everything retained.
        for i in 9..<60 { t.feed("l\(i)\r\n") }
        let all = t.logicalTail(fromRow: 0)
        #expect(all.lines == t.logicalTail().lines)
        #expect(all.startRows.first! > 0)
    }

    @Test func wrappedLineHasOneStartRowAndLimitHolds() {
        let t = Terminal(cols: 10, rows: 5, scrollback: 50)
        t.feed("a\r\n" + String(repeating: "x", count: 25) + "\r\nz")
        let tail = t.logicalTail()
        #expect(tail.lines == ["a", String(repeating: "x", count: 25), "z"])
        #expect(tail.startRows[2] - tail.startRows[1] == 3)
        #expect(t.logicalTail(limit: 1).lines == ["z"])
        #expect(tail.cols == 10 && tail.alternate == false)
        #expect(Terminal(cols: 10, rows: 5).logicalTail().lines.isEmpty)
    }

    @Test func alternateScreenIsFlagged() {
        let t = Terminal(cols: 10, rows: 4)
        t.feed("x\u{1b}[?1049hy")
        #expect(t.logicalTail().alternate)
    }
}
