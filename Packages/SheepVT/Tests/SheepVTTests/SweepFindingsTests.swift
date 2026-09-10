import Testing
@testable import SheepVT

/// The whole-app sweep after 3.0 (59) ran probes against the package objects
/// and found these. Each is kept as the reproducer that was reported.
@Suite("whole-app sweep findings after 3.0 (59)")
struct SweepFindingsTests {
    final class Replies: TerminalDelegate {
        var sent: [String] = []
        func send(_ terminal: Terminal, bytes: [UInt8]) {
            sent.append(String(decoding: bytes, as: UTF8.self))
        }
    }

    /// The per-row text cache is ~8 B per cell of scrollback (200 MB on a
    /// 200,000-row ring) and used to survive the find bar closing, for the
    /// life of the tab. An empty term is the bar closing.
    @Test("closing the find bar releases the per-row text cache")
    func rowCacheReleasedOnEmptyTerm() {
        let t = Terminal(cols: 40, rows: 5, scrollback: 500)
        for i in 0..<200 { t.feed("line \(i) target\r\n") }
        let e = SearchEngine(terminal: t)
        e.term = "target"
        #expect(e.findAll().count == 200)
        #expect(e.rowCacheEntryCount > 0)
        e.term = ""
        #expect(e.rowCacheEntryCount == 0)
        // …and reopening works from cold.
        e.term = "target"
        #expect(e.findAll().count == 200)
    }

    /// `a*c|a`: the high-priority `a*c` thread stays alive to the end of the
    /// line for every `a` reported, so the line costs O(line) per match —
    /// 2.4 s for 20,000 scalars, on the paint path. The budget cuts the
    /// list short instead; a pattern whose threads die after a match is not
    /// touched by it.
    @Test("a regex that costs a line per match is cut off by the budget")
    func regexBudget() {
        let t = Terminal(cols: 80, rows: 5, scrollback: 1000)
        t.feed(String(repeating: "a", count: 20_000))          // one 250-row logical line
        let e = SearchEngine(terminal: t)
        e.options.regex = true
        e.term = "a*c|a"
        // The exhaustion flag, not a stopwatch: it is deterministic and the
        // same under Release and the Debug exclusivity build, where a
        // wall-clock ceiling calibrated for Release would flake (this line
        // ran 0.6 s Release, 12 s Debug). The flag being set IS the budget
        // engaging — a regression that removed the bound clears it.
        let found = e.findAll()
        #expect(e.regexBudgetExhaustions == 1)
        #expect(!found.isEmpty, "the budget cuts the list short, it does not empty it")

        e.term = "a"
        #expect(e.findAll().count == 1_000, "findAll's own overall cap")
        #expect(e.regexBudgetExhaustions == 1, "a plain regex never hits the budget")
    }

    /// The first shape of the budget was consulted only after a match came
    /// back: a pattern that never matches — `a{1000}b` over 200,000 `a`s, a
    /// thousand live threads at every position — ran to the end of the line
    /// (3.3 s on the paint path) with the budget never looked at. The check
    /// lives inside the position loop now, and on the no-match path.
    @Test("the budget stops a regex that never matches, inside the matcher")
    func regexBudgetStopsANoMatchRun() throws {
        let rx = try LinearRegex.compile(pattern: "a{100}b", ignoresCase: false)
        let hay = Array(String(repeating: "a", count: 10_000).unicodeScalars)
        let tight = rx.matches(in: hay, limit: 10, budget: 1)
        #expect(tight.exhausted, "budget 1 must report exhaustion even with nothing found")
        #expect(tight.ranges.isEmpty)
        let loose = rx.matches(in: hay, limit: 10, budget: Int.max)
        #expect(!loose.exhausted && loose.ranges.isEmpty, "no match is still no match")

        let t = Terminal(cols: 80, rows: 5, scrollback: 5_000)
        t.feed(String(repeating: "a", count: 200_000))          // 2,500 rows, one line
        let e = SearchEngine(terminal: t)
        e.options.regex = true
        e.term = "a{1000}b"
        // Deterministic again: unbounded this ran to the end of a 200,000-scalar
        // line (3.3 s Release, far worse Debug) with the budget never consulted
        // — `regexBudgetExhaustions == 0` was the actual bug. The flag is the
        // build-independent proof that the in-loop check fired on a run that
        // finds nothing.
        let found = e.findAll()
        #expect(found.isEmpty)
        #expect(e.regexBudgetExhaustions == 1)
    }

    /// The budget stops the matcher part way through a line, and the matches
    /// past that point are never looked for — so an empty result is "nothing
    /// in the part we reached", not "not here". Reported as "not found" it is
    /// a confident falsehood about text nobody searched: this line really does
    /// contain `a{1000}b`. Found by the recheck of 3.0 (61), which is the
    /// build that introduced the budget.
    @Test("a search stopped by the budget reports itself incomplete, not empty")
    func budgetExhaustionIsReportedNotHidden() {
        let t = Terminal(cols: 100, rows: 10, scrollback: 2_100)
        t.feed(String(repeating: "a", count: 200_000) + "b")    // the match is at the very end
        let e = SearchEngine(terminal: t)
        e.options.regex = true
        e.term = "a{1000}b"
        #expect(e.findAll().isEmpty, "the budget stops before the match")
        #expect(e.resultsIncomplete, "…and the engine says the answer is partial")

        // The cache must be as honest as the scan that filled it: asking again
        // without touching the buffer serves the same list and the same verdict.
        #expect(e.findAll().isEmpty)
        #expect(e.resultsIncomplete, "a cache hit forgot the search was incomplete")

        // A new term has not been searched at all yet.
        e.term = "a{2}b"
        #expect(!e.resultsIncomplete, "the verdict outlived the query that made it")
        #expect(e.findAll().count == 1, "and the cheap pattern finds the real match")
        #expect(!e.resultsIncomplete)

        // A term that completes over the same text is complete, and one that
        // genuinely is not present says so without the incomplete flag.
        e.term = "zzz"
        #expect(e.findAll().isEmpty)
        #expect(!e.resultsIncomplete, "a finished search that finds nothing is not incomplete")
    }

    /// The other half: matches DO come back, but from only part of the text.
    /// The count is then a floor, not a total.
    @Test("partial results from a budgeted search are marked partial")
    func partialResultsAreMarkedPartial() {
        let t = Terminal(cols: 100, rows: 10, scrollback: 2_100)
        // `ab` matches at once; the `a{1000}c` branch never matches but keeps a
        // thousand threads alive at every position after it, which is what
        // spends the budget.
        t.feed("ab" + String(repeating: "a", count: 200_000))
        let e = SearchEngine(terminal: t)
        e.options.regex = true
        e.term = "ab|a{1000}c"
        let found = e.findAll()
        #expect(!found.isEmpty, "the matches before the cut-off are real")
        #expect(e.resultsIncomplete, "…but the list is not everything")
    }

    /// `rowOffset * oldCols / newCols` counted the gap a wide character
    /// leaves at the end of a row as text. At three columns of CJK every row
    /// is one character plus a gap, so the product overshot by half: a reader
    /// 113 rows into the line was put 84 rows into the rewrapped one, looking
    /// at different characters — with nothing trimmed. The anchor is content
    /// cells now, measured the way reflow moves them.
    @Test("a reader inside a wide-character paragraph keeps their place across odd widths")
    func wideCharacterAnchorAcrossOddWidths() {
        let t = Terminal(cols: 3, rows: 10, scrollback: 500)
        var chars: [Character] = []
        for i in 0..<200 { chars.append(Character(Unicode.Scalar(0x4E00 + i)!)) }
        t.feed(String(chars))                                   // 200 rows: one CJK + a gap each
        t.feed("\r\ntail\r\n")
        t.scrollViewport(by: -80)
        let b = t.buffer
        func topLeftIndex() -> Int {
            guard let c = (b.row(line: b.lineNumber(ofViewportRow: 0))?.string() ?? "").first else { return -1 }
            return chars.firstIndex(of: c) ?? -1
        }
        let start = topLeftIndex()
        #expect(start == 113, "the reader is 80 rows up, on the 114th CJK character")
        #expect(b.ydisp < b.ybase)

        // The old `rowOffset * oldCols / newCols` counted the wrap-gap cell at
        // the end of each 3-column row as text, so narrowing halved the offset
        // and the top jumped from character 113 to 84 — a different part of the
        // paragraph, with nothing trimmed. Mapping content cells the way reflow
        // lays them out holds the place: across this storm the top-left CJK
        // character stays within one of where it began (a row boundary can fall
        // one character either side of the cell at an odd width, and narrowing
        // floors), and the view never resumes following.
        for cols in [4, 5, 3, 7, 3, 2, 6, 3] {
            t.resize(cols: cols, rows: 10)
            #expect(b.ydisp < b.ybase, "cols \(cols): the reader was put back to following")
            let drift = abs(topLeftIndex() - start)
            #expect(drift <= 2, "cols \(cols): top-left is character \(topLeftIndex()), started at \(start)")
        }
    }

    /// The regex path cannot resume, and its results were refused by the
    /// line cache past 64 rows — so a logical line longer than that was
    /// re-matched from scratch on every paint that moved the change counter.
    @Test("a regex over a logical line longer than the span cap is cached")
    func regexLongLineCached() {
        let t = Terminal(cols: 40, rows: 5, scrollback: 1000)
        t.feed(String(repeating: "xx1 ", count: 900))           // 3,600 scalars, 90 rows > the 64-row cap
        t.feed("\r\ntail\r\n")
        let e = SearchEngine(terminal: t)
        e.options.regex = true
        e.term = "\\d"
        #expect(e.findAll().count == 900)
        let matched = e.logicalMatchCount
        t.feed("m")                                            // touches the cursor row only
        #expect(e.findAll().count == 900)
        #expect(e.logicalMatchCount - matched <= 1, "the long line was re-matched")
    }

    /// xterm.js pads a resize with DEFAULT_ATTR_DATA; padding with the pen
    /// painted a coloured band down every new column when the window was
    /// widened while a program had left a background colour set.
    @Test("a resize pads new cells with default attributes, not the pen's background")
    func resizePadsWithDefaults() {
        let t = Terminal(cols: 20, rows: 5, scrollback: 50)
        t.feed("\u{1b}[44mhello")
        t.resize(cols: 30, rows: 8)
        let b = t.buffer
        #expect(b.lines[0][25].bgSource == .default)
        #expect(b.lines[7][0].bgSource == .default)
        #expect(b.lines[0][0].bgSource != .default, "the text keeps its colour")
    }

    /// xterm.js `restoreCursor` ends in `_restrictCursor`: a cursor saved at
    /// screen row 7 and restored under origin mode after `CSI 1;3 r` used to
    /// come back on row 7, outside the region.
    @Test("DECRC under origin mode restores into the margins")
    func decrcRestrictsToMargins() {
        let t = Terminal(cols: 20, rows: 12, scrollback: 0)
        t.feed("\u{1b}[6;11r\u{1b}[?6h")   // margins rows 5…10 (0-based), origin mode on
        t.feed("\u{1b}[3;1H")              // origin-relative row 3 = screen row 7
        #expect(t.buffer.y == 7)
        t.feed("\u{1b}7")                  // DECSC
        t.feed("\u{1b}[1;3r")              // region rows 0…2
        t.feed("\u{1b}8")                  // DECRC
        #expect(t.buffer.y == 2, "restored to \(t.buffer.y), outside the region")
        t.feed("X")
        #expect(t.buffer.lines[2].string().contains("X"))
    }

    /// A 7 MiB `4;0;?;0;?…` under the payload cap drew 1.8 million replies
    /// (45 MB) from one sequence. One palette's worth per OSC is the bound.
    @Test("OSC 4 answers at most one palette's worth of queries per sequence")
    func osc4ReplyCap() {
        let host = Replies()
        let t = Terminal(cols: 20, rows: 5, scrollback: 50)
        t.delegate = host
        var payload = "\u{1b}]4"
        for _ in 0..<2_000 { payload += ";0;?" }
        payload += "\u{7}"
        t.feed(payload)
        #expect(host.sent.count == 256, "\(host.sent.count) replies")
        // A normal probe is still answered in full.
        host.sent.removeAll()
        t.feed("\u{1b}]4;1;?;2;?\u{7}")
        #expect(host.sent.count == 2)
    }
}
