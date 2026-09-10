// SheepVTRender — the row builder and the palette, without a GPU.
//
// `FakeGlyphSource` stands in for the atlas so every drawing rule (wide chars,
// clusters, inverse/dim/bold, decorations, selection, search, the highlight
// overlay, the cursor) can be asserted on the instance arrays directly.

import CoreGraphics
import Testing

@testable import SheepVTRender
import SheepVT

// MARK: - fixtures

/// A glyph source that hands back a fixed placement and records what it was
/// asked for. `inkless` scalars come back nil (a glyph with no ink).
final class FakeGlyphSource: GlyphSource {
    struct ScalarRequest: Equatable { var scalar: Unicode.Scalar; var bold: Bool; var italic: Bool }
    struct ClusterRequest: Equatable { var cluster: String; var bold: Bool; var italic: Bool }

    var scalarRequests: [ScalarRequest] = []
    var clusterRequests: [ClusterRequest] = []
    var inkless: Set<Unicode.Scalar> = []
    /// Scalars answered from the BGRA atlas (colour emoji).
    var colorScalars: Set<Unicode.Scalar> = []
    /// Placement size in points, so tests can predict the quad.
    var size = SIMD2<Float>(6, 10)
    var offset = SIMD2<Float>(1, 2)

    func glyph(_ scalar: Unicode.Scalar, bold: Bool, italic: Bool) -> GlyphPlacement? {
        scalarRequests.append(ScalarRequest(scalar: scalar, bold: bold, italic: italic))
        guard !inkless.contains(scalar) else { return nil }
        return placement(color: colorScalars.contains(scalar))
    }

    func glyph(cluster: String, span: Int, bold: Bool, italic: Bool) -> GlyphPlacement? {
        clusterRequests.append(ClusterRequest(cluster: cluster, bold: bold, italic: italic))
        return placement(color: false)
    }

    private func placement(color: Bool) -> GlyphPlacement {
        GlyphPlacement(atlas: color ? .bgra : .grayscale,
                       uvOrigin: SIMD2<Float>(0.25, 0.5),
                       uvSize: SIMD2<Float>(0.1, 0.2),
                       offset: offset,
                       size: size)
    }
}

/// 8 × 16 pt cells at scale 2 — round numbers so the expected geometry is exact.
let testMetrics = CellMetrics(width: 8,
                              height: 16,
                              baseline: 12,
                              underlinePosition: 13,
                              underlineThickness: 1,
                              strikethroughPosition: 8,
                              scale: 2)

func makeBuilder(_ glyphs: FakeGlyphSource, palette: Palette = Palette(colors: .sheepTerm)) -> RowBuilder {
    RowBuilder(palette: palette, metrics: testMetrics, glyphs: glyphs)
}

/// A printable cell.
func textCell(_ ch: Character, fg: UInt32 = 0, bg: UInt32 = 0, width: Int = 1) -> Cell {
    Cell(code: ch.unicodeScalars.first!.value, width: UInt32(width), fg: fg, bg: bg)
}

func row(_ text: String, cols: Int? = nil) -> Row {
    let scalars = Array(text.unicodeScalars)
    let r = Row(cols: cols ?? scalars.count)
    for (i, s) in scalars.enumerated() where i < r.cols {
        r[i] = Cell(code: s.value, width: 1, fg: 0, bg: 0)
    }
    return r
}

func emptyOverlay() -> FrameOverlay {
    var o = FrameOverlay()
    o.cursorVisible = false
    return o
}

func approxEqual(_ a: Float, _ b: Float, _ tolerance: Float = 0.002) -> Bool {
    abs(a - b) <= tolerance
}

// MARK: - layout

@Suite struct InstanceLayoutTests {
    @Test func backgroundInstanceStrideIs32() {
        #expect(MemoryLayout<BackgroundInstance>.stride == 32)
        #expect(MemoryLayout<BackgroundInstance>.size == 32)
        #expect(MemoryLayout<BackgroundInstance>.alignment == 16)
    }

    @Test func glyphInstanceStrideIs48() {
        #expect(MemoryLayout<GlyphInstance>.stride == 48)
        #expect(MemoryLayout<GlyphInstance>.size == 48)
        #expect(MemoryLayout<GlyphInstance>.alignment == 16)
    }

    @Test func shaderSourceDeclaresEveryEntryPoint() {
        for name in [Shaders.backgroundVertex, Shaders.backgroundFragment, Shaders.glyphVertex,
                     Shaders.glyphFragmentGray, Shaders.glyphFragmentBGRA] {
            #expect(Shaders.source.contains(name), "missing \(name)")
        }
        // The Metal structs must carry the same fields in the same order.
        #expect(Shaders.source.contains("float2 uvOrigin"))
        #expect(Shaders.source.contains("float2 uvSize"))
    }
}

// MARK: - palette

@Suite struct PaletteTests {
    @Test func ansiColoursComeFromTheTheme() {
        let p = Palette(colors: .sheepTerm)
        #expect(p.rgb(at: 0) == 0x1C1F26)
        #expect(p.rgb(at: 1) == 0xED7A7A)
        #expect(p.rgb(at: 9) == 0xF29B9B)
        #expect(p.rgb(at: 15) == 0xF2F4F8)
    }

    @Test func cubeUsesXtermLevels() {
        let p = Palette(colors: .sheepTerm)
        #expect(p.rgb(at: 16) == 0x000000)
        #expect(p.rgb(at: 231) == 0xFFFFFF)
        #expect(p.rgb(at: 196) == 0xFF0000)   // r = 5, g = 0, b = 0
        #expect(p.rgb(at: 46) == 0x00FF00)    // r = 0, g = 5, b = 0
        #expect(p.rgb(at: 21) == 0x0000FF)    // r = 0, g = 0, b = 5
        #expect(p.rgb(at: 17) == 0x00005F)    // one step = 95
    }

    @Test func greyRampIsEightPlusTen() {
        let p = Palette(colors: .sheepTerm)
        #expect(p.rgb(at: 232) == 0x080808)
        #expect(p.rgb(at: 243) == 0x767676)
        #expect(p.rgb(at: 255) == 0xEEEEEE)
    }

    @Test func osc4OverridesReplaceEntries() {
        var p = Palette(colors: .sheepTerm)
        var overrides = [UInt32?](repeating: nil, count: 256)
        overrides[1] = 0x123456
        overrides[200] = 0xABCDEF
        p.apply(overrides: overrides)
        #expect(p.rgb(at: 1) == 0x123456)
        #expect(p.rgb(at: 200) == 0xABCDEF)
        #expect(p.rgb(at: 2) == 0x7DD98C)     // untouched
        p.apply(overrides: [UInt32?](repeating: nil, count: 256))
        #expect(p.rgb(at: 1) == 0xED7A7A)     // OSC 104 puts the theme back
    }

    @Test func defaultCellDrawsNoBackground() {
        let p = Palette(colors: .sheepTerm)
        let (fg, bg) = p.resolve(.empty, reverseVideo: false)
        #expect(bg == nil)
        #expect(fg == p.rgba(0xEDEFF3))
    }

    @Test func boldBrightensPalette16Foregrounds() {
        let p = Palette(colors: .sheepTerm)
        let plain = Cell(code: 65, width: 1,
                         fg: Cell.colorWord(source: .palette16, value: 1), bg: 0)
        let bold = Cell(code: 65, width: 1,
                        fg: Cell.colorWord(source: .palette16, value: 1, flags: Cell.FgFlag.bold), bg: 0)
        #expect(p.resolve(plain, reverseVideo: false).fg == p.rgba(0xED7A7A))
        #expect(p.resolve(bold, reverseVideo: false).fg == p.rgba(0xF29B9B))
        // A background is never brightened by bold.
        let boldBg = Cell(code: 65, width: 1,
                          fg: Cell.colorWord(source: .default, value: 0, flags: Cell.FgFlag.bold),
                          bg: Cell.colorWord(source: .palette16, value: 1))
        #expect(p.resolve(boldBg, reverseVideo: false).bg == p.rgba(0xED7A7A))
    }

    @Test func inverseSwapsAndAlwaysDrawsABackground() {
        let p = Palette(colors: .sheepTerm)
        let cell = Cell(code: 65, width: 1,
                        fg: Cell.colorWord(source: .default, value: 0, flags: Cell.FgFlag.inverse), bg: 0)
        let (fg, bg) = p.resolve(cell, reverseVideo: false)
        #expect(fg == p.rgba(0x1E2128))
        #expect(bg == p.rgba(0xEDEFF3))
    }

    @Test func dimScalesTheForeground() {
        let p = Palette(colors: .sheepTerm)
        let cell = Cell(code: 65, width: 1,
                        fg: Cell.colorWord(source: .rgb, value: 0xFFFFFF, flags: Cell.FgFlag.dim), bg: 0)
        let fg = p.resolve(cell, reverseVideo: false).fg
        #expect(approxEqual(fg.x, Palette.dimFactor))
        #expect(approxEqual(fg.w, 1))
    }

    @Test func invisibleMakesTheInkTheGround() {
        let p = Palette(colors: .sheepTerm)
        let cell = Cell(code: 65, width: 1,
                        fg: Cell.colorWord(source: .rgb, value: 0xFFFFFF),
                        bg: Cell.colorWord(source: .palette16, value: 4, flags: Cell.BgFlag.invisible))
        let (fg, bg) = p.resolve(cell, reverseVideo: false)
        #expect(fg == p.rgba(0x6CA9E0))
        #expect(bg == p.rgba(0x6CA9E0))
    }

    @Test func reverseVideoSwapsTheDefaults() {
        let p = Palette(colors: .sheepTerm)
        let (fg, bg) = p.resolve(.empty, reverseVideo: true)
        #expect(fg == p.rgba(0x1E2128))
        #expect(bg == nil)                    // the clear colour is the swapped one
        #expect(p.defaults(reverseVideo: true).bg == 0xEDEFF3)
    }

    @Test func trueColourPassesThrough() {
        let p = Palette(colors: .sheepTerm)
        let cell = Cell(code: 65, width: 1,
                        fg: Cell.colorWord(source: .rgb, value: 0x336699),
                        bg: Cell.colorWord(source: .palette256, value: 196))
        let (fg, bg) = p.resolve(cell, reverseVideo: false)
        #expect(fg == p.rgba(0x336699))
        #expect(bg == p.rgba(0xFF0000))
    }

    @Test func packedColourWordsDecode() {
        let p = Palette(colors: .sheepTerm)
        #expect(p.color(word: 0) == nil)
        #expect(p.color(word: Cell.colorWord(source: .palette256, value: 231)) == 0xFFFFFF)
        #expect(p.color(word: Cell.colorWord(source: .rgb, value: 0x010203)) == 0x010203)
    }
}

// MARK: - the row builder

@Suite struct RowBuilderTests {
    @Test func asciiRowEmitsOneGlyphPerCharacterAndNoBackgrounds() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let out = builder.build(row: row("hi"), line: 0, screenRow: 0, cols: 4,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.grayGlyphs.count == 2)
        #expect(out.colorGlyphs.isEmpty)
        #expect(out.backgrounds.isEmpty)     // default bg = the clear colour
        #expect(out.decorations.isEmpty)
        #expect(out.grayGlyphs[0].position == SIMD2<Float>(1, 2))
        #expect(out.grayGlyphs[1].position == SIMD2<Float>(9, 2))
        #expect(out.grayGlyphs[0].size == SIMD2<Float>(6, 10))
    }

    @Test func screenRowMovesTheWholeRowDown() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let out = builder.build(row: row("x"), line: 5, screenRow: 3, cols: 2,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.grayGlyphs[0].position.y == Float(3 * 16) + 2)
    }

    @Test func spacesAndEmptyCellsEmitNothing() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let out = builder.build(row: row("a b"), line: 0, screenRow: 0, cols: 3,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.grayGlyphs.count == 2)
        #expect(glyphs.scalarRequests.count == 2)   // the space is never looked up
    }

    @Test func aCellWithABackgroundDrawsOneQuad() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let r = Row(cols: 3)
        r[1] = Cell(code: 0, width: 1, fg: 0, bg: Cell.colorWord(source: .palette16, value: 2))
        let out = builder.build(row: r, line: 0, screenRow: 0, cols: 3,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.backgrounds.count == 1)
        #expect(out.backgrounds[0].position == SIMD2<Float>(8, 0))
        #expect(out.backgrounds[0].size == SIMD2<Float>(8, 16))
        #expect(out.backgrounds[0].color == Palette(colors: .sheepTerm).rgba(0x7DD98C))
        #expect(out.grayGlyphs.isEmpty)             // code 0 has nothing to draw
    }

    @Test func wideCharacterEmitsOneGlyphAndTwoCellsOfBackground() {
        let glyphs = FakeGlyphSource()
        glyphs.size = SIMD2<Float>(14, 12)
        let builder = makeBuilder(glyphs)
        let r = Row(cols: 4)
        let bg = Cell.colorWord(source: .palette16, value: 4)
        r[0] = Cell(code: 0x4E2D, width: 2, fg: 0, bg: bg)
        r[1] = Cell(code: 0, width: 0, fg: 0, bg: bg)      // the spacer
        let out = builder.build(row: r, line: 0, screenRow: 0, cols: 4,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.grayGlyphs.count == 1)
        #expect(glyphs.scalarRequests.count == 1)
        #expect(out.backgrounds.count == 1)
        #expect(out.backgrounds[0].size == SIMD2<Float>(16, 16))   // two cells wide
        // The glyph is centred in its two-cell slot: (16 - 14) / 2 = 1.
        #expect(out.grayGlyphs[0].position.x == 1)
        #expect(out.grayGlyphs[0].size.x == 14)
    }

    @Test func combinedCellsGoThroughTheClusterLookup() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let r = Row(cols: 2)
        r[0] = Cell(code: 0x0E01, width: 1, fg: 0, bg: 0)
        r.setCombined("ก\u{0E49}", at: 0)
        let out = builder.build(row: r, line: 0, screenRow: 0, cols: 2,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.grayGlyphs.count == 1)
        #expect(glyphs.clusterRequests == [FakeGlyphSource.ClusterRequest(cluster: "ก\u{0E49}", bold: false, italic: false)])
        #expect(glyphs.scalarRequests.isEmpty)
    }

    @Test func colourGlyphsGoToTheirOwnArrayAtFullBrightness() {
        let glyphs = FakeGlyphSource()
        glyphs.colorScalars = ["😀"]
        let builder = makeBuilder(glyphs)
        let r = Row(cols: 2)
        r[0] = Cell(code: 0x1F600, width: 2, fg: Cell.colorWord(source: .rgb, value: 0xFF0000), bg: 0)
        r[1] = Cell(code: 0, width: 0, fg: 0, bg: 0)
        let out = builder.build(row: r, line: 0, screenRow: 0, cols: 2,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.grayGlyphs.isEmpty)
        #expect(out.colorGlyphs.count == 1)
        // The bitmap carries its own colour: the instance must not tint it.
        #expect(out.colorGlyphs[0].color == SIMD4<Float>(1, 1, 1, 1))
    }

    @Test func invisibleSkipsTheGlyphButKeepsTheBackground() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let r = Row(cols: 2)
        r[0] = Cell(code: 65, width: 1, fg: 0,
                    bg: Cell.colorWord(source: .palette16, value: 1, flags: Cell.BgFlag.invisible))
        let out = builder.build(row: r, line: 0, screenRow: 0, cols: 2,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.grayGlyphs.isEmpty)
        #expect(glyphs.scalarRequests.isEmpty)
        #expect(out.backgrounds.count == 1)
    }

    @Test func boldAndItalicReachTheGlyphSource() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let r = Row(cols: 2)
        r[0] = Cell(code: 65, width: 1,
                    fg: Cell.colorWord(source: .default, value: 0,
                                       flags: Cell.FgFlag.bold | Cell.FgFlag.italic), bg: 0)
        _ = builder.build(row: r, line: 0, screenRow: 0, cols: 2,
                          overlay: emptyOverlay(), cursor: nil)
        #expect(glyphs.scalarRequests.first?.bold == true)
        #expect(glyphs.scalarRequests.first?.italic == true)
    }

    @Test func anInklessGlyphEmitsNoInstance() {
        let glyphs = FakeGlyphSource()
        glyphs.inkless = ["a"]
        let builder = makeBuilder(glyphs)
        let out = builder.build(row: row("ab"), line: 0, screenRow: 0, cols: 2,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.grayGlyphs.count == 1)
    }

    @Test func aBlankLineStillBuildsWithoutARow() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let out = builder.build(row: nil, line: 7, screenRow: 1, cols: 10,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.isEmpty)
    }
}

// MARK: - decorations

@Suite struct DecorationTests {
    @Test func singleUnderlineIsOneQuadPerCell() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let r = Row(cols: 3)
        for i in 0..<2 {
            r[i] = Cell(code: 65, width: 1,
                        fg: Cell.colorWord(source: .default, value: 0, flags: Cell.FgFlag.underline), bg: 0)
        }
        let out = builder.build(row: r, line: 0, screenRow: 0, cols: 3,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.decorations.count == 2)
        // Centre 13, thickness 1 → the quad's top edge is 12.5.
        #expect(out.decorations[0].position == SIMD2<Float>(0, 12.5))
        #expect(out.decorations[0].size == SIMD2<Float>(8, 1))
        #expect(out.decorations[1].position.x == 8)
    }

    @Test func doubleAndCurlyUnderlinesAreTwoLines() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        for style in [ExtendedAttributes.UnderlineStyle.double, .curly] {
            let r = Row(cols: 1)
            r[0] = Cell(code: 65, width: 1, fg: 0, bg: 0)
            var ext = ExtendedAttributes()
            ext.underlineStyle = style
            r.setExtended(ext, at: 0)
            let out = builder.build(row: r, line: 0, screenRow: 0, cols: 1,
                                    overlay: emptyOverlay(), cursor: nil)
            #expect(out.decorations.count == 2, "\(style)")
            #expect(out.decorations[1].position.y > out.decorations[0].position.y)
        }
    }

    @Test func dottedAndDashedUnderlinesAreSegments() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        var counts: [Int] = []
        for style in [ExtendedAttributes.UnderlineStyle.dotted, .dashed] {
            let r = Row(cols: 1)
            r[0] = Cell(code: 65, width: 1, fg: 0, bg: 0)
            var ext = ExtendedAttributes()
            ext.underlineStyle = style
            r.setExtended(ext, at: 0)
            let out = builder.build(row: r, line: 0, screenRow: 0, cols: 1,
                                    overlay: emptyOverlay(), cursor: nil)
            counts.append(out.decorations.count)
        }
        #expect(counts[0] == 4)          // dotted: 1 pt on, 1 pt off across 8 pt
        #expect(counts[1] == 2)          // dashed: 2.67 pt on, 2.67 off
    }

    @Test func underlineColourOverridesTheForeground() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let r = Row(cols: 1)
        r[0] = Cell(code: 65, width: 1, fg: 0, bg: 0)
        var ext = ExtendedAttributes()
        ext.underlineStyle = .single
        ext.underlineColor = Cell.colorWord(source: .rgb, value: 0xFF0000)
        r.setExtended(ext, at: 0)
        let out = builder.build(row: r, line: 0, screenRow: 0, cols: 1,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.decorations.count == 1)
        #expect(out.decorations[0].color == SIMD4<Float>(1, 0, 0, 1))
    }

    @Test func strikethroughAndOverlineAreTheirOwnQuads() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let r = Row(cols: 1)
        r[0] = Cell(code: 65, width: 1, fg: 0,
                    bg: Cell.colorWord(source: .default, value: 0,
                                       flags: Cell.BgFlag.strikethrough | Cell.BgFlag.overline))
        let out = builder.build(row: r, line: 0, screenRow: 0, cols: 1,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.decorations.count == 2)
        #expect(out.decorations[0].position.y == 7.5)   // centre 8, thickness 1
        #expect(out.decorations[1].position.y == 0)     // overline hugs the top
    }

    @Test func aWideCellsDecorationSpansBothColumns() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let r = Row(cols: 2)
        r[0] = Cell(code: 0x4E2D, width: 2,
                    fg: Cell.colorWord(source: .default, value: 0, flags: Cell.FgFlag.underline), bg: 0)
        r[1] = Cell(code: 0, width: 0, fg: 0, bg: 0)
        let out = builder.build(row: r, line: 0, screenRow: 0, cols: 2,
                                overlay: emptyOverlay(), cursor: nil)
        #expect(out.decorations.count == 1)
        #expect(out.decorations[0].size.x == 16)
    }
}

// MARK: - overlays

@Suite struct OverlayTintTests {
    /// A terminal with one line of text and a live selection over it.
    private func terminalWithText(_ text: String) -> Terminal {
        let t = Terminal(cols: 20, rows: 3, scrollback: 100)
        t.feed(text)
        return t
    }

    @Test func selectionAddsOneTintOverTheCellBackgrounds() throws {
        let t = terminalWithText("interface up")
        let line = t.buffer.lineNumber(ofScreenRow: 0)
        let selection = Selection(terminal: t)
        selection.begin(at: Position(line: line, col: 0))
        selection.extend(to: Position(line: line, col: 3))

        var overlay = emptyOverlay()
        overlay.selection = selection
        let glyphs = FakeGlyphSource()
        let out = makeBuilder(glyphs).build(row: t.buffer.row(line: line), line: line, screenRow: 0,
                                            cols: 20, overlay: overlay, cursor: nil)
        let tint = try #require(out.backgrounds.last)
        #expect(tint.position == SIMD2<Float>(0, 0))
        #expect(tint.size == SIMD2<Float>(32, 16))       // 4 cells
        #expect(approxEqual(tint.color.w, 0.30))
    }

    @Test func selectionOnAnotherLineTintsNothing() {
        let t = terminalWithText("interface up")
        let line = t.buffer.lineNumber(ofScreenRow: 0)
        let selection = Selection(terminal: t)
        selection.begin(at: Position(line: line, col: 0))
        selection.extend(to: Position(line: line, col: 3))
        var overlay = emptyOverlay()
        overlay.selection = selection
        let out = makeBuilder(FakeGlyphSource()).build(row: nil, line: line + 1, screenRow: 1,
                                                       cols: 20, overlay: overlay, cursor: nil)
        #expect(out.backgrounds.isEmpty)
    }

    @Test func searchMatchesAndTheCurrentOneUseDifferentTints() {
        var overlay = emptyOverlay()
        overlay.searchMatches = [SearchMatch(start: Position(line: 4, col: 2), end: Position(line: 4, col: 4)),
                                 SearchMatch(start: Position(line: 4, col: 10), end: Position(line: 4, col: 11))]
        overlay.currentMatch = overlay.searchMatches[1]
        let out = makeBuilder(FakeGlyphSource()).build(row: nil, line: 4, screenRow: 0,
                                                       cols: 20, overlay: overlay, cursor: nil)
        #expect(out.backgrounds.count == 2)
        #expect(out.backgrounds[0].size.x == 24)         // cols 2…4 inclusive
        #expect(approxEqual(out.backgrounds[0].color.w, 0.35))
        #expect(approxEqual(out.backgrounds[1].color.w, 0.55))
        #expect(out.backgrounds[1].position.x == 80)
    }

    @Test func aMatchSpanningTwoLinesTintsToTheMarginOnTheFirst() {
        var overlay = emptyOverlay()
        overlay.searchMatches = [SearchMatch(start: Position(line: 4, col: 18), end: Position(line: 5, col: 1))]
        let first = makeBuilder(FakeGlyphSource()).build(row: nil, line: 4, screenRow: 0, cols: 20,
                                                         overlay: overlay, cursor: nil)
        let second = makeBuilder(FakeGlyphSource()).build(row: nil, line: 5, screenRow: 1, cols: 20,
                                                          overlay: overlay, cursor: nil)
        #expect(first.backgrounds.count == 1)
        #expect(first.backgrounds[0].position.x == 144)   // col 18
        #expect(first.backgrounds[0].size.x == 16)        // to the right margin
        #expect(second.backgrounds[0].position.x == 0)
        #expect(second.backgrounds[0].size.x == 16)       // cols 0…1
    }

    @Test func highlightOverridesOnlyTouchDefaultForegrounds() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let r = Row(cols: 3)
        r[0] = Cell(code: 65, width: 1, fg: 0, bg: 0)                                        // default fg
        r[1] = Cell(code: 66, width: 1, fg: Cell.colorWord(source: .rgb, value: 0x00FF00), bg: 0)
        var overlay = emptyOverlay()
        let word = FrameOverlay.highlightPresentBit | 0xFF0000
        overlay.highlightOverrides = { _ in [word, word, 0] }
        let out = builder.build(row: r, line: 0, screenRow: 0, cols: 3, overlay: overlay, cursor: nil)
        #expect(out.grayGlyphs.count == 2)
        #expect(out.grayGlyphs[0].color == SIMD4<Float>(1, 0, 0, 1))          // overridden
        #expect(out.grayGlyphs[1].color == SIMD4<Float>(0, 1, 0, 1))          // the device's colour survives
    }

    @Test func aBoldHighlightAsksForTheBoldGlyph() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        var overlay = emptyOverlay()
        overlay.highlightOverrides = { _ in [FrameOverlay.highlightPresentBit | FrameOverlay.highlightBoldBit | 0x00FF00] }
        _ = builder.build(row: row("a"), line: 0, screenRow: 0, cols: 1, overlay: overlay, cursor: nil)
        #expect(glyphs.scalarRequests.first?.bold == true)
    }

    @Test func reverseVideoFlipsTheDefaultInk() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        var overlay = emptyOverlay()
        overlay.reverseVideo = true
        let out = builder.build(row: row("a"), line: 0, screenRow: 0, cols: 1, overlay: overlay, cursor: nil)
        #expect(out.grayGlyphs[0].color == Palette(colors: .sheepTerm).rgba(0x1E2128))
        #expect(out.backgrounds.isEmpty)      // the clear colour already carries the swap
    }
}

// MARK: - cursor

@Suite struct CursorTests {
    private func overlay(focused: Bool = true, blinkOn: Bool = true, visible: Bool = true) -> FrameOverlay {
        var o = FrameOverlay()
        o.focused = focused
        o.cursorBlinkOn = blinkOn
        o.cursorVisible = visible
        return o
    }

    @Test func focusedBlockFillsTheCellAndInvertsTheGlyph() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let out = builder.build(row: row("ab"), line: 0, screenRow: 0, cols: 2,
                                overlay: overlay(), cursor: (col: 1, style: .steadyBlock))
        #expect(out.backgrounds.count == 1)
        #expect(out.backgrounds[0].position == SIMD2<Float>(8, 0))
        #expect(out.backgrounds[0].size == SIMD2<Float>(8, 16))
        #expect(out.backgrounds[0].color == Palette(colors: .sheepTerm).rgba(0xEDEFF3))
        #expect(out.grayGlyphs.count == 2)
        #expect(out.grayGlyphs[1].color == Palette(colors: .sheepTerm).rgba(0x1E2128))
        #expect(out.grayGlyphs[0].color == Palette(colors: .sheepTerm).rgba(0xEDEFF3))
    }

    @Test func barCursorIsAThinDecoration() {
        let builder = makeBuilder(FakeGlyphSource())
        let out = builder.build(row: row("ab"), line: 0, screenRow: 0, cols: 2,
                                overlay: overlay(), cursor: (col: 0, style: .blinkBar))
        #expect(out.backgrounds.isEmpty)
        #expect(out.decorations.count == 1)
        #expect(out.decorations[0].size == SIMD2<Float>(1, 16))
        #expect(out.grayGlyphs[0].color == Palette(colors: .sheepTerm).rgba(0xEDEFF3))
    }

    @Test func underlineCursorSitsOnTheCellsFloor() {
        let builder = makeBuilder(FakeGlyphSource())
        let out = builder.build(row: row("ab"), line: 0, screenRow: 2, cols: 2,
                                overlay: overlay(), cursor: (col: 1, style: .steadyUnderline))
        #expect(out.decorations.count == 1)
        let quad = out.decorations[0]
        #expect(quad.position.y + quad.size.y == Float(3 * 16))
        #expect(quad.size.x == 8)
    }

    @Test func anUnfocusedCursorIsAHollowRectangle() {
        let builder = makeBuilder(FakeGlyphSource())
        let out = builder.build(row: row("ab"), line: 0, screenRow: 0, cols: 2,
                                overlay: overlay(focused: false), cursor: (col: 0, style: .steadyBlock))
        #expect(out.backgrounds.isEmpty)
        #expect(out.decorations.count == 4)
        // One device pixel at scale 2 = half a point.
        #expect(out.decorations.allSatisfy { min($0.size.x, $0.size.y) == 0.5 })
        #expect(out.grayGlyphs[0].color == Palette(colors: .sheepTerm).rgba(0xEDEFF3))
    }

    @Test func blinkOffAndHiddenCursorsDrawNothing() {
        let builder = makeBuilder(FakeGlyphSource())
        for o in [overlay(blinkOn: false), overlay(visible: false)] {
            let out = builder.build(row: row("ab"), line: 0, screenRow: 0, cols: 2,
                                    overlay: o, cursor: (col: 0, style: .steadyBlock))
            #expect(out.backgrounds.isEmpty)
            #expect(out.decorations.isEmpty)
        }
    }

    @Test func aBlockCursorOnAWideCellCoversBothColumns() {
        let glyphs = FakeGlyphSource()
        let builder = makeBuilder(glyphs)
        let r = Row(cols: 2)
        r[0] = Cell(code: 0x4E2D, width: 2, fg: 0, bg: 0)
        r[1] = Cell(code: 0, width: 0, fg: 0, bg: 0)
        let out = builder.build(row: r, line: 0, screenRow: 0, cols: 2,
                                overlay: overlay(), cursor: (col: 0, style: .steadyBlock))
        #expect(out.backgrounds.count == 1)
        #expect(out.backgrounds[0].size.x == 16)
    }

    @Test func aCursorPastTheLastColumnIsIgnored() {
        let builder = makeBuilder(FakeGlyphSource())
        let out = builder.build(row: row("ab"), line: 0, screenRow: 0, cols: 2,
                                overlay: overlay(), cursor: (col: 5, style: .steadyBlock))
        #expect(out.backgrounds.isEmpty)
        #expect(out.decorations.isEmpty)
    }

    @Test func cursorShapeFoldsAwayTheBlinkStyles() {
        #expect(RowBuilder.CursorShape(.blinkBlock) == .block)
        #expect(RowBuilder.CursorShape(.steadyBlock) == .block)
        #expect(RowBuilder.CursorShape(.blinkUnderline) == .underline)
        #expect(RowBuilder.CursorShape(.steadyUnderline) == .underline)
        #expect(RowBuilder.CursorShape(.blinkBar) == .bar)
        #expect(RowBuilder.CursorShape(.steadyBar) == .bar)
    }
}
