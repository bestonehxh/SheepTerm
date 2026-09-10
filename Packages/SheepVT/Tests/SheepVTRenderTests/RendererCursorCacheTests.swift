// SheepVTRender — the cursor's half of the row-cache key.
//
// The cursor blinks twice a second for as long as a window is open. It used to
// sit in every row's key, so an idle terminal rebuilt its whole screen twice a
// second; measured at 120x40 that was 40 rows and 0.92 ms per blink against
// 1 row and 0.54 ms now. These tests pin the rebuild counts so the cursor
// cannot creep back into the other rows' keys — and check the pixels either
// side of a toggle, because a cache that never rebuilds is only correct if the
// row it does rebuild is the one whose picture changed.

import CoreGraphics
import Metal
import Testing

@testable import SheepVTRender
import SheepVT

/// A frame overlay with a visible cursor (the opposite of `plainOverlay`).
private func cursorOverlay(blinkOn: Bool = true, focused: Bool = true) -> FrameOverlay {
    var o = FrameOverlay()
    o.cursorVisible = true
    o.cursorBlinkOn = blinkOn
    o.focused = focused
    return o
}

@Suite struct RendererCursorCacheTests {
    @Test func aBlinkRebuildsOnlyTheRowTheCursorIsOn() throws {
        guard let harness = try makeHarness() else { return }
        // Fill the screen and leave the cursor on the last row.
        harness.terminal.feed("interface\r\nline protocol\r\nspeed 1000")
        harness.render(cursorOverlay())
        harness.render(cursorOverlay())
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows)

        // Blink off, then on again: one row each way, never the screen.
        harness.render(cursorOverlay(blinkOn: false))
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == 1)
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows - 1)
        harness.render(cursorOverlay(blinkOn: true))
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == 1)
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows - 1)
    }

    @Test func aHiddenCursorBlinksNothing() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("interface\r\nline protocol\r\nspeed 1000")
        // DECTCEM off: the blink phase still toggles, but nothing is painted,
        // so not even the cursor's own row may move.
        harness.terminal.feed("\u{1B}[?25l")
        harness.render(cursorOverlay())
        harness.render(cursorOverlay())
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows)
        harness.render(cursorOverlay(blinkOn: false))
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == 0)
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows)
    }

    @Test func aCursorScrolledOutOfTheViewportBlinksNothing() throws {
        guard let harness = try makeHarness() else { return }
        for i in 0..<20 { harness.terminal.feed("line \(i)\r\n") }
        // Look at the top of the scrollback: the cursor is far below.
        harness.terminal.buffer.ydisp = 0
        #expect(harness.terminal.buffer.ybase > harness.rows)
        harness.render(cursorOverlay())
        harness.render(cursorOverlay())
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows)
        harness.render(cursorOverlay(blinkOn: false))
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == 0)
    }

    @Test func theCursorMovingRebuildsTheRowItLeftAndTheOneItArrivesOn() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("interface\r\nline protocol\r\nspeed 1000")
        harness.render(cursorOverlay())
        harness.render(cursorOverlay())
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows)

        // CUP to the top row: no glyph printed, so only the cursor's two rows
        // may move — the one it left and the one it arrived on.
        harness.terminal.feed("\u{1B}[1;1H")
        harness.render(cursorOverlay())
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == 2)
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows - 2)
    }

    @Test func movingWithinARowRebuildsOnlyThatRow() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("interface\r\nline protocol\r\nspeed 1000")
        harness.render(cursorOverlay())
        harness.render(cursorOverlay())
        harness.terminal.feed("\u{1B}[3;2H")     // same row, a column to the left
        harness.render(cursorOverlay())
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == 1)
    }

    @Test func losingFocusRebuildsOnlyTheCursorRow() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("interface\r\nline protocol\r\nspeed 1000")
        harness.render(cursorOverlay())
        harness.render(cursorOverlay())
        // Focus changes the cursor from a filled block to a hollow rectangle
        // and nothing else, so it is a one-row repaint like the blink.
        harness.render(cursorOverlay(focused: false))
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == 1)
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows - 1)
    }

    @Test func theBlinkStillPaintsAndErasesTheCursorCell() throws {
        guard let harness = try makeHarness() else { return }
        harness.render(cursorOverlay())
        #expect(harness.readback().rgb(x: 2, y: 2) == 0xEDEFF3)   // the cursor fill
        harness.render(cursorOverlay(blinkOn: false))
        #expect(harness.readback().rgb(x: 2, y: 2) == 0x1E2128)   // the theme ground
        // …and back, from a cache that has now seen both phases of this row.
        harness.render(cursorOverlay())
        #expect(harness.readback().rgb(x: 2, y: 2) == 0xEDEFF3)
    }

    @Test func aBlinkOverAWideCharactersSpacerRepaintsTheWholeCharacter() throws {
        guard let harness = try makeHarness() else { return }
        // A block cursor on the trailing half of a wide char snaps to the head
        // cell and covers both, so the row genuinely renders differently — the
        // one-row rebuild has to be that row, and it has to be complete.
        harness.terminal.feed("\u{6F22}\u{5B57}\r\nsecond\r\nthird")
        harness.terminal.feed("\u{1B}[1;2H")     // the spacer of the first char
        harness.render(cursorOverlay())
        harness.render(cursorOverlay())
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows)

        let cellHeight = Int(harness.renderer.fontSet.metrics.height * harness.scale)
        let lit = harness.readback().histogram(rows: 0..<cellHeight)[0xEDEFF3] ?? 0
        #expect(lit > 0)                          // the fill is on screen

        harness.render(cursorOverlay(blinkOn: false))
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == 1)
        let dark = harness.readback().histogram(rows: 0..<cellHeight)[0xEDEFF3] ?? 0
        #expect(dark < lit)                       // and gone again
    }
}
