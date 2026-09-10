// SheepVT — the selection model.
//
// Pure model: it knows nothing about mice, pixels or views. Phase 3 turns a
// click into a `Position` and asks this object what is selected. Positions are
// scroll-invariant line numbers (`Buffer+Lines.swift`), so a selection survives
// output scrolling for free and only a reflow or a buffer switch invalidates it
// — the host clears the selection on both.
//
// "For free" holds for every scroll but one: a top-anchored scroll region whose
// bottom margin is above the last row reassigns the numbers of the rows below
// that margin without moving their text (`Buffer.scrollUp`), and this is the
// only holder of a line number with nothing to check it against. So the
// terminal tells it — see `shiftLines(atOrAfter:by:)` and
// `Terminal.linesRenumbered`, which every selection registers for in `init`.
//
// The four modes are the ones every macOS terminal offers: character (drag),
// word (double click), line (triple click) and block (option-drag). Word and
// line gestures keep the *unit* the anchor landed on and add whole units at the
// focus end, which is what a user dragging after a double click expects.
//
// The word/expression rules are ported from SwiftTerm `SelectionService.swift`
// (`selectWordOrExpression`, `simpleScanSelection`, `balancedSearchForward`,
// `balancedSearchBackward`), MIT. Two things differ: our bounds are inclusive
// on both ends (SwiftTerm's `end` is one past the last cell), and our runs
// continue across a soft-wrap boundary in both directions, because a wrapped
// row is the same logical line.

public final class Selection {
    public enum Mode: Sendable {
        case character
        /// Double click: whole words / blank runs / balanced expressions.
        case word
        /// Triple click: the whole logical line, wrapped rows included.
        case line
        /// Option-drag: the rectangle between anchor and focus.
        case block
    }

    /// Characters that count as part of a word beside letters and digits.
    /// Network CLI text is full of `10.0.0.1`, `Gi1/0/1`, `fe80::1`,
    /// `snake_case` and `dash-names`, so the default is `. _ - : /`.
    ///
    /// Set once at startup, before any terminal runs; it is deliberately a
    /// plain global (queue-confined like everything else in SheepVT).
    nonisolated(unsafe) public static var wordCharacters: Set<Character> = [".", "_", "-", ":", "/"]

    /// How far a balanced-expression search may wander from the clicked cell.
    /// SwiftTerm stops at the bottom of the screen; we have a 10,000-line
    /// scrollback, so the scan needs an explicit ceiling.
    static let balancedScanLines = 1_000

    /// Weak: the model outlives nothing. Every call is a no-op once it is gone.
    /// Assigning it re-registers for the renumbering notice below, so a
    /// selection pointed at another terminal hears from the right one.
    public weak var terminal: Terminal? {
        didSet { terminal?.registerLineNumberHolder(self) }
    }

    public private(set) var isActive = false
    public private(set) var mode: Mode = .character

    /// Where the gesture started and where it is now — the raw cells, before
    /// word/line expansion. Both inclusive.
    public private(set) var anchor: Position?
    public private(set) var focus: Position?

    /// Ordered bounds, `start <= end`, both **inclusive**. For `.block` they are
    /// the top-left and bottom-right corners of the rectangle.
    public private(set) var start: Position?
    public private(set) var end: Position?

    /// The expanded unit under the anchor / under the focus (identical to the
    /// bare cell in `.character` and `.block`).
    private var anchorUnit: (Position, Position)?
    private var focusUnit: (Position, Position)?

    public init(terminal: Terminal) {
        self.terminal = terminal
        // `didSet` does not fire from init.
        terminal.registerLineNumberHolder(self)
    }

    private var buffer: Buffer? { terminal?.buffer }

    // MARK: - gestures

    /// Start a gesture at `p`. `.word` and `.line` expand the anchor cell right
    /// away (a double or triple click selects something before any drag).
    public func begin(at p: Position, mode: Mode = .character) {
        guard let buf = buffer else { reset(); return }
        let q = clamped(p, buf)
        self.mode = mode
        anchor = q
        focus = q
        anchorUnit = unit(at: q, mode: mode, buf)
        focusUnit = anchorUnit
        isActive = true
        recompute(buf)
    }

    /// Drag or shift-click. `.word` and `.line` extend by whole units and always
    /// keep the unit the anchor landed on; a focus before the anchor simply
    /// swaps which end is `start` (the anchor itself never moves).
    public func extend(to p: Position) {
        guard isActive, let buf = buffer else { return }
        let q = clamped(p, buf)
        focus = q
        focusUnit = unit(at: q, mode: mode, buf)
        recompute(buf)
    }

    /// Everything the buffer still holds: the oldest retained line, column 0,
    /// through the newest line's last column.
    public func selectAll() {
        guard let buf = buffer, buf.lineCount > 0 else { reset(); return }
        let lastCol = Swift.max(buf.cols - 1, 0)
        let s = Position(line: buf.firstLine, col: 0)
        let e = Position(line: buf.lastLine, col: lastCol)
        mode = .character
        anchor = s
        focus = e
        anchorUnit = (s, s)
        focusUnit = (e, e)
        isActive = true
        start = s
        end = e
    }

    public func clear() { reset() }

    private func reset() {
        isActive = false
        mode = .character
        anchor = nil; focus = nil
        anchorUnit = nil; focusUnit = nil
        start = nil; end = nil
    }

    /// Drop what fell off the top of the scrollback. Returns false when nothing
    /// of the selection is left (the caller then treats it as "no selection").
    @discardableResult
    public func validate() -> Bool {
        guard isActive else { return false }
        guard let buf = buffer, buf.lineCount > 0, var s = start, var e = end else {
            reset()
            return false
        }
        let first = buf.firstLine
        let last = buf.lastLine
        if e.line < first || s.line > last {
            reset()
            return false
        }
        if s.line < first {
            // Only part of the selection fell off: clip the start to the first
            // line that is still there. `.block` keeps its left column, because
            // moving it to 0 would widen the rectangle.
            s = Position(line: first, col: mode == .block ? s.col : 0)
        }
        if e.line > last {
            e = Position(line: last, col: mode == .block ? e.col : Swift.max(buf.cols - 1, 0))
        }
        start = s
        end = e
        anchor = anchor.map { clamped($0, buf) }
        focus = focus.map { clamped($0, buf) }
        anchorUnit = anchorUnit.map { (clamped($0.0, buf), clamped($0.1, buf)) }
        focusUnit = focusUnit.map { (clamped($0.0, buf), clamped($0.1, buf)) }
        return true
    }

    /// A stretch of line numbers was reassigned without its text moving: every
    /// number at or above `line` is now `line + delta`. Only one scroll shape
    /// does this (`Terminal.linesRenumbered` explains which and why); an
    /// ordinary scroll leaves numbers alone and never gets here.
    ///
    /// Pure arithmetic on the eight positions this object holds — no re-scan of
    /// the grid. The text under a stored position has not changed, only its
    /// address, so re-running the word/line expansion would be both wasted work
    /// on the scroll loop's hot path and wrong: it would re-expand against a
    /// grid the user has not looked at yet. Every position has to move, or the
    /// bounds and the units they were computed from stop agreeing.
    ///
    /// The shift preserves ordering (the predicate is monotone in `line`), so
    /// `start <= end` still holds afterwards even when the range straddles the
    /// margin.
    func shiftLines(atOrAfter line: Int, by delta: Int) {
        guard isActive, delta != 0 else { return }
        @inline(__always)
        func move(_ p: Position) -> Position {
            p.line >= line ? Position(line: p.line + delta, col: p.col) : p
        }
        anchor = anchor.map(move)
        focus = focus.map(move)
        start = start.map(move)
        end = end.map(move)
        anchorUnit = anchorUnit.map { (move($0.0), move($0.1)) }
        focusUnit = focusUnit.map { (move($0.0), move($0.1)) }
    }

    // MARK: - reading the selection

    public var lineRange: ClosedRange<Int>? {
        guard isActive, let s = start, let e = end, s.line <= e.line else { return nil }
        return s.line...e.line
    }

    /// The cells selected on `line`, as a half-open column range; nil when the
    /// line is not part of the selection.
    public func columnRange(onLine line: Int) -> Range<Int>? {
        guard isActive, let buf = buffer, let s = start, let e = end else { return nil }
        guard line >= s.line, line <= e.line else { return nil }
        let cols = buf.cols
        let lo: Int
        let hi: Int
        if mode == .block {
            lo = Swift.min(s.col, e.col)
            hi = Swift.max(s.col, e.col) + 1
        } else {
            lo = (line == s.line) ? s.col : 0
            hi = (line == e.line) ? e.col + 1 : cols
        }
        return widened(lo, hi, onLine: line, buf)
    }

    public func contains(_ p: Position) -> Bool {
        columnRange(onLine: p.line)?.contains(p.col) ?? false
    }

    /// The selected text.
    ///
    /// Cells become characters exactly as `Row.string` does (code 0 → space,
    /// the trailing half of a wide char is skipped, a combined cell uses its
    /// side-table grapheme). Rows are joined with "\n" except where the next
    /// row is a soft continuation, in which case they are joined directly and
    /// the earlier row is **not** right-trimmed — those blanks are real text in
    /// the middle of a logical line. `.block` right-trims every row and always
    /// joins with "\n".
    public func text() -> String {
        guard isActive, let buf = buffer, let s = start, let e = end else { return "" }
        var out = ""
        var line = s.line
        while line <= e.line {
            guard let range = columnRange(onLine: line) else { line += 1; continue }
            if mode == .block {
                out += rowText(buf, line: line, range: range, trimRight: true)
                if line < e.line { out += "\n" }
            } else {
                let continues = line < e.line && (buf.row(line: line + 1)?.wrapped ?? false)
                out += rowText(buf, line: line, range: range, trimRight: !continues)
                if line < e.line && !continues { out += "\n" }
            }
            line += 1
        }
        return out
    }

    // MARK: - bounds

    private func recompute(_ buf: Buffer) {
        guard let a = anchorUnit, let f = focusUnit else { start = nil; end = nil; return }
        if mode == .block {
            guard let a0 = anchor, let f0 = focus else { start = nil; end = nil; return }
            start = Position(line: Swift.min(a0.line, f0.line), col: Swift.min(a0.col, f0.col))
            end = Position(line: Swift.max(a0.line, f0.line), col: Swift.max(a0.col, f0.col))
            return
        }
        // min/max over both units is the whole rule: it keeps the anchor unit,
        // adds the focus unit, and handles a focus before the anchor by itself.
        start = adjustedStart(Swift.min(a.0, f.0), buf)
        end = adjustedEnd(Swift.max(a.1, f.1), buf)
    }

    private func unit(at p: Position, mode: Mode, _ buf: Buffer) -> (Position, Position) {
        switch mode {
        case .character, .block: return (p, p)
        case .word: return wordUnit(at: p, buf)
        case .line: return lineUnit(at: p, buf)
        }
    }

    private func lineUnit(at p: Position, _ buf: Buffer) -> (Position, Position) {
        let range = buf.logicalLine(containing: p.line)
        return (Position(line: range.lowerBound, col: 0),
                Position(line: range.upperBound, col: Swift.max(buf.cols - 1, 0)))
    }

    private func clamped(_ p: Position, _ buf: Buffer) -> Position {
        Position(line: buf.clampLine(p.line),
                 col: Swift.min(Swift.max(p.col, 0), Swift.max(buf.cols - 1, 0)))
    }

    /// A start that landed on the trailing half of a wide character moves to
    /// its head, so the character is never cut in two.
    private func adjustedStart(_ p: Position, _ buf: Buffer) -> Position {
        guard p.col > 0, let row = buf.row(line: p.line), p.col < row.cols,
              row.cell(at: p.col).isSpacer else { return p }
        return Position(line: p.line, col: p.col - 1)
    }

    /// An end that landed on the head of a wide character takes its trailing
    /// half too.
    private func adjustedEnd(_ p: Position, _ buf: Buffer) -> Position {
        guard p.col >= 0, let row = buf.row(line: p.line), p.col + 1 < row.cols,
              row.cell(at: p.col).width == 2 else { return p }
        return Position(line: p.line, col: p.col + 1)
    }

    /// Clamp a column range to the row and grow it outwards so it never cuts a
    /// wide character in half. Idempotent: running it on already-adjusted
    /// bounds changes nothing.
    private func widened(_ lo: Int, _ hi: Int, onLine line: Int, _ buf: Buffer) -> Range<Int> {
        let cols = buf.cols
        var l = Swift.min(Swift.max(lo, 0), cols)
        var h = Swift.min(Swift.max(hi, 0), cols)
        if h < l { h = l }
        guard let row = buf.row(line: line) else { return l..<h }
        let n = Swift.min(cols, row.cols)
        if l > 0, l < n, row.cell(at: l).isSpacer { l -= 1 }
        if h > 0, h < n, row.cell(at: h).isSpacer { h += 1 }
        return l..<h
    }

    // MARK: - text of one row

    private func rowText(_ buf: Buffer, line: Int, range: Range<Int>, trimRight: Bool) -> String {
        guard let row = buf.row(line: line) else {
            // Never materialised: the whole row is blanks.
            return trimRight ? "" : String(repeating: " ", count: Swift.max(range.count, 0))
        }
        var out = ""
        out.reserveCapacity(range.count)
        var i = Swift.max(range.lowerBound, 0)
        let hi = Swift.min(range.upperBound, row.cols)
        while i < hi {
            let c = row.cell(at: i)
            if c.isCombined, let s = row.combinedString(at: i) {
                out += s
            } else if c.code == 0 {
                out.append(" ")
            } else {
                out.unicodeScalars.append(Unicode.Scalar(c.code) ?? "\u{FFFD}")
            }
            i += Swift.max(c.width, 1)
        }
        if trimRight {
            while out.last == " " { out.removeLast() }
        }
        return out
    }

    // MARK: - words and expressions

    private enum CharKind: Equatable {
        /// Code 0 or a space — a run of "nothing".
        case blank
        case word
        /// `(`, `[`, `{`
        case open
        /// `)`, `]`, `}`
        case close
        case other
    }

    /// The character in a cell, or nil when the cell holds nothing. A cell with
    /// a combining mark reports its whole grapheme, so `é` classifies as a
    /// letter whether it arrived precomposed or as e + U+0301.
    private func character(_ buf: Buffer, line: Int, col: Int) -> Character? {
        guard col >= 0, let row = buf.row(line: line), col < row.cols else { return nil }
        let c = row.cell(at: col)
        if c.isCombined, let s = row.combinedString(at: col), let first = s.first { return first }
        guard c.code != 0, let scalar = Unicode.Scalar(c.code) else { return nil }
        return Character(scalar)
    }

    /// The trailing half of a wide character belongs to its head: a run of CJK
    /// must not stop at the spacer between two glyphs.
    private func effectiveCol(_ buf: Buffer, line: Int, col: Int) -> Int {
        guard col > 0, let row = buf.row(line: line), col < row.cols,
              row.cell(at: col).isSpacer else { return col }
        return col - 1
    }

    private func kind(_ buf: Buffer, line: Int, col: Int) -> CharKind {
        guard let ch = character(buf, line: line, col: effectiveCol(buf, line: line, col: col)) else {
            return .blank
        }
        if ch == " " { return .blank }
        if ch.isLetter || ch.isNumber || Selection.wordCharacters.contains(ch) { return .word }
        if ch == "(" || ch == "[" || ch == "{" { return .open }
        if ch == ")" || ch == "]" || ch == "}" { return .close }
        return .other
    }

    /// Port of SwiftTerm `selectWordOrExpression`.
    private func wordUnit(at p: Position, _ buf: Buffer) -> (Position, Position) {
        switch kind(buf, line: p.line, col: p.col) {
        case .blank, .word: return scanRun(from: p, buf)
        case .open: return balancedForward(from: p, buf)
        case .close: return balancedBackward(from: p, buf)
        case .other: return (p, p)
        }
    }

    /// SwiftTerm `simpleScanSelection`, extended to walk over soft-wrap
    /// boundaries: a word split by the right margin is still one word.
    private func scanRun(from p: Position, _ buf: Buffer) -> (Position, Position) {
        let target = kind(buf, line: p.line, col: p.col)
        let cols = buf.cols
        guard cols > 0 else { return (p, p) }

        var lo = p
        var line = p.line
        var col = p.col
        while true {
            var pl = line
            var pc = col - 1
            if pc < 0 {
                guard buf.isWrapped(line: line) else { break }
                pl = line - 1
                pc = cols - 1
            }
            guard kind(buf, line: pl, col: pc) == target else { break }
            line = pl; col = pc
            lo = Position(line: pl, col: pc)
        }

        var hi = p
        line = p.line
        col = p.col
        while true {
            var nl = line
            var nc = col + 1
            if nc >= cols {
                guard line < buf.lastLine, buf.row(line: line + 1)?.wrapped == true else { break }
                nl = line + 1
                nc = 0
            }
            guard kind(buf, line: nl, col: nc) == target else { break }
            line = nl; col = nc
            hi = Position(line: nl, col: nc)
        }
        return (lo, hi)
    }

    /// SwiftTerm `balancedSearchForward`, with an inclusive end.
    private func balancedForward(from p: Position, _ buf: Buffer) -> (Position, Position) {
        let cols = buf.cols
        let limit = Swift.min(buf.lastLine, p.line + Selection.balancedScanLines)
        var wait: [Character] = []
        var line = p.line
        var col = p.col
        while line <= limit {
            while col < cols {
                if let ch = character(buf, line: line, col: col) {
                    if ch == "(" { wait.append(")") }
                    else if ch == "[" { wait.append("]") }
                    else if ch == "{" { wait.append("}") }
                    else if let want = wait.last, want == ch {
                        wait.removeLast()
                        if wait.isEmpty { return (p, Position(line: line, col: col)) }
                    }
                }
                col += 1
            }
            col = 0
            line += 1
        }
        return (p, p)
    }

    /// SwiftTerm `balancedSearchBackward`, with an inclusive end.
    private func balancedBackward(from p: Position, _ buf: Buffer) -> (Position, Position) {
        let cols = buf.cols
        let limit = Swift.max(buf.firstLine, p.line - Selection.balancedScanLines)
        var wait: [Character] = []
        var line = p.line
        var col = p.col
        while line >= limit {
            while col >= 0 {
                if let ch = character(buf, line: line, col: col) {
                    if ch == ")" { wait.append("(") }
                    else if ch == "]" { wait.append("[") }
                    else if ch == "}" { wait.append("{") }
                    else if let want = wait.last, want == ch {
                        wait.removeLast()
                        if wait.isEmpty { return (Position(line: line, col: col), p) }
                    }
                }
                col -= 1
            }
            col = cols - 1
            line -= 1
        }
        return (p, p)
    }
}
