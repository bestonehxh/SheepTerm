// SheepVT — regressions from the phase-1 code review. One test per finding,
// each pinning the specific misbehaviour rather than the fix's shape.

import Testing
@testable import SheepVT

// MARK: - 5. reading the grid never allocates rows

@Suite("SheepVT regressions — laziness")
struct LazyReadTests {

    @Test("allLines does not materialise the empty scrollback")
    func allLinesDoesNotAllocate() {
        let t = Terminal(cols: 80, rows: 25, scrollback: 10_000)
        for _ in 0..<9_000 { t.feed("\r\n") }
        let before = t.buffer.lines.allocatedRowCount
        let lines = t.allLines()
        #expect(t.buffer.lines.allocatedRowCount == before)
        #expect(lines.count == t.buffer.lines.count)
        #expect(lines.allSatisfy { $0.isEmpty })
    }

    @Test("screenLines does not materialise blank screen rows")
    func screenLinesDoNotAllocate() {
        let t = Terminal(cols: 80, rows: 25, scrollback: 100)
        let before = t.buffer.lines.allocatedRowCount
        #expect(t.screenLines() == [String](repeating: "", count: 25))
        #expect(t.buffer.lines.allocatedRowCount == before)
    }

    @Test("text still comes back once rows exist")
    func allLinesStillReadsContent() {
        let t = Terminal(cols: 20, rows: 3, scrollback: 100)
        t.feed("one\r\ntwo\r\nthree\r\nfour")
        #expect(t.allLines() == ["one", "two", "three", "four"])
    }
}

// MARK: - 6. cursor-only changes are dirty

@Suite("SheepVT regressions — dirty rows")
struct DirtyRowTests {

    private func terminal() -> Terminal {
        let t = Terminal(cols: 20, rows: 5, scrollback: 100)
        t.feed("hello")
        return t
    }

    @Test("CR marks the cursor row")
    func carriageReturnIsDirty() {
        let t = terminal()
        t.clearDirty()
        t.feed("\r")
        #expect(t.dirtyRows == 0...0)
    }

    @Test("HT marks the cursor row")
    func tabIsDirty() {
        let t = terminal()
        t.clearDirty()
        t.feed("\t")
        #expect(t.dirtyRows == 0...0)
        #expect(t.buffer.x == 8)
    }

    @Test("BS marks the cursor row")
    func backspaceIsDirty() {
        let t = terminal()
        t.clearDirty()
        t.feed("\u{8}")
        #expect(t.dirtyRows == 0...0)
        #expect(t.buffer.x == 4)
    }

    @Test("reverse-wrap BS marks both rows")
    func reverseWrapBackspaceIsDirty() {
        let t = Terminal(cols: 4, rows: 5, scrollback: 100)
        t.feed("\u{1b}[?45h")
        t.feed("abcdef")                 // wraps onto row 1
        #expect(t.buffer.y == 1)
        t.clearDirty()
        t.feed("\u{8}\u{8}\u{8}")        // back over the soft wrap
        #expect(t.buffer.y == 0)
        #expect(t.dirtyRows == 0...1)
    }

    @Test("DECTCEM marks the cursor row")
    func cursorVisibilityIsDirty() {
        let t = terminal()
        t.feed("\r\n\r\n")               // cursor on row 2
        t.clearDirty()
        t.feed("\u{1b}[?25l")
        #expect(t.cursorVisible == false)
        #expect(t.dirtyRows == 2...2)
        t.clearDirty()
        t.feed("\u{1b}[?25h")
        #expect(t.cursorVisible == true)
        #expect(t.dirtyRows == 2...2)
    }
}

// MARK: - 7. the hyperlink registry is bounded in bytes

@Suite("SheepVT regressions — hyperlinks")
struct HyperlinkTests {

    private func retainedBytes(_ t: Terminal) -> Int {
        t.hyperlinks.reduce(0) { $0 + $1.utf8.count }
    }

    private func link(_ t: Terminal, id: String, uri: String) {
        t.feed("\u{1b}]8;id=\(id);\(uri)\u{7}x\u{1b}]8;;\u{7}")
    }

    @Test("an over-long URI is dropped, its text is not")
    func overLongURIDropped() {
        let t = Terminal(cols: 80, rows: 25, scrollback: 100)
        let uri = "https://example.com/" + String(repeating: "a", count: Terminal.maxHyperlinkLength)
        link(t, id: "1", uri: uri)
        #expect(t.hyperlinks.isEmpty)
        #expect(t.screenLines()[0] == "x")
    }

    @Test("300 x 200 KB URIs stay inside the cap")
    func giantURIsStayInsideCap() {
        let t = Terminal(cols: 80, rows: 25, scrollback: 100)
        for i in 0..<300 {
            link(t, id: "\(i)", uri: "https://example.com/\(i)/" + String(repeating: "a", count: 200_000))
        }
        #expect(retainedBytes(t) <= Terminal.maxHyperlinkBytes)
        #expect(t.hyperlinks.isEmpty)
    }

    @Test("many legal URIs stop at the byte cap")
    func legalURIsStopAtByteCap() {
        let t = Terminal(cols: 80, rows: 25, scrollback: 100)
        let pad = String(repeating: "a", count: 8_000)
        for i in 0..<1_000 {
            link(t, id: "\(i)", uri: "https://example.com/\(i)/" + pad)
        }
        #expect(retainedBytes(t) <= Terminal.maxHyperlinkBytes)
        #expect(!t.hyperlinks.isEmpty)
    }

    @Test("a normal link is registered and reset clears the budget")
    func normalLinkSurvives() {
        let t = Terminal(cols: 80, rows: 25, scrollback: 100)
        link(t, id: "a", uri: "https://example.com/")
        #expect(t.hyperlinks == ["https://example.com/"])
        t.reset()
        #expect(t.hyperlinks.isEmpty)
        link(t, id: "a", uri: "https://example.com/")
        #expect(t.hyperlinks == ["https://example.com/"])
    }
}

// MARK: - 8. IL / DL fix up `wrapped`

@Suite("SheepVT regressions — insert/delete lines")
struct LineEditTests {

    /// "abcdefgh" on a 4-column screen: row 0 "abcd", row 1 "efgh" (wrapped).
    private func wrappedTerminal() -> Terminal {
        let t = Terminal(cols: 4, rows: 5, scrollback: 100)
        t.feed("abcdefgh")
        #expect(t.buffer.row(1).wrapped)
        return t
    }

    @Test("IL clears wrapped on the row that shifted down")
    func insertLinesClearsWrap() {
        let t = wrappedTerminal()
        t.feed("\u{1b}[2;1H\u{1b}[L")     // IL at row 1
        #expect(t.buffer.row(1).string() == "")
        #expect(t.buffer.row(2).string() == "efgh")
        #expect(t.buffer.row(2).wrapped == false)
    }

    @Test("DL clears wrapped on the row that shifted up")
    func deleteLinesClearsWrap() {
        let t = wrappedTerminal()
        t.feed("\u{1b}[1;1H\u{1b}[M")     // DL at row 0
        #expect(t.buffer.row(0).string() == "efgh")
        #expect(t.buffer.row(0).wrapped == false)
    }

    @Test("IL leaves the rows it did not move alone")
    func insertLinesKeepsOtherWraps() {
        let t = wrappedTerminal()
        t.feed("\u{1b}[3;1H\u{1b}[L")     // IL below the wrapped pair
        #expect(t.buffer.row(1).wrapped)
    }
}

// MARK: - 9. ICH / DCH counts are clamped

@Suite("SheepVT regressions — cell shifts")
struct CellShiftTests {

    private func row(_ text: String, cols: Int) -> Row {
        let r = Row(cols: cols)
        for (i, ch) in text.unicodeScalars.enumerated() where i < cols {
            r[i] = Cell(code: ch.value, width: 1, fg: 0, bg: 0)
        }
        return r
    }

    @Test("insertCells with Int.max does not overflow")
    func insertMax() {
        let r = row("abcdef", cols: 6)
        r.insertCells(at: 2, count: .max, fill: .empty)
        #expect(r.string(trimRight: false) == "ab    ")
    }

    @Test("deleteCells with Int.max does not overflow")
    func deleteMax() {
        let r = row("abcdef", cols: 6)
        r.deleteCells(at: 2, count: .max, fill: .empty)
        #expect(r.string(trimRight: false) == "ab    ")
    }

    @Test("clamping does not change the ordinary cases")
    func clampedCountsMatchUnclamped() {
        let a = row("abcdef", cols: 6)
        a.insertCells(at: 2, count: 2, fill: .empty)
        #expect(a.string(trimRight: false) == "ab  cd")
        let b = row("abcdef", cols: 6)
        b.deleteCells(at: 2, count: 2, fill: .empty)
        #expect(b.string(trimRight: false) == "abef  ")
    }
}

// MARK: - 10. the parser survives a re-entrant feed

/// An actor that answers a CSI by writing back into the same parser — the shape
/// of a host that loops a DA/DSR reply straight into the terminal.
private final class EchoingActor: VTActor {
    var parser: VTParser?
    var printed = ""
    var csiCount = 0

    func print(_ codePoint: UInt32) {
        printed.unicodeScalars.append(Unicode.Scalar(codePoint) ?? "\u{FFFD}")
    }
    func printRun(_ bytes: UnsafeBufferPointer<UInt8>) {
        for b in bytes { print(UInt32(b)) }
    }
    func csiDispatch(prefix: UInt8, intermediates: ArraySlice<UInt8>, final: UInt8, params: CSIParams) {
        csiCount += 1
        if csiCount == 1 { parser?.feed("X") }
    }
}

@Suite("SheepVT regressions — parser reentrancy")
struct ParserReentrancyTests {

    @Test("bytes fed from a callback are parsed after the outer feed")
    func reentrantFeedIsQueued() {
        let actor = EchoingActor()
        let parser = VTParser(actor: actor)
        actor.parser = parser
        parser.feed("\u{1b}[1mAB")
        #expect(actor.csiCount == 1)
        #expect(actor.printed == "ABX")
        #expect(parser.state == .ground)
    }

    @Test("the sequence in flight is not corrupted by the re-entrant bytes")
    func reentrantFeedKeepsStateSane() {
        let actor = EchoingActor()
        let parser = VTParser(actor: actor)
        actor.parser = parser
        // The CSI that triggers the callback is followed by a second, complete
        // sequence: it must still be recognised, and nothing may leak into it.
        parser.feed("\u{1b}[1m\u{1b}[2mA")
        #expect(actor.csiCount == 2)
        #expect(actor.printed == "AX")
        #expect(parser.state == .ground)
    }

    @Test("a re-entrant feed in the middle of a split sequence")
    func reentrantFeedAcrossChunks() {
        let actor = EchoingActor()
        let parser = VTParser(actor: actor)
        actor.parser = parser
        parser.feed("\u{1b}[")
        #expect(parser.state == .csiEntry)
        parser.feed("1mZ")
        #expect(actor.printed == "ZX")
        #expect(parser.state == .ground)
    }
}

// MARK: - 11. tab stops after a widening resize

@Suite("SheepVT regressions — tab stops")
struct TabStopTests {

    @Test("growing adds the default stops, not stops from a custom one")
    func growKeepsDefaultGrid() {
        let t = Terminal(cols: 80, rows: 25, scrollback: 100)
        t.feed("\u{1b}[3g")              // TBC 3 — clear every stop
        t.feed("\u{1b}[6G\u{1b}H")       // cursor to column 6 (index 5), HTS
        #expect(t.buffer.tabStops.indices.filter { t.buffer.tabStops[$0] } == [5])

        t.resize(cols: 120, rows: 25)
        let stops = t.buffer.tabStops.indices.filter { t.buffer.tabStops[$0] }
        #expect(stops == [5, 80, 88, 96, 104, 112])
    }

    @Test("shrinking keeps only the stops that still fit")
    func shrinkTruncates() {
        let t = Terminal(cols: 80, rows: 25, scrollback: 100)
        t.resize(cols: 40, rows: 25)
        let stops = t.buffer.tabStops.indices.filter { t.buffer.tabStops[$0] }
        #expect(stops == Array(stride(from: 0, to: 40, by: 8)))
    }
}


@Suite("visibleGlyphsPrinted") struct VisibleGlyphTests {
    @Test func typedTextAndTypedSpacesCount() {
        let t = Terminal(cols: 40, rows: 4, scrollback: 10)
        let before = t.visibleGlyphsPrinted
        t.feed("show")
        #expect(t.visibleGlyphsPrinted > before)
        let afterWord = t.visibleGlyphsPrinted
        t.feed(" ")                       // a typed space lands on an empty cell
        #expect(t.visibleGlyphsPrinted > afterWord)
        let afterSpace = t.visibleGlyphsPrinted
        t.feed("run")
        #expect(t.visibleGlyphsPrinted > afterSpace)
    }

    @Test func erasingAPromptWithSpacesDoesNotCount() {
        let t = Terminal(cols: 40, rows: 4, scrollback: 10)
        t.feed("-- MORE --")
        let after = t.visibleGlyphsPrinted
        t.feed("\r          \r")          // the pager wipes its prompt: blanks over text
        #expect(t.visibleGlyphsPrinted == after)
        #expect(t.screenLines()[0] == "")
        t.feed("interface 1/1/1")          // …then the page: text again
        #expect(t.visibleGlyphsPrinted > after)
    }
}
