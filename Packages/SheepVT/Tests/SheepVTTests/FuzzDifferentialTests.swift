// FuzzDifferentialTests.swift — SheepVT
//
// Two differential oracles over the same hostile generator as `FuzzTests`.
// Neither compares against a golden output; both compare the emulator against
// *itself* run a second, simpler way, which is what makes them cheap to trust.
//
//  1. `fuzzChunkInvariance` — the same bytes fed in small irregular pieces must
//     land exactly like the same bytes fed whole. `ReplayTests` proves this for
//     the 77 real device logs; nothing proved it for input designed to break
//     the parser, where the carry-over state (a half-decoded UTF-8 sequence, a
//     string payload waiting for its terminator, a CSI mid-parameter) is
//     precisely what is under attack.
//
//  2. `fuzzSearchCache` — `SearchEngine` is 1200 lines of incremental caching
//     keyed on row identity, row generation and `changeCounter`. A stale entry
//     produces a plausible-looking answer, so the grid invariants cannot see it.
//     The oracle is a second engine built from scratch on the same terminal: an
//     engine that has watched the whole session must agree with one that has
//     just arrived.
//
// Long soak:  SHEEPVT_FUZZ_CASES=50000 ./Tests/run.sh vt -c release --filter fuzzChunk
//             SHEEPVT_FUZZ_CASES=50000 ./Tests/run.sh vt -c release --filter fuzzSearch

import Foundation
import Testing

@testable import SheepVT

// MARK: - a comparable snapshot of everything the user can see

struct GridSnapshot: Equatable {
    var cols: Int
    var rows: Int
    var alternate: Bool
    var cursor: [Int]            // x, y
    var ybase: Int
    var lineCount: Int
    var lines: [String]
    var wrapped: [Bool]
    var widths: [[Int]]

    init(_ t: Terminal) {
        let b = t.buffer
        cols = t.cols
        rows = t.rows
        alternate = t.isAlternate
        cursor = [b.x, b.y]
        ybase = b.ybase
        lineCount = b.lineCount
        lines = []
        wrapped = []
        widths = []
        for i in 0..<b.lineCount {
            let row = b.lines.allocatedRow(at: i)
            lines.append(row?.string(trimRight: false) ?? "")
            wrapped.append(row?.wrapped ?? false)
            widths.append((0..<(row?.cols ?? 0)).map { row![$0].width })
        }
    }

    /// The first field that differs, for a readable failure message.
    func firstDifference(from other: GridSnapshot) -> String? {
        if cols != other.cols { return "cols \(cols) vs \(other.cols)" }
        if rows != other.rows { return "rows \(rows) vs \(other.rows)" }
        if alternate != other.alternate { return "alternate \(alternate) vs \(other.alternate)" }
        if cursor != other.cursor { return "cursor \(cursor) vs \(other.cursor)" }
        if ybase != other.ybase { return "ybase \(ybase) vs \(other.ybase)" }
        if lineCount != other.lineCount { return "lineCount \(lineCount) vs \(other.lineCount)" }
        for i in 0..<Swift.min(lines.count, other.lines.count) where lines[i] != other.lines[i] {
            return "line \(i): \(String(reflecting: lines[i])) vs \(String(reflecting: other.lines[i]))"
        }
        for i in 0..<Swift.min(wrapped.count, other.wrapped.count) where wrapped[i] != other.wrapped[i] {
            return "line \(i) wrapped \(wrapped[i]) vs \(other.wrapped[i])"
        }
        for i in 0..<Swift.min(widths.count, other.widths.count) where widths[i] != other.widths[i] {
            return "line \(i) cell widths \(widths[i]) vs \(other.widths[i])"
        }
        return self == other ? nil : "snapshots differ"
    }
}

// MARK: - the tests

@Suite("SheepVT differential fuzz", .serialized)
struct FuzzDifferentialTests {

    static var caseCount: Int {
        if let s = ProcessInfo.processInfo.environment["SHEEPVT_FUZZ_CASES"], let n = Int(s) { return n }
        return 250
    }

    /// Replay a case with no delegate and no selection — just bytes and
    /// resizes — and return what the screen and history look like afterwards.
    private static func replay(_ c: FuzzCase, mergingFeeds: Bool) -> GridSnapshot {
        let t = Terminal(cols: c.cols, rows: c.rows, scrollback: c.scrollback)
        var pending: [UInt8] = []
        func flush() {
            if !pending.isEmpty { t.feed(pending); pending.removeAll(keepingCapacity: true) }
        }
        for op in c.ops {
            switch op {
            case .feed(let bytes):
                if mergingFeeds { pending += bytes } else { t.feed(bytes) }
            case .resize(let cols, let rows):
                flush()
                t.resize(cols: cols, rows: rows)
            case .setScrollback(let n):
                flush()
                t.scrollback = n
            case .scrollViewport(let n):
                flush()
                if n == 0 { t.scrollViewportToBottom() } else { t.scrollViewport(by: n) }
            case .select:
                break                       // no selection in this oracle
            }
        }
        flush()
        return GridSnapshot(t)
    }

    @Test("hostile bytes land the same whether fed whole or in pieces")
    func fuzzChunkInvariance() {
        let cases = FuzzDifferentialTests.caseCount
        let base = FuzzTests.baseSeed &+ 0xABCD_EF01
        var reported = 0
        var bytesFed = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<cases {
                let seed = base &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15
                var gen = FuzzGenerator(seed: seed)
                let c = gen.makeCase()
                bytesFed += c.ops.reduce(0) { $0 + $1.byteCount }

                let piecemeal = FuzzDifferentialTests.replay(c, mergingFeeds: false)
                let whole = FuzzDifferentialTests.replay(c, mergingFeeds: true)
                guard let diff = piecemeal.firstDifference(from: whole) else { continue }
                reported += 1
                Issue.record("""
                    chunking changed the result — seed 0x\(String(seed, radix: 16)) (case \(i))
                      \(diff)
                    repro:
                    \(c.literal())
                    """)
                if reported >= 3 { return }
            }
        }
        print("chunk-invariance fuzz: \(cases) cases, \(bytesFed) bytes, \(elapsed), \(reported) reported")
    }

    @Test("an incrementally updated search engine agrees with a fresh one")
    func fuzzSearchCache() {
        let cases = FuzzDifferentialTests.caseCount
        let base = FuzzTests.baseSeed &+ 0x0FED_CBA9
        let terms = ["a", "ab", "e", "  ", "\u{4E00}", "0", "aa"]
        var reported = 0
        var comparisons = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<cases {
                let seed = base &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15
                var gen = FuzzGenerator(seed: seed)
                let c = gen.makeCase()
                let term = terms[gen.int(terms.count)]
                let options = SearchOptions(caseSensitive: gen.chance(2),
                                            regex: false,
                                            wholeWord: gen.chance(3))

                let t = Terminal(cols: c.cols, rows: c.rows, scrollback: c.scrollback)
                // The long-lived engine: it sees every intermediate state, so
                // its caches are built up incrementally, evicted and revalidated.
                let live = SearchEngine(terminal: t)
                live.options = options
                live.term = term

                for (opIndex, op) in c.ops.enumerated() {
                    switch op {
                    case .feed(let bytes): t.feed(bytes)
                    case .resize(let cols, let rows):
                        t.resize(cols: cols, rows: rows)
                        live.invalidate()       // the host's contract on a reflow
                    case .setScrollback(let n):
                        t.scrollback = n
                        live.invalidate()
                    case .scrollViewport(let n):
                        if n == 0 { t.scrollViewportToBottom() } else { t.scrollViewport(by: n) }
                    case .select: break
                    }

                    let liveMatches = live.findAll(limit: 500)
                    let fresh = SearchEngine(terminal: t)
                    fresh.options = options
                    fresh.term = term
                    let freshMatches = fresh.findAll(limit: 500)
                    comparisons += 1
                    guard liveMatches != freshMatches else { continue }
                    reported += 1
                    Issue.record("""
                        the search cache disagrees with a fresh engine — \
                        seed 0x\(String(seed, radix: 16)) (case \(i)), after op \(opIndex)
                          term \(String(reflecting: term)), options \(options)
                          live:  \(liveMatches.prefix(6).map { "\($0.start)…\($0.end)" })
                                 (\(liveMatches.count) matches)
                          fresh: \(freshMatches.prefix(6).map { "\($0.start)…\($0.end)" })
                                 (\(freshMatches.count) matches)
                        repro:
                        \(c.literal())
                        """)
                    break
                }
                if reported >= 3 { return }
            }
        }
        print("search-cache fuzz: \(cases) cases, \(comparisons) comparisons, \(elapsed), "
              + "\(reported) reported")
    }

    /// The one scroll shape that reassigns line numbers without moving text:
    /// a scroll region anchored at row 0 whose bottom margin is above the last
    /// row (`Buffer.scrollUp` → `Terminal.linesRenumbered` →
    /// `Selection.shiftLines`). Rows *below* that margin are untouched by the
    /// scroll, so a selection sitting on one of them must still say exactly the
    /// same thing afterwards. Nothing else in the suite holds a selection across
    /// this path, and the arithmetic is the sort that is off by one.
    @Test("a selection below a scroll margin survives the region scrolling")
    func fuzzSelectionSurvivesRegionScroll() {
        let cases = FuzzDifferentialTests.caseCount
        let base = FuzzTests.baseSeed &+ 0x2222_3333
        var reported = 0
        var checks = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<cases {
                let seed = base &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15
                var gen = FuzzGenerator(seed: seed)
                let cols = gen.pick([8, 12, 20, 40])
                let rows = gen.pick([4, 5, 6, 8, 12])
                let t = Terminal(cols: cols, rows: rows, scrollback: gen.pick([0, 4, 50, 500]))

                // Distinct, recognisable content on every row.
                for r in 0..<rows {
                    t.feed(Array("\u{1b}[\(r + 1);1H".utf8))
                    t.feed(Array("row\(r)-\(String(repeating: "abcdefgh", count: 3))".prefix(cols).utf8))
                }

                // Top-anchored region whose bottom margin is above the last row.
                let margin = 1 + gen.int(rows - 2)              // 1…rows-2 (0-based bottom)
                t.feed(Array("\u{1b}[1;\(margin + 1)r".utf8))

                // Select a stretch on a row below the margin — untouched text.
                let selRow = margin + 1 + gen.int(rows - margin - 1)
                guard selRow < rows else { continue }
                let sel = Selection(terminal: t)
                let line = t.buffer.lineNumber(ofScreenRow: selRow)
                let c0 = gen.int(Swift.max(cols - 2, 1))
                let c1 = Swift.min(c0 + 1 + gen.int(5), cols - 1)
                sel.begin(at: Position(line: line, col: c0), mode: .character)
                sel.extend(to: Position(line: line, col: c1))
                let before = sel.text()
                guard !before.isEmpty else { continue }

                // Scroll the region, hard enough to push lines into history.
                let scrolls = 1 + gen.int(12)
                for _ in 0..<scrolls {
                    switch gen.int(3) {
                    case 0: t.feed(Array("\u{1b}[S".utf8))                 // SU
                    case 1: t.feed(Array("\u{1b}[\(margin + 1);1H\n".utf8))  // LF at the margin
                    default: t.feed(Array("\u{1b}[1;1H\u{1b}[M".utf8))     // DL inside the region
                    }
                }

                checks += 1
                let stillValid = sel.validate()
                let after = stillValid ? sel.text() : ""
                guard !(stillValid && after == before) else { continue }
                reported += 1
                Issue.record("""
                    a selection below the scroll margin changed — \
                    seed 0x\(String(seed, radix: 16)) (case \(i))
                      \(cols)x\(rows), margin row \(margin), selection on screen row \(selRow), \
                    \(scrolls) scrolls
                      before: \(String(reflecting: before))
                      after:  \(stillValid ? String(reflecting: after) : "<selection invalidated>")
                      screen: \(t.screenLines())
                    """)
                if reported >= 3 { return }
            }
        }
        print("selection/region fuzz: \(cases) cases, \(checks) checked, \(elapsed), \(reported) reported")
    }
}
