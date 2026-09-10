// SheepVT — selection model + scroll-invariant line numbering (agent B's
// phase-2 contract: Position, Buffer+Lines, Selection).
//
// Everything here drives a real `Terminal` through the parser, so the grid is
// the one the emulator actually produces — wrapped rows, wide-character
// spacers, combining marks and all.
//
// The suite is `.serialized` because two tests swap `Selection.wordCharacters`,
// which is a deliberate global.

import Testing
@testable import SheepVT

@Suite("Selection", .serialized)
struct SelectionTests {

    // MARK: - helpers

    private func makeTerminal(cols: Int = 20, rows: Int = 6, scrollback: Int = 50) -> Terminal {
        Terminal(cols: cols, rows: rows, scrollback: scrollback)
    }

    /// A terminal holding one screen of text, one line per element.
    private func terminal(_ lines: [String], cols: Int = 20, rows: Int = 6,
                          scrollback: Int = 50) -> Terminal {
        let t = makeTerminal(cols: cols, rows: rows, scrollback: scrollback)
        t.feed(lines.joined(separator: "\r\n"))
        return t
    }

    private let alphabet25 = "abcdefghijklmnopqrstuvwxy"   // 25 chars: 3 rows at 10 cols

    // MARK: - Position

    @Test("Position orders in reading order")
    func positionOrdering() {
        #expect(Position(line: 1, col: 5) < Position(line: 2, col: 0))
        #expect(Position(line: 2, col: 0) < Position(line: 2, col: 1))
        #expect(!(Position(line: 2, col: 1) < Position(line: 2, col: 1)))
        #expect(Position(line: 3, col: 4) == Position(line: 3, col: 4))
        let set: Set<Position> = [Position(line: 1, col: 1), Position(line: 1, col: 1)]
        #expect(set.count == 1)
        #expect(Swift.max(Position(line: 0, col: 9), Position(line: 1, col: 0)) == Position(line: 1, col: 0))
    }

    // MARK: - Buffer+Lines

    @Test("line numbers round-trip on a fresh buffer")
    func lineNumbersFresh() {
        let t = terminal(["one", "two", "three"])
        let b = t.buffer
        #expect(b.firstLine == 0)
        #expect(b.lineCount == 6)
        #expect(b.lastLine == 5)
        for i in 0..<b.lineCount {
            let n = b.lineNumber(atIndex: i)
            #expect(n == i)
            #expect(b.index(ofLine: n) == i)
        }
        #expect(b.index(ofLine: -1) == nil)
        #expect(b.index(ofLine: 6) == nil)
        #expect(b.hasLine(0))
        #expect(!b.hasLine(6))
    }

    @Test("line numbers keep counting after the ring cap is passed")
    func lineNumbersAfterRingCap() {
        // 4 rows + 6 lines of scrollback = a 10-line ring; 30 lines overflow it.
        let t = makeTerminal(cols: 20, rows: 4, scrollback: 6)
        for i in 0..<30 { t.feed("line\(i)\r\n") }
        let b = t.buffer
        #expect(b.lines.trimmed > 0)
        #expect(b.lineCount == 10)
        #expect(b.firstLine == b.lines.trimmed)
        #expect(b.lastLine == b.firstLine + 9)
        // Old numbers are gone, not reused.
        #expect(b.index(ofLine: 0) == nil)
        #expect(b.index(ofLine: b.firstLine) == 0)
        #expect(b.lineNumber(atIndex: 0) == b.firstLine)
        #expect(b.clampLine(0) == b.firstLine)
        #expect(b.clampLine(b.lastLine + 100) == b.lastLine)
        // The text at the first retained line is what it says it is.
        #expect(b.row(line: b.firstLine)?.string() == "line\(b.firstLine)")
    }

    @Test("screen and viewport rows resolve to line numbers")
    func screenAndViewportRows() {
        let t = makeTerminal(cols: 20, rows: 4, scrollback: 20)
        for i in 0..<10 { t.feed("line\(i)\r\n") }
        let b = t.buffer
        #expect(b.lineNumber(ofScreenRow: 0) == b.lineNumber(atIndex: b.ybase))
        #expect(b.lineNumber(ofViewportRow: 0) == b.lineNumber(atIndex: b.ydisp))
        #expect(b.isFollowing)
        t.scrollViewport(by: -3)
        #expect(!b.isFollowing)
        #expect(b.lineNumber(ofViewportRow: 0) == b.lineNumber(ofScreenRow: 0) - 3)
        // A screen row still points at the same text after the user scrolls.
        let bottom = b.lineNumber(ofScreenRow: 0)
        t.scrollViewportToBottom()
        #expect(b.lineNumber(ofScreenRow: 0) == bottom)
    }

    @Test("row(line:) never allocates and reports nil for fallen-off lines")
    func rowLine() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 4)
        t.feed("hello")
        let b = t.buffer
        #expect(b.row(line: 0)?.string() == "hello")
        // Rows 1…3 have never been written: still nil, and asking did not
        // materialise them.
        let before = b.lines.allocatedRowCount
        #expect(b.row(line: 3) == nil)
        #expect(b.lines.allocatedRowCount == before)
        // Beyond the produced lines, and below the retained ones.
        #expect(b.row(line: 99) == nil)
        #expect(b.row(line: -1) == nil)
    }

    @Test("logicalLine spans a soft-wrapped run")
    func logicalLineWrapped() {
        let t = makeTerminal(cols: 10, rows: 6, scrollback: 20)
        t.feed(alphabet25)
        let b = t.buffer
        #expect(b.row(line: 1)?.wrapped == true)
        #expect(b.row(line: 2)?.wrapped == true)
        #expect(b.logicalLine(containing: 0) == 0...2)
        #expect(b.logicalLine(containing: 1) == 0...2)
        #expect(b.logicalLine(containing: 2) == 0...2)
        #expect(b.isWrapped(line: 1))
        #expect(!b.isWrapped(line: 0))
    }

    @Test("logicalLine of an unwrapped line is that line alone")
    func logicalLineSingle() {
        let t = terminal(["one", "two", "three"])
        let b = t.buffer
        #expect(b.logicalLine(containing: 1) == 1...1)
        // Blank never-materialised rows are not continuations.
        #expect(b.logicalLine(containing: 4) == 4...4)
        // Out of range clamps.
        #expect(b.logicalLine(containing: -5) == 0...0)
        #expect(b.logicalLine(containing: 999) == b.lastLine...b.lastLine)
    }

    @Test("a 200-character line at 80 columns is one logical line")
    func longLineAt80() {
        let t = makeTerminal(cols: 80, rows: 25, scrollback: 200)
        let long = String(repeating: "x", count: 200)
        t.feed(long)
        let b = t.buffer
        #expect(b.logicalLine(containing: 0) == 0...2)
        #expect(b.row(line: 1)?.wrapped == true)
        #expect(b.row(line: 2)?.wrapped == true)
    }

    // MARK: - character mode

    @Test("begin selects a single cell")
    func characterSingleCell() {
        let t = terminal(["hello world"])
        let s = Selection(terminal: t)
        #expect(!s.isActive)
        #expect(s.text() == "")
        s.begin(at: Position(line: 0, col: 4))
        #expect(s.isActive)
        #expect(s.mode == .character)
        #expect(s.start == Position(line: 0, col: 4))
        #expect(s.end == Position(line: 0, col: 4))
        #expect(s.text() == "o")
        #expect(s.columnRange(onLine: 0) == 4..<5)
        #expect(s.columnRange(onLine: 1) == nil)
        #expect(s.lineRange == 0...0)
        #expect(s.contains(Position(line: 0, col: 4)))
        #expect(!s.contains(Position(line: 0, col: 5)))
    }

    @Test("extend forward on one line")
    func characterExtendForward() {
        let t = terminal(["hello world"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0))
        s.extend(to: Position(line: 0, col: 4))
        #expect(s.text() == "hello")
        #expect(s.columnRange(onLine: 0) == 0..<5)
        s.extend(to: Position(line: 0, col: 10))
        #expect(s.text() == "hello world")
    }

    @Test("extend before the anchor swaps start and end, the anchor stays")
    func extendBackwardSwaps() {
        let t = terminal(["hello world"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 6))
        s.extend(to: Position(line: 0, col: 0))
        #expect(s.anchor == Position(line: 0, col: 6))
        #expect(s.focus == Position(line: 0, col: 0))
        #expect(s.start == Position(line: 0, col: 0))
        #expect(s.end == Position(line: 0, col: 6))
        #expect(s.text() == "hello w")
    }

    @Test("a selection across hard line breaks joins with newlines")
    func characterAcrossHardBreaks() {
        let t = terminal(["one", "two", "three"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0))
        s.extend(to: Position(line: 2, col: 4))
        #expect(s.text() == "one\ntwo\nthree")
        #expect(s.lineRange == 0...2)
        #expect(s.columnRange(onLine: 0) == 0..<20)
        #expect(s.columnRange(onLine: 1) == 0..<20)
        #expect(s.columnRange(onLine: 2) == 0..<5)
    }

    @Test("a selection across a soft wrap has no newline")
    func characterAcrossSoftWrap() {
        let t = makeTerminal(cols: 10, rows: 6, scrollback: 20)
        t.feed(alphabet25)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0))
        s.extend(to: Position(line: 2, col: 4))
        #expect(s.text() == alphabet25)
    }

    @Test("a middle row that continues into a wrapped row is not right-trimmed")
    func wrappedRowKeepsItsBlanks() {
        // A wide char at the right margin forces an early wrap, leaving a real
        // blank in the middle of the logical line.
        let t = makeTerminal(cols: 6, rows: 4, scrollback: 20)
        t.feed("abcde漢fg")
        let b = t.buffer
        #expect(b.row(line: 1)?.wrapped == true)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0))
        s.extend(to: Position(line: 1, col: 3))
        // Row 0 = "abcde" + one blank cell (the wide char did not fit) and is
        // NOT trimmed; row 1 = "漢fg".
        #expect(s.text() == "abcde 漢fg")
    }

    @Test("a hard-broken row IS right-trimmed")
    func hardRowIsTrimmed() {
        let t = terminal(["ab", "cd"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0))
        s.extend(to: Position(line: 1, col: 19))
        #expect(s.text() == "ab\ncd")
    }

    @Test("positions clamp to the grid")
    func clamping() {
        let t = terminal(["hello"], cols: 10, rows: 4)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 500))
        #expect(s.start == Position(line: 0, col: 9))
        s.extend(to: Position(line: 9_999, col: -3))
        #expect(s.focus == Position(line: t.buffer.lastLine, col: 0))
        #expect(s.anchor == Position(line: 0, col: 9))
        #expect(s.start == Position(line: 0, col: 9))
        #expect(s.end == Position(line: t.buffer.lastLine, col: 0))
        #expect(s.columnRange(onLine: 0) == 9..<10)
        #expect(s.columnRange(onLine: 1) == 0..<10)
        #expect(s.columnRange(onLine: t.buffer.lastLine) == 0..<1)
    }

    // MARK: - word mode

    @Test("double click picks the word under the cell")
    func wordBasic() {
        let t = terminal(["hello world"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 7), mode: .word)
        #expect(s.mode == .word)
        #expect(s.start == Position(line: 0, col: 6))
        #expect(s.end == Position(line: 0, col: 10))
        #expect(s.text() == "world")
        // …and the first word from its first cell.
        let s2 = Selection(terminal: t)
        s2.begin(at: Position(line: 0, col: 0), mode: .word)
        #expect(s2.text() == "hello")
    }

    @Test("double click on a blank picks the run of blanks")
    func wordBlankRun() {
        let t = terminal(["a    b"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 3), mode: .word)
        #expect(s.start == Position(line: 0, col: 1))
        #expect(s.end == Position(line: 0, col: 4))
        #expect(s.columnRange(onLine: 0) == 1..<5)
        // Trailing never-written cells count as blanks too and stop at the 'b'.
        let s2 = Selection(terminal: t)
        s2.begin(at: Position(line: 0, col: 12), mode: .word)
        #expect(s2.start == Position(line: 0, col: 6))
        #expect(s2.end == Position(line: 0, col: 19))
    }

    @Test("word characters keep an IPv4 prefix together")
    func wordIPv4() {
        let t = terminal(["ping 10.0.0.1/24 ok"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 8), mode: .word)
        #expect(s.text() == "10.0.0.1/24")
    }

    @Test("word characters keep an interface name together")
    func wordInterfaceName() {
        let t = terminal(["port Gi1/0/1 up"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 6), mode: .word)
        #expect(s.text() == "Gi1/0/1")
        let s2 = Selection(terminal: t)
        s2.begin(at: Position(line: 0, col: 9), mode: .word)   // on a "/"
        #expect(s2.text() == "Gi1/0/1")
    }

    @Test("word characters keep an IPv6 address and snake/dash names together")
    func wordColonsAndDashes() {
        let t = terminal(["addr fe80::1 dev some_if-0"], cols: 40)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 7), mode: .word)
        #expect(s.text() == "fe80::1")
        let s2 = Selection(terminal: t)
        s2.begin(at: Position(line: 0, col: 20), mode: .word)
        #expect(s2.text() == "some_if-0")
    }

    @Test("wordCharacters is the documented default and is honoured live")
    func wordCharactersSetting() {
        #expect(Selection.wordCharacters == [".", "_", "-", ":", "/"])
        let saved = Selection.wordCharacters
        defer { Selection.wordCharacters = saved }
        Selection.wordCharacters = []
        let t = terminal(["ping 10.0.0.1 ok"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 5), mode: .word)
        #expect(s.text() == "10")
    }

    @Test("a non-word, non-bracket character selects just itself")
    func wordOther() {
        let t = terminal(["a = b"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 2), mode: .word)
        #expect(s.start == Position(line: 0, col: 2))
        #expect(s.end == Position(line: 0, col: 2))
        #expect(s.text() == "=")
    }

    @Test("an opening bracket selects to its balanced closer")
    func wordBalancedForward() {
        let t = terminal(["a (b [c] d) e"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 2), mode: .word)
        #expect(s.start == Position(line: 0, col: 2))
        #expect(s.end == Position(line: 0, col: 10))
        #expect(s.text() == "(b [c] d)")
        // The inner bracket balances on its own.
        let s2 = Selection(terminal: t)
        s2.begin(at: Position(line: 0, col: 5), mode: .word)
        #expect(s2.text() == "[c]")
    }

    @Test("a closing bracket selects back to its balanced opener")
    func wordBalancedBackward() {
        let t = terminal(["a (b [c] d) e"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 10), mode: .word)
        #expect(s.start == Position(line: 0, col: 2))
        #expect(s.end == Position(line: 0, col: 10))
        #expect(s.text() == "(b [c] d)")
        let s2 = Selection(terminal: t)
        s2.begin(at: Position(line: 0, col: 7), mode: .word)
        #expect(s2.text() == "[c]")
    }

    @Test("an unbalanced bracket selects only itself")
    func wordUnbalanced() {
        let t = terminal(["a ( b"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 2), mode: .word)
        #expect(s.start == Position(line: 0, col: 2))
        #expect(s.end == Position(line: 0, col: 2))
        #expect(s.text() == "(")
    }

    @Test("a balanced expression may span rows")
    func wordBalancedAcrossRows() {
        let t = terminal(["x (alpha", "beta) y"], cols: 12)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 2), mode: .word)
        #expect(s.start == Position(line: 0, col: 2))
        #expect(s.end == Position(line: 1, col: 4))
        #expect(s.text() == "(alpha\nbeta)")
    }

    @Test("a word run continues across a soft wrap, both ways")
    func wordAcrossSoftWrap() {
        let t = makeTerminal(cols: 10, rows: 6, scrollback: 20)
        t.feed(alphabet25)
        // Forward from the first row.
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 2), mode: .word)
        #expect(s.start == Position(line: 0, col: 0))
        #expect(s.end == Position(line: 2, col: 4))
        #expect(s.text() == alphabet25)
        // Backward from the last row.
        let s2 = Selection(terminal: t)
        s2.begin(at: Position(line: 2, col: 1), mode: .word)
        #expect(s2.start == Position(line: 0, col: 0))
        #expect(s2.end == Position(line: 2, col: 4))
        // A run does NOT continue across a hard break.
        let t2 = terminal(["abc", "def"], cols: 10)
        let s3 = Selection(terminal: t2)
        s3.begin(at: Position(line: 1, col: 0), mode: .word)
        #expect(s3.text() == "def")
    }

    @Test("word extend keeps the anchor word and adds whole words")
    func wordExtend() {
        let t = terminal(["alpha beta gamma"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 7), mode: .word)     // "beta"
        #expect(s.text() == "beta")
        s.extend(to: Position(line: 0, col: 12))                // inside "gamma"
        #expect(s.text() == "beta gamma")
        #expect(s.start == Position(line: 0, col: 6))
        #expect(s.end == Position(line: 0, col: 15))
        // Extending backwards past the anchor keeps the anchor word.
        s.extend(to: Position(line: 0, col: 1))                 // inside "alpha"
        #expect(s.text() == "alpha beta")
        #expect(s.start == Position(line: 0, col: 0))
        #expect(s.end == Position(line: 0, col: 9))
        #expect(s.anchor == Position(line: 0, col: 7))
    }

    // MARK: - line mode

    @Test("triple click takes the whole logical line")
    func lineMode() {
        let t = makeTerminal(cols: 10, rows: 6, scrollback: 20)
        t.feed(alphabet25)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 1, col: 4), mode: .line)
        #expect(s.mode == .line)
        #expect(s.start == Position(line: 0, col: 0))
        #expect(s.end == Position(line: 2, col: 9))
        #expect(s.columnRange(onLine: 0) == 0..<10)
        #expect(s.columnRange(onLine: 1) == 0..<10)
        #expect(s.columnRange(onLine: 2) == 0..<10)
        #expect(s.text() == alphabet25)
    }

    @Test("line mode extends by whole logical lines")
    func lineModeExtend() {
        let t = makeTerminal(cols: 10, rows: 8, scrollback: 20)
        t.feed("one\r\n")
        t.feed(alphabet25)          // lines 1…3, wrapped
        t.feed("\r\nlast")          // line 4
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 1), mode: .line)
        #expect(s.text() == "one")
        s.extend(to: Position(line: 2, col: 5))
        #expect(s.start == Position(line: 0, col: 0))
        #expect(s.end == Position(line: 3, col: 9))
        #expect(s.text() == "one\n" + alphabet25)
        // Extending backwards from a later anchor keeps that logical line whole.
        let s2 = Selection(terminal: t)
        s2.begin(at: Position(line: 4, col: 2), mode: .line)
        s2.extend(to: Position(line: 2, col: 0))
        #expect(s2.start == Position(line: 1, col: 0))
        #expect(s2.end == Position(line: 4, col: 9))
        #expect(s2.text() == alphabet25 + "\nlast")
    }

    // MARK: - block mode

    @Test("block mode selects a rectangle")
    func blockMode() {
        let t = terminal(["abcdefgh", "ijklmnop", "qrstuvwx"], cols: 12)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 2), mode: .block)
        s.extend(to: Position(line: 2, col: 4))
        #expect(s.mode == .block)
        #expect(s.start == Position(line: 0, col: 2))
        #expect(s.end == Position(line: 2, col: 4))
        #expect(s.columnRange(onLine: 0) == 2..<5)
        #expect(s.columnRange(onLine: 1) == 2..<5)
        #expect(s.columnRange(onLine: 2) == 2..<5)
        #expect(s.columnRange(onLine: 3) == nil)
        #expect(s.text() == "cde\nklm\nstu")
        #expect(s.contains(Position(line: 1, col: 3)))
        #expect(!s.contains(Position(line: 1, col: 5)))
    }

    @Test("a block dragged up and left normalises its corners")
    func blockNormalises() {
        let t = terminal(["abcdefgh", "ijklmnop", "qrstuvwx"], cols: 12)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 2, col: 4), mode: .block)
        s.extend(to: Position(line: 0, col: 2))
        #expect(s.start == Position(line: 0, col: 2))
        #expect(s.end == Position(line: 2, col: 4))
        #expect(s.text() == "cde\nklm\nstu")
    }

    @Test("block mode right-trims each row and always joins with newlines")
    func blockTrimsRows() {
        let t = makeTerminal(cols: 10, rows: 6, scrollback: 20)
        t.feed(alphabet25)          // three soft-wrapped rows
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 3), mode: .block)
        s.extend(to: Position(line: 2, col: 6))
        #expect(s.text() == "defg\nnopq\nxy")
    }

    // MARK: - wide characters

    @Test("a bound on the trailing half of a wide char moves to its head")
    func wideStartOnSpacer() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 20)
        t.feed("a漢字b")
        let b = t.buffer
        #expect(b.row(line: 0)?.cell(at: 1).width == 2)
        #expect(b.row(line: 0)?.cell(at: 2).isSpacer == true)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 2))          // the spacer of 漢
        #expect(s.start == Position(line: 0, col: 1))
        #expect(s.end == Position(line: 0, col: 2))     // the head pulls its spacer in
        #expect(s.text() == "漢")
        #expect(s.columnRange(onLine: 0) == 1..<3)
    }

    @Test("an end on a wide head takes the spacer too")
    func wideEndOnHead() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 20)
        t.feed("a漢字b")
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0))
        s.extend(to: Position(line: 0, col: 3))         // head of 字
        #expect(s.end == Position(line: 0, col: 4))
        #expect(s.text() == "a漢字")
        #expect(s.columnRange(onLine: 0) == 0..<5)
    }

    @Test("a block never cuts a wide character in half")
    func wideInBlock() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 20)
        t.feed("a漢字b\r\nxyzwv")
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 2), mode: .block)
        s.extend(to: Position(line: 1, col: 3))
        // The rectangle is cols 2…3, widened on row 0 to 1…4 so both wide
        // characters stay whole; row 1 has no wide characters and stays 2…3.
        #expect(s.columnRange(onLine: 0) == 1..<5)
        #expect(s.columnRange(onLine: 1) == 2..<4)
        #expect(s.text() == "漢字\nzw")
    }

    @Test("a wide-character run is one word")
    func wideWord() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 20)
        t.feed("a漢字b")
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 1), mode: .word)
        // Letters and CJK are all "word" characters, so the whole run goes.
        #expect(s.text() == "a漢字b")
        // …and clicking on the spacer gives the same answer.
        let s2 = Selection(terminal: t)
        s2.begin(at: Position(line: 0, col: 2), mode: .word)
        #expect(s2.text() == "a漢字b")
    }

    // MARK: - combining marks

    @Test("combining marks come back with their base character")
    func combiningMarks() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 20)
        t.feed("cafe\u{301} x")
        let b = t.buffer
        #expect(b.row(line: 0)?.cell(at: 3).isCombined == true)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0))
        s.extend(to: Position(line: 0, col: 3))
        #expect(s.text() == "cafe\u{301}")
        // A combined cell still classifies as a letter for word selection.
        let s2 = Selection(terminal: t)
        s2.begin(at: Position(line: 0, col: 3), mode: .word)
        #expect(s2.text() == "cafe\u{301}")
    }

    // MARK: - scrolling, validity, selectAll

    @Test("a selection survives output scrolling untouched")
    func survivesScrolling() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 40)
        t.feed("target\r\n")
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0), mode: .word)
        #expect(s.text() == "target")
        let startBefore = s.start
        for i in 0..<20 { t.feed("filler\(i)\r\n") }
        #expect(t.buffer.ybase > 0)
        #expect(s.start == startBefore)
        #expect(s.text() == "target")          // same line number, same text
        #expect(s.validate())
    }

    @Test("validate drops a selection that fell off the top")
    func validateDropsFallenSelection() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 8)
        t.feed("gone\r\n")
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0), mode: .word)
        #expect(s.text() == "gone")
        // ED 3 throws away everything above the screen.
        for i in 0..<8 { t.feed("more\(i)\r\n") }
        t.feed("\u{1b}[3J")
        #expect(t.buffer.firstLine > 0)
        #expect(!s.validate())
        #expect(!s.isActive)
        #expect(s.start == nil)
        #expect(s.text() == "")
    }

    @Test("validate clips a selection that only partly fell off")
    func validateClipsPartialSelection() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 8)
        for i in 0..<8 { t.feed("row\(i)\r\n") }
        let b = t.buffer
        #expect(b.ybase > 0)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0))
        s.extend(to: Position(line: b.lastLine, col: 9))
        t.feed("\u{1b}[3J")                    // clear scrollback
        let first = t.buffer.firstLine
        #expect(first > 0)
        #expect(s.validate())
        #expect(s.isActive)
        #expect(s.start == Position(line: first, col: 0))
        #expect(s.end?.line == t.buffer.lastLine)
    }

    @Test("validate on an inactive selection is false")
    func validateInactive() {
        let t = terminal(["hi"])
        let s = Selection(terminal: t)
        #expect(!s.validate())
        s.begin(at: Position(line: 0, col: 0))
        #expect(s.validate())
        s.clear()
        #expect(!s.validate())
    }

    @Test("selectAll covers the scrollback and the screen")
    func selectAllCoversHistory() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 40)
        for i in 0..<10 { t.feed("row\(i)\r\n") }
        let b = t.buffer
        #expect(b.ybase > 0)
        let s = Selection(terminal: t)
        s.selectAll()
        #expect(s.isActive)
        #expect(s.mode == .character)
        #expect(s.start == Position(line: b.firstLine, col: 0))
        #expect(s.end == Position(line: b.lastLine, col: b.cols - 1))
        #expect(s.lineRange == b.firstLine...b.lastLine)
        let text = s.text()
        #expect(text.hasPrefix("row0\nrow1\n"))
        #expect(text.contains("row9"))
    }

    @Test("clear resets everything")
    func clearResets() {
        let t = terminal(["hello"])
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0), mode: .word)
        #expect(s.isActive)
        s.clear()
        #expect(!s.isActive)
        #expect(s.mode == .character)
        #expect(s.anchor == nil)
        #expect(s.focus == nil)
        #expect(s.start == nil)
        #expect(s.end == nil)
        #expect(s.text() == "")
        #expect(s.columnRange(onLine: 0) == nil)
        #expect(s.lineRange == nil)
        #expect(!s.contains(Position(line: 0, col: 0)))
        // extend after clear does nothing (the gesture is over).
        s.extend(to: Position(line: 0, col: 3))
        #expect(!s.isActive)
    }

    @Test("everything is a no-op once the terminal is gone")
    func deadTerminal() {
        var t: Terminal? = terminal(["hello"])
        let s = Selection(terminal: t!)
        s.begin(at: Position(line: 0, col: 0))
        s.extend(to: Position(line: 0, col: 4))
        #expect(s.text() == "hello")
        t = nil
        #expect(s.terminal == nil)
        s.extend(to: Position(line: 0, col: 2))     // no crash, no change
        #expect(s.text() == "")
        #expect(!s.validate())
        s.begin(at: Position(line: 0, col: 0))
        #expect(!s.isActive)
        s.selectAll()
        #expect(!s.isActive)
    }

    @Test("the alternate screen selects from the alternate buffer")
    func alternateBuffer() {
        let t = makeTerminal(cols: 10, rows: 4, scrollback: 20)
        t.feed("primary\r\n")
        t.feed("\u{1b}[?1049h\u{1b}[H")     // to the alternate screen, cursor home
        t.feed("alt text")
        #expect(t.isAlternate)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0), mode: .line)
        #expect(s.text() == "alt text")
        t.feed("\u{1b}[?1049l")
        #expect(!t.isAlternate)
    }

    @Test("a selection over never-materialised rows is blank, not a crash")
    func blankRows() {
        let t = makeTerminal(cols: 10, rows: 6, scrollback: 20)
        t.feed("top")
        let s = Selection(terminal: t)
        s.begin(at: Position(line: 0, col: 0))
        s.extend(to: Position(line: 4, col: 9))
        #expect(s.text() == "top\n\n\n\n")
        let s2 = Selection(terminal: t)
        s2.begin(at: Position(line: 3, col: 2), mode: .word)
        #expect(s2.start == Position(line: 3, col: 0))
        #expect(s2.end == Position(line: 3, col: 9))
        #expect(s2.text() == "")
    }

    // MARK: - a scroll region that renumbers lines
    //
    // A top-anchored region whose bottom margin is above the last row pushes its
    // vacated line into history and then moves the blank back down to the bottom
    // of the *region* (`Buffer.scrollUp`, xterm.js's rule, kept for device
    // pagers). That move renumbers every row below the margin without touching
    // its text — a vim/tmux status line, or any pager footer. The selection has
    // to follow, and only there.

    /// One screen of `rowN-KEEPME`, `rows` lines tall, cursor-addressed so no
    /// scrolling happens on the way in.
    private func keepMeScreen(cols: Int = 14, rows: Int = 6, scrollback: Int = 50) -> Terminal {
        let t = makeTerminal(cols: cols, rows: rows, scrollback: scrollback)
        for r in 1...rows { t.feed("\u{1b}[\(r);1Hrow\(r)-KEEPME") }
        return t
    }

    @Test("a region scroll into history carries a selection below the margin")
    func regionScrollBelowMarginFollowsItsText() {
        let t = keepMeScreen()
        let b = t.buffer
        let line6 = b.lineNumber(atIndex: b.ybase + 5)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: line6, col: 0), mode: .word)
        #expect(s.text() == "row6-KEEPME")

        t.feed("\u{1b}[1;5r")     // DECSTBM 1..5: bottom margin above the last row
        t.feed("\u{1b}[S")        // scroll the region up once

        #expect(s.text() == "row6-KEEPME")
        #expect(s.start?.line == line6 + 1)
        #expect(s.end?.line == line6 + 1)
        // The number the selection used to hold now belongs to the blank at the
        // bottom of the region, which is exactly why it had to move. (A blank
        // row is never materialised, so `row(line:)` answers nil for it.)
        #expect(b.row(line: line6)?.string() ?? "" == "")
        #expect(b.row(line: line6 + 1)?.string() == "row6-KEEPME")
    }

    @Test("a region scroll into history leaves the rows above the margin alone")
    func regionScrollAboveMarginDoesNotShift() {
        let t = keepMeScreen()
        let b = t.buffer
        let line1 = b.lineNumber(atIndex: b.ybase)        // scrolls into history
        let line5 = b.lineNumber(atIndex: b.ybase + 4)    // last row of the region
        let inHistory = Selection(terminal: t)
        inHistory.begin(at: Position(line: line1, col: 0), mode: .word)
        let inRegion = Selection(terminal: t)
        inRegion.begin(at: Position(line: line5, col: 0), mode: .word)

        t.feed("\u{1b}[1;5r\u{1b}[S")

        #expect(inHistory.start?.line == line1)
        #expect(inHistory.text() == "row1-KEEPME")
        #expect(inRegion.start?.line == line5)
        #expect(inRegion.text() == "row5-KEEPME")
    }

    @Test("a selection spanning the margin keeps both halves")
    func regionScrollSelectionSpanningTheMargin() {
        let t = keepMeScreen()
        let b = t.buffer
        let line5 = b.lineNumber(atIndex: b.ybase + 4)
        let line6 = line5 + 1
        let s = Selection(terminal: t)
        s.begin(at: Position(line: line5, col: 0))
        s.extend(to: Position(line: line6, col: 10))
        #expect(s.text() == "row5-KEEPME\nrow6-KEEPME")

        t.feed("\u{1b}[1;5r\u{1b}[S")

        // The start is inside the region and kept its number; the end was below
        // the margin and moved with its text. Both ends still cover the text
        // the user picked — and the region's new blank bottom row is now
        // *between* them, so the range honestly grew by that blank line. A
        // start/end selection cannot say "these two rows but not the one that
        // appeared between them", and neither can the user's eyes: on screen
        // the highlight is contiguous.
        #expect(s.start?.line == line5)
        #expect(s.end?.line == line6 + 1)
        #expect(s.text() == "row5-KEEPME\n\nrow6-KEEPME")
    }

    @Test("several region scrolls in one feed each shift the selection")
    func regionScrollRepeatedInOneFeed() {
        let t = keepMeScreen()
        let b = t.buffer
        let line6 = b.lineNumber(atIndex: b.ybase + 5)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: line6, col: 0), mode: .word)

        t.feed("\u{1b}[1;5r\u{1b}[3S")

        #expect(s.start?.line == line6 + 3)
        #expect(s.text() == "row6-KEEPME")
    }

    @Test("a region scroll that trims the ring still lands the selection right")
    func regionScrollWhileTheRingTrims() {
        // Two lines of scrollback and six rows: the ring is full after two
        // full-screen scrolls, so the region scroll below recycles the oldest
        // line instead of growing (`trimmed` moves, `ybase` does not).
        let t = makeTerminal(cols: 14, rows: 6, scrollback: 2)
        t.feed(String(repeating: "\r\n", count: 7))
        for r in 1...6 { t.feed("\u{1b}[\(r);1Hrow\(r)-KEEPME") }
        let b = t.buffer
        #expect(b.lineCount == b.lines.maxLength)   // full: the next push trims

        let line6 = b.lineNumber(atIndex: b.ybase + 5)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: line6, col: 0), mode: .word)
        #expect(s.text() == "row6-KEEPME")

        let trimmedBefore = b.firstLine
        t.feed("\u{1b}[1;5r\u{1b}[S")
        #expect(b.firstLine == trimmedBefore + 1)   // a line really did fall off
        #expect(s.start?.line == line6 + 1)
        #expect(s.text() == "row6-KEEPME")
    }

    @Test("an ordinary full-screen scroll still moves nothing")
    func fullScreenScrollDoesNotShift() {
        let t = keepMeScreen()
        let b = t.buffer
        let line6 = b.lineNumber(atIndex: b.ybase + 5)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: line6, col: 0), mode: .word)

        t.feed("\u{1b}[6;1H\n")   // LF at the bottom row: the whole screen scrolls

        #expect(s.start?.line == line6)
        #expect(s.text() == "row6-KEEPME")
    }

    @Test("a region scroll that stays inside the region shifts nothing")
    func inRegionScrollDoesNotShift() {
        // scrollTop > 0, so nothing goes into history and no line is renumbered:
        // the rows move between fixed line numbers, which is what a region
        // scroll means everywhere. The selection must NOT be corrected for that.
        let t = keepMeScreen()
        let b = t.buffer
        let line1 = b.lineNumber(atIndex: b.ybase)        // above the region
        let line2 = b.lineNumber(atIndex: b.ybase + 1)    // top of the region
        let line6 = b.lineNumber(atIndex: b.ybase + 5)    // below the region
        let above = Selection(terminal: t)
        above.begin(at: Position(line: line1, col: 0), mode: .word)
        let inside = Selection(terminal: t)
        inside.begin(at: Position(line: line2, col: 0), mode: .word)
        let below = Selection(terminal: t)
        below.begin(at: Position(line: line6, col: 0), mode: .word)

        t.feed("\u{1b}[2;5r\u{1b}[S")

        #expect(above.start?.line == line1)
        #expect(above.text() == "row1-KEEPME")
        #expect(below.start?.line == line6)
        #expect(below.text() == "row6-KEEPME")
        // Inside the region the text moved and the numbers did not: the
        // selection stays where it was and now covers the row that came up.
        #expect(inside.start?.line == line2)
        #expect(inside.text() == "row3-KEEPME")
    }

    @Test("scrollDown never renumbers, so the selection stays put")
    func regionScrollDownDoesNotShift() {
        let t = keepMeScreen()
        let b = t.buffer
        let line6 = b.lineNumber(atIndex: b.ybase + 5)
        let s = Selection(terminal: t)
        s.begin(at: Position(line: line6, col: 0), mode: .word)

        t.feed("\u{1b}[1;5r\u{1b}[T")   // top-anchored region, scrolled DOWN

        #expect(s.start?.line == line6)
        #expect(s.text() == "row6-KEEPME")
    }
}
