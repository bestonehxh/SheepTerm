// FuzzTests.swift — SheepVT
//
// Everything else the emulator is tested against is well-formed: the xterm.js
// escape-sequence fixtures agree with a real terminal, and the device-log
// replay corpus only compares three *feeding orders* of the same bytes against
// each other — a sequence that corrupts the grid identically all three ways
// passes it.
//
// This file is the other half: hostile-but-plausible bytes, and an oracle that
// is a set of **grid invariants** rather than a golden output. The generator is
// seeded (`Xorshift64RNG`, shared with `ReplayTests`) and the seed is printed,
// so a failure is reproducible; when one fires, `FuzzRunner.reduce` delta-debugs
// the op list into a minimal script and prints it as a paste-ready repro.
//
//   ./Tests/run.sh vt -c release --filter fuzzGrid            (well under a second)
//   SHEEPVT_FUZZ_CASES=200000 ./Tests/run.sh vt -c release --filter fuzzGrid
//   SHEEPVT_FUZZ_SEED=0x…                                     (a specific run)
//   SHEEPVT_FUZZ_SUPPRESS=kind,kind                           (triage: ignore a
//                                                              known bug so the
//                                                              run gets past it)
//
// The invariants live in `GridInvariants.check`, each tagged with a stable
// `kind` so failures can be deduplicated and suppressed. They are the
// properties every other layer silently assumes: no orphan half of a wide
// character, side tables that agree with the flag bits in the cells, a cursor
// inside the grid, line numbers that round-trip, a hyperlink table inside its
// budget. Selection and search are run against the same grids, because they
// consume line numbers and row identity and must never hand back a position
// that does not exist.
//
// Known-bad cases found by this fuzzer live in `FuzzFindingsTests.swift` as
// standalone failing tests.
//
// Finding 1 (the spacer half of a wide character claiming an extended-attribute
// entry it does not have) is **fixed** — `Pen.cell` no longer sets the flag — so
// `fuzzGrid` is green with no suppression, and
// `SHEEPVT_FUZZ_SUPPRESS=extended-flag-without-entry` is only of historical
// interest. Runs recorded while it was still open (that suppression on):
//
//   * 400,000 cases / 399 MB of hostile bytes (10m 24s) — no other invariant
//     broken
//   * 200,000 cases / 199 MB again (5m 30s) once the loopback delegate, the
//     live selection, the regex search terms and the findNext/findPrevious
//     walk agreement were added — still nothing
//   * 120,000 cases each of chunk-invariance (120 MB), reflow round-trip
//     (2.9 M logical lines) and search-cache agreement (25 M comparisons)
//     in `FuzzDifferentialTests` / `FuzzReflowTests` — all clean
//
// Since the fix, at 3.0 (54) + the viewport-anchor change: 6,000 cases (20x the
// default) of `fuzzGrid`, `fuzzChunkInvariance`, `fuzzSearchCache`,
// `fuzzSelectionSurvivesRegionScroll` and `fuzzReflow` under each of five seeds
// (the default, 0x1, 0xDEADBEEFCAFEF00D, 0x0BADC0DE12345678, 0xFFFF…FFFF) —
// 30,000 cases and ~30 MB of hostile bytes per suite, nothing reported. The one
// thing that did break is in `FuzzReflowTests.fuzzReflowLineOps`, the new IL/DL
// stream: finding 2 in `FuzzFindingsTests.swift`.

import Foundation
import Testing

@testable import SheepVT

// MARK: - the op script

/// One step of a fuzz case. A case is a list of these; reduction removes and
/// shrinks them.
enum FuzzOp: Equatable {
    case feed([UInt8])
    case resize(cols: Int, rows: Int)
    /// `Terminal.scrollback = n` — trims history and reallocates the ring.
    case setScrollback(Int)
    /// The user scrolling the viewport (moves `ydisp` only).
    case scrollViewport(Int)
    /// Start/extend a selection at a *relative* position: line = firstLine +
    /// (l % lineCount), col = c % cols, so the op survives reduction and a
    /// change of geometry.
    case select(mode: Int, l0: Int, c0: Int, l1: Int, c1: Int)

    var byteCount: Int {
        switch self {
        case .feed(let b): return b.count
        default: return 0
        }
    }
}

struct FuzzCase {
    var cols: Int
    var rows: Int
    var scrollback: Int
    var ops: [FuzzOp]

    /// A paste-ready Swift literal for a regression test.
    func literal() -> String {
        var s = "FuzzCase(cols: \(cols), rows: \(rows), scrollback: \(scrollback), ops: [\n"
        for op in ops {
            switch op {
            case .feed(let b):
                let hex = b.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
                s += "    .feed([\(hex)]),\n"
            case .resize(let c, let r):
                s += "    .resize(cols: \(c), rows: \(r)),\n"
            case .setScrollback(let n):
                s += "    .setScrollback(\(n)),\n"
            case .scrollViewport(let n):
                s += "    .scrollViewport(\(n)),\n"
            case .select(let m, let l0, let c0, let l1, let c1):
                s += "    .select(mode: \(m), l0: \(l0), c0: \(c0), l1: \(l1), c1: \(c1)),\n"
            }
        }
        s += "])"
        return s
    }
}

/// One broken invariant. `kind` is stable across runs (no numbers, no
/// coordinates) so it can key deduplication and suppression; `detail` carries
/// the actual position and values.
struct Violation: Equatable, CustomStringConvertible {
    var kind: String
    var detail: String
    var description: String { "\(kind) — \(detail)" }
}

// MARK: - invariants

enum GridInvariants {

    /// Kinds to skip. Set from `SHEEPVT_FUZZ_SUPPRESS` for triage only: a
    /// suppressed invariant is one whose bug is already recorded in
    /// `FuzzFindingsTests.swift`, and skipping it lets a run reach the ops that
    /// come *after* the first violation.
    nonisolated(unsafe) static var suppressed: Set<String> = {
        guard let s = ProcessInfo.processInfo.environment["SHEEPVT_FUZZ_SUPPRESS"] else { return [] }
        return Set(s.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    }()

    /// Every violation found in `t`. Empty = healthy. Checks both buffers: the
    /// alternate screen is resized and erased by the same code paths and is just
    /// as able to go wrong while it is off-screen.
    static func check(_ t: Terminal) -> [Violation] {
        var out: [Violation] = []
        out += check(buffer: t.primary, name: "primary", t)
        out += check(buffer: t.alternate, name: "alternate", t)

        if t.hyperlinks.count > Terminal.maxHyperlinks {
            out.append(Violation(kind: "hyperlink-count-over-budget",
                                 detail: "hyperlinks.count \(t.hyperlinks.count)"))
        }
        if t.hyperlinkBytes > Terminal.maxHyperlinkBytes {
            out.append(Violation(kind: "hyperlink-bytes-over-budget",
                                 detail: "hyperlinkBytes \(t.hyperlinkBytes)"))
        }
        // The renderer repaints exactly `dirtyRows`; a range that runs off the
        // screen is either a crash or a silently skipped repaint.
        if let d = t.dirtyRows, d.lowerBound < 0 || d.upperBound >= t.rows {
            out.append(Violation(kind: "dirty-rows-outside-screen",
                                 detail: "\(d), rows \(t.rows)"))
        }
        return suppressed.isEmpty ? out : out.filter { !suppressed.contains($0.kind) }
    }

    private static func check(buffer b: Buffer, name: String, _ t: Terminal) -> [Violation] {
        var out: [Violation] = []
        func fail(_ kind: String, _ detail: String) {
            out.append(Violation(kind: kind, detail: "[\(name)] \(detail)"))
        }

        let cols = b.cols
        let rows = b.rows

        // --- geometry ------------------------------------------------------
        if cols != t.cols { fail("buffer-cols-mismatch", "buffer.cols \(cols) vs terminal \(t.cols)") }
        if rows != t.rows { fail("buffer-rows-mismatch", "buffer.rows \(rows) vs terminal \(t.rows)") }
        if cols < 1 || rows < 1 { fail("degenerate-geometry", "\(cols)x\(rows)") }

        // --- cursor and margins ---------------------------------------------
        // `x == cols` is the legal pending-wrap column; anything past it is not.
        if b.x < 0 || b.x > cols { fail("cursor-x-out-of-grid", "x \(b.x), cols \(cols)") }
        if b.y < 0 || b.y >= rows { fail("cursor-y-out-of-grid", "y \(b.y), rows \(rows)") }
        if b.scrollTop < 0 || b.scrollTop >= rows {
            fail("scroll-top-out-of-grid", "scrollTop \(b.scrollTop), rows \(rows)")
        }
        if b.scrollBottom < 0 || b.scrollBottom >= rows {
            fail("scroll-bottom-out-of-grid", "scrollBottom \(b.scrollBottom), rows \(rows)")
        }
        if b.scrollTop > b.scrollBottom {
            fail("inverted-scroll-region", "\(b.scrollTop)...\(b.scrollBottom)")
        }
        if let s = b.savedCursor {
            if s.x < 0 || s.x > cols { fail("saved-cursor-x-out-of-grid", "x \(s.x), cols \(cols)") }
            if s.y < 0 || s.y >= rows { fail("saved-cursor-y-out-of-grid", "y \(s.y), rows \(rows)") }
        }

        // --- the ring --------------------------------------------------------
        let ring = b.lines
        if ring.count < 0 || ring.count > ring.maxLength {
            fail("ring-count-over-max", "count \(ring.count), maxLength \(ring.maxLength)")
        }
        if b.lineCount != ring.count {
            fail("line-count-mismatch", "lineCount \(b.lineCount), ring.count \(ring.count)")
        }
        if b.ybase < 0 { fail("ybase-negative", "ybase \(b.ybase)") }
        if b.ydisp < 0 || b.ydisp > b.ybase { fail("ydisp-out-of-range", "ydisp \(b.ydisp), ybase \(b.ybase)") }
        // A whole screen must exist below ybase, or `Buffer.row(_:)` clamps and
        // two different screen rows alias the same `Row`.
        if b.ybase + rows > ring.count {
            fail("screen-does-not-fit",
                 "ybase \(b.ybase) + rows \(rows) > lines.count \(ring.count)")
        }
        if ring.cols != cols { fail("ring-cols-mismatch", "ring.cols \(ring.cols), buffer.cols \(cols)") }

        // --- line numbering ---------------------------------------------------
        if ring.count > 0 {
            if b.firstLine != ring.trimmed {
                fail("first-line-mismatch", "firstLine \(b.firstLine), trimmed \(ring.trimmed)")
            }
            if b.lastLine != b.firstLine + ring.count - 1 {
                fail("last-line-mismatch", "lastLine \(b.lastLine), firstLine \(b.firstLine), count \(ring.count)")
            }
            var previous = Int.min
            for i in 0..<ring.count {
                let ln = b.lineNumber(atIndex: i)
                if ln <= previous {
                    fail("line-numbers-not-increasing", "index \(i), number \(ln)")
                    break
                }
                previous = ln
                if b.index(ofLine: ln) != i {
                    fail("line-number-round-trip",
                         "index(ofLine: \(ln)) = \(String(describing: b.index(ofLine: ln))), expected \(i)")
                    break
                }
                if b.row(line: ln) !== ring.allocatedRow(at: i) {
                    fail("row-by-line-mismatch", "line \(ln) is not the row at index \(i)")
                    break
                }
                if !b.hasLine(ln) { fail("has-line-false-for-retained", "line \(ln)") ; break }
            }
            if b.hasLine(b.firstLine - 1) { fail("has-line-true-below-first", "\(b.firstLine - 1)") }
            if b.hasLine(b.lastLine + 1) { fail("has-line-true-above-last", "\(b.lastLine + 1)") }
        }

        // --- rows ---------------------------------------------------------------
        for i in 0..<ring.count {
            guard let row = ring.allocatedRow(at: i) else { continue }
            let line = b.lineNumber(atIndex: i)
            func rfail(_ kind: String, _ detail: String) { fail(kind, "line \(line) (index \(i)): \(detail)") }

            if row.cols != cols {
                rfail("row-cols-mismatch", "row.cols \(row.cols), buffer.cols \(cols)")
                continue
            }
            let tl = row.trimmedLength
            if tl < 0 || tl > row.cols { rfail("trimmed-length-out-of-range", "trimmedLength \(tl), cols \(row.cols)") }

            // Wide-character pairing: a width-0 spacer follows a width-2 head,
            // and a width-2 head is followed by its spacer. Either half alone is
            // an orphan, and the renderer, selection and reflow all trip over it.
            for col in 0..<row.cols {
                let w = row[col].width
                if w == 3 { rfail("impossible-cell-width", "col \(col)") }
                if w == 0, col == 0 || row[col - 1].width != 2 {
                    rfail("orphan-spacer",
                          "col \(col), predecessor width \(col == 0 ? -1 : row[col - 1].width)")
                }
                if w == 2 {
                    if col + 1 >= row.cols {
                        rfail("wide-head-without-room", "col \(col) is the last column")
                    } else if row[col + 1].width != 0 {
                        rfail("wide-head-without-spacer",
                              "col \(col), follower width \(row[col + 1].width)")
                    }
                }
            }

            // Side tables agree with the flag bits, both ways.
            for c in 0..<row.cols {
                let cell = row[c]
                let hasCombinedEntry = row.combinedString(at: c) != nil
                if cell.isCombined && !hasCombinedEntry {
                    rfail("combined-flag-without-entry", "col \(c)")
                }
                if !cell.isCombined && hasCombinedEntry {
                    rfail("combined-entry-without-flag", "col \(c)")
                }
                let hasExtEntry = row.extended(at: c) != nil
                if cell.hasExtended && !hasExtEntry {
                    rfail("extended-flag-without-entry", "col \(c)")
                }
                if !cell.hasExtended && hasExtEntry {
                    rfail("extended-entry-without-flag", "col \(c)")
                }
                if let e = row.extended(at: c) {
                    if e.hyperlinkID > UInt32(t.hyperlinks.count) {
                        rfail("hyperlink-id-past-table",
                              "col \(c), id \(e.hyperlinkID), table \(t.hyperlinks.count)")
                    }
                    if e.isDefault { rfail("default-extended-in-table", "col \(c)") }
                }
            }
            if let combined = row.combined {
                for k in combined.keys where k < 0 || k >= row.cols {
                    rfail("combined-key-out-of-range", "col \(k)")
                }
            }
            if let extended = row.extended {
                for k in extended.keys where k < 0 || k >= row.cols {
                    rfail("extended-key-out-of-range", "col \(k)")
                }
            }

            // `wrapped` on the very first retained row is legal (what it
            // continued fell off the top) — but `isWrapped(line:)`, which is
            // what selection and reflow ask, must say no.
            if i == 0 && b.isWrapped(line: line) {
                rfail("first-line-reported-wrapped", "")
            }
        }

        // --- logical lines are contiguous ---------------------------------------
        if ring.count > 0 {
            for i in 0..<ring.count {
                let line = b.lineNumber(atIndex: i)
                let range = b.logicalLine(containing: line)
                if range.lowerBound < b.firstLine || range.upperBound > b.lastLine {
                    fail("logical-line-escapes-buffer", "line \(line) -> \(range)")
                    break
                }
                if !range.contains(line) {
                    fail("logical-line-excludes-own-line", "line \(line) -> \(range)")
                    break
                }
                var bad = false
                for l in range.lowerBound...range.upperBound where l > range.lowerBound {
                    if b.row(line: l)?.wrapped != true { bad = true; break }
                }
                if bad { fail("logical-line-not-contiguous", "line \(line) -> \(range)") ; break }
            }
        }

        return out
    }
}

// MARK: - a selection that is live across the whole run

enum LiveSelectionInvariants {

    /// A selection held across output. `validate()` is the contract: it returns
    /// false when nothing of the selection survives, and otherwise the bounds it
    /// leaves behind must address cells that exist. Nothing else in the suite
    /// keeps a selection alive across a scroll that renumbers lines.
    static func check(_ sel: Selection, _ t: Terminal) -> [Violation] {
        var out: [Violation] = []
        guard sel.validate() else { return out }
        let b = t.buffer
        guard b.lineCount > 0 else { return out }
        guard let s = sel.start, let e = sel.end else { return out }

        func bad(_ kind: String, _ detail: String) {
            out.append(Violation(kind: kind, detail: detail))
        }
        for (p, what) in [(s, "start"), (e, "end")] {
            if p.line < b.firstLine || p.line > b.lastLine {
                bad("live-selection-line-outside-buffer",
                    "\(what) line \(p.line) outside \(b.firstLine)...\(b.lastLine)")
            }
            if p.col < 0 || p.col >= Swift.max(b.cols, 1) {
                bad("live-selection-col-outside-row", "\(what) col \(p.col), cols \(b.cols)")
            }
        }
        if e < s { bad("live-selection-reversed", "\(s) > \(e)") }
        if let lr = sel.lineRange {
            for line in lr {
                if let r = sel.columnRange(onLine: line), r.lowerBound < 0 || r.upperBound > b.cols {
                    bad("live-selection-column-range-outside-row", "line \(line) -> \(r), cols \(b.cols)")
                }
            }
        }
        _ = sel.text()      // must not trap
        return GridInvariants.suppressed.isEmpty
            ? out : out.filter { !GridInvariants.suppressed.contains($0.kind) }
    }
}

// MARK: - selection and search, against the same grids

enum ConsumerInvariants {

    /// Run the search engine and the selection model over `t` and check that
    /// nothing they hand back addresses a cell that does not exist. A corrupt
    /// grid must not be able to make them invent positions (or crash).
    static func check(_ t: Terminal, rng: inout Xorshift64RNG) -> [Violation] {
        var out: [Violation] = []
        let b = t.buffer
        guard b.lineCount > 0 else { return out }
        let first = b.firstLine
        let last = b.lastLine
        let cols = b.cols

        func validate(_ p: Position, _ kind: String, _ what: String) {
            if p.line < first || p.line > last {
                out.append(Violation(kind: kind, detail: "\(what): line \(p.line) outside \(first)...\(last)"))
            }
            if p.col < 0 || p.col >= Swift.max(cols, 1) {
                out.append(Violation(kind: kind, detail: "\(what): col \(p.col) outside 0..<\(cols)"))
            }
        }

        // --- search --------------------------------------------------------------
        let plainTerms = ["a", "ab", "  ", "\u{4E00}", "x", "0"]
        let regexTerms = ["a+", "[ab]", "\\w+", "a.b", "^a", "b$", "(a|b){1,3}", "\\d"]
        let useRegex = rng.next() % 4 == 0
        let terms = useRegex ? regexTerms : plainTerms
        let term = terms[Int(rng.next() % UInt64(terms.count))]
        let engine = SearchEngine(terminal: t)
        engine.options = SearchOptions(caseSensitive: rng.next() & 1 == 0,
                                       regex: useRegex,
                                       wholeWord: !useRegex && rng.next() & 1 == 0)
        engine.term = term
        let limit = 5_000
        let all = engine.findAll(limit: limit)
        for m in all {
            validate(m.start, "search-position-outside-buffer", "findAll.start")
            validate(m.end, "search-position-outside-buffer", "findAll.end")
            if m.end < m.start {
                out.append(Violation(kind: "search-match-reversed", detail: "\(m.start) > \(m.end)"))
            }
        }
        for k in 1..<Swift.max(all.count, 1) where all[k].start <= all[k - 1].start {
            out.append(Violation(kind: "search-matches-out-of-order",
                                 detail: "\(all[k - 1].start) then \(all[k].start)"))
            break
        }
        let n = engine.findNext(after: nil)
        let p = engine.findPrevious(before: nil)
        if let n {
            validate(n.start, "search-position-outside-buffer", "findNext.start")
            validate(n.end, "search-position-outside-buffer", "findNext.end")
        }
        if let p {
            validate(p.start, "search-position-outside-buffer", "findPrevious.start")
            validate(p.end, "search-position-outside-buffer", "findPrevious.end")
        }
        // The navigation walk and the batch scan are two different code paths
        // over the same grid; below the limit they must agree.
        if all.count < limit {
            if n != all.first {
                out.append(Violation(kind: "find-next-disagrees-with-find-all",
                                     detail: "findNext(nil) = \(String(describing: n)), "
                                             + "findAll.first = \(String(describing: all.first))"))
            }
            if p != all.last {
                out.append(Violation(kind: "find-previous-disagrees-with-find-all",
                                     detail: "findPrevious(nil) = \(String(describing: p)), "
                                             + "findAll.last = \(String(describing: all.last))"))
            }
            let steps = Swift.max(Swift.min(all.count - 1, 6), 0)
            for k in 0..<steps {
                if engine.findNext(after: all[k].start) != all[k + 1] {
                    out.append(Violation(kind: "find-next-walk-skips-a-match",
                                         detail: "after \(all[k].start) expected \(all[k + 1].start)"))
                    break
                }
            }
            for k in stride(from: steps, to: 0, by: -1) {
                if engine.findPrevious(before: all[k].start) != all[k - 1] {
                    out.append(Violation(kind: "find-previous-walk-skips-a-match",
                                         detail: "before \(all[k].start) expected \(all[k - 1].start)"))
                    break
                }
            }
        }
        for i in 0..<b.lineCount {
            let line = first + i
            for r in engine.matches(onLine: line) where r.lowerBound < 0 || r.upperBound > cols {
                out.append(Violation(kind: "search-column-range-outside-row",
                                     detail: "line \(line) -> \(r), cols \(cols)"))
            }
        }

        // --- selection -------------------------------------------------------------
        let modes: [Selection.Mode] = [.character, .word, .line, .block]
        for mode in modes {
            let sel = Selection(terminal: t)
            let a = Position(line: first + Int(rng.next() % UInt64(b.lineCount)),
                             col: Int(rng.next() % UInt64(Swift.max(cols, 1))))
            let f = Position(line: first + Int(rng.next() % UInt64(b.lineCount)),
                             col: Int(rng.next() % UInt64(Swift.max(cols, 1))))
            sel.begin(at: a, mode: mode)
            sel.extend(to: f)
            _ = sel.validate()
            if let s = sel.start, let e = sel.end {
                validate(s, "selection-position-outside-buffer", "start(\(mode))")
                validate(e, "selection-position-outside-buffer", "end(\(mode))")
                if e < s {
                    out.append(Violation(kind: "selection-reversed", detail: "\(mode): \(s) > \(e)"))
                }
            }
            if let lr = sel.lineRange {
                for line in lr {
                    if let r = sel.columnRange(onLine: line), r.lowerBound < 0 || r.upperBound > cols {
                        out.append(Violation(kind: "selection-column-range-outside-row",
                                             detail: "\(mode): line \(line) -> \(r), cols \(cols)"))
                    }
                }
            }
            _ = sel.text()          // must not trap
        }
        let whole = Selection(terminal: t)
        whole.selectAll()
        _ = whole.text()

        return GridInvariants.suppressed.isEmpty
            ? out : out.filter { !GridInvariants.suppressed.contains($0.kind) }
    }
}

// MARK: - the generator

/// Hostile-but-plausible byte streams. Every emitter is a shape a real device
/// or a real bug produces; the fuzzer's job is the combinations.
struct FuzzGenerator {
    var rng: Xorshift64RNG

    init(seed: UInt64) { rng = Xorshift64RNG(seed: seed) }

    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(rng.next() % UInt64(n)) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
    mutating func chance(_ oneIn: Int) -> Bool { int(oneIn) == 0 }

    // --- parameters ---------------------------------------------------------

    /// A CSI parameter list, including everything a real one never is.
    mutating func params() -> [UInt8] {
        switch int(12) {
        case 0: return []                                   // no parameters at all
        case 1: return Array(";".utf8)                      // one omitted parameter
        case 2: return Array(";;;;".utf8)
        case 3: return Array("0".utf8)
        case 4: return Array("4294967296".utf8)             // past UInt32
        case 5: return Array("99999999999999999999".utf8)   // past Int64
        case 6: return Array("2147483647".utf8)             // Int32.max exactly
        case 7:                                             // 33+ parameters (overflow)
            let n = 30 + int(8)
            return Array(Array(repeating: "1", count: n).joined(separator: ";").utf8)
        case 8: return Array("38:2:255:0:0".utf8)           // colons
        case 9: return Array("1:2;3:4:5;;6".utf8)           // colons and semicolons mixed
        case 10: return Array("0;0;0".utf8)
        default:
            let n = 1 + int(4)
            var parts: [String] = []
            for _ in 0..<n {
                parts.append(pick(["0", "1", "2", "3", "5", "7", "8", "12", "24", "64", "255",
                                   "1000", "65535", "", "9999999"]))
            }
            return Array(parts.joined(separator: pick([";", ":", ";"])).utf8)
        }
    }

    // --- sequences ----------------------------------------------------------

    mutating func csi() -> [UInt8] {
        var out: [UInt8] = [0x1B, 0x5B]
        if chance(4) { out.append(pick(Array("<=>?".utf8))) }
        // Intermediates deliberately go *before* and sometimes *after* the
        // parameters, which is the wrong order for the second case.
        if chance(6) { out += Array(pick([" ", "!", "\"", "$", "'", "#", "%", " !", "$$"]).utf8) }
        out += params()
        if chance(3) { out += Array(pick([" ", "!", "\"", "$", "'", "#"]).utf8) }
        out.append(pick(Array("ABCDEFGHIJKLMPSTXZ@`abcdefghilmnpqrstuxyz{|}~".utf8)))
        return out
    }

    /// The margin/mode sequences, emitted often enough to actually interact.
    mutating func stateChange(rows: Int) -> [UInt8] {
        switch int(14) {
        case 0:  // DECSTBM, including inverted / one line / bigger than the screen
            let top = pick(["", "0", "1", "2", "\(rows)", "\(rows + 5)", "99"])
            let bottom = pick(["", "0", "1", "2", "\(rows)", "\(rows - 1)", "\(rows + 9)", "1"])
            return Array("\u{1b}[\(top);\(bottom)r".utf8)
        case 1: return Array(pick(["\u{1b}[?7h", "\u{1b}[?7l"]).utf8)          // DECAWM
        case 2: return Array(pick(["\u{1b}[?6h", "\u{1b}[?6l"]).utf8)          // DECOM
        case 3: return Array(pick(["\u{1b}[4h", "\u{1b}[4l"]).utf8)            // IRM
        case 4: return Array(pick(["\u{1b}[?1049h", "\u{1b}[?1049l",
                                   "\u{1b}[?47h", "\u{1b}[?47l",
                                   "\u{1b}[?1047h", "\u{1b}[?1047l"]).utf8)    // alt screen
        case 5: return Array("\u{1b}[!p".utf8)                                 // DECSTR
        case 6: return Array("\u{1b}c".utf8)                                   // RIS
        case 7: return Array(pick(["\u{1b}7", "\u{1b}8", "\u{1b}[s", "\u{1b}[u"]).utf8)
        case 8: return Array(pick(["\u{1b}M", "\u{1b}D", "\u{1b}E", "\u{1b}H"]).utf8)
        case 9: return Array("\u{1b}#8".utf8)                                  // DECALN
        case 10: return Array(pick(["\u{1b}[?45h", "\u{1b}[?45l"]).utf8)       // reverse wrap
        case 11: return Array(pick(["\u{1b}[\"1q", "\u{1b}[\"0q"]).utf8)       // DECSCA
        case 12: return Array(pick(["\u{1b}(0", "\u{1b}(B", "\u{0e}", "\u{0f}"]).utf8)
        case 13: // sequences that make the terminal answer — the loopback host
                 // feeds every reply straight back in, from inside this feed.
            return Array(pick(["\u{1b}[c", "\u{1b}[>c", "\u{1b}[=c", "\u{1b}[6n", "\u{1b}[?6n",
                               "\u{1b}[5n", "\u{1b}[?1$p", "\u{1b}[4$p", "\u{1b}[?u",
                               "\u{1b}[14t", "\u{1b}[18t",
                               "\u{1b}[8;\(1 + int(6));\(1 + int(30))t",
                               "\u{1b}P$qr\u{1b}\\", "\u{1b}P$qm\u{1b}\\",
                               "\u{1b}]11;?\u{7}", "\u{1b}]52;c;?\u{7}"]).utf8)
        default: return Array("\u{1b}[\(int(60))m".utf8)                       // SGR
        }
    }

    /// OSC / DCS / APC in every broken shape: unterminated, doubly terminated,
    /// ESC inside, over the caps.
    mutating func stringSequence() -> [UInt8] {
        switch int(15) {
        case 0: return Array("\u{1b}]0;title\u{7}".utf8)
        case 1: return Array("\u{1b}]0;title\u{1b}\\".utf8)
        case 2: return Array("\u{1b}]0;never terminated".utf8)                 // runs into what follows
        case 3: return Array("\u{1b}]0;twice\u{7}\u{7}".utf8)
        case 4: return Array("\u{1b}]0;esc\u{1b}inside\u{7}".utf8)
        case 5: return Array("\u{1b}]8;id=x;http://example.com/\(int(1000))\u{1b}\\".utf8)
        case 6: return Array("\u{1b}]8;;\u{1b}\\".utf8)
        case 7: // a payload that is long, but not so long the run takes minutes
            return Array(("\u{1b}]0;" + String(repeating: "T", count: 5000) + "\u{7}").utf8)
        case 8: return Array("\u{1b}P$q\u{1b}\\".utf8)
        case 9: return Array("\u{1b}P$qm\u{1b}\\".utf8)
        case 10: // DCS payload past the 4096 cap
            return Array(("\u{1b}P$q" + String(repeating: "q", count: 5000) + "\u{1b}\\").utf8)
        case 11: return Array("\u{1b}_apc payload\u{1b}\\".utf8)
        case 12: return Array("\u{1b}^pm\u{1b}\\".utf8)
        case 13: // OSC 8 with a long id and a long URI, repeatedly (budget pressure)
            return Array("\u{1b}]8;id=\(int(100));http://h/\(int(100))\u{7}".utf8)
        default: return Array("\u{1b}]4;1;rgb:ff/00/00\u{7}".utf8)
        }
    }

    /// UTF-8 broken in every position, plus the valid wide/combining shapes
    /// that make the grid interesting.
    mutating func text() -> [UInt8] {
        switch int(16) {
        case 0:  // printable ASCII run
            let n = 1 + int(12)
            return (0..<n).map { _ in UInt8(0x20 + int(0x5F)) }
        case 1:  // wide CJK
            let n = 1 + int(4)
            var out: [UInt8] = []
            for _ in 0..<n { out += Array(String(UnicodeScalar(0x4E00 + UInt32(int(200)))!).utf8) }
            return out
        case 2:  // combining marks, possibly many stacked
            let n = 1 + int(8)
            var out: [UInt8] = []
            for _ in 0..<n { out += Array(String(UnicodeScalar(0x0300 + UInt32(int(0x30)))!).utf8) }
            return out
        case 3:  // emoji (wide, astral)
            return Array(String(UnicodeScalar(0x1F600 + UInt32(int(60)))!).utf8)
        case 4:  // truncated 2/3/4-byte lead
            return pick([[0xC3], [0xE4, 0xB8], [0xF0, 0x9F, 0x98], [0xE0], [0xF4]])
        case 5:  // overlong
            return pick([[0xC0, 0x80], [0xC1, 0xBF], [0xE0, 0x80, 0x80], [0xF0, 0x80, 0x80, 0x80]])
        case 6:  // surrogate halves
            return pick([[0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF]])
        case 7:  // past U+10FFFF
            return pick([[0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xFE], [0xFF]])
        case 8:  // continuation bytes with no lead
            let n = 1 + int(4)
            return (0..<n).map { _ in UInt8(0x80 + int(0x40)) }
        case 9:  // C1 range, raw
            return [UInt8(0x80 + int(0x20))]
        case 10: // controls
            return [pick([0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x18, 0x1A, 0x00, 0x7F])]
        case 11: // NUL / DEL mixed into text
            return [0x41, 0x00, 0x42, 0x7F, 0x43]
        case 12: // ZWJ sequences
            return Array("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}".utf8)
        case 13: // soft hyphen, NBSP, Hangul
            return Array("\u{00AD}\u{00A0}\u{AC00}".utf8)
        case 14: // Thai (zero-width marks over a narrow base)
            return Array("\u{0E01}\u{0E48}\u{0E33}".utf8)
        default:
            let n = 1 + int(6)
            return (0..<n).map { _ in UInt8(0x41 + int(26)) }
        }
    }

    /// Content built to wrap: long enough to run over several rows at any of
    /// the widths the fuzzer resizes to, and salted with wide characters so a
    /// wrap boundary can fall in the middle of one. This is what gives reflow
    /// something to get wrong.
    mutating func wrappingText(cols: Int) -> [UInt8] {
        var out: [UInt8] = []
        let target = cols * (1 + int(4)) + int(cols + 2)
        var produced = 0
        while produced < target {
            switch int(8) {
            case 0, 1:
                out += Array(String(UnicodeScalar(0x4E00 + UInt32(int(200)))!).utf8)
                produced += 2
            case 2:
                out += Array(String(UnicodeScalar(0x0300 + UInt32(int(0x30)))!).utf8)
            case 3:
                out += Array(String(UnicodeScalar(0x1F600 + UInt32(int(60)))!).utf8)
                produced += 2
            case 4:
                out.append(0x20)
                produced += 1
            default:
                out.append(UInt8(0x41 + int(26)))
                produced += 1
            }
        }
        return out
    }

    /// Scroll-region workout: set margins (sometimes degenerate), park the
    /// cursor somewhere relative to them, then run the region-sensitive
    /// commands. This is the combination the fixtures never make.
    mutating func regionWorkout(rows: Int) -> [UInt8] {
        var out: [UInt8] = []
        let top = pick(["", "1", "2", "\(Swift.max(rows - 1, 1))", "\(rows)", "\(rows + 3)", "0"])
        let bottom = pick(["", "1", "2", "\(rows)", "\(rows - 1)", "\(rows + 3)", "0"])
        out += Array("\u{1b}[\(top);\(bottom)r".utf8)
        if chance(3) { out += Array(pick(["\u{1b}[?6h", "\u{1b}[?6l"]).utf8) }
        // Park the cursor: inside, above, below, or in the pending-wrap column.
        out += Array("\u{1b}[\(1 + int(rows + 3));\(1 + int(8))H".utf8)
        let n = 1 + int(4)
        for _ in 0..<n {
            out += Array(pick(["\u{1b}[L", "\u{1b}[2L", "\u{1b}[M", "\u{1b}[3M",
                               "\u{1b}[S", "\u{1b}[2S", "\u{1b}[T", "\u{1b}[9T",
                               "\u{1b}M", "\u{1b}D", "\u{1b}E",
                               "\u{1b}[@", "\u{1b}[3@", "\u{1b}[P", "\u{1b}[4P",
                               "\u{1b}[X", "\u{1b}[5X", "\u{1b}[J", "\u{1b}[1J",
                               "\u{1b}[K", "\u{1b}[1K", "\u{1b}[2K",
                               "\u{1b}[ @", "\u{1b}[ A", "\u{1b}['}", "\u{1b}['~"]).utf8)
            if chance(2) { out += text() }
        }
        return out
    }

    /// Combining marks and wide characters aimed at the awkward columns: the
    /// last one, the pending-wrap column, and the cell after a soft wrap.
    mutating func wrapEdge(cols: Int) -> [UInt8] {
        var out: [UInt8] = []
        out += Array("\u{1b}[\(1 + int(3));\(Swift.max(cols - int(3), 1))H".utf8)
        switch int(6) {
        case 0: out += Array("\u{4E00}\u{0301}\u{0302}".utf8)      // wide then marks
        case 1: out += Array("A\u{4E00}".utf8)
        case 2: out += Array("\u{1b}[?7l\u{4E00}\u{4E01}".utf8)    // DECAWM off, wide
        case 3: out += Array("\u{0301}\u{0301}\u{0301}".utf8)      // marks with no base
        case 4: out += Array("\u{4E00}\u{8}\u{0301}".utf8)         // mark onto a spacer
        default: out += Array("\u{1b}[4h\u{4E00}\u{4E01}\u{1b}[4l".utf8)   // insert mode, wide
        }
        return out
    }

    mutating func blob(cols: Int, rows: Int, flavour: Int) -> [UInt8] {
        var out: [UInt8] = []
        let n = 1 + int(6)
        for _ in 0..<n {
            switch flavour {
            case 1:     // reflow storm: mostly wrapping content
                switch int(6) {
                case 0, 1, 2: out += wrappingText(cols: cols)
                case 3: out += wrapEdge(cols: cols)
                case 4: out += csi()
                default: out += stateChange(rows: rows)
                }
            case 2:     // region storm
                switch int(6) {
                case 0, 1, 2: out += regionWorkout(rows: rows)
                case 3: out += text()
                case 4: out += wrappingText(cols: cols)
                default: out += csi()
                }
            default:    // the general mix
                switch int(11) {
                case 0, 1, 2, 3: out += text()
                case 4, 5, 6: out += csi()
                case 7: out += stateChange(rows: rows)
                case 8: out += stringSequence()
                case 9: out += wrapEdge(cols: cols)
                default: out += [pick([0x0A, 0x0D, 0x08, 0x09])]
                }
            }
        }
        return out
    }

    /// A whole case: geometry plus a script of feeds and resizes. Chunk sizes
    /// are deliberately small and irregular, so terminators and multi-byte
    /// UTF-8 land across feed boundaries — and a resize can fall mid-sequence.
    mutating func makeCase() -> FuzzCase {
        let cols = pick([2, 3, 4, 5, 8, 10, 16, 40])
        let rows = pick([1, 2, 3, 4, 6, 10])
        let scrollback = pick([0, 1, 2, 5, 20, 200])
        let flavour = int(3)
        // A reflow storm resizes constantly; the others now and then.
        let resizeOneIn = flavour == 1 ? 3 : 8
        var ops: [FuzzOp] = []
        let steps = 4 + int(14)
        for _ in 0..<steps {
            if chance(resizeOneIn) {
                ops.append(.resize(cols: pick([1, 2, 3, 4, 5, 7, 8, 9, 16, 20, 33, 200]),
                                   rows: pick([1, 2, 3, 4, 6, 7, 40])))
                continue
            }
            if chance(9) {
                ops.append(.select(mode: int(4), l0: int(64), c0: int(64),
                                   l1: int(64), c1: int(64)))
                continue
            }
            if chance(14) { ops.append(.setScrollback(pick([0, 1, 2, 5, 50, 10_000]))) ; continue }
            if chance(14) { ops.append(.scrollViewport(pick([0, 1, -1, 3, -3, 1000, -1000]))) ; continue }
            var bytes = blob(cols: cols, rows: rows, flavour: flavour)
            while !bytes.isEmpty {
                let take = 1 + int(Swift.min(bytes.count, 9))
                ops.append(.feed(Array(bytes.prefix(take))))
                bytes.removeFirst(take)
            }
        }
        return FuzzCase(cols: cols, rows: rows, scrollback: scrollback, ops: ops)
    }
}

// MARK: - running a case

/// A host that behaves like the worst plausible one: it loops every reply the
/// terminal produces straight back into `feed` (which is what happens the
/// moment an app echoes, and the path `VTParser.pending` exists for), and it
/// honours the program's XTWINOPS resize request. Both re-enter the terminal
/// from inside a `feed`, which no other test does.
final class LoopbackDelegate: TerminalDelegate {
    weak var terminal: Terminal?
    /// The host's job: a selection means nothing after a buffer switch
    /// (`TerminalView+TerminalDelegate.bufferActivated` does exactly this).
    weak var selection: Selection?
    /// Replies are bounded: a device that answers its own answers would
    /// otherwise never stop.
    var budget = 64
    var honourResizeRequests = false

    func send(_ terminal: Terminal, bytes: [UInt8]) {
        guard budget > 0 else { return }
        budget -= 1
        terminal.feed(bytes)
    }

    func resizeRequested(_ terminal: Terminal, cols: Int, rows: Int) {
        guard honourResizeRequests, budget > 0 else { return }
        budget -= 1
        terminal.resize(cols: Swift.max(1, Swift.min(cols, 400)),
                        rows: Swift.max(1, Swift.min(rows, 200)))
        selection?.clear()      // same contract as an ordinary resize
    }

    func bufferActivated(_ terminal: Terminal, alternate: Bool) { selection?.clear() }

    func pixelSize(_ terminal: Terminal) -> (width: Int, height: Int)? { (800, 600) }
    func getClipboard(_ terminal: Terminal, selection: String) -> [UInt8]? { Array("clip".utf8) }
}

enum FuzzRunner {

    /// Replay `c`, checking the invariants after every op. Returns the first
    /// failure (op index + violations), or nil.
    ///
    /// A `Selection` is created up front and dragged around by the `.select`
    /// ops, so it is live across every scroll — the only way to exercise
    /// `Terminal.linesRenumbered` / `Selection.shiftLines`, which a
    /// top-anchored scroll region with a bottom margin above the last row is
    /// the sole producer of.
    @discardableResult
    static func run(_ c: FuzzCase, consumerSeed: UInt64? = nil) -> (op: Int, violations: [Violation])? {
        let t = Terminal(cols: c.cols, rows: c.rows, scrollback: c.scrollback)
        let host = LoopbackDelegate()
        host.terminal = t
        host.honourResizeRequests = c.scrollback % 2 == 0
        t.delegate = host
        let selection = Selection(terminal: t)
        host.selection = selection

        for (i, op) in c.ops.enumerated() {
            switch op {
            case .feed(let bytes):
                t.feed(bytes)
            case .resize(let cols, let rows):
                t.resize(cols: cols, rows: rows)
                // The host's contract, from `Position.swift`: positions are
                // dropped on a resize, because reflow renumbers lines
                // arbitrarily. `TerminalView.layout` does exactly this.
                selection.clear()
            case .setScrollback(let n):
                t.scrollback = n
                selection.clear()
            case .scrollViewport(let n):
                if n == 0 { t.scrollViewportToBottom() } else { t.scrollViewport(by: n) }
            case .select(let mode, let l0, let c0, let l1, let c1):
                let b = t.buffer
                guard b.lineCount > 0, b.cols > 0 else { break }
                let modes: [Selection.Mode] = [.character, .word, .line, .block]
                func position(_ l: Int, _ col: Int) -> Position {
                    Position(line: b.firstLine + (abs(l) % b.lineCount), col: abs(col) % b.cols)
                }
                selection.begin(at: position(l0, c0), mode: modes[abs(mode) % 4])
                selection.extend(to: position(l1, c1))
            }
            var bad = GridInvariants.check(t)
            bad += LiveSelectionInvariants.check(selection, t)
            if !bad.isEmpty { return (i, bad) }
        }
        if let seed = consumerSeed {
            var rng = Xorshift64RNG(seed: seed)
            let bad = ConsumerInvariants.check(t, rng: &rng)
            if !bad.isEmpty { return (c.ops.count, bad) }
        }
        return nil
    }

    /// The set of invariant kinds a case breaks — the identity a reduction has
    /// to preserve, so a shrunken case that trips a *different* bug is not
    /// mistaken for a smaller repro of this one.
    static func signature(_ violations: [Violation]) -> String {
        Set(violations.map(\.kind)).sorted().joined(separator: "+")
    }

    /// Delta-debug a failing case down to something a human can read: drop ops,
    /// then shrink the bytes inside the ops that are left, then merge what is
    /// left back together. Only ever runs on a failure, and is capped so it
    /// cannot hang the suite.
    static func reduce(_ input: FuzzCase, signature sig: String, consumerSeed: UInt64,
                       budget: Int = 20_000) -> FuzzCase {
        var best = input
        var evaluations = 0
        func stillFails(_ c: FuzzCase) -> Bool {
            guard evaluations < budget else { return false }
            evaluations += 1
            guard let f = run(c, consumerSeed: consumerSeed) else { return false }
            return signature(f.violations) == sig
        }

        // 1. Drop runs of ops, largest first.
        var span = Swift.max(best.ops.count / 2, 1)
        while span >= 1, evaluations < budget {
            var i = 0
            while i < best.ops.count, evaluations < budget {
                var trial = best
                trial.ops.removeSubrange(i..<Swift.min(i + span, trial.ops.count))
                if stillFails(trial) { best = trial } else { i += span }
            }
            if span == 1 { break }
            span /= 2
        }

        // 2. Shrink the bytes of each remaining feed.
        var opIndex = 0
        while opIndex < best.ops.count, evaluations < budget {
            if case .feed(let bytes) = best.ops[opIndex] {
                var current = bytes
                var byteSpan = Swift.max(current.count / 2, 1)
                while byteSpan >= 1, evaluations < budget {
                    var j = 0
                    while j < current.count, evaluations < budget {
                        var shorter = current
                        shorter.removeSubrange(j..<Swift.min(j + byteSpan, shorter.count))
                        var trial = best
                        trial.ops[opIndex] = .feed(shorter)
                        if stillFails(trial) { best = trial; current = shorter } else { j += byteSpan }
                    }
                    if byteSpan == 1 { break }
                    byteSpan /= 2
                }
                if current.isEmpty {
                    var trial = best
                    trial.ops.remove(at: opIndex)
                    if stillFails(trial) { best = trial; continue }
                }
            }
            opIndex += 1
        }

        // 3. Merge adjacent feeds where that keeps it failing (shorter script).
        var k = 0
        while k + 1 < best.ops.count, evaluations < budget {
            if case .feed(let a) = best.ops[k], case .feed(let b) = best.ops[k + 1] {
                var trial = best
                trial.ops[k] = .feed(a + b)
                trial.ops.remove(at: k + 1)
                if stillFails(trial) { best = trial; continue }
            }
            k += 1
        }
        return best
    }
}

// MARK: - the test

@Suite("SheepVT fuzz", .serialized)
struct FuzzTests {

    /// Cases per run. Small by default so the normal suite stays fast; the env
    /// var is how the long soak is driven.
    static var caseCount: Int {
        if let s = ProcessInfo.processInfo.environment["SHEEPVT_FUZZ_CASES"], let n = Int(s) { return n }
        return 300
    }

    static var baseSeed: UInt64 {
        if let s = ProcessInfo.processInfo.environment["SHEEPVT_FUZZ_SEED"] {
            if s.hasPrefix("0x"), let n = UInt64(s.dropFirst(2), radix: 16) { return n }
            if let n = UInt64(s) { return n }
        }
        return 0x5EED_0C0F_FEE1_2345
    }

    @Test("grid invariants survive hostile input")
    func fuzzGrid() {
        let cases = FuzzTests.caseCount
        let base = FuzzTests.baseSeed
        var bytesFed = 0
        var found: [String: String] = [:]     // signature -> report
        var order: [String] = []
        var totalFailures = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<cases {
                let seed = base &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15
                var gen = FuzzGenerator(seed: seed)
                let c = gen.makeCase()
                bytesFed += c.ops.reduce(0) { $0 + $1.byteCount }
                guard let failure = FuzzRunner.run(c, consumerSeed: seed) else { continue }
                totalFailures += 1
                let sig = FuzzRunner.signature(failure.violations)
                guard found[sig] == nil else { continue }
                let reduced = FuzzRunner.reduce(c, signature: sig, consumerSeed: seed)
                let reducedFailure = FuzzRunner.run(reduced, consumerSeed: seed) ?? failure
                order.append(sig)
                found[sig] = """
                    fuzz failure — seed 0x\(String(seed, radix: 16)) (case \(i))
                    invariant(s) broken after op \(reducedFailure.op):
                      \(reducedFailure.violations.prefix(4).map(\.description).joined(separator: "\n  "))
                    minimal repro:
                    \(reduced.literal())
                    """
                if order.count >= 12 { return }
            }
        }
        print("fuzz: \(cases) cases, \(bytesFed) bytes, seed 0x\(String(base, radix: 16)), "
              + "\(elapsed), \(totalFailures) failing cases, \(order.count) distinct signatures")
        for sig in order { Issue.record(Comment(rawValue: found[sig]!)) }
    }
}
