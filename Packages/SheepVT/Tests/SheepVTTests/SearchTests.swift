// SheepVT — search engine tests (agent C's contract: SearchOptions,
// SearchMatch, SearchEngine).
//
// Every test drives a real `Terminal` through the parser so the grid, the
// wrapped flags and the wide/combined cells are the ones the emulator actually
// produces — never a hand-built Row.

import Testing
@testable import SheepVT

// MARK: - helpers

private func makeTerminal(cols: Int = 20, rows: Int = 6, scrollback: Int = 100,
                          text: String = "") -> Terminal {
    let t = Terminal(cols: cols, rows: rows, scrollback: scrollback)
    if !text.isEmpty { t.feed(text) }
    return t
}

private func engine(_ t: Terminal, _ term: String,
                    caseSensitive: Bool = false, regex: Bool = false,
                    wholeWord: Bool = false) -> SearchEngine {
    let e = SearchEngine(terminal: t)
    e.options = SearchOptions(caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord)
    e.term = term
    return e
}

/// (line, col) pairs of every match, for compact expectations.
private func pairs(_ ms: [SearchMatch]) -> [[Int]] {
    ms.map { [$0.start.line, $0.start.col, $0.end.line, $0.end.col] }
}

/// Step through the buffer with `findNext` once per match, then back with
/// `findPrevious`, and check the walk visits exactly `expected` in order and
/// wraps at both ends. This is the invariant the limit used to break: the walk
/// is not allowed to know anything about how much of the buffer `findAll`
/// would have painted.
private func navigationEnumerates(_ e: SearchEngine, expected: [SearchMatch]) -> Bool {
    guard let firstExpected = expected.first, let lastExpected = expected.last else {
        return e.findNext(after: nil) == nil && e.findPrevious(before: nil) == nil
    }
    var forward: [SearchMatch] = []
    var p: Position?
    for _ in expected.indices {
        guard let m = e.findNext(after: p) else { return false }
        forward.append(m)
        p = m.start
    }
    guard forward == expected, e.findNext(after: p)?.start == firstExpected.start else { return false }

    var backward: [SearchMatch] = []
    p = nil
    for _ in expected.indices {
        guard let m = e.findPrevious(before: p) else { return false }
        backward.append(m)
        p = m.start
    }
    return backward == expected.reversed() && e.findPrevious(before: p)?.start == lastExpected.start
}

@Suite("Search")
struct SearchTests {

    // MARK: - plain matching

    @Test("a plain substring match reports inclusive head cells")
    func plainSingle() {
        let t = makeTerminal(text: "hello world")
        let e = engine(t, "world")
        let all = e.findAll()
        #expect(all.count == 1)
        #expect(all.first?.start == Position(line: 0, col: 6))
        #expect(all.first?.end == Position(line: 0, col: 10))
    }

    @Test("search is case-insensitive by default")
    func caseInsensitiveDefault() {
        let t = makeTerminal(text: "Hello World")
        #expect(engine(t, "WORLD").findAll().count == 1)
        #expect(engine(t, "hello").findAll().count == 1)
    }

    @Test("caseSensitive requires an exact case match")
    func caseSensitive() {
        let t = makeTerminal(text: "Hello World")
        #expect(engine(t, "world", caseSensitive: true).findAll().isEmpty)
        #expect(engine(t, "World", caseSensitive: true).findAll().count == 1)
    }

    @Test("several matches on one line come back in reading order")
    func multiplePerLine() {
        let t = makeTerminal(text: "ab ab ab")
        #expect(pairs(engine(t, "ab").findAll()) == [[0, 0, 0, 1], [0, 3, 0, 4], [0, 6, 0, 7]])
    }

    @Test("overlapping matches are not reported")
    func nonOverlapping() {
        let t = makeTerminal(text: "aaaa")
        #expect(pairs(engine(t, "aa").findAll()) == [[0, 0, 0, 1], [0, 2, 0, 3]])
    }

    @Test("matches on several lines come back top to bottom")
    func multipleLines() {
        let t = makeTerminal(text: "one hit\r\nno\r\nanother hit here")
        #expect(pairs(engine(t, "hit").findAll()) == [[0, 4, 0, 6], [2, 8, 2, 10]])
    }

    @Test("a term that is not there yields nothing")
    func noMatch() {
        let t = makeTerminal(text: "hello")
        #expect(engine(t, "zzz").findAll().isEmpty)
        #expect(engine(t, "zzz").findNext(after: nil) == nil)
        #expect(engine(t, "zzz").findPrevious(before: nil) == nil)
    }

    @Test("trailing blank cells are not searchable text")
    func blankCellsAreNotText() {
        let t = makeTerminal(text: "ab")
        // Two spaces would only exist if the empty rest of the row counted.
        #expect(engine(t, "  ").findAll().isEmpty)
        // Real printed spaces do count.
        let t2 = makeTerminal(text: "a  b")
        #expect(engine(t2, "  ").findAll().count == 1)
    }

    // MARK: - whole word

    @Test("wholeWord rejects matches glued to letters")
    func wholeWord() {
        let t = makeTerminal(cols: 40, text: "cat concat cats cat.")
        let all = engine(t, "cat", wholeWord: true).findAll()
        #expect(pairs(all) == [[0, 0, 0, 2], [0, 16, 0, 18]])
        #expect(engine(t, "cat").findAll().count == 4)
    }

    @Test("wholeWord treats digits and underscore as word characters")
    func wholeWordUnderscoreAndDigits() {
        let t = makeTerminal(cols: 40, text: "foo_bar foo2 foo")
        #expect(pairs(engine(t, "foo", wholeWord: true).findAll()) == [[0, 13, 0, 15]])
    }

    @Test("wholeWord allows punctuation neighbours")
    func wholeWordPunctuation() {
        let t = makeTerminal(cols: 40, text: "(ip) ip/24 ip")
        #expect(engine(t, "ip", wholeWord: true).findAll().count == 3)
    }

    // MARK: - regex

    @Test("regex matches a pattern")
    func regexBasic() {
        let t = makeTerminal(cols: 40, text: "ip 10.0.0.1 up")
        let all = engine(t, "[0-9]+", regex: true).findAll()
        #expect(all.count == 4)
        #expect(all.first?.start == Position(line: 0, col: 3))
        #expect(all.first?.end == Position(line: 0, col: 4))
    }

    @Test("regex ignores case unless caseSensitive is set")
    func regexCase() {
        let t = makeTerminal(text: "Ethernet0")
        #expect(engine(t, "ethernet", regex: true).findAll().count == 1)
        #expect(engine(t, "ethernet", caseSensitive: true, regex: true).findAll().isEmpty)
    }

    @Test("regex honours wholeWord too")
    func regexWholeWord() {
        let t = makeTerminal(cols: 40, text: "up upstream up")
        #expect(engine(t, "up", regex: true, wholeWord: true).findAll().count == 2)
    }

    @Test("an invalid regex is not valid and never matches")
    func invalidRegex() {
        let t = makeTerminal(text: "hello")
        let e = engine(t, "[unclosed", regex: true)
        #expect(!e.isValid)
        #expect(e.findAll().isEmpty)
        #expect(e.findNext(after: nil) == nil)
        #expect(e.findPrevious(before: nil) == nil)
        // The same term is a perfectly good literal.
        e.options = SearchOptions()
        #expect(e.isValid)
    }

    @Test("an empty term is not valid")
    func emptyTerm() {
        let t = makeTerminal(text: "hello")
        let e = engine(t, "")
        #expect(!e.isValid)
        #expect(e.findAll().isEmpty)
        #expect(e.matches(onLine: 0).isEmpty)
    }

    @Test("a zero-width regex match is ignored")
    func zeroWidthRegex() {
        let t = makeTerminal(text: "abc")
        let e = engine(t, "x*", regex: true)
        #expect(e.isValid)
        #expect(e.findAll().isEmpty)
    }

    // MARK: - limit

    @Test("limit caps findAll")
    func limit() {
        let t = makeTerminal(cols: 40, text: "a a a a a a a")
        let e = engine(t, "a")
        #expect(e.findAll().count == 7)
        #expect(e.findAll(limit: 3).count == 3)
        #expect(e.findAll(limit: 1) == [e.findAll().first!])
        #expect(e.findAll(limit: 0).isEmpty)
        #expect(SearchEngine.defaultLimit == 1000)
    }

    // MARK: - next / previous

    @Test("findNext walks forward and wraps to the top")
    func findNext() {
        let t = makeTerminal(text: "ab\r\nab\r\nab")
        let e = engine(t, "ab")
        let first = e.findNext(after: nil)
        #expect(first?.start == Position(line: 0, col: 0))
        #expect(e.findNext(after: first?.start)?.start == Position(line: 1, col: 0))
        #expect(e.findNext(after: Position(line: 1, col: 0))?.start == Position(line: 2, col: 0))
        // past the last one → wrap
        #expect(e.findNext(after: Position(line: 2, col: 0))?.start == Position(line: 0, col: 0))
    }

    @Test("findPrevious walks back and wraps to the bottom")
    func findPrevious() {
        let t = makeTerminal(text: "ab\r\nab\r\nab")
        let e = engine(t, "ab")
        #expect(e.findPrevious(before: nil)?.start == Position(line: 2, col: 0))
        #expect(e.findPrevious(before: Position(line: 2, col: 0))?.start == Position(line: 1, col: 0))
        #expect(e.findPrevious(before: Position(line: 1, col: 0))?.start == Position(line: 0, col: 0))
        // before the first one → wrap
        #expect(e.findPrevious(before: Position(line: 0, col: 0))?.start == Position(line: 2, col: 0))
    }

    @Test("next/previous are strict about the position they are given")
    func strictBounds() {
        let t = makeTerminal(cols: 40, text: "xx yy xx")
        let e = engine(t, "xx")
        // a position inside the first match is still "before" the second
        #expect(e.findNext(after: Position(line: 0, col: 0))?.start == Position(line: 0, col: 6))
        #expect(e.findPrevious(before: Position(line: 0, col: 6))?.start == Position(line: 0, col: 0))
        // a position exactly on a match start does not return that match
        #expect(e.findPrevious(before: Position(line: 0, col: 0))?.start == Position(line: 0, col: 6))
    }

    // MARK: - navigation past the limit

    @Test("navigation reaches the matches past the findAll limit, in both directions")
    func navigationPastTheLimit() {
        // 1,100 lines, one match each: a hundred of them sit past
        // `defaultLimit` and are simply not in the painted list. Navigation
        // used to walk that list, so `next` at the thousandth wrapped to the
        // top and `previous` from the bottom started at the thousandth.
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 1200)
        for _ in 0..<1100 { t.feed("target\r\n") }
        let e = engine(t, "target")

        #expect(t.buffer.firstLine == 0)                      // nothing trimmed yet
        #expect(e.findAll().count == SearchEngine.defaultLimit)   // the cap is untouched

        #expect(e.findNext(after: Position(line: 999, col: 0))?.start == Position(line: 1000, col: 0))
        #expect(e.findNext(after: Position(line: 1050, col: 0))?.start == Position(line: 1051, col: 0))
        #expect(e.findPrevious(before: nil)?.start == Position(line: 1099, col: 0))
        #expect(e.findPrevious(before: Position(line: 1099, col: 0))?.start == Position(line: 1098, col: 0))
        // and the wrap at each end still happens at the real ends
        #expect(e.findNext(after: Position(line: 1099, col: 0))?.start == Position(line: 0, col: 0))
        #expect(e.findPrevious(before: Position(line: 0, col: 0))?.start == Position(line: 1099, col: 0))
    }

    @Test("stepping through every match enumerates the whole buffer, past the limit")
    func navigationEnumeratesEverything() {
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 1200)
        for _ in 0..<1100 { t.feed("target\r\n") }
        let e = engine(t, "target")
        #expect(navigationEnumerates(e, expected: e.findAll(limit: 20_000)))

        // More output than the ring holds: every line number moves under the
        // caches and the top of the scrollback is gone.
        for _ in 0..<400 { t.feed("target\r\n") }
        #expect(t.buffer.firstLine > 0)
        #expect(navigationEnumerates(e, expected: e.findAll(limit: 20_000)))

        // A resize reflows and renumbers arbitrarily; the walk still visits
        // exactly what a full findAll reports.
        t.resize(cols: 12, rows: 6)
        #expect(navigationEnumerates(e, expected: e.findAll(limit: 20_000)))
        t.resize(cols: 40, rows: 10)
        #expect(navigationEnumerates(e, expected: e.findAll(limit: 20_000)))
    }

    @Test("navigation walks a soft-wrapped line from anywhere inside it")
    func navigationInsideAWrappedLine() {
        // One logical line over several rows with a match on the last of them:
        // a walk that started at the row `p` sits on instead of the head of the
        // logical line would never build that line at all.
        let t = makeTerminal(cols: 10, rows: 8, scrollback: 100)
        t.feed(String(repeating: ".", count: 35) + "target")
        let e = engine(t, "target")
        let all = e.findAll()
        #expect(all.count == 1)
        let m = all[0]
        #expect(m.start.line > 0)                              // really past the first row
        #expect(e.findNext(after: Position(line: m.start.line, col: 0))?.start == m.start)
        #expect(e.findPrevious(before: Position(line: m.start.line, col: m.start.col + 1))?.start
                == m.start)
    }

    // MARK: - a pattern that never answers

    @Test("a catastrophic regex is abandoned instead of hanging the caller")
    func catastrophicRegexIsAbandoned() {
        // `(a+)+b` over a line of `a` with no `b`: measured at 1.4 s for
        // sixteen characters and "did not finish in three seconds" for twenty
        // before there was a deadline. All of it was spent inside
        // `text.matches(of:)` on the caller's thread.
        let t = makeTerminal(cols: 40, text: String(repeating: "a", count: 24))
        let e = engine(t, "(a+)+b", regex: true)
        #expect(e.isValid)

        let clock = ContinuousClock()
        // It answers. `LinearRegex` runs every input in instructions x scalars,
        // so the pattern that could not be stopped is now an ordinary search
        // that finds nothing — no deadline, no abandoned matcher, no flag.
        let first = clock.measure { #expect(e.findAll().isEmpty) }
        #expect(first < .milliseconds(50))
        #expect(e.regexProblem == nil)
        #expect(e.findNext(after: nil) == nil)
        #expect(e.findPrevious(before: nil) == nil)
        #expect(e.matches(onLine: 0).isEmpty)

        e.term = "a+"
        let sane = clock.measure { #expect(e.findAll().count == 1) }
        #expect(sane < .seconds(1))
        #expect(e.regexProblem == nil)

        // And the constructs the engine refuses are reported as refusals, not
        // as "not found": a search that never ran must not read like one that
        // ran and came back empty.
        e.term = "(a) \\1"
        #expect(!e.isValid)
        #expect(e.regexProblem == .unsupported)
        e.term = "a(?=b)"
        #expect(e.regexProblem == .unsupported)
        e.term = "[a"
        #expect(e.regexProblem == .malformed)
        // The verdict survives everything that does not change the pattern.
        // `invalidate()` runs on a resize and on an alt-screen switch as well
        // as on a new term, and clearing the verdict there sent the find bar
        // back to saying "not found" about a pattern that had never run.
        e.invalidate()
        #expect(e.regexProblem == .malformed)
        e.options = SearchOptions(caseSensitive: false, regex: true, wholeWord: true)
        #expect(e.regexProblem == .malformed)
        // A real change to the pattern gets a fresh verdict.
        e.term = "a+"
        #expect(e.regexProblem == nil)
        #expect(e.isValid)
    }

    // MARK: - matches(onLine:)

    @Test("matches(onLine:) gives the renderer half-open column ranges")
    func matchesOnLine() {
        let t = makeTerminal(cols: 40, text: "abc def\r\nno hits here\r\nabc")
        let e = engine(t, "abc")
        _ = e.findAll()
        #expect(e.matches(onLine: 0) == [0..<3])
        #expect(e.matches(onLine: 1).isEmpty)
        #expect(e.matches(onLine: 2) == [0..<3])
        #expect(e.matches(onLine: 99).isEmpty)
    }

    @Test("matches(onLine:) covers the spacer of a wide last character")
    func matchesOnLineWide() {
        let t = makeTerminal(text: "\u{4E2D}\u{6587}ok")
        let e = engine(t, "\u{6587}")
        #expect(pairs(e.findAll()) == [[0, 2, 0, 2]])
        #expect(e.matches(onLine: 0) == [2..<4])
    }

    @Test("matches(onLine:) reports every line a wrapped match touches")
    func matchesOnLineWrapped() {
        // 20 columns: row 0 = a…t, row 1 = u…y
        let t = makeTerminal(cols: 20, text: "abcdefghijklmnopqrstuvwxy")
        let e = engine(t, "stuv")
        #expect(pairs(e.findAll()) == [[0, 18, 1, 1]])
        #expect(e.matches(onLine: 0) == [18..<20])
        #expect(e.matches(onLine: 1) == [0..<2])
    }

    // MARK: - wrapped lines

    @Test("a match crosses a soft wrap")
    func acrossWrap() {
        let t = makeTerminal(cols: 20, text: "abcdefghijklmnopqrstuvwxy")
        #expect(t.buffer.row(line: 1)?.wrapped == true)
        let all = engine(t, "tu").findAll()
        #expect(all.count == 1)
        #expect(all.first?.start == Position(line: 0, col: 19))
        #expect(all.first?.end == Position(line: 1, col: 0))
    }

    @Test("a term longer than a row spans two wrapped rows")
    func termLongerThanRow() {
        let t = makeTerminal(cols: 10, rows: 6,
                             text: "0123456789abcdefghijklmno")
        let all = engine(t, "56789abcdefg").findAll()
        #expect(all.count == 1)
        #expect(all.first?.start == Position(line: 0, col: 5))
        #expect(all.first?.end == Position(line: 1, col: 6))
    }

    @Test("a match may start on the very last cell of a row")
    func startOnLastCell() {
        let t = makeTerminal(cols: 20, text: "abcdefghijklmnopqrstuvwxy")
        let all = engine(t, "tuv").findAll()
        #expect(all.first?.start == Position(line: 0, col: 19))
        #expect(all.first?.end == Position(line: 1, col: 1))
    }

    @Test("a wide character pushed to the next row leaves no phantom space")
    func wideAtWrapBoundary() {
        // 19 ASCII cells then a wide char: it does not fit at column 19, so the
        // last cell of row 0 stays blank and the character moves to row 1.
        let t = makeTerminal(cols: 20, text: "abcdefghijklmnopqrs\u{4E2D}")
        #expect(t.buffer.row(line: 1)?.wrapped == true)
        let all = engine(t, "s\u{4E2D}").findAll()
        #expect(all.count == 1)
        #expect(all.first?.start == Position(line: 0, col: 18))
        #expect(all.first?.end == Position(line: 1, col: 0))
        // The blank cell is not text: "s " must not match.
        #expect(engine(t, "s ").findAll().isEmpty)
    }

    @Test("real blanks inside a wrapped line are searchable")
    func blanksInsideWrappedLine() {
        let t = makeTerminal(cols: 10, rows: 6, text: "abc def ghijkl")
        #expect(t.buffer.row(line: 1)?.wrapped == true)
        #expect(pairs(engine(t, "ghi").findAll()) == [[0, 8, 1, 0]])
    }

    // MARK: - unicode

    @Test("wide characters before a match shift its columns")
    func wideShiftsColumns() {
        let t = makeTerminal(text: "\u{4E2D}\u{6587}hello")
        let all = engine(t, "hello").findAll()
        #expect(all.first?.start == Position(line: 0, col: 4))
        #expect(all.first?.end == Position(line: 0, col: 8))
    }

    @Test("a CJK term matches and its bounds land on head cells")
    func cjkTerm() {
        let t = makeTerminal(text: "ok\u{4E2D}\u{6587}ok")
        let all = engine(t, "\u{4E2D}\u{6587}").findAll()
        #expect(all.count == 1)
        #expect(all.first?.start == Position(line: 0, col: 2))
        #expect(all.first?.end == Position(line: 0, col: 4))
        #expect(t.buffer.row(line: 0)?[4].width == 2)   // end is the head, not the spacer
    }

    @Test("Thai combining marks live in one cell and map back to it")
    func thaiCombining() {
        // ก + ิ (a combining vowel) share one cell; น is the next cell.
        let t = makeTerminal(text: "\u{0E01}\u{0E34}\u{0E19} ok")
        let row = t.buffer.row(line: 0)
        #expect(row?[0].isCombined == true)
        let all = engine(t, "\u{0E01}\u{0E34}\u{0E19}").findAll()
        #expect(all.count == 1)
        #expect(all.first?.start == Position(line: 0, col: 0))
        #expect(all.first?.end == Position(line: 0, col: 1))
    }

    @Test("a match starting inside a combined cell keeps that cell's column")
    func combinedCellColumns() {
        let t = makeTerminal(text: "x\u{0E01}\u{0E34}y")
        let all = engine(t, "\u{0E01}\u{0E34}y").findAll()
        #expect(all.first?.start == Position(line: 0, col: 1))
        #expect(all.first?.end == Position(line: 0, col: 2))
    }

    @Test("case-insensitive matching works on non-ASCII letters")
    func nonASCIICaseFolding() {
        let t = makeTerminal(text: "CAF\u{C9} au lait")
        #expect(engine(t, "caf\u{E9}").findAll().count == 1)
        #expect(engine(t, "caf\u{E9}", caseSensitive: true).findAll().isEmpty)
        #expect(engine(t, "CAF\u{C9}", caseSensitive: true).findAll().count == 1)
    }

    // MARK: - scrolling and invalidation

    @Test("matches keep their line numbers after the screen scrolls")
    func scrollInvariance() {
        let t = makeTerminal(cols: 20, rows: 3, scrollback: 100, text: "needle\r\n")
        let e = engine(t, "needle")
        #expect(pairs(e.findAll()) == [[0, 0, 0, 5]])
        for i in 0..<10 { t.feed("filler \(i)\r\n") }
        #expect(t.buffer.ybase > 0)                       // the line really scrolled off
        #expect(pairs(e.findAll()) == [[0, 0, 0, 5]])     // same number, still found
        #expect(t.buffer.row(line: 0)?.string() == "needle")
    }

    @Test("results are recomputed when the terminal prints more")
    func invalidatedByOutput() {
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 100, text: "hit\r\n")
        let e = engine(t, "hit")
        #expect(e.findAll().count == 1)
        t.feed("hit again\r\n")
        #expect(e.findAll().count == 2)
    }

    @Test("changing the term or the options drops the cached results")
    func invalidatedByTermChange() {
        let t = makeTerminal(cols: 40, text: "Alpha alpha")
        let e = engine(t, "alpha")
        #expect(e.findAll().count == 2)
        e.options = SearchOptions(caseSensitive: true)
        #expect(e.findAll().count == 1)
        e.term = "Alpha"
        #expect(e.findAll().count == 1)
        e.term = "zzz"
        #expect(e.findAll().isEmpty)
    }

    @Test("a line dropped from the scrollback stops matching")
    func clearedScrollback() {
        let t = makeTerminal(cols: 20, rows: 3, scrollback: 100, text: "needle\r\n")
        let e = engine(t, "needle")
        for i in 0..<10 { t.feed("filler \(i)\r\n") }
        #expect(e.findAll().count == 1)
        t.buffer.clearScrollback()
        t.touch()
        #expect(e.findAll().isEmpty)
        #expect(e.matches(onLine: 0).isEmpty)
    }

    @Test("the active buffer is what gets searched")
    func alternateBuffer() {
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 100, text: "primary text\r\n")
        let e = engine(t, "text")
        #expect(e.findAll().count == 1)
        t.feed("\u{1b}[?1049h")          // to the alternate screen (cursor kept)
        t.feed("alternate text here")
        let alt = e.findAll()
        #expect(alt.count == 1)
        #expect(alt.first?.start == Position(line: 1, col: 10))
        t.feed("\u{1b}[?1049l")          // back to primary
        #expect(pairs(e.findAll()) == [[0, 8, 0, 11]])
    }

    // MARK: - caching

    @Test("an unchanged terminal is not re-stringified")
    func rowCacheReuse() {
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 100, text: "one\r\ntwo\r\nthree\r\n")
        let e = engine(t, "t")
        let first = e.findAll()
        let built = e.rowStringifyCount
        #expect(built > 0)
        // Same results, and not one row re-read (the match cache answers).
        #expect(e.findAll() == first)
        #expect(e.rowStringifyCount == built)
        // Even after dropping the match cache the rows are still good.
        e.invalidate()
        #expect(e.findAll() == first)
        #expect(e.rowStringifyCount == built)
    }

    @Test("only the rows whose generation moved are re-stringified")
    func rowCachePerRow() {
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 100, text: "one\r\ntwo\r\nthree\r\n")
        let e = engine(t, "t")
        _ = e.findAll()
        let built = e.rowStringifyCount
        // Overwrite the middle row in place: exactly one generation moves.
        t.feed("\u{1b}[2;1Htwenty")
        #expect(e.findAll().count > 0)
        #expect(e.rowStringifyCount == built + 1)
        // A different term reuses every cached row.
        e.term = "one"
        #expect(e.findAll().count == 1)
        #expect(e.rowStringifyCount == built + 1)
        // A new row at the bottom costs one more, and only one.
        t.feed("\u{1b}[4;1Hfourth line")
        e.term = "line"
        #expect(e.findAll().count == 1)
        #expect(e.rowStringifyCount == built + 2)
    }

    @Test("a resize resets the caches instead of returning stale columns")
    func resizeResetsCache() {
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 100, text: "hello world\r\n")
        let e = engine(t, "world")
        #expect(e.findAll().count == 1)
        t.resize(cols: 40, rows: 6)
        let after = e.findAll()
        #expect(after.count == 1)
        #expect(after.first?.start.col == 6)
    }

    @Test("output at the bottom re-matches only the lines it touched")
    func lineCacheIncremental() {
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 500)
        for i in 0..<200 { t.feed("line \(i) has target\r\n") }
        let e = engine(t, "target")
        let first = e.findAll()
        #expect(first.count == 200)
        let matched = e.logicalMatchCount
        #expect(matched >= 200)          // the first pass had to read everything

        // One more line of output: exactly the rows it wrote are re-matched
        // (the new line, plus the row the cursor left behind).
        t.feed("another target here\r\n")
        let second = e.findAll()
        #expect(second.count == 201)
        #expect(e.logicalMatchCount - matched <= 3)

        // ...and the answer is the one a cold engine gives.
        let cold = engine(t, "target")
        #expect(cold.findAll() == second)
    }

    @Test("a scrollback that trims does not leave the line cache behind")
    func lineCacheEvictsTrimmedLines() {
        // 106 rows of ring, three rows to a logical line: about 35 live ones,
        // and 400 lines fed through them so that the ring trims over and over
        // — a ring that never trims cannot show the leak at all.
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
        let e = engine(t, "zzzz")              // never matches: every line is scanned
        let w = engine(t, "row")
        for i in 0..<400 {
            t.feed("row \(i) " + String(repeating: "x", count: 36) + "\r\n")
            #expect(e.findAll().isEmpty)
            _ = w.findAll()
        }
        // Budget: one entry per logical line the ring still holds (36) and
        // one signature row per row of it (106). The count-based prune instead
        // kept every start line that had scrolled off until there were more of
        // them than there were lines — 133 entries and 397 signature rows.
        #expect(e.lineCacheEntryCount <= 50)
        #expect(e.lineCacheSignatureRows <= 160)
        // ...and what a cache that has been trimmed under reports is still
        // what an engine that has seen nothing reports.
        #expect(w.findAll() == engine(t, "row").findAll())
    }

    @Test("a soft-wrapped history is not cached span by span")
    func lineCacheWrappedHistoryBudget() {
        // Every row wraps into the next, so the whole ring is ONE logical line
        // whose signature is every row of it — the shape that turned the cache
        // into a copy of the scrollback per frame.
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
        let e = engine(t, "zzzz")
        let w = engine(t, "aaaa")
        for _ in 0..<220 {
            t.feed(String(repeating: "a", count: 20))
            #expect(e.findAll().isEmpty)
            _ = w.findAll()
        }
        #expect(e.lineCacheEntryCount <= 2)
        #expect(e.lineCacheSignatureRows <= 2 * SearchEngine.maxCachedSpan)
        #expect(w.findAll() == engine(t, "aaaa").findAll())
    }

    @Test("a logical line longer than the span bound is left uncached")
    func lineCacheLongSpanSkipped() {
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 300)
        let e = engine(t, "zzzz")
        t.feed(String(repeating: "b", count: 20 * (SearchEngine.maxCachedSpan + 2)))
        #expect(e.findAll().isEmpty)
        #expect(e.lineCacheEntryCount == 0)
        // A line beside it that is short enough still earns its entry.
        t.feed("\r\nshort line\r\n")
        #expect(e.findAll().isEmpty)
        #expect(e.lineCacheEntryCount >= 1)
        #expect(e.lineCacheSignatureRows <= SearchEngine.maxCachedSpan)
    }

    @Test("the per-line cap stops the scan, not just the list")
    func maxMatchesPerLineCap() {
        // One logical line of 10,400 characters, every one of them a match.
        let t = makeTerminal(cols: 80, rows: 6, scrollback: 300)
        let e = engine(t, "a")
        t.feed(String(repeating: "a", count: 80 * 130))
        #expect(e.findAll(limit: 50_000).count == SearchEngine.maxMatchesPerLine)
    }

    @Test("a row wrapped onto the end of a cached line invalidates it")
    func lineCacheSpanGrows() {
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
        t.feed("aaaaaaaaaaaaaaaatarg")     // fills the row exactly, no wrap yet
        let e = engine(t, "target")
        #expect(e.findAll().isEmpty)
        t.feed("et and more")              // wraps: the logical line now holds it
        let after = e.findAll()
        #expect(after.count == 1)
        #expect(after == engine(t, "target").findAll())
    }

    @Test("a region scroll does not serve a cached line's old matches")
    func lineCacheRegionScroll() {
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
        t.feed("\u{1b}[?1049h")            // alternate screen: no scrollback to confuse
        for i in 1...5 { t.feed("\u{1b}[\(i);1Hrow \(i) target") }
        let e = engine(t, "target")
        #expect(e.findAll().count == 5)
        t.feed("\u{1b}[2;4r\u{1b}[2;1H\u{1b}[2S")   // scroll the middle region twice
        let after = e.findAll()
        #expect(after == engine(t, "target").findAll())
    }

    @Test("changing the term or the options drops the per-line matches")
    func lineCacheTermChange() {
        let t = makeTerminal(cols: 20, rows: 6, scrollback: 100, text: "Target here\r\ntarget too\r\n")
        let e = engine(t, "target")
        #expect(e.findAll().count == 2)
        e.options = SearchOptions(caseSensitive: true)
        #expect(e.findAll().count == 1)
        e.term = "here"
        #expect(e.findAll().count == 1)
        #expect(e.findAll() == engine(t, "here").findAll())
    }

    // MARK: - incremental vs. cold

    @Test("an engine fed incrementally answers exactly like a cold one")
    func incrementalMatchesColdEngine() {
        // Wide characters, a Thai combining pair, an accented letter that has a
        // case partner, and enough repetition that overlapping candidates and
        // matches straddling a wrap actually happen.
        let atoms = ["a", "b", "A", "B", " ", "x", "\u{4E2D}", "\u{6587}",
                     "\u{0E01}\u{0E34}", "\u{0E19}", "_", "1", "\u{E9}", "\u{C9}", "aa"]
        let terms = ["a", "ab", "aa", "\u{4E2D}\u{6587}", "\u{0E01}\u{0E34}\u{0E19}",
                     "b a", "A", "x\u{4E2D}", " ", "aaa", "\u{E9}a"]
        var rng = SearchRNG(state: 0xC0FFEE)
        for trial in terms.indices {
            let t = Terminal(cols: 8 + trial, rows: 5, scrollback: 60)
            let options = SearchOptions(caseSensitive: trial % 3 == 0,
                                        regex: false,
                                        wholeWord: trial % 4 == 0)
            let live = engine(t, terms[trial],
                              caseSensitive: options.caseSensitive, wholeWord: options.wholeWord)
            for step in 0..<80 {
                var chunk = ""
                for _ in 0..<rng.below(12) { chunk += atoms[rng.below(atoms.count)] }
                switch rng.below(8) {
                case 0: chunk += "\r\n"                                    // a hard line break
                case 1: chunk = "\u{1b}[\(1 + rng.below(5));\(1 + rng.below(6))H" + chunk
                case 2: chunk += "\u{1b}[K"                                 // shorten a row
                default: break
                }
                t.feed(chunk)
                let cold = engine(t, terms[trial],
                                  caseSensitive: options.caseSensitive, wholeWord: options.wholeWord)
                #expect(live.findAll(limit: 20_000) == cold.findAll(limit: 20_000),
                        "trial \(trial), step \(step)")
            }
        }
    }

    @Test("a soft-wrapped line longer than one cache entry resumes correctly")
    func incrementalLongWrappedLine() {
        // 40 screen rows over a ~130-row logical line: cursor addressing then
        // reaches the MIDDLE of the span, which is what the checkpoints and the
        // one-row backup before the first changed row exist for.
        let atoms = ["a", "b", " ", "A", "\u{4E2D}", "\u{0E01}\u{0E34}", "x"]
        var rng = SearchRNG(state: 0xBEEF)
        let cases: [(String, SearchOptions)] = [
            ("ab", SearchOptions()),
            ("a", SearchOptions(wholeWord: true)),
            ("A", SearchOptions(caseSensitive: true)),
            ("aba", SearchOptions()),           // overlapping candidates
        ]
        for (term, options) in cases {
            let t = Terminal(cols: 8, rows: 40, scrollback: 200)
            let live = engine(t, term,
                              caseSensitive: options.caseSensitive, wholeWord: options.wholeWord)
            for _ in 0..<900 { t.feed(atoms[rng.below(atoms.count)]) }
            _ = live.findAll(limit: 20_000)
            #expect(t.buffer.lineCount > SearchEngine.maxCachedSpan)
            #expect(live.spanCacheEntryCount >= 1)     // the resumable path really engaged
            for step in 0..<120 {
                switch rng.below(3) {
                case 0:
                    t.feed(atoms[rng.below(atoms.count)])                       // grow the tail
                case 1:
                    t.feed("\u{1b}[\(1 + rng.below(40));\(1 + rng.below(8))H"
                           + atoms[rng.below(atoms.count)])                     // poke the middle
                default:
                    t.feed("\u{1b}[\(1 + rng.below(40));1H"
                           + atoms[rng.below(atoms.count)] + atoms[rng.below(atoms.count)])
                }
                let cold = engine(t, term,
                                  caseSensitive: options.caseSensitive, wholeWord: options.wholeWord)
                #expect(live.findAll(limit: 20_000) == cold.findAll(limit: 20_000),
                        "term \(term), step \(step)")
            }
        }
    }

    @Test("the resumable cache stays inside the signature budget")
    func spanCacheBudget() {
        // One logical line over a ring that trims under it, re-matched after
        // every row of output: the entry is re-keyed and evicted, never
        // accumulated, and what it reports is what a cold engine reports.
        let t = Terminal(cols: 20, rows: 6, scrollback: 100)
        let e = engine(t, "zzzz")            // never matches: every row is scanned
        let w = engine(t, "aab")             // straddles the wrap in both directions
        for _ in 0..<280 {
            t.feed(String(repeating: "a", count: 19) + "b")
            #expect(e.findAll().isEmpty)
            #expect(w.findAll() == engine(t, "aab").findAll())
        }
        #expect(e.spanCacheEntryCount <= 2)
        #expect(e.spanCacheSignatureRows <= 2 * t.buffer.lineCount)
        // The all-or-nothing cache still refuses the long span — what little
        // it holds is the short lines at the bottom of the ring.
        #expect(e.lineCacheSignatureRows <= 2 * SearchEngine.maxCachedSpan)
    }

    // MARK: - lifetime

    @Test("the engine holds the terminal weakly and goes quiet when it dies")
    func weakTerminal() {
        var t: Terminal? = makeTerminal(text: "hello")
        let e = SearchEngine(terminal: t!)
        e.term = "hello"
        #expect(e.findAll().count == 1)
        t = nil
        #expect(e.findAll().isEmpty)
        #expect(e.findNext(after: nil) == nil)
        #expect(e.matches(onLine: 0).isEmpty)
    }

    // MARK: - the linear matcher (KMP) and the whole-word advance

    /// The workload the audit froze the window with: 1,000,000 `a`s as one
    /// soft-wrapped logical line, searched for `a…ab`, which cannot match
    /// anywhere. The compare-at-every-position loop that used to be here paid
    /// the whole term at every one of a million positions — 11.5 s at 16,384
    /// scalars, on the main thread, from the render path. A term up to
    /// `maxResumableNeedle` goes through `SpanScanner` and a longer one through
    /// `plainRanges`; both had the loop, so both are measured here.
    @Test("a very long term does not freeze the search")
    func longTermIsLinear() {
        let t = Terminal(cols: 100, rows: 25, scrollback: 20_000)
        t.feed(String(repeating: "a", count: 1_000_000))
        let clock = ContinuousClock()
        for length in [SearchEngine.maxResumableNeedle, 16_384] {
            let e = SearchEngine(terminal: t)
            e.term = String(repeating: "a", count: length - 1) + "b"
            var found: [SearchMatch] = []
            let elapsed = clock.measure { found = e.findAll() }
            #expect(found.isEmpty)
            // Measured at 0.017–0.025 s at -O; four seconds is two orders of
            // magnitude of slack and still below the 11.5 s the 16,384-scalar
            // term used to cost. The budget is generous because this test also
            // runs in DEBUG under `run.sh vt-exclusivity`, where the same work
            // takes about 1.09 s — a one-second budget failed there, which
            // turned an invariant check into a stopwatch nobody could trust.
            // What is being asserted is "not quadratic", not "fast".
            #expect(elapsed < .seconds(4), "a term of \(length) scalars took \(elapsed)")
        }
    }

    /// `xa-a-a` searching `a-a` with Whole Word used to report NOTHING. The
    /// candidate at column 1 is refused — there is an `x` on its left — and the
    /// scan then skipped the whole term, stepping straight over the real match
    /// at columns 3–5, which begins inside the candidate it had just thrown
    /// away. A refusal now costs one scalar, not one term.
    @Test("a rejected whole-word candidate does not hide an overlapping match")
    func wholeWordOverlapAfterRejection() {
        let t = makeTerminal(text: "xa-a-a ")
        #expect(pairs(engine(t, "a-a", wholeWord: true).findAll()) == [[0, 3, 0, 5]])
        // Without the `x` the first candidate is accepted, and the term is
        // consumed: the second `a-a` overlaps it and is not a separate match.
        let clean = makeTerminal(text: "a-a-a ")
        #expect(pairs(engine(clean, "a-a", wholeWord: true).findAll()) == [[0, 0, 0, 2]])
    }

    /// The same refusal, with the candidate and the match both straddling soft
    /// wraps — the resumable `SpanScanner` path, where the window is trimmed
    /// between rows and a start that survived a rejection must survive the trim.
    @Test("a rejected whole-word candidate across a soft wrap keeps the overlap")
    func wholeWordOverlapAcrossWrap() {
        let t = makeTerminal(cols: 4, text: "xa-a-a-a-a.")
        #expect(pairs(engine(t, "a-a", wholeWord: true).findAll())
                == [[0, 3, 1, 1], [1, 3, 2, 1]])
    }

    /// The whole-line path (`matchWholeSpan` / `plainRanges`) is only reached by
    /// a term past `maxResumableNeedle`, and it had the same bug. Same shape as
    /// `xa-a-a`, scaled up so it lands there.
    @Test("the whole-line matcher backs up after a rejected candidate too")
    func wholeWordOverlapLongTerm() {
        let k = 300
        let a = String(repeating: "a", count: k)
        let t = makeTerminal(cols: 1000, rows: 4, scrollback: 20,
                             text: "x" + a + "-" + a + "-" + a + " ")
        let e = engine(t, a + "-" + a, wholeWord: true)
        #expect(e.term.unicodeScalars.count > SearchEngine.maxResumableNeedle)
        #expect(pairs(e.findAll()) == [[0, k + 2, 0, 3 * k + 2]])
    }

    /// A needle whose prefix repeats is where a border table earns its keep and
    /// where a wrong one shows: the match starts inside the failed attempt.
    @Test("a needle with a repeated prefix matches at the right offset")
    func repeatedPrefixNeedle() {
        let repeated = makeTerminal(text: "aaaaaab")
        #expect(pairs(engine(repeated, "aaab").findAll()) == [[0, 3, 0, 6]])
        #expect(engine(repeated, "zzz").findAll().isEmpty)
        let alternating = makeTerminal(text: "abababa")
        #expect(pairs(engine(alternating, "ababa").findAll()) == [[0, 0, 0, 4]])
        let noB = makeTerminal(text: "aaaaaa")
        #expect(engine(noB, "aaab").findAll().isEmpty)
    }

    @Test("a repeated-prefix needle past the resumable bound behaves the same")
    func repeatedPrefixLongNeedle() {
        let k = 300
        let t = makeTerminal(cols: 1000, rows: 4, scrollback: 20,
                             text: String(repeating: "a", count: k + 3) + "b")
        let e = engine(t, String(repeating: "a", count: k) + "b")
        #expect(e.term.unicodeScalars.count > SearchEngine.maxResumableNeedle)
        #expect(pairs(e.findAll()) == [[0, 3, 0, k + 3]])
    }

    /// Offsets are SCALARS and columns are CELLS, and the matcher must not
    /// confuse them: Thai has one cell per scalar and no case at all, an emoji
    /// is one scalar over two cells.
    @Test("scalar offsets survive Thai and emoji")
    func nonASCIIOffsets() {
        let thai = makeTerminal(text: "\u{0E01}\u{0E01}\u{0E01}\u{0E02}")     // ก ก ก ข
        #expect(pairs(engine(thai, "\u{0E01}\u{0E01}\u{0E02}").findAll()) == [[0, 1, 0, 3]])
        #expect(engine(thai, "\u{0E01}\u{0E02}\u{0E02}").findAll().isEmpty)

        let emoji = makeTerminal(text: "\u{1F600}\u{1F600}\u{1F600}")
        #expect(pairs(engine(emoji, "\u{1F600}\u{1F600}").findAll()) == [[0, 0, 0, 2]])
        #expect(pairs(engine(emoji, "\u{1F600}").findAll())
                == [[0, 0, 0, 0], [0, 2, 0, 2], [0, 4, 0, 4]])
    }

    /// The needle is folded once and the haystack once; the border table is
    /// built on the FOLDED needle, so a case difference must not shift anything.
    @Test("case folding still lines up under a repeated prefix")
    func caseInsensitiveRepeatedPrefix() {
        let t = makeTerminal(text: "AAAAAAB")
        #expect(pairs(engine(t, "aaab").findAll()) == [[0, 3, 0, 6]])
        #expect(pairs(engine(t, "AaAb").findAll()) == [[0, 3, 0, 6]])
        #expect(engine(t, "aaab", caseSensitive: true).findAll().isEmpty)
        #expect(pairs(engine(t, "AAAB", caseSensitive: true).findAll()) == [[0, 3, 0, 6]])
    }
}

/// Deterministic PRNG (SplitMix64) so a differential failure is reproducible
/// and the tests stay free of Foundation.
private struct SearchRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
}
