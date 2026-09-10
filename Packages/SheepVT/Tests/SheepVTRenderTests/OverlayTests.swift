// SheepVTRender — tests for the highlight overlay (SPEC.md phase 3, agent D).
//
// The provider here stands in for the app's matcher: it colours one fixed word
// with the same word-boundary rule the real packs use (`\bup\b` over bytes), so
// the stand-in bytes for Thai/CJK/emoji are tested for the only thing they have
// to get right — the word boundary — and not for their identity.

import Testing
@testable import SheepVTRender

// MARK: - Fake provider

@inline(__always)
private func isWordByte(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
}

private final class FakeProvider: HighlightProvider {
    let word: [UInt8]
    var rgb: UInt32 = 0x33CC66
    var bold = false
    var revision: UInt64 = 1

    /// How many times the overlay actually ran a match — the cache proof.
    private(set) var calls = 0
    /// The bytes of the last paragraph handed over.
    private(set) var lastParagraph: [UInt8] = []

    init(word: String = "up") { self.word = Array(word.utf8) }

    func spans(in paragraph: [UInt8]) -> [HighlightSpan] {
        calls += 1
        lastParagraph = paragraph
        guard !word.isEmpty, paragraph.count >= word.count else { return [] }
        var out: [HighlightSpan] = []
        for i in 0...(paragraph.count - word.count) {
            var hit = true
            for k in 0..<word.count where paragraph[i + k] != word[k] { hit = false; break }
            guard hit else { continue }
            if i > 0, isWordByte(paragraph[i - 1]) { continue }
            let end = i + word.count
            if end < paragraph.count, isWordByte(paragraph[end]) { continue }
            out.append(HighlightSpan(range: i..<end, rgb: rgb, bold: bold))
        }
        return out
    }
}

// MARK: - Helpers

private func columns(_ overrides: [UInt32]?) -> [Int] {
    guard let overrides else { return [] }
    return overrides.indices.filter { overrides[$0] != 0 }
}

@Suite struct OverlayTests {

    // MARK: - The basics

    @Test func colouredWordLandsOnItsColumns() {
        let t = Terminal(cols: 40, rows: 5)
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        t.feed("interface up\r\n")

        let row = o.overrides(line: 0, in: t)
        #expect(row?.count == 40)
        #expect(columns(row) == [10, 11])                 // "interface up"
        #expect(row?[10] == HighlightOverlay.word(rgb: 0x33CC66, bold: false))
    }

    @Test func wordEncodingCarriesBoldAndRGB() {
        let t = Terminal(cols: 20, rows: 3)
        let p = FakeProvider()
        p.rgb = 0x123456
        p.bold = true
        let o = HighlightOverlay(provider: p)
        t.feed("link up\r\n")

        let row = o.overrides(line: 0, in: t)
        #expect(columns(row) == [5, 6])
        // Spelled with a typed constant, not a bare literal expression: an
        // untyped `0x8000_0000 | (1 << 24) | 0x123456` inside `#expect` is
        // inferred independently of the left-hand side, and the macro then
        // compares a UInt32 against an Int — which is false however identical
        // the two numbers print (it failed in Debug and passed in Release).
        let expected: UInt32 = HighlightOverlay.presentBit | HighlightOverlay.boldBit | 0x123456
        #expect(row?[5] == expected)
        #expect(row?[0] == 0)
        // The documented decoding.
        #expect((row![5] & HighlightOverlay.rgbMask) == 0x123456)
        #expect((row![5] & HighlightOverlay.boldBit) != 0)
        #expect((row![5] & HighlightOverlay.presentBit) != 0)
    }

    @Test func aRowWithNoMatchIsAllZeroButStillCols() {
        let t = Terminal(cols: 24, rows: 4)
        let o = HighlightOverlay(provider: FakeProvider())
        t.feed("nothing to see here\r\n")

        let row = o.overrides(line: 0, in: t)
        #expect(row?.count == 24)
        #expect(columns(row).isEmpty)
    }

    @Test func aDeviceColouredCellStillGetsAnOverride() {
        // Whether the override is *applied* is the row builder's call
        // (`fgSource == .default`); the overlay produces it either way.
        let t = Terminal(cols: 24, rows: 4)
        let o = HighlightOverlay(provider: FakeProvider())
        t.feed("link \u{1b}[31mup\u{1b}[0m\r\n")

        #expect(columns(o.overrides(line: 0, in: t)) == [5, 6])
    }

    // MARK: - Paragraphs

    /// 200 characters at 80 columns: "up" starts in the last column of row 0 and
    /// finishes in the first column of row 1. Matching per physical row loses it.
    private func wrappedTerminal() -> Terminal {
        let t = Terminal(cols: 80, rows: 24)
        var line = String(repeating: "x", count: 78)
        line += " up "
        line += String(repeating: "y", count: 200 - line.count)
        #expect(line.count == 200)
        t.feed(line)
        return t
    }

    @Test func tokenSplitAtTheMarginIsStillOneSpan() {
        let t = wrappedTerminal()
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)

        #expect(t.buffer.isWrapped(line: 1))
        #expect(t.buffer.isWrapped(line: 2))
        #expect(columns(o.overrides(line: 0, in: t)) == [79])   // 'u'
        #expect(columns(o.overrides(line: 1, in: t)) == [0])    // 'p'
        #expect(columns(o.overrides(line: 2, in: t)).isEmpty)
        #expect(p.calls == 1)                                   // one paragraph, one match
    }

    @Test func askingTheTailStillMatchesTheWholeParagraph() {
        // The first visible row is often the tail of a line whose head is above
        // the viewport: the walk goes back to the head before matching.
        let t = wrappedTerminal()
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)

        #expect(columns(o.overrides(line: 1, in: t)) == [0])
        #expect(p.lastParagraph.count > 80)                     // more than the asked row
        #expect(p.calls == 1)
    }

    @Test func everyRowOfTheParagraphIsServedFromOneMatch() {
        let t = wrappedTerminal()
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)

        for _ in 0..<3 {
            _ = o.overrides(line: 0, in: t)
            _ = o.overrides(line: 1, in: t)
            _ = o.overrides(line: 2, in: t)
        }
        #expect(p.calls == 1)
    }

    @Test func separateParagraphsAreSeparateMatches() {
        let t = Terminal(cols: 40, rows: 6)
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        t.feed("interface up\r\nother line up\r\n")

        #expect(columns(o.overrides(line: 0, in: t)) == [10, 11])
        #expect(columns(o.overrides(line: 1, in: t)) == [11, 12])
        #expect(p.calls == 2)
    }

    @Test func theHeadWalkAndTheParagraphAreBounded() {
        // A base64 blob wrapped into hundreds of rows must not turn one frame
        // into a scan of the scrollback: ≤ 32 rows back, ≤ 96 rows in total.
        let t = Terminal(cols: 80, rows: 24)
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        t.feed(String(repeating: "z", count: 80 * 200))

        _ = o.overrides(line: 150, in: t)
        #expect(p.calls == 1)
        #expect(p.lastParagraph.count <= 80 * HighlightOverlay.maxParagraphRows)
        #expect(p.lastParagraph.count >= 80 * 60)     // it did walk both ways
    }

    // MARK: - Cache invalidation

    @Test func newOutputOnAnyRowOfTheParagraphMisses() {
        let t = wrappedTerminal()
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)

        _ = o.overrides(line: 0, in: t)
        #expect(p.calls == 1)
        _ = o.overrides(line: 2, in: t)
        #expect(p.calls == 1)

        t.feed(" up")                                  // extends row 2 of the paragraph
        #expect(columns(o.overrides(line: 0, in: t)) == [79])
        #expect(p.calls == 2)
        #expect(columns(o.overrides(line: 2, in: t)).count == 2)
    }

    @Test func editingAnEarlierRowOfTheParagraphMisses() {
        let t = wrappedTerminal()
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        _ = o.overrides(line: 2, in: t)
        #expect(p.calls == 1)

        t.feed("\u{1b}[1;1H!")                         // rewrite column 0 of row 0
        _ = o.overrides(line: 2, in: t)
        #expect(p.calls == 2)
    }

    @Test func invalidateMissesAndMovesTheRevision() {
        let t = wrappedTerminal()
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        _ = o.overrides(line: 0, in: t)
        let before = o.revision

        o.invalidate()
        #expect(o.revision != before)
        _ = o.overrides(line: 0, in: t)
        #expect(p.calls == 2)
    }

    @Test func providerRevisionMissesAndMovesTheRevision() {
        let t = wrappedTerminal()
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        _ = o.overrides(line: 0, in: t)
        let before = o.revision
        #expect(p.calls == 1)

        p.revision &+= 1                                // a vendor switch
        #expect(o.revision != before)
        #expect(columns(o.overrides(line: 0, in: t)) == [79])
        #expect(p.calls == 2)
        // …and it settles again.
        let after = o.revision
        _ = o.overrides(line: 0, in: t)
        #expect(o.revision == after)
        #expect(p.calls == 2)
    }

    @Test func aNewProviderDropsEverything() {
        let t = wrappedTerminal()
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        _ = o.overrides(line: 0, in: t)
        let before = o.revision

        let q = FakeProvider(word: "yy")
        o.provider = q
        #expect(o.revision != before)
        _ = o.overrides(line: 0, in: t)
        #expect(q.calls == 1)
        #expect(p.calls == 1)
    }

    @Test func farAwayParagraphsAreTrimmedFromTheCache() {
        let t = Terminal(cols: 40, rows: 24)
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        for _ in 0..<600 { t.feed("interface up\r\n") }

        for line in 0..<10 { _ = o.overrides(line: line, in: t) }
        #expect(p.calls == 10)
        _ = o.overrides(line: 500, in: t)               // far away: 0…9 are dropped
        #expect(p.calls == 11)
        _ = o.overrides(line: 0, in: t)
        #expect(p.calls == 12)
        _ = o.overrides(line: 500, in: t)               // and back: 500 is gone now
        #expect(p.calls == 13)
        // Lines near the last one asked are still cached, however often we ask.
        for _ in 0..<5 {
            _ = o.overrides(line: 500, in: t)
            _ = o.overrides(line: 501, in: t)
        }
        #expect(p.calls == 14)
    }

    // MARK: - Stand-ins for non-ASCII

    @Test func anASCIITokenAfterThaiKeepsItsColumns() {
        let t = Terminal(cols: 40, rows: 4)
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        t.feed("(ไปตู้ MDF) up\r\n")

        let row = o.overrides(line: 0, in: t)
        let cols = columns(row)
        #expect(cols.count == 2)
        // The token sits where the grid actually put it.
        let cells = t.buffer.row(line: 0)!.cells
        #expect(cells[cols[0]].code == UInt32(UInt8(ascii: "u")))
        #expect(cells[cols[1]].code == UInt32(UInt8(ascii: "p")))
    }

    @Test func aWideCharSpacerRepeatsItsHeadByte() {
        let t = Terminal(cols: 40, rows: 4)
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        t.feed("中interface up\r\n")

        #expect(t.buffer.row(line: 0)!.cells[0].width == 2)
        #expect(t.buffer.row(line: 0)!.cells[1].isSpacer)
        // Two stand-in bytes for the two columns, so the ASCII after it is not
        // shifted: "interface" starts at column 2, "up" at 12/13.
        #expect(columns(o.overrides(line: 0, in: t)) == [12, 13])
        #expect(p.lastParagraph[0] == 0x5F)
        #expect(p.lastParagraph[1] == 0x5F)
    }

    @Test func aLetterStandInBlocksTheWordBoundary() {
        // `中up` must not match, exactly as the regex on the real stream would not.
        let t = Terminal(cols: 40, rows: 4)
        let o = HighlightOverlay(provider: FakeProvider())
        t.feed("中up\r\n")

        #expect(columns(o.overrides(line: 0, in: t)).isEmpty)
    }

    @Test func aSymbolStandInDoesNotBlockTheWordBoundary() {
        // `😀up` must match: an emoji is not a word character.
        let t = Terminal(cols: 40, rows: 4)
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        t.feed("😀up\r\n")

        let cols = columns(o.overrides(line: 0, in: t))
        #expect(cols.count == 2)
        let cells = t.buffer.row(line: 0)!.cells
        #expect(cells[cols[0]].code == UInt32(UInt8(ascii: "u")))
        #expect(p.lastParagraph[0] == 0x7F)
    }

    @Test func aCombinedCellClassifiesByItsGrapheme() {
        // "é" as e + U+0301 is one combined cell and one column; it is a letter,
        // so it blocks the boundary the way a plain letter does.
        let t = Terminal(cols: 40, rows: 4)
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        t.feed("e\u{0301}up up\r\n")

        let row = t.buffer.row(line: 0)!
        #expect(row.cells[0].isCombined)
        #expect(row.combinedString(at: 0) == "e\u{0301}")
        #expect(p.lastParagraph.isEmpty)                 // nothing matched yet
        let cols = columns(o.overrides(line: 0, in: t))
        #expect(p.lastParagraph[0] == 0x5F)              // letter → `_`
        #expect(cols == [4, 5])                          // only the second "up"
    }

    // MARK: - When there is nothing to give

    @Test func disabledReturnsNil() {
        let t = Terminal(cols: 40, rows: 4)
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        t.feed("interface up\r\n")

        o.enabled = false
        #expect(o.overrides(line: 0, in: t) == nil)
        #expect(p.calls == 0)
        o.enabled = true
        #expect(columns(o.overrides(line: 0, in: t)) == [10, 11])
    }

    @Test func togglingEnabledMovesTheRevision() {
        let o = HighlightOverlay(provider: FakeProvider())
        let before = o.revision
        o.enabled = false
        #expect(o.revision != before)
        let off = o.revision
        o.enabled = false                                // no change, no bump
        #expect(o.revision == off)
        o.enabled = true
        #expect(o.revision != off)
    }

    @Test func theAlternateScreenGetsNothing() {
        let t = Terminal(cols: 40, rows: 4)
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        t.feed("interface up\r\n")
        _ = o.overrides(line: 0, in: t)

        t.feed("\u{1b}[?1049h")                          // vim, htop: it owns its cells
        #expect(t.isAlternate)
        #expect(o.overrides(line: t.buffer.lastLine, in: t) == nil)
        #expect(o.overrides(line: 0, in: t) == nil)

        t.feed("\u{1b}[?1049l")
        #expect(columns(o.overrides(line: 0, in: t)) == [10, 11])
    }

    @Test func aLineThatIsNotRetainedReturnsNil() {
        let t = Terminal(cols: 40, rows: 4)
        let o = HighlightOverlay(provider: FakeProvider())
        t.feed("interface up\r\n")

        #expect(o.overrides(line: -1, in: t) == nil)
        #expect(o.overrides(line: t.buffer.firstLine - 1, in: t) == nil)
        #expect(o.overrides(line: t.buffer.lastLine + 1, in: t) == nil)
        #expect(o.overrides(line: t.buffer.lastLine, in: t) != nil)
    }

    @Test func aRetainedButUntouchedLineIsBlankNotNil() {
        let t = Terminal(cols: 40, rows: 8)
        let o = HighlightOverlay(provider: FakeProvider())
        t.feed("interface up\r\n")

        let blank = t.buffer.lastLine
        #expect(t.buffer.row(line: blank) == nil)        // never materialised
        let row = o.overrides(line: blank, in: t)
        #expect(row?.count == 40)
        #expect(columns(row).isEmpty)
    }

    @Test func aBlankParagraphIsCachedToo() {
        let t = Terminal(cols: 40, rows: 8)
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        t.feed("interface up\r\n")
        let blank = t.buffer.lastLine

        for _ in 0..<5 { _ = o.overrides(line: blank, in: t) }
        #expect(p.calls == 0)                            // no bytes, no match, no re-read
    }

    // MARK: - Geometry

    @Test func overridesFollowTheColumnCountAcrossAResize() {
        let t = Terminal(cols: 40, rows: 6)
        let o = HighlightOverlay(provider: FakeProvider())
        t.feed("interface up\r\n")
        #expect(o.overrides(line: 0, in: t)?.count == 40)

        t.resize(cols: 20, rows: 6)
        o.invalidate()                                   // the view does this on resize
        for line in t.buffer.firstLine...t.buffer.lastLine {
            #expect(o.overrides(line: line, in: t)?.count == 20)
        }
    }

    @Test func anEarlierRowIsNeverTrimmed() {
        // A wide character that does not fit in the last column wraps early, so
        // an earlier row of a paragraph CAN end in a blank column. Trimming it
        // (as the last row is trimmed) would pull every following byte one
        // column left and land the override on the wrong cells.
        let t = Terminal(cols: 20, rows: 6)
        let p = FakeProvider()
        let o = HighlightOverlay(provider: p)
        t.feed(String(repeating: "x", count: 19) + "中 up tail")

        let head = t.buffer.row(line: 0)!
        #expect(head.trimmedLength == 19)                // blank last column
        #expect(t.buffer.isWrapped(line: 1))
        #expect(p.lastParagraph.isEmpty)

        #expect(columns(o.overrides(line: 1, in: t)) == [3, 4])   // "中 up" → cols 0,1,2,3,4
        #expect(p.lastParagraph.count == 20 + 10)        // full first row + trimmed tail
        #expect(columns(o.overrides(line: 0, in: t)).isEmpty)
    }
}
