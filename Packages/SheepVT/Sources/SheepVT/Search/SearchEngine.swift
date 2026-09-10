// SheepVT — search over the terminal's logical lines.
//
// One class, no view, no AppKit, and — since the regex path became
// `LinearRegex` — no Dispatch either: there is no longer a matcher that needs
// to be run somewhere it can be abandoned. Everything is expressed in the
// scroll-invariant line numbers of `Buffer+Lines` (`LineRing.trimmed + index`),
// so a match found before the screen scrolled still points at the same text
// afterwards. The unit searched is the *logical* line — a row plus every
// following row whose `wrapped` flag is set — so a term may straddle a soft
// wrap.
//
// The mapping between the string handed to the matcher and the grid is exact:
// every unicode scalar appended remembers which cell produced it (line + head
// column), so a match's bounds land on head cells even with wide characters
// (two cells, one scalar) and combined cells (one cell, several scalars).
//
// Per-row text is cached on `Row.generation`: a redraw of one row does not
// re-stringify the whole scrollback. The list of matches is cached on
// `Terminal.changeCounter`.
//
// A logical line is matched one ROW at a time (`SpanScanner`), so a line that
// is longer than the cache is willing to hold whole — a program that emits a
// single soft-wrapped line spanning the entire scrollback — is re-matched from
// a checkpoint a bounded distance before the first row that moved instead of
// from its beginning. See `matchSpan`.
//
// The plain matcher is KMP (`kmpFailure` + the two scan loops in `SpanScanner`
// and `plainRanges`), so the term's length is not a multiplier on the text:
// `findAll` runs synchronously from the render path, and the compare-the-term-
// at-every-position loop that came before it froze the window for 11.5 s on a
// 16,384-scalar term. Numbers in `plainRanges`.


/// Options that shape a search.
public struct SearchOptions: Equatable, Sendable {
    /// Match case exactly (default: case-insensitive).
    public var caseSensitive: Bool
    /// Treat the term as a regex pattern (`LinearRegex`'s subset).
    public var regex: Bool
    /// Require a non-word character (or nothing) on both sides of the match.
    public var wholeWord: Bool

    public init(caseSensitive: Bool = false, regex: Bool = false, wholeWord: Bool = false) {
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.wholeWord = wholeWord
    }
}

/// One match, as a pair of **inclusive** cells. `start` and `end` may sit on
/// different lines when the match crosses a soft wrap. Both always land on the
/// head cell of a wide character, never on its spacer.
public struct SearchMatch: Equatable, Sendable {
    public var start: Position
    public var end: Position

    public init(start: Position, end: Position) {
        self.start = start
        self.end = end
    }
}

public final class SearchEngine {
    /// Default cap on how many matches `findAll` reports.
    public static let defaultLimit = 1000

    private weak var terminal: Terminal?

    /// The term to look for. Setting it drops the cached results.
    public var term: String = "" {
        didSet {
            guard term != oldValue else { return }
            // An empty term is the find bar closing: nothing will be looked
            // up until it opens again, and the per-row text (~8 B per cell
            // of scrollback — 200 MB on a 200,000-row ring) is not worth
            // holding for the life of the tab against a keystroke's worth of
            // re-stringifying later.
            if term.isEmpty { invalidateAll() } else { invalidate() }
        }
    }

    /// How to interpret `term`. Setting it drops the cached results.
    public var options = SearchOptions() {
        didSet { if options != oldValue { invalidate() } }
    }

    public init(terminal: Terminal) {
        self.terminal = terminal
    }

    // MARK: - validity

    /// Whether `term` is usable: non-empty, and a compilable pattern when
    /// `options.regex` is set.
    public var isValid: Bool {
        guard !term.isEmpty else { return false }
        guard options.regex else { return true }
        return compiledRegex() != nil
    }

    /// Why the current regex term was refused, or nil when there is nothing
    /// wrong with it. Compiles on demand rather than being a flag someone has
    /// to remember to refresh: the first version was a stored property set by
    /// `compiledRegex`, which meant reading it before anything had asked
    /// `isValid` gave the previous term's answer.
    public var regexProblem: LinearRegex.Failure? {
        guard options.regex, !term.isEmpty else { return nil }
        _ = compiledRegex()
        return regexProblemValue
    }

    // MARK: - caches

    /// Text of one row, keyed by its scroll-invariant line number and valid
    /// while `Row.generation` has not moved.
    private struct RowText {
        /// Which `Row` object this text came from. `Row.generation` alone is
        /// not enough: a region scroll moves row REFERENCES between line
        /// numbers, and two rows written the same number of times carry the
        /// same generation — the line number would then serve the old row's text.
        var rowID: ObjectIdentifier
        var generation: UInt64
        /// Scalars of the row up to `trimmedLength` (trailing empty cells are
        /// synthesised as spaces only when the row continues into a wrapped one).
        var scalars: [Unicode.Scalar]
        /// Head column each scalar came from, same count as `scalars`.
        var columns: [Int32]
        var trimmedLength: Int
        var cols: Int
    }

    private var rowCache: [Int: RowText] = [:]
    /// Rows whose text is cached right now. Tests read it to prove the cache
    /// is released when the find bar closes.
    public var rowCacheEntryCount: Int { rowCache.count }

    /// How many times a row was actually turned into text. Tests watch this to
    /// prove the per-row cache is doing its job.
    private(set) var rowStringifyCount = 0

    /// Matches of one logical line, keyed by the line number its first row
    /// carries. Valid while every row of the span is the same object at the
    /// same generation and no row has been wrapped onto the end of it — which
    /// is what lets a stream of output re-run only the lines it touched
    /// instead of the whole scrollback on every frame.
    private struct LineMatches {
        var rowIDs: [ObjectIdentifier]
        var generations: [UInt64]
        var matches: [SearchMatch]
        /// The matcher gave up on this line before reaching its end (the regex
        /// work budget). Cached WITH the matches, because a line served from
        /// the cache is exactly as incomplete as it was when it was matched —
        /// forgetting that on a cache hit would make the answer honest only on
        /// the first frame after a keystroke.
        var incomplete = false
    }

    private var lineCache: [Int: LineMatches] = [:]

    /// Rows of signature `lineCache` is holding, kept in step with it. Entry
    /// COUNT says nothing about what the cache costs — one entry of a
    /// soft-wrapped history carries a row identity and a generation for every
    /// row of the span — so the volume is what is bounded.
    private(set) var lineCacheSignatureRows = 0

    /// Entries in `lineCache`. Tests watch this and `lineCacheSignatureRows`
    /// to prove the cache stays inside its budget.
    var lineCacheEntryCount: Int { lineCache.count }

    /// The first line number the ring held the last time `findAll` looked.
    /// Everything below it has scrolled off and can be evicted in one step.
    private var lastFirstLine: Int?

    /// How many logical lines were actually matched (as opposed to served from
    /// `lineCache`). Tests watch this to prove the cache is doing its job.
    private(set) var logicalMatchCount = 0

    /// Whether the last `findAll` searched everything it was asked to.
    ///
    /// A regex that runs out of its work budget stops part way through a line,
    /// and the matches past that point are simply not looked for — so an empty
    /// result means "nothing found in the part we reached", NOT "not here".
    /// Reporting the second is the same lie the find bar already refuses to
    /// tell for a pattern that would not compile ("bad pattern", not "not
    /// found"): `a{1000}b` over 200,000 `a`s followed by a `b` DOES match, and
    /// this used to read "not found". Per QUERY, not the cumulative
    /// `regexBudgetExhaustions` — that counter spans every search this engine
    /// has ever run and cannot answer "is what I am showing you complete?".
    public private(set) var resultsIncomplete = false
    /// The answer that goes with `cachedMatches`, so a cache hit is as honest
    /// as the scan that filled it.
    private var cachedIncomplete = false

    private var cachedMatches: [SearchMatch]?
    private var cachedChange: UInt64 = 0
    private var cachedLimit = 0
    private var cachedBufferID: ObjectIdentifier?
    private var cachedCols = -1

    private var regexSource: String?
    private var regexIgnoresCase = false
    private var regexValue: LinearRegex?
    private var regexProblemValue: LinearRegex.Failure?

    /// Drop the cached match list. The per-row text cache is kept — it
    /// validates itself against `Row.generation`, so keeping it is free and
    /// saves re-stringifying a 10,000-line scrollback after every keystroke.
    public func invalidate() {
        cachedMatches = nil
        cachedLimit = 0
        // The verdict belongs to the query that produced it: a new term, new
        // options or a resize has not been searched at all yet.
        resultsIncomplete = false
        cachedIncomplete = false
        // NOT `regexProblemValue`. It belongs to the term and the case
        // setting, and `compiledRegex` is the only thing that may set it —
        // clearing it here was wrong twice over: `invalidate()` also runs on a
        // RESIZE and on an alt-screen switch, and toggling Whole Word does not
        // change what the pattern compiles to. In each of those the verdict was
        // wiped while the cached compile was kept, so a pattern that had been
        // refused went back to reading "not found" — the exact lie this
        // distinction exists to prevent.

        // The per-line matches depend on the term and the options; the per-row
        // text does not, so only the former is dropped here.
        lineCache.removeAll(keepingCapacity: true)
        lineCacheSignatureRows = 0
        spanCache.removeAll(keepingCapacity: true)
        spanCacheSignatureRows = 0
    }

    /// Drop everything, including the per-row text (used when the grid is
    /// renumbered under us: a different buffer or a different width).
    private func invalidateAll() {
        invalidate()
        rowCache.removeAll(keepingCapacity: true)
        lastFirstLine = nil
    }

    // MARK: - the search

    /// Everything one pass needs that does not change from one logical line to
    /// the next.
    private struct ScanContext {
        var needle: [Unicode.Scalar]
        /// KMP border table of `needle`, built once per pass and not once per
        /// logical line: it costs O(term), which a 16,384-scalar term over a
        /// 10,000-line scrollback would otherwise pay ten thousand times.
        var failure: [Int]
        var regex: LinearRegex?
        /// Only a plain term short enough to sit inside the resume window can
        /// be carried across a row boundary; regex and an absurdly long term
        /// take the whole-line path (see `matchWholeSpan`).
        var resumable: Bool
    }

    /// Everything keyed on a line number is meaningless once the grid is
    /// renumbered under us: a different buffer, or a different width.
    private func syncBuffer(_ buffer: Buffer) {
        let id = ObjectIdentifier(buffer)
        guard id != cachedBufferID || buffer.cols != cachedCols else { return }
        invalidateAll()
        cachedBufferID = id
        cachedCols = buffer.cols
    }

    /// Point the caches at the buffer in front of us and work out how this pass
    /// will match; `nil` when there is nothing to look for. Every entry point
    /// goes through it — `findAll` and both directional scans read the same
    /// caches and must agree about which buffer they belong to.
    private func beginScan(buffer: Buffer) -> ScanContext? {
        syncBuffer(buffer)
        let needle = options.regex ? [] : foldedNeedle()
        if !options.regex && needle.isEmpty { return nil }
        let rx = options.regex ? compiledRegex() : nil
        if options.regex && rx == nil { return nil }
        evictScrolledOff(buffer: buffer)
        return ScanContext(needle: needle,
                           failure: SearchEngine.kmpFailure(needle),
                           regex: rx,
                           resumable: !options.regex
                               && needle.count <= SearchEngine.maxResumableNeedle)
    }

    /// The matches of the logical line that starts at ring index `index`, from
    /// the cache when its rows are untouched.
    ///
    /// This is the only place a logical line becomes matches. `findAll` walks
    /// it from the top of the ring to the bottom; `findNext` / `findPrevious`
    /// walk it from wherever the user is, in their direction, and stop at the
    /// first hit — so navigation and painting share one cache and one matcher.
    private func spanMatches(startingAt index: Int, buffer: Buffer,
                             context: ScanContext) -> SpanResult {
        let startLine = buffer.lineNumber(atIndex: index)
        // A logical line whose rows are untouched keeps the matches it had:
        // output arriving at the bottom of the screen re-runs the matcher on
        // the handful of lines it wrote, not on the whole scrollback.
        if let hit = lineCache[startLine],
           let end = validateSpan(hit, startingAt: index, buffer: buffer) {
            return SpanResult(endIndex: end, matches: hit.matches, incomplete: hit.incomplete)
        }
        return context.resumable
            ? matchSpan(startingAt: index, startLine: startLine, buffer: buffer,
                        needle: context.needle, failure: context.failure)
            : matchWholeSpan(startingAt: index, startLine: startLine, buffer: buffer,
                             needle: context.needle, failure: context.failure,
                             regex: context.regex)
    }

    /// Ring index of the first row of the logical line `index` belongs to. A
    /// walk that starts in the middle of a soft-wrapped line has to back up to
    /// its head: a continuation row is not the start of anything the matcher
    /// knows about, and a match may straddle the boundary above it.
    private func spanStart(ofIndex index: Int, buffer: Buffer) -> Int {
        var i = Swift.min(Swift.max(index, 0), buffer.lines.count - 1)
        while i > 0, buffer.lines.allocatedRow(at: i)?.wrapped == true { i -= 1 }
        return i
    }

    /// Every match from the top of the scrollback to the bottom of the screen,
    /// at most `limit` of them. Cached until `Terminal.changeCounter` moves.
    public func findAll(limit: Int = SearchEngine.defaultLimit) -> [SearchMatch] {
        guard limit > 0, let terminal, isValid else { return [] }
        let buffer = terminal.buffer
        // Ahead of `beginScan`: the renderer asks for this once a frame, and a
        // cache hit should not fold the term or walk the ring to say so.
        syncBuffer(buffer)
        if let cached = cachedMatches, cachedChange == terminal.changeCounter, cachedLimit >= limit {
            resultsIncomplete = cachedIncomplete
            return cached.count <= limit ? cached : Array(cached.prefix(limit))
        }
        guard let context = beginScan(buffer: buffer) else { return [] }

        var out: [SearchMatch] = []
        var incomplete = false
        let count = buffer.lines.count
        var index = 0
        outer: while index < count {
            let result = spanMatches(startingAt: index, buffer: buffer, context: context)
            incomplete = incomplete || result.incomplete
            index = result.endIndex + 1
            for m in result.matches {
                out.append(m)
                if out.count >= limit { break outer }
            }
        }

        resultsIncomplete = incomplete
        cachedIncomplete = incomplete
        cachedMatches = out
        cachedChange = terminal.changeCounter
        cachedLimit = limit
        pruneRowCache(buffer: buffer)
        return out
    }

    /// The first match starting strictly after `p`, wrapping to the first match
    /// of all. `nil` means "start from the top".
    ///
    /// The walk starts at `p` and stops at the first hit instead of asking
    /// `findAll` for a list and reading that. `findAll`'s limit bounds the set
    /// the renderer PAINTS; a list that stops at the thousandth match simply
    /// cannot say what comes after the thousandth, and navigation used to wrap
    /// to the top there instead of going on. Walking costs a dictionary lookup
    /// per logical line passed, and every line it does have to match is left in
    /// the same cache `findAll` fills — so nothing is matched twice.
    public func findNext(after p: Position?) -> SearchMatch? {
        guard let terminal, isValid else { return nil }
        let buffer = terminal.buffer
        guard let context = beginScan(buffer: buffer), buffer.lines.count > 0 else { return nil }
        let count = buffer.lines.count

        // A match may start anywhere in the logical line `p` sits in, including
        // before `p` itself, so the walk begins at the head of that line and it
        // is the comparison — not the starting point — that makes it strict. A
        // `p` whose line has scrolled off the top puts us at the top; one past
        // the bottom (a resize can leave one) has nothing after it at all.
        if let p, p.line <= buffer.lastLine {
            var index = spanStart(ofIndex: p.line - buffer.firstLine, buffer: buffer)
            while index < count {
                let r = spanMatches(startingAt: index, buffer: buffer, context: context)
                for m in r.matches where m.start > p { return m }
                index = r.endIndex + 1
            }
        }
        return firstMatch(buffer: buffer, context: context)
    }

    /// The last match starting strictly before `p`, wrapping to the last match
    /// of all. `nil` means "start from the bottom". Backwards twin of
    /// `findNext`, and past the limit for the same reason.
    public func findPrevious(before p: Position?) -> SearchMatch? {
        guard let terminal, isValid else { return nil }
        let buffer = terminal.buffer
        guard let context = beginScan(buffer: buffer), buffer.lines.count > 0 else { return nil }

        if let p, p.line >= buffer.firstLine {
            var index: Int? = spanStart(ofIndex: p.line - buffer.firstLine, buffer: buffer)
            while let start = index {
                let r = spanMatches(startingAt: start, buffer: buffer, context: context)
                for m in r.matches.reversed() where m.start < p { return m }
                index = start > 0 ? spanStart(ofIndex: start - 1, buffer: buffer) : nil
            }
        }
        return lastMatch(buffer: buffer, context: context)
    }

    /// The very first match in the buffer — where `findNext` wraps to.
    private func firstMatch(buffer: Buffer, context: ScanContext) -> SearchMatch? {
        let count = buffer.lines.count
        var index = 0
        while index < count {
            let r = spanMatches(startingAt: index, buffer: buffer, context: context)
            if let first = r.matches.first { return first }
            index = r.endIndex + 1
        }
        return nil
    }

    /// The very last match in the buffer — where `findPrevious` wraps to.
    private func lastMatch(buffer: Buffer, context: ScanContext) -> SearchMatch? {
        var index = buffer.lines.count - 1
        while index >= 0 {
            let start = spanStart(ofIndex: index, buffer: buffer)
            let r = spanMatches(startingAt: start, buffer: buffer, context: context)
            if let last = r.matches.last { return last }
            index = start - 1
        }
        return nil
    }

    /// Half-open column ranges the matches cover on `line`, for the renderer.
    /// The range of a match ending on a wide character covers its spacer too.
    public func matches(onLine line: Int) -> [Range<Int>] {
        let all = findAll(limit: cachedLimit > 0 ? cachedLimit : SearchEngine.defaultLimit)
        guard !all.isEmpty, let terminal else { return [] }
        let buffer = terminal.buffer
        let row = buffer.row(line: line)
        let cols = row?.cols ?? buffer.cols
        var out: [Range<Int>] = []
        for m in all {
            guard m.start.line <= line, line <= m.end.line else { continue }
            let lo = line == m.start.line ? m.start.col : 0
            var hi: Int
            if line == m.end.line {
                var width = 1
                if let row, m.end.col >= 0, m.end.col < row.cols {
                    width = Swift.max(row[m.end.col].width, 1)
                }
                hi = m.end.col + width
            } else {
                hi = cols
            }
            hi = Swift.min(hi, cols)
            if lo < hi { out.append(lo..<hi) }
        }
        return out
    }

    // MARK: - logical lines

    private struct LogicalLine {
        var scalars: [Unicode.Scalar] = []
        var lines: [Int] = []
        var columns: [Int32] = []
        /// Ring index of the last row of the logical line.
        var endIndex = 0
        /// Identity and generation of every row of the span, in order, so the
        /// matches built from it can be cached and re-validated cheaply.
        var rowIDs: [ObjectIdentifier] = []
        var generations: [UInt64] = []
    }

    /// Ceiling on how many matches one logical line may contribute. A logical
    /// line can be the whole scrollback (every row soft-wrapped), and a
    /// one-character term would then produce millions of matches to cache.
    static let maxMatchesPerLine = 10_000

    /// Longest span (in rows) worth keeping in `lineCache`. A `lineCache` entry
    /// is only valid while every row of the span is untouched, so a span of
    /// hundreds of rows is thrown away by the next byte written anywhere in it —
    /// copying its signature would be paid on every frame and never repay.
    /// 64 rows is far past any real wrapped CLI line (25,600 characters at 400
    /// columns) and caps one entry at 64 identities plus 64 generations.
    /// Anything longer goes to `spanCache`, which is *resumable* and therefore
    /// does repay its signature.
    static let maxCachedSpan = 64

    /// Ceiling on the rows of signature the whole cache may hold. The spans of
    /// one pass partition the ring, so the useful volume is the ring's own
    /// size; the slack is for entries left by earlier partitions when the
    /// wrapping changes. At 16 bytes a row this is a few megabytes, against
    /// the ~100M rows the count-based prune allowed on a wrapped history.
    static let maxSignatureRows = 262_144

    /// Keep the matches of one logical line, unless the entry would cost more
    /// than it can save. The stale entry at `line` is dropped either way: the
    /// only way here is a cache miss, so whatever sat there has already failed
    /// to validate.
    ///
    /// `unbounded` lifts the span cap for the regex path: that path cannot
    /// resume (no `spanCache`), so a logical line longer than the cap was
    /// re-matched from scratch on every paint that moved the change counter
    /// — one byte of output on a 200,000-scalar line cost `a{100}b` 211 ms
    /// per frame. The signature budget still bounds the memory.
    private func store(_ value: LineMatches, at line: Int, unbounded: Bool = false) {
        if let stale = lineCache.removeValue(forKey: line) {
            lineCacheSignatureRows -= stale.rowIDs.count
        }
        let span = value.rowIDs.count
        guard span <= SearchEngine.maxCachedSpan || unbounded,
              lineCacheSignatureRows + span <= SearchEngine.maxSignatureRows else { return }
        lineCache[line] = value
        lineCacheSignatureRows += span
    }

    /// Forget the logical lines and the row text that have scrolled off the
    /// top. Only the keys between the previous first line and the new one can
    /// have gone, so the sweep costs what it evicts — the old count-based
    /// prune instead held every stale entry until there were more of them than
    /// there were lines, which on a soft-wrapped history is one entry per row
    /// of the whole ring, each carrying the signature of the whole ring.
    private func evictScrolledOff(buffer: Buffer) {
        let count = buffer.lines.count
        guard count > 0 else {
            lineCache.removeAll(keepingCapacity: true)
            lineCacheSignatureRows = 0
            spanCache.removeAll(keepingCapacity: true)
            spanCacheSignatureRows = 0
            rowCache.removeAll(keepingCapacity: true)
            lastFirstLine = nil
            return
        }
        let first = buffer.lineNumber(atIndex: 0)
        defer { lastFirstLine = first }
        guard let previous = lastFirstLine, previous != first else { return }
        // A ring only ever trims from the top; a first line that went backwards
        // means the numbering moved under us and nothing keyed on it is usable.
        guard first > previous else {
            invalidate()
            rowCache.removeAll(keepingCapacity: true)
            return
        }
        // Output that ran for longer than the find bar was open can leave a gap
        // wider than the caches are: walking it key by key would then cost more
        // than looking at every entry once.
        guard first - previous <= lineCache.count + rowCache.count else {
            let last = buffer.lineNumber(atIndex: count - 1)
            lineCache = lineCache.filter { $0.key >= first && $0.key <= last }
            lineCacheSignatureRows = lineCache.values.reduce(0) { $0 + $1.rowIDs.count }
            spanCache = spanCache.filter { $0.key >= first && $0.key <= last }
            spanCacheSignatureRows = spanCache.values.reduce(0) { $0 + $1.rowIDs.count }
            rowCache = rowCache.filter { $0.key >= first && $0.key <= last }
            return
        }
        for line in previous..<first {
            if let gone = lineCache.removeValue(forKey: line) {
                lineCacheSignatureRows -= gone.rowIDs.count
            }
            dropSpan(at: line)
            rowCache.removeValue(forKey: line)
        }
    }

    /// Identity of a row that is not allocated (an empty parked row). Rows are
    /// class instances, so any object of ours is a value no `Row` can collide
    /// with.
    private var unallocatedRowID: ObjectIdentifier { ObjectIdentifier(self) }

    /// The ring index the span starting at `startIndex` ends on, if the rows
    /// are still the ones `hit` was built from and nothing has been wrapped
    /// onto its end. `nil` means the cached matches cannot be trusted.
    private func validateSpan(_ hit: LineMatches, startingAt startIndex: Int, buffer: Buffer) -> Int? {
        let count = buffer.lines.count
        let span = hit.rowIDs.count
        guard span > 0, startIndex + span <= count else { return nil }
        for k in 0..<span {
            let row = buffer.lines.allocatedRow(at: startIndex + k)
            let id = row.map(ObjectIdentifier.init) ?? unallocatedRowID
            guard id == hit.rowIDs[k], (row?.generation ?? 0) == hit.generations[k] else { return nil }
            // Every row after the first was a soft continuation when the span
            // was built; `wrapped` bumps the generation, so the check above
            // already covers a row that stopped being one.
        }
        let end = startIndex + span - 1
        // A row appended after the span may have extended the logical line.
        if end + 1 < count, buffer.lines.allocatedRow(at: end + 1)?.wrapped == true { return nil }
        return end
    }

    /// Rows joined while the *next* row is a soft continuation, as one scalar
    /// run plus the (line, column) each scalar came from.
    private func buildLogicalLine(startingAt startIndex: Int, buffer: Buffer) -> LogicalLine {
        var out = LogicalLine()
        out.endIndex = startIndex
        let count = buffer.lines.count
        var index = startIndex
        while index < count {
            let row = buffer.lines.allocatedRow(at: index)
            out.rowIDs.append(row.map(ObjectIdentifier.init) ?? unallocatedRowID)
            out.generations.append(row?.generation ?? 0)
            let wrapsToNext = index + 1 < count
                && (buffer.lines.allocatedRow(at: index + 1)?.wrapped ?? false)

            appendSegment(at: index, buffer: buffer, wrapsToNext: wrapsToNext,
                          scalars: &out.scalars, columns: &out.columns, lines: &out.lines)

            if wrapsToNext {
                out.endIndex = index + 1
                index += 1
            } else {
                out.endIndex = index
                break
            }
        }
        return out
    }

    /// Everything the row at ring index `index` contributes to its logical
    /// line, appended to the three parallel arrays. `wrapsToNext` is the
    /// caller's decision — it already knows where the span ends — and shapes
    /// the two boundary rules that make a soft wrap read as continuous text.
    private func appendSegment(at index: Int, buffer: Buffer, wrapsToNext: Bool,
                               scalars: inout [Unicode.Scalar],
                               columns: inout [Int32],
                               lines: inout [Int]) {
        let line = buffer.lineNumber(atIndex: index)
        let row = buffer.lines.allocatedRow(at: index)
        let cols = row?.cols ?? buffer.cols
        let text = rowText(line: line, row: row, cols: cols)
        scalars.append(contentsOf: text.scalars)
        columns.append(contentsOf: text.columns)
        for _ in text.scalars { lines.append(line) }
        guard wrapsToNext else { return }

        // How much of this row is content? Exactly the question reflow asks, so
        // it is asked with reflow's own answer: `Buffer.wrappedTrimmedLength`
        // reads the wrap gap the emulator RECORDED (`Row.wrapGapBefore`) rather
        // than guessing it back out of the cells. Guessing is what this used to
        // do — "last cell NUL and the next row starts wide" — and an overwrite
        // leaves the identical shape with no gap anywhere, so `ab界界` with the
        // 界 overwritten by `c` lost the real space at the end of the row: `c 界`
        // found nothing and `c界` matched, and a resize that changed no text
        // made both correct again because reflow and search disagreed about what
        // the logical line contained. One question, one answer, one function.
        let next = buffer.lines.allocatedRow(at: index + 1)
        var contentLength = cols
        if let row, let next, cols > 0, next.cols > 0 {
            contentLength = buffer.wrappedTrimmedLength(row, next: next, cols: cols)
        }

        // The cells past `trimmedLength` are empty and print as spaces; they
        // are part of the logical line because the text continues.
        if text.trimmedLength < contentLength {
            for c in text.trimmedLength..<contentLength {
                scalars.append(" ")
                columns.append(Int32(c))
                lines.append(line)
            }
        } else if text.trimmedLength > contentLength {
            // The row ends in a wrap gap: the wide character that made it is on
            // the next row, and the cell it left behind is not text.
            while let c = columns.last, c >= Int32(contentLength), lines.last == line {
                scalars.removeLast()
                columns.removeLast()
                lines.removeLast()
            }
        }
    }

    /// Text of one row, from the cache when its generation has not moved.
    private func rowText(line: Int, row: Row?, cols: Int) -> RowText {
        guard let row else {
            return RowText(rowID: ObjectIdentifier(self), generation: 0, scalars: [],
                           columns: [], trimmedLength: 0, cols: cols)
        }
        if let hit = rowCache[line], hit.rowID == ObjectIdentifier(row),
           hit.generation == row.generation, hit.cols == row.cols {
            return hit
        }
        let built = buildRowText(row)
        rowCache[line] = built
        return built
    }

    /// Mirror of `Row.string(trimRight: true)`, recording the head column of
    /// every scalar as it goes.
    private func buildRowText(_ row: Row) -> RowText {
        rowStringifyCount += 1
        let end = row.trimmedLength
        var scalars: [Unicode.Scalar] = []
        var columns: [Int32] = []
        scalars.reserveCapacity(end)
        columns.reserveCapacity(end)
        var i = 0
        while i < end {
            let c = row[i]
            if c.isCombined, let s = row.combinedString(at: i) {
                for u in s.unicodeScalars {
                    scalars.append(u)
                    columns.append(Int32(i))
                }
            } else if c.code == 0 {
                scalars.append(" ")
                columns.append(Int32(i))
            } else {
                scalars.append(Unicode.Scalar(c.code) ?? "\u{FFFD}")
                columns.append(Int32(i))
            }
            i += Swift.max(c.width, 1)
        }
        return RowText(rowID: ObjectIdentifier(row), generation: row.generation,
                       scalars: scalars, columns: columns,
                       trimmedLength: end, cols: row.cols)
    }

    /// Backstop for row text that `evictScrolledOff` cannot reach: a row whose
    /// line number is above the ring's last one, left by a screen that shrank.
    private func pruneRowCache(buffer: Buffer) {
        let count = buffer.lines.count
        guard rowCache.count > count + 64 else { return }
        guard count > 0 else {
            rowCache.removeAll(keepingCapacity: true)
            return
        }
        let first = buffer.lineNumber(atIndex: 0)
        let last = buffer.lineNumber(atIndex: count - 1)
        rowCache = rowCache.filter { $0.key >= first && $0.key <= last }
    }

    // MARK: - one logical line

    /// What one logical line contributed to a pass.
    private struct SpanResult {
        /// Ring index of the last row of the logical line.
        var endIndex: Int
        var matches: [SearchMatch]
        /// This line was not searched all the way through.
        var incomplete = false
    }

    /// The whole-line path: build every scalar of the logical line and match
    /// all of it. This is what regex gets, and it is deliberate — an arbitrary
    /// pattern can look further back than any fixed window (`^`, `\b`, a
    /// lookbehind, a greedy quantifier), so there is no overlap width that
    /// makes resuming provably safe. A correct slow path beats a fast wrong one.
    private func matchWholeSpan(startingAt startIndex: Int, startLine: Int, buffer: Buffer,
                                needle: [Unicode.Scalar], failure: [Int],
                                regex rx: LinearRegex?) -> SpanResult {
        let logical = buildLogicalLine(startingAt: startIndex, buffer: buffer)
        guard !logical.scalars.isEmpty else {
            store(LineMatches(rowIDs: logical.rowIDs, generations: logical.generations, matches: []),
                  at: startLine, unbounded: rx != nil)
            return SpanResult(endIndex: logical.endIndex, matches: [])
        }

        logicalMatchCount += 1
        var lineMatches: [SearchMatch] = []
        func position(_ r: Range<Int>) -> SearchMatch {
            SearchMatch(start: Position(line: logical.lines[r.lowerBound],
                                        col: Int(logical.columns[r.lowerBound])),
                        end: Position(line: logical.lines[r.upperBound - 1],
                                      col: Int(logical.columns[r.upperBound - 1])))
        }
        var incomplete = false
        if let rx {
            let run = regexRanges(in: logical.scalars, regex: rx)
            incomplete = run.exhausted
            lineMatches.reserveCapacity(run.ranges.count)
            for r in run.ranges { lineMatches.append(position(r)) }
        } else {
            // The cap stops the scan itself, so a one-character term on a
            // logical line that is the whole scrollback allocates the matches
            // it keeps and no more.
            plainRanges(in: logical.scalars, needle: needle, failure: failure) { r in
                guard !options.wholeWord || SearchEngine.isWholeWord(r, in: logical.scalars) else {
                    return .rejected
                }
                lineMatches.append(position(r))
                return lineMatches.count < SearchEngine.maxMatchesPerLine ? .accepted : .stop
            }
        }
        store(LineMatches(rowIDs: logical.rowIDs, generations: logical.generations,
                          matches: lineMatches, incomplete: incomplete),
              at: startLine, unbounded: rx != nil)
        return SpanResult(endIndex: logical.endIndex, matches: lineMatches, incomplete: incomplete)
    }

    // MARK: - resumable spans

    /// Longest plain term the resumable path will carry across a row boundary.
    /// The resume window is the term wide and a copy of it is parked at every
    /// checkpoint, so a pathological term would trade the time saved back for
    /// memory. A term this long is not a find-bar search; it takes the
    /// whole-line path instead.
    static let maxResumableNeedle = 256

    /// Rows between the resume points of a long span. A change lands at most
    /// this many rows after the checkpoint it resumes from, so the re-scan a
    /// frame pays is bounded by `checkpointStride * cols` scalars — 1,280 at 80
    /// columns — however long the logical line is.
    static let checkpointStride = 16

    /// The scan state at a row boundary of a long logical line: enough to pick
    /// the matcher up mid-line and produce exactly what a run from the top of
    /// the line would have produced.
    private struct SpanCheckpoint {
        /// Row of the span this state sits *before*.
        var rowOffset: Int
        /// The overlap window — the last scalars before the boundary, with the
        /// cell each came from. A match may straddle the boundary by at most
        /// `term.count - 1` scalars (one more with `wholeWord`, which reads the
        /// scalar on each side), so this is all the context that can matter.
        var scalars: [Unicode.Scalar]
        var columns: [Int32]
        var lines: [Int]
        /// Index in the window of the leftmost candidate start still alive.
        /// Everything before it has been ruled out — by a mismatch, by an
        /// accepted match consuming the term, or by `wholeWord` refusing a
        /// candidate — and that history is the part no amount of re-reading
        /// text could recover.
        var next: Int
        /// How many matches the line had produced by this point.
        var matchCount: Int
    }

    /// A logical line too long for `lineCache`, matched incrementally. Kept
    /// apart from `lineCache` because the two answer different questions:
    /// `lineCache` is all-or-nothing and is bounded by refusing long spans,
    /// while this one exists precisely for them and earns its signature back by
    /// re-matching only the rows after the first one that moved.
    private struct SpanMatches {
        var rowIDs: [ObjectIdentifier]
        var generations: [UInt64]
        var matches: [SearchMatch]
        var checkpoints: [SpanCheckpoint]
    }

    private var spanCache: [Int: SpanMatches] = [:]

    /// Rows of signature `spanCache` holds, bounded exactly like `lineCache`'s.
    private(set) var spanCacheSignatureRows = 0

    /// Entries in `spanCache`. Tests watch this and `spanCacheSignatureRows`.
    var spanCacheEntryCount: Int { spanCache.count }

    private func storeSpan(_ value: SpanMatches, at line: Int) {
        dropSpan(at: line)
        guard spanCacheSignatureRows + value.rowIDs.count <= SearchEngine.maxSignatureRows else { return }
        spanCacheSignatureRows += value.rowIDs.count
        spanCache[line] = value
    }

    private func dropLine(at line: Int) {
        if let gone = lineCache.removeValue(forKey: line) {
            lineCacheSignatureRows -= gone.rowIDs.count
        }
    }

    private func dropSpan(at line: Int) {
        if let stale = spanCache.removeValue(forKey: line) {
            spanCacheSignatureRows -= stale.rowIDs.count
        }
    }

    /// One logical line, matched row by row and resumed from the last
    /// checkpoint at or before the first row that moved.
    ///
    /// The walk over the span is unavoidable — the end of a logical line is
    /// only knowable by reading the `wrapped` flag of every row of it — but it
    /// is two loads and two compares a row. Everything expensive (turning cells
    /// into scalars, folding them, running the matcher) happens only from the
    /// checkpoint onwards.
    private func matchSpan(startingAt startIndex: Int, startLine: Int, buffer: Buffer,
                           needle: [Unicode.Scalar], failure: [Int]) -> SpanResult {
        let count = buffer.lines.count
        let cached = spanCache[startLine]

        // Pass 1: the span's signature, and where it first differs from the
        // signature the cached matches were built from.
        var rowIDs: [ObjectIdentifier] = []
        var generations: [UInt64] = []
        var firstDirty = Int.max
        var endIndex = startIndex
        var index = startIndex
        var row = index < count ? buffer.lines.allocatedRow(at: index) : nil
        while index < count {
            let id = row.map(ObjectIdentifier.init) ?? unallocatedRowID
            let generation = row?.generation ?? 0
            let offset = rowIDs.count
            rowIDs.append(id)
            generations.append(generation)
            if firstDirty == Int.max, let cached {
                if offset >= cached.rowIDs.count || cached.rowIDs[offset] != id
                    || cached.generations[offset] != generation { firstDirty = offset }
            }
            endIndex = index
            let next = index + 1 < count ? buffer.lines.allocatedRow(at: index + 1) : nil
            guard next?.wrapped == true else { break }
            index += 1
            row = next
        }
        let span = rowIDs.count
        guard span > 0 else { return SpanResult(endIndex: endIndex, matches: []) }

        if let cached, firstDirty == Int.max, cached.rowIDs.count == span {
            // Not one row of the line moved: it keeps every match it had.
            return SpanResult(endIndex: endIndex, matches: cached.matches)
        }
        if cached == nil {
            firstDirty = 0
        } else if firstDirty == Int.max {
            // Every row compared equal but the line is no longer the same
            // length: the last row of it is the one to redo.
            firstDirty = span
        }
        // The row above the first changed one has to be redone too: its segment
        // ends in the padding and wide-character rules, and both read the row
        // below it.
        let redoFrom = Swift.min(Swift.max(0, firstDirty - 1), span - 1)

        var scanner = SpanScanner(needle: needle,
                                  failure: failure,
                                  caseSensitive: options.caseSensitive,
                                  wholeWord: options.wholeWord)
        var checkpoints: [SpanCheckpoint] = []
        var offset = 0
        if let cached, let k = cached.checkpoints.lastIndex(where: { $0.rowOffset <= redoFrom }) {
            let checkpoint = cached.checkpoints[k]
            checkpoints = cached.checkpoints
            checkpoints.removeSubrange((k + 1)...)
            scanner.restore(checkpoint)
            scanner.matches = Array(cached.matches.prefix(checkpoint.matchCount))
            offset = checkpoint.rowOffset
        }
        dropSpan(at: startLine)

        // Pass 2: text and matching, from the resume point to the end.
        let resumedAt = offset
        var produced = 0
        index = startIndex + offset
        while offset < span {
            let isLast = offset == span - 1
            let mark = scanner.scalars.count
            appendSegment(at: index, buffer: buffer, wrapsToNext: !isLast,
                          scalars: &scanner.scalars, columns: &scanner.columns,
                          lines: &scanner.lines)
            produced += scanner.scalars.count - mark
            scanner.foldAppended(from: mark)
            scanner.scan(isLastRow: isLast)
            offset += 1
            index += 1
            if scanner.capped { break }
            scanner.trim()
            // Checkpoints only pay for themselves on a line `lineCache` will
            // not take; below that bound a miss re-matches at most 64 rows.
            if offset < span, offset >= SearchEngine.maxCachedSpan,
               offset % SearchEngine.checkpointStride == 0 {
                checkpoints.append(scanner.checkpoint(atRowOffset: offset))
            }
        }

        let matches = scanner.matches
        // An empty logical line still earns its entry — it proves there is
        // nothing to find there — but it was never "matched". A line resumed
        // part way through obviously had text before the resume point.
        if resumedAt > 0 || produced > 0 { logicalMatchCount += 1 }
        if span <= SearchEngine.maxCachedSpan {
            store(LineMatches(rowIDs: rowIDs, generations: generations, matches: matches), at: startLine)
        } else {
            // The line has outgrown `lineCache`. An entry from when it was
            // short would now be validated — and fail — on every frame, and
            // would hold its rows against the signature budget until the line
            // scrolled off. `store` drops it as part of writing; this path
            // does not go through `store`, so it drops it here.
            dropLine(at: startLine)
        }
        if span > SearchEngine.maxCachedSpan, !scanner.capped {
            // A capped line stopped scanning part way through, so its
            // checkpoints describe a line the matcher never finished: it is
            // cheaper to leave it out than to teach the resume about the cap.
            storeSpan(SpanMatches(rowIDs: rowIDs, generations: generations,
                                  matches: matches, checkpoints: checkpoints),
                      at: startLine)
        }
        return SpanResult(endIndex: endIndex, matches: matches)
    }

    /// The plain matcher, fed one row segment at a time.
    ///
    /// It produces exactly what `plainRanges` produces over the whole logical
    /// line: candidates are tried left to right, an accepted one consumes the
    /// term (so matches never overlap), and anything else — a mismatch, or a
    /// candidate `wholeWord` refuses — leaves the starts after it alive. The
    /// only difference is *when* a candidate is judged: one that would run past
    /// the end of what has arrived waits for the next row, which changes
    /// nothing about the answer, only how much of the line has to be in memory
    /// at once. Both halves walk their text once (KMP); the two must keep
    /// agreeing, and `incrementalMatchesColdEngine` is what says they do.
    private struct SpanScanner {
        let needle: [Unicode.Scalar]
        /// KMP border table of `needle` (`SearchEngine.kmpFailure`), built once
        /// for the whole pass by `beginScan`.
        let failure: [Int]
        let caseSensitive: Bool
        let wholeWord: Bool

        /// The live window: the scalars a match could still start in or reach
        /// into, with the cell each came from. Trimmed after every row to the
        /// term's width, which is why a logical line of any length costs the
        /// same to scan through.
        var scalars: [Unicode.Scalar] = []
        var columns: [Int32] = []
        var lines: [Int] = []
        /// `scalars` folded for comparison, same count. Folding is per scalar
        /// (`SearchEngine.fold` leaves anything whose lowercase form is not one
        /// scalar alone), so these offsets never drift from the cell map.
        var folded: [Unicode.Scalar] = []
        /// Index in the window of the next candidate start.
        var next = 0
        var matches: [SearchMatch] = []
        /// The per-line cap fired: this line is finished, wherever it stopped.
        var capped = false

        mutating func foldAppended(from mark: Int) {
            if caseSensitive {
                folded.append(contentsOf: scalars[mark...])
            } else {
                folded.reserveCapacity(scalars.count)
                for k in mark..<scalars.count { folded.append(SearchEngine.fold(scalars[k])) }
            }
        }

        /// Judge every candidate the window can now decide. On any row but the
        /// last, `wholeWord` also needs the scalar *after* the match, so a
        /// candidate that ends exactly at the row boundary waits for the row
        /// below — the same answer, one row later.
        ///
        /// KMP, exactly like `plainRanges`: the window is walked once, the
        /// border table takes the place of re-comparing from the next start.
        /// The scan restarts from `next` on every row rather than carrying the
        /// partial-match length across the boundary — `trim` has already cut
        /// the window down to the term's width, so the re-read is bounded by
        /// the term and not by the line.
        mutating func scan(isLastRow: Bool) {
            guard !capped else { return }
            let m = needle.count
            guard m > 0 else { return }
            // The last scalar a match may end on: with `wholeWord` on any row
            // but the last, the scalar after the match has to be in the window
            // already, so the final one is left for the next row.
            let limit = scalars.count - ((wholeWord && !isLastRow) ? 1 : 0)
            var i = next
            var k = 0
            while i < limit {
                while k > 0, folded[i] != needle[k] { k = failure[k - 1] }
                if folded[i] == needle[k] { k += 1 }
                i += 1
                guard k == m else { continue }
                let lo = i - m
                if !wholeWord || isWholeWord(lo, i) {
                    matches.append(SearchMatch(
                        start: Position(line: lines[lo], col: Int(columns[lo])),
                        end: Position(line: lines[i - 1], col: Int(columns[i - 1]))))
                    if matches.count >= SearchEngine.maxMatchesPerLine {
                        capped = true
                        next = i
                        return
                    }
                    // Accepted: the term is consumed, so matches never overlap.
                    k = 0
                } else {
                    // Refused by a rule the matcher does not know. The next
                    // candidate is one scalar on, NOT one term on — the border
                    // table resumes there without re-reading anything.
                    k = failure[m - 1]
                }
            }
            // `i - k` is the leftmost start still alive: everything before it
            // has been ruled out, and `trim` may drop it.
            next = i - k
        }

        /// `trim` always keeps the scalar before `next`, so a candidate at
        /// window index 0 can only be the very first scalar of the line.
        func isWholeWord(_ lo: Int, _ hi: Int) -> Bool {
            if lo > 0, SearchEngine.isWordScalar(scalars[lo - 1]) { return false }
            if hi < scalars.count, SearchEngine.isWordScalar(scalars[hi]) { return false }
            return true
        }

        /// Drop everything no candidate can reach any more, keeping the one
        /// scalar to the left of `next` that `wholeWord` reads.
        mutating func trim() {
            let drop = Swift.max(0, next - 1)
            guard drop > 0 else { return }
            scalars.removeFirst(drop)
            folded.removeFirst(drop)
            columns.removeFirst(drop)
            lines.removeFirst(drop)
            next -= drop
        }

        func checkpoint(atRowOffset offset: Int) -> SpanCheckpoint {
            SpanCheckpoint(rowOffset: offset, scalars: scalars, columns: columns, lines: lines,
                           next: next, matchCount: matches.count)
        }

        mutating func restore(_ c: SpanCheckpoint) {
            scalars = c.scalars
            columns = c.columns
            lines = c.lines
            next = c.next
            folded = []
            foldAppended(from: 0)
        }
    }

    // MARK: - matching

    private func foldedNeedle() -> [Unicode.Scalar] {
        let raw = Array(term.unicodeScalars)
        return options.caseSensitive ? raw : raw.map(SearchEngine.fold)
    }

    /// What the caller made of a candidate, and therefore where the scan picks
    /// up again.
    private enum PlainVerdict {
        /// Kept: the term is consumed, so reported matches never overlap.
        case accepted
        /// Refused by a rule the matcher does not know — today that is only
        /// `wholeWord`. The scan resumes ONE scalar on, not one term on: an
        /// overlapping start is a perfectly good match. Skipping the whole term
        /// here is what made `xa-a-a` searching `a-a` with Whole Word report
        /// nothing at all — the candidate at column 1 is refused (an `x` on its
        /// left), and the real match at columns 3–5 starts inside it.
        case rejected
        /// The caller has all it wants; stop scanning.
        case stop
    }

    /// Non-overlapping substring matches, scalar by scalar so that the offsets
    /// stay aligned with the cell map even when a character's lowercase form
    /// has a different length. Each range is handed to `body`, whose verdict
    /// says where to resume — so the caller's cap bounds the scanning and the
    /// allocation, not just the list that survives it.
    ///
    /// Knuth–Morris–Pratt over the folded scalars: each one is looked at once
    /// and the border table (`failure`, built once per pass in `beginScan`)
    /// moves the scan forward and never back, so the cost is O(haystack) after
    /// the O(term) table instead of the O(haystack x term) of comparing the
    /// term at every position. That is not a micro-optimisation: this runs
    /// synchronously from the render path (`TerminalView` builds the frame's
    /// search tint and its find-bar count through `findAll`), so a long term
    /// froze the window even with nothing to find. 1,000,000 `a`s as one
    /// soft-wrapped line, searching `a…ab`, at -O:
    ///
    ///     term length       16        256      4,096    16,384
    ///     before         0.027 s   0.268 s    2.673 s  11.530 s
    ///     after          0.017 s   0.025 s    0.020 s   0.017 s
    ///
    /// After the fix all four are the same figure, and it is not the matching:
    /// it is turning 1,000,000 cells into scalars and folding them, which every
    /// term pays once. `longTermIsLinear` guards the 16,384 case.
    ///
    /// (The 16 and 256 columns go through `SpanScanner`, which had the same
    /// compare-at-every-position loop and got the same treatment; 4,096 and
    /// 16,384 are past `maxResumableNeedle` and land here.)
    private func plainRanges(in hay: [Unicode.Scalar], needle: [Unicode.Scalar],
                             failure: [Int], _ body: (Range<Int>) -> PlainVerdict) {
        let n = hay.count, m = needle.count
        guard m > 0, n >= m else { return }
        // Fold the haystack once per logical line, not once per comparison.
        let folded = options.caseSensitive ? hay : hay.map(SearchEngine.fold)
        var i = 0
        var k = 0                       // scalars of `needle` matched so far
        while i < n {
            while k > 0, folded[i] != needle[k] { k = failure[k - 1] }
            if folded[i] == needle[k] { k += 1 }
            i += 1
            guard k == m else { continue }
            switch body((i - m)..<i) {
            case .stop: return
            case .accepted: k = 0               // consume the term: no overlap
            case .rejected: k = failure[m - 1]  // one scalar on, via the table
            }
        }
    }

    /// The regex half of the same contract.
    ///
    /// No queue, no deadline, no way for this to fail to answer: `LinearRegex`
    /// is a Thompson NFA simulation, so its cost is instructions x scalars on
    /// every input there is. What used to be here — hand the match to a queue,
    /// wait 50 ms, abandon the job — bounded the WAIT and not the work, and the
    /// abandoned matchers went on burning a core each for the life of the
    /// process (measured: 3.9 cores still busy after every tab holding them was
    /// closed, because the job was owned by the queue and not by the engine).
    ///
    /// `wholeWord` is applied here rather than inside the engine, so the
    /// per-line cap counts matches BEFORE the filter — unlike the plain path,
    /// whose scan stops when enough have survived it. It shows only on a
    /// contrived line: a pattern matching far more often than whole-word
    /// accepts, on a logical line long enough to reach 1,000 of them, reports
    /// fewer than the plain search would. Filtering inside the engine instead
    /// would mean handing it a word rule that is the caller's, and asking for
    /// "enough after filtering" has no bound at all.
    /// Work a regex may spend on ONE logical line, in thread-steps: linear in
    /// the line with a constant floor. Leftmost-first matching keeps the
    /// higher-priority threads running past a match (`a*c|a` keeps `a*c`
    /// alive to the end of the line for every `a` it reports), so a pattern
    /// shaped like that costs O(line) PER MATCH and a 20,000-scalar line with
    /// 10,000 matches took 2.4 s on the paint path. Past the budget the line's
    /// list is cut short; `regexBudgetExhaustions` counts it for the tests.
    static func regexBudget(for scalarCount: Int) -> Int { 64 * scalarCount + 1_000_000 }
    public private(set) var regexBudgetExhaustions = 0

    private func regexRanges(in scalars: [Unicode.Scalar],
                             regex: LinearRegex) -> (ranges: [Range<Int>], exhausted: Bool) {
        let run = regex.matches(in: scalars, limit: SearchEngine.maxMatchesPerLine,
                                budget: SearchEngine.regexBudget(for: scalars.count))
        if run.exhausted { regexBudgetExhaustions += 1 }
        let found = run.ranges
        guard options.wholeWord else { return (found, run.exhausted) }
        return (found.filter { SearchEngine.isWholeWord($0, in: scalars) }, run.exhausted)
    }

    private func compiledRegex() -> LinearRegex? {
        let ignoresCase = !options.caseSensitive
        if regexSource == term && regexIgnoresCase == ignoresCase { return regexValue }
        regexSource = term
        regexIgnoresCase = ignoresCase
        do {
            regexValue = try LinearRegex.compile(pattern: term, ignoresCase: ignoresCase)
            regexProblemValue = nil
        } catch {
            regexValue = nil
            regexProblemValue = (error as? LinearRegex.Failure) ?? .malformed
        }
        return regexValue
    }

    /// Static because both halves of the search call it and neither needs the
    /// engine — it reads only the scalars it is given.
    static func isWholeWord(_ r: Range<Int>, in scalars: [Unicode.Scalar]) -> Bool {
        if r.lowerBound > 0, SearchEngine.isWordScalar(scalars[r.lowerBound - 1]) { return false }
        if r.upperBound < scalars.count, SearchEngine.isWordScalar(scalars[r.upperBound]) { return false }
        return true
    }

    /// KMP border table: `failure[i]` is the length of the longest proper
    /// prefix of `needle[0...i]` that is also a suffix of it. Empty for an
    /// empty needle (both matchers guard on that).
    static func kmpFailure(_ needle: [Unicode.Scalar]) -> [Int] {
        var failure = [Int](repeating: 0, count: needle.count)
        var k = 0
        var i = 1
        while i < needle.count {
            while k > 0, needle[i] != needle[k] { k = failure[k - 1] }
            if needle[i] == needle[k] { k += 1 }
            failure[i] = k
            i += 1
        }
        return failure
    }

    // MARK: - scalar helpers

    /// Single-scalar case folding. A scalar whose lowercase form is not exactly
    /// one scalar (U+0130 and friends) is left alone so that string offsets and
    /// cell offsets never drift apart.
    @inline(__always)
    static func fold(_ s: Unicode.Scalar) -> Unicode.Scalar {
        let v = s.value
        if v < 128 {
            if v >= 65 && v <= 90 { return Unicode.Scalar(v + 32)! }
            return s
        }
        // Most non-ASCII text in a network CLI (Thai, CJK, box drawing) has no
        // case at all — skip the String round trip for it.
        guard s.properties.changesWhenLowercased else { return s }
        let lowered = String(s).lowercased().unicodeScalars
        if lowered.count == 1, let first = lowered.first { return first }
        return s
    }

    /// Word characters for `wholeWord`: letters, digits and `_`.
    @inline(__always)
    static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 128 {
            return (v >= 97 && v <= 122) || (v >= 65 && v <= 90) || (v >= 48 && v <= 57) || v == 95
        }
        let p = s.properties
        return p.isAlphabetic || p.numericType != nil
    }
}
