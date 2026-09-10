// FuzzReflowTests.swift — SheepVT
//
// A second oracle for the fuzzer, aimed at the one part of the emulator where a
// structural invariant is not enough: **reflow**. `FuzzTests` proves the grid
// stays well-formed across a width change; it says nothing about whether the
// text is still there. The property here is the one a user actually notices:
//
//   Rewrapping the scrollback must not change what it says.
//
// So: write plain text into a terminal with a deep scrollback, snapshot the
// logical lines, resize the width, resize back, and compare. Only the history
// *above* the cursor's own logical line is compared — reflow deliberately
// leaves the cursor's logical line to the program (xterm.js does the same, and
// the rows it does not rewrap are simply cropped to the new width), and lines
// that fall off the top of the ring are gone by design, so both are excluded.
//
// Two case streams: `fuzzReflow` writes nothing but words, spaces and line
// breaks; `fuzzReflowLineOps` writes the same words through DECSTBM, IL and DL,
// because those are the other way a row's `wrapped` flag gets rearranged and the
// plain stream cannot produce the topologies they leave behind.
//
// Long soak:  SHEEPVT_FUZZ_CASES=50000 ./Tests/run.sh vt -c release --filter fuzzReflow
//
// `fuzzReflowLineOps` used to report one case at
// `SHEEPVT_FUZZ_SEED=0xFFFFFFFFFFFFFFFF` (case 2044, 4 cols -> 2 -> 4) — finding
// 2 in `FuzzFindingsTests.swift`, where it is reduced to 26 bytes. It is fixed
// (`Row.wrapGapBefore`), and both streams are now clean at that seed at 50,000
// cases each, and at 6,000 cases under five seeds.

import Foundation
import Testing

@testable import SheepVT

// MARK: - reading logical lines

enum ReflowSnapshot {

    /// Every logical line of the buffer, oldest first, as text. A logical line
    /// is a row plus every following row flagged `wrapped`; the rows are joined
    /// without trimming (blanks in the middle of a wrapped line are real text)
    /// and only the whole line is right-trimmed.
    ///
    /// The last entry is the logical line the cursor is on, which reflow does
    /// not touch; `upToCursor` drops it and everything after it.
    static func logicalLines(_ t: Terminal, upToCursor: Bool = true) -> [String] {
        let b = t.buffer
        guard b.lineCount > 0 else { return [] }
        let cursorLine = b.lineNumber(ofScreenRow: b.y)
        let cursorLogical = b.logicalLine(containing: cursorLine)

        var out: [String] = []
        var line = b.firstLine
        while line <= b.lastLine {
            let range = b.logicalLine(containing: line)
            if upToCursor && range.lowerBound >= cursorLogical.lowerBound { break }
            var text = ""
            for l in range.lowerBound...range.upperBound {
                text += b.row(line: l)?.string(trimRight: false) ?? ""
            }
            while text.last == " " { text.removeLast() }
            out.append(text)
            line = range.upperBound + 1
        }
        return out
    }
}

// MARK: - the test

@Suite("SheepVT reflow fuzz", .serialized)
struct FuzzReflowTests {

    static var caseCount: Int {
        if let s = ProcessInfo.processInfo.environment["SHEEPVT_FUZZ_CASES"], let n = Int(s) { return n }
        return 250
    }

    /// Text with no escape sequences at all: words, spaces and explicit line
    /// breaks, salted with wide characters and combining marks so a wrap
    /// boundary lands inside a glyph.
    static func content(_ gen: inout FuzzGenerator, lines: Int) -> [UInt8] {
        var out: [UInt8] = []
        for _ in 0..<lines {
            let words = 1 + gen.int(8)
            for w in 0..<words {
                if w > 0 { out.append(0x20) }
                switch gen.int(8) {
                case 0:
                    let n = 1 + gen.int(3)
                    for _ in 0..<n {
                        out += Array(String(UnicodeScalar(0x4E00 + UInt32(gen.int(200)))!).utf8)
                    }
                case 1:
                    out += Array(String(UnicodeScalar(0x1F600 + UInt32(gen.int(60)))!).utf8)
                case 2:
                    out.append(UInt8(0x61 + gen.int(26)))
                    out += Array(String(UnicodeScalar(0x0300 + UInt32(gen.int(0x30)))!).utf8)
                default:
                    let n = 1 + gen.int(9)
                    for _ in 0..<n { out.append(UInt8(0x61 + gen.int(26))) }
                }
            }
            out += [0x0D, 0x0A]
        }
        return out
    }

    /// The same words, but written through the sequences that *move whole rows
    /// around*: DECSTBM, IL and DL. `content` never emits an escape, so every
    /// wrapped flag it produces was set by the printer wrapping at the right
    /// margin — a scrollback whose wrap topology is uniform. IL/DL and a scroll
    /// region are the other way rows and their flags get rearranged (both clear
    /// a `wrapped` bit on the row that moved, and a region leaves a row *below*
    /// the margin whose flag has to be cleared too), and that topology — a
    /// continuation row whose head was deleted out from under it, a wrapped row
    /// pushed below a margin — is exactly the input reflow has to be right on.
    /// Kept as a separate case stream so the plain-text one stays comparable
    /// with every soak recorded above.
    static func contentWithLineOps(_ gen: inout FuzzGenerator, lines: Int, rows: Int) -> [UInt8] {
        var out: [UInt8] = []
        for _ in 0..<lines {
            switch gen.int(10) {
            case 0 where rows >= 2:
                // A region somewhere inside the screen, sometimes only part of it.
                let top = 1 + gen.int(Swift.max(rows - 1, 1))
                let bottom = Swift.min(top + gen.int(rows), rows)
                out += Array("\u{1b}[\(top);\(bottom)r".utf8)
                break
            case 1:
                out += Array("\u{1b}[\(1 + gen.int(Swift.max(rows, 1)));1H".utf8)
                out += Array("\u{1b}[\(1 + gen.int(3))L".utf8)          // IL
            case 2:
                out += Array("\u{1b}[\(1 + gen.int(Swift.max(rows, 1)));1H".utf8)
                out += Array("\u{1b}[\(1 + gen.int(3))M".utf8)          // DL
            case 3:
                out += Array("\u{1b}[r".utf8)                            // whole screen again
            default:
                break
            }
            let words = 1 + gen.int(6)
            for w in 0..<words {
                if w > 0 { out.append(0x20) }
                switch gen.int(6) {
                case 0:
                    out += Array(String(UnicodeScalar(0x4E00 + UInt32(gen.int(200)))!).utf8)
                case 1:
                    out.append(UInt8(0x61 + gen.int(26)))
                    out += Array(String(UnicodeScalar(0x0300 + UInt32(gen.int(0x30)))!).utf8)
                default:
                    let n = 1 + gen.int(9)
                    for _ in 0..<n { out.append(UInt8(0x61 + gen.int(26))) }
                }
            }
            out += [0x0D, 0x0A]
        }
        // Land the cursor on a fresh blank bottom row, the way a program that
        // has finished writing leaves it — region reset, cursor to the last
        // row, one more newline to scroll what it was on into the history.
        // Without this the cursor sits wherever the last CUP put it, in the
        // middle of the history, and `logicalLines(upToCursor:)` stops the
        // comparison there: the reflow of everything below it would go
        // unchecked, and the line the cursor is on is cropped rather than
        // rewrapped by design, so it would report a difference that is not one.
        out += Array("\u{1b}[r".utf8)
        out += Array("\u{1b}[\(Swift.max(rows, 1));1H".utf8)
        out += [0x0D, 0x0A]
        return out
    }

    @Test("rewrapping a scrollback built with IL/DL and scroll regions is lossless")
    func fuzzReflowLineOps() {
        let cases = FuzzReflowTests.caseCount
        let base = FuzzTests.baseSeed &+ 0x7A5C_0DE1
        var reported = 0
        var comparedLines = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<cases {
                let seed = base &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15
                var gen = FuzzGenerator(seed: seed)
                let cols = gen.pick([4, 6, 8, 10, 16, 20, 40])
                let rows = gen.pick([2, 3, 4, 6, 10])
                let t = Terminal(cols: cols, rows: rows, scrollback: 5_000)
                t.feed(FuzzReflowTests.contentWithLineOps(&gen, lines: 5 + gen.int(40), rows: rows))

                let before = ReflowSnapshot.logicalLines(t)
                let other = gen.pick([2, 3, 5, 7, 9, 12, 17, 24, 31, 60, 80])
                t.resize(cols: other, rows: rows)
                t.resize(cols: cols, rows: rows)
                let after = ReflowSnapshot.logicalLines(t)

                let shared = Swift.min(before.count, after.count)
                comparedLines += shared
                var mismatch: Int?
                for k in 0..<shared where before[k] != after[k] { mismatch = k; break }
                if mismatch == nil && before.count != after.count { mismatch = shared }
                guard let k = mismatch else { continue }
                reported += 1
                Issue.record("""
                    reflow round-trip changed a history built with IL/DL —
                    seed 0x\(String(seed, radix: 16)) (case \(i))
                    \(cols) cols -> \(other) -> \(cols), \(rows) rows
                    logical line \(k):
                      before: \(k < before.count ? String(reflecting: before[k]) : "<missing>")
                      after:  \(k < after.count ? String(reflecting: after[k]) : "<missing>")
                    (\(before.count) logical lines before, \(after.count) after)
                    """)
                if reported >= 4 { return }
            }
        }
        print("reflow/line-ops fuzz: \(cases) cases, \(comparedLines) logical lines compared, "
              + "\(elapsed), \(reported) reported")
    }

    @Test("rewrapping the scrollback does not change what it says")
    func fuzzReflow() {
        let cases = FuzzReflowTests.caseCount
        let base = FuzzTests.baseSeed &+ 0x1234_5678
        var reported = 0
        var comparedLines = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<cases {
                let seed = base &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15
                var gen = FuzzGenerator(seed: seed)
                let cols = gen.pick([4, 6, 8, 10, 16, 20, 40])
                let rows = gen.pick([2, 3, 4, 6, 10])
                // Deep enough that nothing falls off the top: that is the one
                // way reflow is allowed to lose text.
                let t = Terminal(cols: cols, rows: rows, scrollback: 5_000)
                t.feed(FuzzReflowTests.content(&gen, lines: 5 + gen.int(40)))

                let before = ReflowSnapshot.logicalLines(t)
                let other = gen.pick([2, 3, 5, 7, 9, 12, 17, 24, 31, 60, 80])
                t.resize(cols: other, rows: rows)
                t.resize(cols: cols, rows: rows)
                let after = ReflowSnapshot.logicalLines(t)

                // Reflow may legitimately have nothing left to compare (all of
                // the history joined the cursor's logical line); only a
                // *difference* in the shared prefix is a failure.
                let shared = Swift.min(before.count, after.count)
                comparedLines += shared
                var mismatch: Int?
                for k in 0..<shared where before[k] != after[k] { mismatch = k; break }
                if mismatch == nil && before.count != after.count { mismatch = shared }
                guard let k = mismatch else { continue }
                reported += 1
                Issue.record("""
                    reflow round-trip changed the history — seed 0x\(String(seed, radix: 16)) (case \(i))
                    \(cols) cols -> \(other) -> \(cols), \(rows) rows
                    logical line \(k):
                      before: \(k < before.count ? String(reflecting: before[k]) : "<missing>")
                      after:  \(k < after.count ? String(reflecting: after[k]) : "<missing>")
                    (\(before.count) logical lines before, \(after.count) after)
                    """)
                if reported >= 4 { return }
            }
        }
        print("reflow fuzz: \(cases) cases, \(comparedLines) logical lines compared, "
              + "\(elapsed), \(reported) reported")
    }
}
