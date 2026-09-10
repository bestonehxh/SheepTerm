// SheepVT — the bulk write path (`Row.writeASCIIRun`, used by
// `Terminal.printRun`) and the two things that make it fast: the side-table
// membership filters and the precomputed `UnicodeWidth` blocks.
//
// The shortcut skips work the per-cell setter used to do on every column, so
// these tests hammer exactly what a shortcut breaks: wide characters and their
// spacers, combining marks, extended attributes (SGR 4/58 and OSC 8 links),
// `trimmedLength`, and the generation counter the renderer/search/highlight
// caches key on.

import Testing
@testable import SheepVT

// MARK: - helpers

/// The behaviour `writeASCIIRun` is a bulk form of: what the old per-cell loop
/// through the subscript setter (plus `setExtended`) produced.
private func referenceRun(_ row: Row, _ bytes: [UInt8], at col: Int,
                          fg: UInt32, bg: UInt32, ext: ExtendedAttributes?) {
    var bgWord = bg & ~Cell.BgFlag.hasExtended
    if ext != nil { bgWord |= Cell.BgFlag.hasExtended }
    for (i, b) in bytes.enumerated() {
        row[col + i] = Cell(code: UInt32(b), width: 1, fg: fg, bg: bgWord)
        if let ext { row.setExtended(ext, at: col + i) }
    }
}

private func dump(_ row: Row) -> [String] {
    (0..<row.cols).map { c in
        let cell = row[c]
        return "\(cell.content)/\(cell.fg)/\(cell.bg)"
            + "/c:\(row.combinedString(at: c) ?? "-")"
            + "/e:\(String(describing: row.extended(at: c)))"
    }
}

private func underline(_ style: ExtendedAttributes.UnderlineStyle) -> ExtendedAttributes {
    var e = ExtendedAttributes(); e.underlineStyle = style; return e
}

// MARK: - writeASCIIRun == the loop it replaces

@Suite("SheepVT bulk write — writeASCIIRun")
struct WriteASCIIRunTests {

    @Test("a run writes exactly what the per-cell setter loop wrote")
    func matchesTheSetterLoop() {
        // A deterministic sweep: for every starting column and length, and for
        // several pre-existing row states, the bulk write and the per-cell loop
        // must leave byte-identical rows *and* identical side tables.
        let bytes: [UInt8] = Array("Interface up 10.0.0.1".utf8)
        for start in 0..<12 {
            for len in 1...(min(bytes.count, 24 - start)) {
                for ext in [nil, underline(.curly)] as [ExtendedAttributes?] {
                    for seed in 0..<4 {
                        let a = Row(cols: 24), b = Row(cols: 24)
                        for r in [a, b] { preload(r, seed: seed) }
                        let chunk = Array(bytes[0..<len])
                        referenceRun(a, chunk, at: start, fg: 7, bg: 0, ext: ext)
                        chunk.withUnsafeBufferPointer {
                            b.writeASCIIRun($0.baseAddress!, count: len, at: start,
                                            fg: 7, bg: 0, extended: ext)
                        }
                        #expect(dump(a) == dump(b),
                                "start \(start) len \(len) ext \(ext != nil) seed \(seed)")
                        #expect((a.combined == nil) == (b.combined == nil))
                        #expect((a.extended == nil) == (b.extended == nil))
                        #expect(a.trimmedLength == b.trimmedLength)
                    }
                }
            }
        }
    }

    /// Four starting states, all of which the run has to reconcile: empty, a
    /// row full of combining clusters, a row full of extended attributes, and
    /// a row of wide characters with their spacers.
    private func preload(_ r: Row, seed: Int) {
        switch seed {
        case 1:
            for c in stride(from: 0, to: r.cols, by: 3) {
                r[c] = Cell(code: 0x65, width: 1, fg: 0, bg: 0)
                r.setCombined("e\u{301}", at: c)
            }
        case 2:
            for c in 0..<r.cols {
                r[c] = Cell(code: 0x41, width: 1, fg: 0, bg: 0)
                r.setExtended(underline(.dotted), at: c)
            }
        case 3:
            for c in stride(from: 0, to: r.cols - 1, by: 2) {
                r[c] = Cell(code: 0x4E2D, width: 2, fg: 0, bg: 0)
                r[c + 1] = Cell(code: 0, width: 0, fg: 0, bg: 0)
            }
        default:
            break
        }
    }

    @Test("a run drops the combining cluster of every cell it covers")
    func runClearsCombined() {
        let r = Row(cols: 8)
        r[2] = Cell(code: 0x65, width: 1, fg: 0, bg: 0)
        r.setCombined("e\u{301}\u{302}", at: 2)
        r[6] = Cell(code: 0x6F, width: 1, fg: 0, bg: 0)
        r.setCombined("o\u{308}", at: 6)
        #expect(r.combined?.count == 2)

        let bytes: [UInt8] = Array("abcd".utf8)
        bytes.withUnsafeBufferPointer {
            r.writeASCIIRun($0.baseAddress!, count: 4, at: 0, fg: 0, bg: 0, extended: nil)
        }
        #expect(r.combinedString(at: 2) == nil)
        #expect(!r[2].isCombined)
        #expect(r.combinedString(at: 6) == "o\u{308}")   // outside the run: untouched
        #expect(r.combined?.count == 1)
    }

    @Test("a run that empties the combined table prunes it back to nil")
    func runPrunesCombined() {
        let r = Row(cols: 8)
        r[1] = Cell(code: 0x65, width: 1, fg: 0, bg: 0)
        r.setCombined("e\u{301}", at: 1)
        #expect(r.combined != nil)
        let bytes: [UInt8] = Array("xxxxxxxx".utf8)
        bytes.withUnsafeBufferPointer {
            r.writeASCIIRun($0.baseAddress!, count: 8, at: 0, fg: 0, bg: 0, extended: nil)
        }
        #expect(r.combined == nil)
    }

    @Test("a run with extended attrs sets one entry per covered cell, and clears them again")
    func runSetsAndClearsExtended() {
        let r = Row(cols: 8)
        let bytes: [UInt8] = Array("abcdefgh".utf8)
        bytes.withUnsafeBufferPointer { p in
            r.writeASCIIRun(p.baseAddress!, count: 4, at: 2, fg: 0, bg: 0,
                            extended: underline(.dashed))
        }
        for c in 2..<6 {
            #expect(r[c].hasExtended)
            #expect(r.extended(at: c)?.underlineStyle == .dashed)
        }
        #expect(r.extended(at: 1) == nil)
        #expect(r.extended(at: 6) == nil)
        #expect(r.extended?.count == 4)

        bytes.withUnsafeBufferPointer { p in
            r.writeASCIIRun(p.baseAddress!, count: 8, at: 0, fg: 0, bg: 0, extended: nil)
        }
        #expect(r.extended == nil)
        #expect((0..<8).allSatisfy { !r[$0].hasExtended })
    }

    @Test("a run longer than 64 columns still clears every side-table entry")
    func runWiderThanTheFilter() {
        // The membership filter is 64 bits wide; a 200-column row folds several
        // columns onto the same bit, and a run wider than 64 sets all of them.
        let r = Row(cols: 200)
        for c in stride(from: 0, to: 200, by: 7) {
            r[c] = Cell(code: 0x65, width: 1, fg: 0, bg: 0)
            r.setCombined("e\u{301}", at: c)
            r.setExtended(underline(.double), at: c)
        }
        let bytes = [UInt8](repeating: 0x2E, count: 200)
        bytes.withUnsafeBufferPointer {
            r.writeASCIIRun($0.baseAddress!, count: 200, at: 0, fg: 0, bg: 0, extended: nil)
        }
        #expect(r.combined == nil)
        #expect(r.extended == nil)
        #expect((0..<200).allSatisfy { !r[$0].isCombined && !r[$0].hasExtended })
        #expect(r.trimmedLength == 200)
    }

    @Test("trimmedLength follows a bulk run")
    func trimmedLengthAfterRun() {
        let r = Row(cols: 16)
        #expect(r.trimmedLength == 0)
        let bytes: [UInt8] = Array("hello".utf8)
        bytes.withUnsafeBufferPointer {
            r.writeASCIIRun($0.baseAddress!, count: 5, at: 3, fg: 0, bg: 0, extended: nil)
        }
        #expect(r.trimmedLength == 8)
        // Blanks are cells too: a run of spaces past the text extends it.
        let blanks = [UInt8](repeating: 0x20, count: 4)
        blanks.withUnsafeBufferPointer {
            r.writeASCIIRun($0.baseAddress!, count: 4, at: 8, fg: 0, bg: 0, extended: nil)
        }
        #expect(r.trimmedLength == 12)
    }

    @Test("an empty run is a no-op and does not bump the generation")
    func emptyRun() {
        let r = Row(cols: 8)
        let g = r.generation
        let bytes: [UInt8] = [0x41]
        bytes.withUnsafeBufferPointer {
            r.writeASCIIRun($0.baseAddress!, count: 0, at: 3, fg: 0, bg: 0, extended: nil)
        }
        #expect(r.generation == g)
        #expect(r.trimmedLength == 0)
    }
}

// MARK: - the generation contract

@Suite("SheepVT bulk write — generation")
struct BulkGenerationTests {

    @Test("a run bumps the generation exactly once, and every run bumps it")
    func oneBumpPerRun() {
        let r = Row(cols: 32)
        let bytes: [UInt8] = Array("abcdefgh".utf8)
        var last = r.generation
        for start in stride(from: 0, to: 24, by: 8) {
            bytes.withUnsafeBufferPointer {
                r.writeASCIIRun($0.baseAddress!, count: 8, at: start, fg: 0, bg: 0, extended: nil)
            }
            #expect(r.generation == last &+ 1)
            last = r.generation
        }
    }

    @Test("every printed row ends with a generation different from the one it started with")
    func everyWrittenRowMoves() {
        let t = Terminal(cols: 40, rows: 6, scrollback: 100)
        t.feed("\u{1B}[H")
        var before: [UInt64] = []
        for y in 0..<6 { before.append(t.buffer.row(y).generation) }
        t.feed("line one\r\nline two\r\n\u{1B}[1;31mred\u{1B}[0m tail\r\n中文 wide\r\n")
        for y in 0..<4 {
            #expect(t.buffer.row(y).generation != before[y], "row \(y) did not bump")
        }
    }

    @Test("a run of blanks over existing text still bumps")
    func blankRunBumps() {
        let t = Terminal(cols: 20, rows: 3, scrollback: 10)
        t.feed("hello world")
        let g = t.buffer.row(0).generation
        t.feed("\r           ")            // eleven spaces over the text
        #expect(t.buffer.row(0).generation != g)
        #expect(t.buffer.row(0).string() == "")
    }
}

// MARK: - wide characters across the bulk path

@Suite("SheepVT bulk write — wide characters")
struct BulkWideTests {

    @Test("an ASCII run landing on a spacer kills the wide head to its left")
    func runOverASpacer() {
        let t = Terminal(cols: 10, rows: 2, scrollback: 10)
        t.feed("中文")                       // cols 0-1 and 2-3
        t.feed("\u{1B}[1;2H")               // cursor on the spacer of the first char
        t.feed("abc")
        let r = t.buffer.row(0)
        #expect(r[0].code == 0)             // orphaned head erased
        #expect(r[0].width == 1)
        #expect(r[1].code == 0x61)
        #expect(r[2].code == 0x62)
        #expect(r[3].code == 0x63)
        #expect(r.string() == " abc")
    }

    @Test("an ASCII run ending on a wide head leaves no lone spacer")
    func runEndingOnAWideHead() {
        let t = Terminal(cols: 10, rows: 2, scrollback: 10)
        t.feed("中文")
        t.feed("\u{1B}[1;1H")
        t.feed("ab")                         // covers the first wide char exactly
        let r = t.buffer.row(0)
        #expect(r[0].code == 0x61)
        #expect(r[1].code == 0x62)
        #expect(r[2].code == 0x6587)         // second wide char intact
        #expect(r[3].isSpacer)
        #expect(r.string() == "ab文")
    }

    @Test("an ASCII run stopping inside a wide pair erases the orphaned half")
    func runStoppingInsideAWidePair() {
        let t = Terminal(cols: 10, rows: 2, scrollback: 10)
        t.feed("中文")
        t.feed("\u{1B}[1;1H")
        t.feed("abc")                        // 3 cells: eats 中 and the head of 文
        let r = t.buffer.row(0)
        #expect(r[0].code == 0x61)
        #expect(r[1].code == 0x62)
        #expect(r[2].code == 0x63)
        #expect(r[3].code == 0)              // the spacer of 文 is orphaned and cleared
        #expect(r[3].width == 1)
        #expect(r.string() == "abc")
    }

    @Test("a wrapping ASCII run does not split a wide character across rows")
    func wrappingRun() {
        // Exactly two columns left: the wide character fits and the run
        // continues on the next row.
        let fits = Terminal(cols: 6, rows: 4, scrollback: 10)
        fits.feed("abcd中ef")
        #expect(fits.buffer.row(0).string() == "abcd中")
        #expect(fits.buffer.row(1).string() == "ef")
        #expect(fits.buffer.row(1).wrapped)

        // One column left: the wide character wraps whole rather than being
        // split, and the ASCII run after it resumes beside it.
        let wraps = Terminal(cols: 6, rows: 4, scrollback: 10)
        wraps.feed("abcde中fg")
        #expect(wraps.buffer.row(0).string() == "abcde")
        #expect(wraps.buffer.row(1).string() == "中fg")
        #expect(wraps.buffer.row(1).wrapped)
        #expect(wraps.buffer.row(1)[0].width == 2)
        #expect(wraps.buffer.row(1)[1].isSpacer)
    }
}

// MARK: - combining marks across the bulk path

@Suite("SheepVT bulk write — combining marks")
struct BulkCombiningTests {

    @Test("a mark after a run attaches to the run's last cell")
    func markAfterARun() {
        let t = Terminal(cols: 20, rows: 2, scrollback: 10)
        t.feed("cafe\u{301} latte")
        let r = t.buffer.row(0)
        #expect(r.combinedString(at: 3) == "e\u{301}")
        #expect(r[3].isCombined)
        #expect(r.string() == "cafe\u{301} latte")
    }

    @Test("Thai tone marks and vowels stack on the consonant printed before them")
    func thaiMarks() {
        let t = Terminal(cols: 20, rows: 2, scrollback: 10)
        t.feed("สวัสดี")
        let r = t.buffer.row(0)
        #expect(r.string() == "สวัสดี")
        #expect(r.combinedString(at: 1) == "ว\u{E31}")
    }

    @Test("an ASCII run overwriting a combined cell drops its cluster")
    func runOverACombinedCell() {
        let t = Terminal(cols: 20, rows: 2, scrollback: 10)
        t.feed("cafe\u{301}s")
        #expect(t.buffer.row(0).combined?.count == 1)
        t.feed("\r")
        t.feed("XXXXXX")
        let r = t.buffer.row(0)
        #expect(r.combined == nil)
        #expect(r.string() == "XXXXXX")
        #expect((0..<6).allSatisfy { !r[$0].isCombined })
    }

    @Test("an emoji ZWJ sequence survives text printed elsewhere on the row")
    func zwjSequenceKeptWhileTheRestIsRewritten() {
        let t = Terminal(cols: 30, rows: 2, scrollback: 10)
        t.feed("ok 👨‍👩‍👧‍👦 done")
        let r = t.buffer.row(0)
        // Each person emoji is a wide cell of its own; the ZWJ that follows it
        // is what lands in the side table (cols 3, 5, 7 — the last emoji has no
        // trailing joiner).
        #expect(r.combinedString(at: 3)?.unicodeScalars.count == 2)
        #expect(r.combinedString(at: 5)?.unicodeScalars.count == 2)
        #expect(r.combinedString(at: 7)?.unicodeScalars.count == 2)
        #expect(r.combined?.count == 3)
        let cluster = r.combinedString(at: 3)

        // Rewrite only the first three columns: the clusters further along the
        // row are outside the run and must survive it.
        t.feed("\r")
        t.feed("no ")
        #expect(r.combinedString(at: 3) == cluster)
        #expect(r[3].isCombined)
        #expect(r.combined?.count == 3)
        #expect(r.string() == "no 👨‍👩‍👧‍👦 done")
    }

    @Test("a mark hops the spacer of a wide character")
    func markHopsASpacer() {
        let t = Terminal(cols: 20, rows: 2, scrollback: 10)
        t.feed("中\u{301}")
        let r = t.buffer.row(0)
        #expect(r.combinedString(at: 0) == "中\u{301}")
        #expect(r.combinedString(at: 1) == nil)
    }
}

// MARK: - extended attributes across the bulk path

@Suite("SheepVT bulk write — extended attributes")
struct BulkExtendedTests {

    @Test("SGR 4:3 gives every cell of the run a curly underline")
    func curlyUnderlineAcrossARun() {
        let t = Terminal(cols: 20, rows: 2, scrollback: 10)
        t.feed("\u{1B}[4:3mwarning\u{1B}[4:0m ok")
        let r = t.buffer.row(0)
        for c in 0..<7 {
            #expect(r[c].hasExtended, "col \(c)")
            #expect(r.extended(at: c)?.underlineStyle == .curly)
        }
        for c in 7..<10 {
            #expect(!r[c].hasExtended, "col \(c)")
            #expect(r.extended(at: c) == nil)
        }
    }

    @Test("SGR 58 underline colour rides the whole run")
    func underlineColourAcrossARun() {
        let t = Terminal(cols: 20, rows: 2, scrollback: 10)
        t.feed("\u{1B}[4m\u{1B}[58;2;255;0;0mred-underline")
        let r = t.buffer.row(0)
        let want = Cell.colorWord(source: .rgb, value: 0xFF0000)
        for c in 0..<13 {
            #expect(r.extended(at: c)?.underlineColor == want, "col \(c)")
        }
    }

    @Test("an OSC 8 hyperlink covers every cell of the run and stops with it")
    func hyperlinkAcrossARun() {
        let t = Terminal(cols: 30, rows: 2, scrollback: 10)
        t.feed("\u{1B}]8;;https://example.com\u{7}click here\u{1B}]8;;\u{7} plain")
        let r = t.buffer.row(0)
        let id = r.extended(at: 0)?.hyperlinkID
        #expect(id != nil && id != 0)
        for c in 0..<10 {
            #expect(r.extended(at: c)?.hyperlinkID == id, "col \(c)")
        }
        for c in 10..<16 {
            #expect(r.extended(at: c)?.hyperlinkID ?? 0 == 0, "col \(c)")
        }
        #expect(t.hyperlinks.first == "https://example.com")
    }

    @Test("plain text over an underlined run drops every extended entry")
    func plainOverExtended() {
        let t = Terminal(cols: 20, rows: 2, scrollback: 10)
        t.feed("\u{1B}[4:3munderlined")
        #expect(t.buffer.row(0).extended?.count == 10)
        t.feed("\u{1B}[m\r")
        t.feed("plain text")
        let r = t.buffer.row(0)
        #expect(r.extended == nil)
        #expect((0..<10).allSatisfy { !r[$0].hasExtended })
    }
}

// MARK: - the membership filters never hide an entry

@Suite("SheepVT bulk write — side-table filters")
struct SideTableFilterTests {

    @Test("random edits keep the row identical to a per-cell reference row")
    func fuzzAgainstAReference() {
        // Two rows driven through the same random sequence of edits, one via
        // the bulk run and one via the per-cell setter. Any column where the
        // filter wrongly claimed "no entry here" would show up as a divergence.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ n: Int) -> Int {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Int(seed % UInt64(n))
        }
        let cols = 80
        let a = Row(cols: cols), b = Row(cols: cols)
        let text: [UInt8] = Array("the quick brown fox jumps over the lazy dog 0123456789".utf8)

        for step in 0..<4000 {
            switch next(6) {
            case 0:
                let c = next(cols)
                a[c] = Cell(code: 0x65, width: 1, fg: 0, bg: 0)
                b[c] = Cell(code: 0x65, width: 1, fg: 0, bg: 0)
                a.setCombined("e\u{301}", at: c); b.setCombined("e\u{301}", at: c)
            case 1:
                let c = next(cols)
                a.setExtended(underline(.dotted), at: c)
                b.setExtended(underline(.dotted), at: c)
            case 2:
                let c = next(cols)
                let cell = Cell(code: UInt32(0x41 + next(26)), width: 1, fg: 0, bg: 0)
                a[c] = cell; b[c] = cell
            case 3:
                let from = next(cols), to = from + next(cols - from) + 1
                a.fill(.empty, from: from, to: to)
                b.fill(.empty, from: from, to: to)
            default:
                let start = next(cols)
                let len = min(next(20) + 1, min(text.count, cols - start))
                let ext: ExtendedAttributes? = next(4) == 0 ? underline(.double) : nil
                let chunk = Array(text[0..<len])
                referenceRun(a, chunk, at: start, fg: 3, bg: 0, ext: ext)
                chunk.withUnsafeBufferPointer {
                    b.writeASCIIRun($0.baseAddress!, count: len, at: start,
                                    fg: 3, bg: 0, extended: ext)
                }
            }
            #expect(dump(a) == dump(b), "diverged at step \(step)")
        }
        #expect((a.combined == nil) == (b.combined == nil))
        #expect((a.extended == nil) == (b.extended == nil))
        #expect(a.trimmedLength == b.trimmedLength)
    }

    @Test("ICH and DCH keep the filters honest about the entries they shuffle")
    func insertAndDeleteMoveEntries() {
        let r = Row(cols: 16)
        for c in 0..<4 {
            r[c] = Cell(code: UInt32(0x61 + c), width: 1, fg: 0, bg: 0)
            r.setCombined("\(Character(UnicodeScalar(0x61 + UInt32(c))!))\u{301}", at: c)
        }
        r.insertCells(at: 0, count: 5, fill: .empty)
        #expect(r.combinedString(at: 5) == "a\u{301}")
        #expect(r.combinedString(at: 8) == "d\u{301}")
        // Overwriting the moved entries must still drop them.
        for c in 5...8 { r[c] = Cell(code: 0x2E, width: 1, fg: 0, bg: 0) }
        #expect(r.combined == nil)
        #expect((5...8).allSatisfy { !r[$0].isCombined })
    }

    @Test("copy(from:) carries the filters with the tables")
    func copyCarriesTheFilters() {
        let src = Row(cols: 16)
        src[9] = Cell(code: 0x65, width: 1, fg: 0, bg: 0)
        src.setCombined("e\u{301}", at: 9)
        src.setExtended(underline(.curly), at: 9)
        let dst = Row(cols: 16)
        dst.copy(from: src)
        #expect(dst.combinedString(at: 9) == "e\u{301}")
        #expect(dst.extended(at: 9)?.underlineStyle == .curly)
        dst[9] = Cell(code: 0x2E, width: 1, fg: 0, bg: 0)
        #expect(dst.combined == nil)
        #expect(dst.extended == nil)
    }

    @Test("copyCells carries the filters for the columns it lands on")
    func copyCellsCarriesTheFilters() {
        let src = Row(cols: 16)
        src[1] = Cell(code: 0x65, width: 1, fg: 0, bg: 0)
        src.setCombined("e\u{301}", at: 1)
        let dst = Row(cols: 16)
        dst.copyCells(from: src, srcCol: 0, dstCol: 10, count: 4)
        #expect(dst.combinedString(at: 11) == "e\u{301}")
        dst[11] = Cell(code: 0x2E, width: 1, fg: 0, bg: 0)
        #expect(dst.combined == nil)
    }
}

// MARK: - the precomputed width blocks are a pure memo

@Suite("SheepVT bulk write — UnicodeWidth tables")
struct UnicodeWidthTableTests {

    @Test("every precomputed block equals compute() for every scalar in it")
    func tablesMatchCompute() {
        for s in 0..<UnicodeWidth.tableLimit {
            #expect(UnicodeWidth.width(s) == UnicodeWidth.compute(s), "U+\(String(s, radix: 16))")
        }
        for s in UnicodeWidth.tableLimit..<0x1_0000 {
            #expect(UnicodeWidth.width(s) == UnicodeWidth.compute(s), "U+\(String(s, radix: 16))")
        }
        for s in UInt32(0x1_F000)..<UInt32(0x1_FB00) {
            #expect(UnicodeWidth.width(s) == UnicodeWidth.compute(s), "U+\(String(s, radix: 16))")
        }
    }

    @Test("the block boundaries answer the same as the computed path")
    func boundaries() {
        for s in [UInt32(0x2FFF), 0x3000, 0x9FFF, 0xA000, 0xFFFF, 0x1_0000,
                  0x1_EFFF, 0x1_F000, 0x1_FAFF, 0x1_FB00, 0x2_0000, 0x10_FFFF] {
            #expect(UnicodeWidth.width(s) == UnicodeWidth.compute(s), "U+\(String(s, radix: 16))")
        }
    }

    @Test("the widths the print path depends on are unchanged")
    func spotChecks() {
        #expect(UnicodeWidth.width(0x4E2D) == 2)      // 中
        #expect(UnicodeWidth.width(0x3042) == 2)      // あ
        #expect(UnicodeWidth.width(0xAC00) == 2)      // 가
        #expect(UnicodeWidth.width(0xFF21) == 2)      // fullwidth A
        #expect(UnicodeWidth.width(0x1F411) == 2)     // 🐑
        #expect(UnicodeWidth.width(0x1F1F9) == 2)     // regional indicator T
        #expect(UnicodeWidth.width(0x200D) == 0)      // ZWJ
        #expect(UnicodeWidth.width(0xFE0F) == 0)      // variation selector 16
        #expect(UnicodeWidth.width(0x0E31) == 0)      // Thai mai han akat
        #expect(UnicodeWidth.width(0x0E01) == 1)      // Thai ko kai
        #expect(UnicodeWidth.width(0x00E9) == 1)      // é
        #expect(UnicodeWidth.width(0x302A) == 0)      // ideographic tone mark (wide range, but a mark)
        #expect(UnicodeWidth.width(0x3099) == 0)      // combining voiced sound mark
    }
}

// MARK: - the shortcuts the removal paths take

/// `Row.fill` and `Row.writeASCIIRun` no longer ask the side tables about every
/// column they cover: a whole-row fill drops the tables outright, and a partial
/// range is skipped entirely when the membership filter proves it holds nothing.
/// A clear bit is a proof of absence, so these tests are about the two ways that
/// proof could be misread — a range the filter says is empty when it is not, and
/// a wholesale drop that takes entries it was not asked to take.
@Suite("SheepVT bulk write — side-table removal shortcuts")
struct SideTableRemovalTests {

    /// A row with clusters and extended attributes scattered across it.
    private func loaded(cols: Int, at columns: [Int]) -> Row {
        let r = Row(cols: cols)
        for c in columns {
            r[c] = Cell(code: 0x65, width: 1, fg: 0, bg: 0)
            r.setCombined("e\u{301}\(c)", at: c)
            r.setExtended(underline(.curly), at: c)
        }
        return r
    }

    @Test("a whole-row fill drops both tables and leaves nothing readable behind")
    func wholeRowFillDropsEverything() {
        let r = loaded(cols: 24, at: [0, 1, 7, 12, 23])
        r.fill(.empty)
        #expect(r.combined == nil)
        #expect(r.extended == nil)
        #expect(r.trimmedLength == 0)
        #expect(r.string() == "")
        for c in 0..<r.cols {
            #expect(r.combinedString(at: c) == nil)
            #expect(r.extended(at: c) == nil)
            #expect(!r[c].isCombined)
            #expect(!r[c].hasExtended)
        }
        // The filter went back to zero with the tables, so a fresh entry at a
        // column that used to hold one is still found.
        r[7] = Cell(code: 0x65, width: 1, fg: 0, bg: 0)
        r.setCombined("e\u{302}", at: 7)
        #expect(r.combinedString(at: 7) == "e\u{302}")
        r[7] = Cell(code: 0x2E, width: 1, fg: 0, bg: 0)
        #expect(r.combined == nil)
    }

    @Test("a fill of exactly the whole row via an explicit range drops it too")
    func explicitWholeRowRange() {
        let r = loaded(cols: 16, at: [3, 9])
        r.fill(.empty, from: 0, to: 16)
        #expect(r.combined == nil && r.extended == nil)
    }

    @Test("a partial fill takes its own range and nothing else")
    func partialFillKeepsTheRest() {
        let r = loaded(cols: 24, at: [2, 5, 11, 20])
        r.fill(.empty, from: 4, to: 12)
        #expect(r.combinedString(at: 2) == "e\u{301}2")
        #expect(r.combinedString(at: 20) == "e\u{301}20")
        #expect(r.extended(at: 2)?.underlineStyle == .curly)
        #expect(r.extended(at: 20)?.underlineStyle == .curly)
        for c in 4..<12 {
            #expect(r.combinedString(at: c) == nil)
            #expect(r.extended(at: c) == nil)
        }
        #expect(r.combined?.count == 2)
        #expect(r.extended?.count == 2)
    }

    @Test("a partial fill over a range the filter proves empty leaves the tables alone")
    func partialFillOverAnEmptyRange() {
        let r = loaded(cols: 24, at: [1, 2, 3])
        r.fill(.empty, from: 8, to: 16)
        #expect(r.combined?.count == 3)
        #expect(r.extended?.count == 3)
        #expect(r.combinedString(at: 1) == "e\u{301}1")
    }

    @Test("a partial fill wider than the 64-bit filter still clears its range")
    func partialFillWiderThanTheFilter() {
        // Ranges of 64 columns or more collapse the filter to "every bit set",
        // which is the branch that must not be allowed to skip anything.
        let r = loaded(cols: 200, at: [10, 70, 130, 150, 180])
        r.fill(.empty, from: 5, to: 160)
        for c in [10, 70, 130, 150] {
            #expect(r.combinedString(at: c) == nil, "column \(c) survived")
            #expect(r.extended(at: c) == nil)
        }
        #expect(r.combinedString(at: 180) == "e\u{301}180")
        #expect(r.extended(at: 180)?.underlineStyle == .curly)
    }

    @Test("a fill that empties the tables one range at a time ends with them nil")
    func repeatedPartialFillsEndAtNil() {
        let r = loaded(cols: 200, at: [10, 70, 130, 180])
        r.fill(.empty, from: 0, to: 100)
        #expect(r.combined?.count == 2)
        r.fill(.empty, from: 100, to: 199)
        // Column 199 was never touched but held nothing; everything else is gone.
        #expect(r.combined == nil)
        #expect(r.extended == nil)
    }

    @Test("an ASCII run over columns the filter clears leaves a cluster elsewhere alone")
    func runOverPlainColumns() {
        let r = loaded(cols: 24, at: [1])
        let bytes: [UInt8] = Array("space".utf8)
        bytes.withUnsafeBufferPointer {
            r.writeASCIIRun($0.baseAddress!, count: bytes.count, at: 10,
                            fg: 0, bg: 0, extended: nil)
        }
        #expect(r.combinedString(at: 1) == "e\u{301}1")
        #expect(r.extended(at: 1)?.underlineStyle == .curly)
        #expect(r.combined?.count == 1)
    }

    @Test("an ASCII run over a cluster still drops it")
    func runOverACluster() {
        let r = loaded(cols: 24, at: [1, 11])
        let bytes: [UInt8] = Array("space".utf8)
        bytes.withUnsafeBufferPointer {
            r.writeASCIIRun($0.baseAddress!, count: bytes.count, at: 10,
                            fg: 0, bg: 0, extended: nil)
        }
        #expect(r.combinedString(at: 11) == nil)
        #expect(r.extended(at: 11) == nil)
        #expect(!r[11].isCombined)
        #expect(!r[11].hasExtended)
        #expect(r.combinedString(at: 1) == "e\u{301}1")
        // Column 0 was never written, so the text starts with its blank.
        #expect(r.string(trimRight: true).hasPrefix(" e\u{301}1"))
    }

    @Test("an ASCII run 64 columns or wider drops every cluster it covers")
    func runWiderThanTheFilter() {
        let r = loaded(cols: 200, at: [10, 40, 90, 150])
        let bytes = [UInt8](repeating: 0x78, count: 100)   // 'x'
        bytes.withUnsafeBufferPointer {
            r.writeASCIIRun($0.baseAddress!, count: 100, at: 20, fg: 0, bg: 0, extended: nil)
        }
        #expect(r.combinedString(at: 10) == "e\u{301}10")
        #expect(r.combinedString(at: 40) == nil)
        #expect(r.combinedString(at: 90) == nil)
        #expect(r.combinedString(at: 150) == "e\u{301}150")
        #expect(r.extended?.count == 2)
    }
}

// MARK: - the print path end to end

/// The write path reaches a row through `Buffer.row` → `LineRing.subscript`, and
/// the rows themselves are recycled: a line that scrolls off the top is blanked
/// in place and handed back for the next line. Anything the blanking misses — a
/// grapheme cluster, an underline, half of a wide character — reappears under
/// text it does not belong to, and only shows up once the ring wraps. These feed
/// real streams through `Terminal` and check the text that comes back out.
@Suite("SheepVT print path — recycled and reshaped rows")
struct PrintPathRecyclingTests {

    /// Lines that between them use every feature a row-level shortcut can break.
    private func sampleLines(_ n: Int) -> [String] {
        let shapes = [
            "สวัสดีครับ เครือข่าย",          // Thai: combining vowels and tone marks
            "plain ascii line \(n)",
            "中文测试 日本語テスト",              // wide characters, each with a spacer
            "café naïve über",              // precomposed Latin-1
            "🐑 flock 👨‍👩‍👧‍👦 zwj ⚠️ vs16",
            "mixed 中 a สี b 🐑 c",
        ]
        return (0..<n).map { shapes[$0 % shapes.count] + " #\($0)" }
    }

    @Test("a scrollback that wraps shows no ghost from the row it recycled")
    func recycledRowsCarryNothingForward() {
        // Scrollback 8 on a 6-row screen: 14 slots for 60 lines, so every row
        // object is reused several times.
        let t = Terminal(cols: 40, rows: 6, scrollback: 8)
        let lines = sampleLines(60)
        for l in lines { t.feed(l + "\r\n") }
        let got = t.allLines()
        // The last 14 lines are what the ring can still hold; the trailing entry
        // is the blank line the final CRLF left the cursor on.
        let want = Array(lines.suffix(13)) + [""]
        #expect(got == want)
    }

    @Test("a scroll region recycles inside itself without leaking clusters")
    func scrollRegionRecycling() {
        let t = Terminal(cols: 40, rows: 10, scrollback: 100)
        t.feed("\u{1B}[3;7r")                 // DECSTBM: rows 3…7 scroll, the rest is fixed
        t.feed("\u{1B}[1;1Hheader 中文 fixed")
        t.feed("\u{1B}[10;1Hfooter สวัสดี fixed")
        t.feed("\u{1B}[3;1H")
        for i in 0..<40 { t.feed(sampleLines(40)[i] + "\r\n") }
        let screen = t.screenLines()
        #expect(screen[0] == "header 中文 fixed")
        #expect(screen[9] == "footer สวัสดี fixed")
        // Rows 3…7 hold the last four lines written into the region, plus the
        // blank one the final CRLF left the cursor sitting on.
        let tail = Array(sampleLines(40).suffix(4)) + [""]
        #expect(Array(screen[2..<7]) == tail)
    }

    @Test("the alternate screen hands back rows the primary never sees")
    func alternateScreenRecycling() {
        let t = Terminal(cols: 40, rows: 6, scrollback: 50)
        for l in sampleLines(6) { t.feed(l + "\r\n") }
        let before = t.allLines()
        t.feed("\u{1B}[?1049h")               // to the alternate screen
        for l in sampleLines(30) { t.feed(l + "\r\n") }
        t.feed("\u{1B}[?1049l")               // …and back
        #expect(t.allLines() == before)
    }

    @Test("a resize round trip rewraps clusters and wide characters back to where they were")
    func reflowRoundTrip() {
        let t = Terminal(cols: 40, rows: 8, scrollback: 200)
        for l in sampleLines(30) { t.feed(l + "\r\n") }
        let before = t.allLines()
        t.resize(cols: 17, rows: 8)
        t.resize(cols: 40, rows: 8)
        #expect(t.allLines() == before)
    }

    @Test("the same stream split anywhere lands on the same cells")
    func chunkInvarianceOverTheWholeFeatureSet() {
        // Wide characters, spacers, combining marks, SGR extended attributes, a
        // scroll region, the alternate screen and a resize, in one stream.
        var s = "\u{1B}[4:3m\u{1B}[58:5:9munderlined\u{1B}[0m\r\n"
        s += "\u{1B}[3;6r"
        for l in sampleLines(24) { s += l + "\r\n" }
        s += "\u{1B}[?1049h" + sampleLines(9).joined(separator: "\r\n")
        s += "\u{1B}[?1049l\u{1B}[r"
        for l in sampleLines(9) { s += l + "\r\n" }
        let bytes = Array(s.utf8)

        func fingerprint(_ t: Terminal) -> [String] {
            let b = t.buffer
            return (0..<b.lineCount).map { i -> String in
                guard let row = b.lines.allocatedRow(at: i) else { return "-" }
                var out = "\(row.trimmedLength)/\(row.wrapped)"
                for c in 0..<row.cols {
                    let cell = row[c]
                    out += "|\(cell.content),\(cell.fg),\(cell.bg)"
                    if let g = row.combinedString(at: c) { out += ",g:\(g)" }
                    if let e = row.extended(at: c) { out += ",e:\(e)" }
                }
                return out
            }
        }

        let whole = Terminal(cols: 30, rows: 8, scrollback: 100)
        whole.feed(bytes)

        let byByte = Terminal(cols: 30, rows: 8, scrollback: 100)
        for b in bytes { byByte.feed([b]) }
        #expect(fingerprint(whole) == fingerprint(byByte))

        var rng = Xorshift64RNG(seed: 0x5EED_0BEE_F00D_1234)
        let chunked = Terminal(cols: 30, rows: 8, scrollback: 100)
        feedChunked(bytes, to: chunked) { Int.random(in: 1...7, using: &rng) }
        #expect(fingerprint(whole) == fingerprint(chunked))
    }
}
