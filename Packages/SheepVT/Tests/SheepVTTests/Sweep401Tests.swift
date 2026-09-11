import Testing
@testable import SheepVT

/// The whole-app sweep of 4.0 (1), package slice.
@Suite("whole-app sweep findings after 4.0 (1)")
struct Sweep401Tests {
    /// A height shrink pops rows; the grow re-creates the same line numbers
    /// with fresh Row objects that malloc can place at the freed addresses,
    /// and a row written the same number of times has the same generation.
    /// The row cache (identity + generation) then served the OLD text: a
    /// "needle" reported on a row that reads `zzzzzz`, 30 rounds in 200.
    /// The engine now drops its row cache whenever the buffer was reshaped.
    @Test("search never serves a freed row's text after a shrink and grow")
    func rowCacheSurvivesRowIdentityReuse() {
        var staleHits = 0
        for _ in 0..<200 {
            let t = Terminal(cols: 20, rows: 5, scrollback: 50)
            let s = SearchEngine(terminal: t)
            t.feed("top\r\nneedle\r\nfiller\r\nfiller\r\nfiller")
            t.feed("\u{1b}[1;1H")
            s.term = "needle"
            #expect(s.findAll().count == 1)
            t.resize(cols: 20, rows: 1); s.invalidate()       // pops the rows below the cursor
            t.resize(cols: 20, rows: 5); s.invalidate()       // re-creates them
            t.feed("\u{1b}[2;1Hzzzzzz")                        // one write: generation 1, like the old row
            if !s.findAll().isEmpty { staleHits += 1 }
        }
        #expect(staleHits == 0, "\(staleHits) stale hits in 200 rounds")
    }

    /// The reshape counter is what makes the drop happen without the view
    /// having to say anything.
    @Test("a reshape drops the row text cache")
    func reshapeDropsRowCache() {
        let t = Terminal(cols: 20, rows: 5, scrollback: 50)
        let s = SearchEngine(terminal: t)
        for i in 0..<20 { t.feed("row \(i) x\r\n") }
        s.term = "x"
        #expect(!s.findAll().isEmpty)
        #expect(s.rowCacheEntryCount > 0)
        let before = t.buffer.reshapeCount
        t.resize(cols: 20, rows: 3)
        #expect(t.buffer.reshapeCount == before + 1)
        _ = s.findAll()                                        // the first scan after it
        // Rebuilt from scratch, so it holds only what this scan touched —
        // nothing it remembered from before the reshape.
        #expect(s.rowCacheEntryCount <= t.buffer.lines.count)
    }

    /// The linear budget is per line; a line that is the whole ring is two
    /// million scalars at the default configuration and the linear rule alone
    /// allowed 129M steps ≈ 1.2 s per frame. The ceiling bounds the frame.
    @Test("the regex budget has an absolute ceiling")
    func regexBudgetCeiling() {
        #expect(SearchEngine.regexBudget(for: 20_000) == 64 * 20_000 + 1_000_000)
        #expect(SearchEngine.regexBudget(for: 2_000_000) == SearchEngine.regexBudgetCeiling)
        // …and a pattern that needs more on such a line is cut and says so.
        let t = Terminal(cols: 200, rows: 10, scrollback: 10_000)
        t.feed(String(repeating: "a", count: 400_000))
        let e = SearchEngine(terminal: t)
        e.options.regex = true
        e.term = "a{1000}b"
        #expect(e.findAll().isEmpty)
        #expect(e.resultsIncomplete)
    }
}
