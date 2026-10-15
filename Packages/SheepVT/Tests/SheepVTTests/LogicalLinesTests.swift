import Testing
@testable import SheepVT

// `Terminal.logicalLines(limit:)` — soft-wrapped rows joined into one line
// (the AI panel's Attach Last 200 Lines masks per LINE: a secret cut at the
// screen width would leave its tail unmasked on the next row).
struct LogicalLinesTests {
    @Test func wrappedLongLineIsOneLogicalLine() {
        let t = Terminal(cols: 80, rows: 24)
        let secret = String(repeating: "A1b2C3d4", count: 15)   // 120 chars
        t.feed("    set password ENC \(secret)\r\nnext\r\n")
        let lines = t.logicalLines()
        #expect(lines == ["    set password ENC \(secret)", "next"])
        // The visual rows cut it (what allLines returns).
        #expect(t.allLines()[1] == String(secret.suffix(61)))
    }

    @Test func limitTakesTheTailAndDropsTrailingBlanks() {
        let t = Terminal(cols: 10, rows: 5)
        t.feed("one\r\ntwo\r\n" + String(repeating: "x", count: 25) + "\r\nfour\r\n")
        #expect(t.logicalLines() == ["one", "two", String(repeating: "x", count: 25), "four"])
        #expect(t.logicalLines(limit: 2) == [String(repeating: "x", count: 25), "four"])
        #expect(t.logicalLines(limit: 0) == [])
        #expect(Terminal(cols: 10, rows: 5).logicalLines() == [])
    }

    @Test func blankLinesInsideAreKept() {
        let t = Terminal(cols: 20, rows: 6)
        t.feed("a\r\n\r\nb")
        #expect(t.logicalLines() == ["a", "", "b"])
    }
}
