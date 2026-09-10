// SheepVTRender — where a frame's search tints come from.
//
// `RowBuilder` can derive a line's tints from `FrameOverlay.searchMatches`
// itself, but that scan is O(matches) for every row it rebuilds. `MetalRenderer`
// therefore bucket-sorts the matches once per frame and installs
// `FrameOverlay.searchTints`. It used to install that closure only when the
// bucket map came out non-empty — so a search whose matches are all in the
// scrollback (map empty, matches many) put every rebuilt row back on the scan:
// 40 rows x 50 rounds with 10,000 off-screen matches cost 0.4116 s in Release
// against 0.0029 s with a closure that answers "none here" in O(1).
//
// `RowBuilder.searchTintFallbacks` counts the scans, so the regression is a
// counter and not a stopwatch.

import Testing

@testable import SheepVTRender
import SheepVT

@Suite struct SearchTintTests {
    /// Matches on lines the viewport does not show, in the numbers a real
    /// search over a full scrollback produces.
    private func offScreenMatches(count: Int, firstOffScreenLine: Int) -> [SearchMatch] {
        (0..<count).map { i in
            let line = firstOffScreenLine + i
            return SearchMatch(start: Position(line: line, col: 0), end: Position(line: line, col: 3))
        }
    }

    @Test func offScreenMatchesDoNotPutRowsBackOnTheMatchScan() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("interface up\r\nline protocol up\r\nvlan 10")
        // Every match sits far above the viewport: the per-frame map is empty,
        // which is an answer ("nothing on screen"), not a missing one.
        let firstVisible = harness.terminal.buffer.lineNumber(ofViewportRow: 0)
        var overlay = plainOverlay()
        overlay.searchMatches = offScreenMatches(count: 10_000,
                                                 firstOffScreenLine: firstVisible - 20_000)
        overlay.currentMatch = overlay.searchMatches.first

        let before = RowBuilder.searchTintFallbacks
        harness.render(overlay)                       // cold: every row is rebuilt
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == harness.rows)
        harness.render(overlay)                       // warm: every row is cached
        #expect(RowBuilder.searchTintFallbacks == before)
    }

    @Test func aVisibleMatchStillGetsItsTintFromTheMap() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("interface up")
        let line = harness.terminal.buffer.lineNumber(ofScreenRow: 0)

        harness.render(plainOverlay())
        let plain = harness.readback()

        var overlay = plainOverlay()
        overlay.searchMatches = [SearchMatch(start: Position(line: line, col: 0),
                                             end: Position(line: line, col: 3))]
        let before = RowBuilder.searchTintFallbacks
        harness.render(overlay)
        let tinted = harness.readback()
        #expect(RowBuilder.searchTintFallbacks == before)
        // y = 1 is the top edge of row 0, above every glyph's ink, so this
        // compares tint against ground and not antialiasing against itself.
        let cellW = Int(harness.renderer.fontSet.metrics.width * harness.scale)
        #expect(tinted.rgb(x: cellW * 2, y: 1) != plain.rgb(x: cellW * 2, y: 1))   // inside cols 0…3
        #expect(tinted.rgb(x: cellW * 10, y: 1) == plain.rgb(x: cellW * 10, y: 1)) // outside them
    }

    /// The scan is still the right answer for a caller that never builds a map
    /// — `RowBuilder` used on its own, which is how most of these tests drive it.
    @Test func aBuilderWithNoMapStillDerivesTintsFromTheMatches() {
        var overlay = FrameOverlay()
        overlay.cursorVisible = false
        overlay.searchMatches = [SearchMatch(start: Position(line: 7, col: 1),
                                             end: Position(line: 7, col: 2))]
        #expect(overlay.searchTints == nil)

        let before = RowBuilder.searchTintFallbacks
        let out = makeBuilder(FakeGlyphSource()).build(row: nil, line: 7, screenRow: 0,
                                                       cols: 20, overlay: overlay, cursor: nil)
        #expect(RowBuilder.searchTintFallbacks == before + 1)
        #expect(out.backgrounds.count == 1)
        #expect(out.backgrounds[0].position.x == 8)      // col 1
        #expect(out.backgrounds[0].size.x == 16)         // cols 1…2
    }

    /// An installed closure that answers "no tints here" must be taken at its
    /// word: it is what an empty map looks like, and it must not fall through.
    @Test func anEmptyAnswerFromTheClosureIsNotAFallThrough() {
        var overlay = FrameOverlay()
        overlay.cursorVisible = false
        overlay.searchMatches = [SearchMatch(start: Position(line: 7, col: 1),
                                             end: Position(line: 7, col: 2))]
        overlay.searchTints = { _ in [] }

        let before = RowBuilder.searchTintFallbacks
        let out = makeBuilder(FakeGlyphSource()).build(row: nil, line: 7, screenRow: 0,
                                                       cols: 20, overlay: overlay, cursor: nil)
        #expect(RowBuilder.searchTintFallbacks == before)
        #expect(out.backgrounds.isEmpty)
    }
}
