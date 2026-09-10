// SheepVTRender — the default colours have to reach the picture.
//
// The core keeps the theme's colours beside the ones a program set with
// OSC 10/11/12, and OSC 110/111/112 and RIS hand them back. A counter that
// moves is not proof that anything changed on screen, so these read the pixels
// back out of the offscreen texture; the view half checks the two places the
// renderer's own sync does not reach (the layer backdrop and the cursor
// colour, which is OSC 12's).

import AppKit
import Metal
import Testing

@testable import SheepVTRender
import SheepVT

@Suite @MainActor struct DefaultColorRenderTests {

    @Test func osc111PutsTheThemeBackOnTheScreen() throws {
        guard let harness = try makeHarness() else { return }
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 0, y: 0) == 0x1E2128)
        harness.terminal.feed("\u{1B}]11;#00ff00\u{07}")
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 0, y: 0) == 0x00FF00)
        // The program hands the ground back on its way out.
        harness.terminal.feed("\u{1B}]111\u{07}")
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 0, y: 0) == 0x1E2128)
        #expect(harness.renderer.palette.colors.background == 0x1E2128)
    }

    /// Same restore, but the theme is not the one the tab was opened with: the
    /// pixels have to land on the host's *current* baseline.
    @Test func osc111RestoresTheThemeTheHostSetLast() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.defaultBackground = 0x102030          // the user's theme
        harness.terminal.feed("\u{1B}]11;#00ff00\u{07}")
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 0, y: 0) == 0x00FF00)
        harness.terminal.feed("\u{1B}]111\u{07}")
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 0, y: 0) == 0x102030)
    }

    @Test func risPutsTheThemeBackOnTheScreen() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.defaultBackground = 0x102030
        harness.terminal.feed("\u{1B}]10;#ff0000\u{07}\u{1B}]11;#00ff00\u{07}")
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 0, y: 0) == 0x00FF00)
        harness.terminal.feed("\u{1B}c")                       // `tput reset`
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 0, y: 0) == 0x102030)
        #expect(harness.renderer.palette.colors.foreground == 0xEDEFF3)
    }

    /// The user picks a theme while a program holds an override: the new theme
    /// is on screen at once, and the program's later restore keeps it.
    @Test func aThemeChangeDuringAnOverrideReachesTheScreen() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("\u{1B}]11;#00ff00\u{07}")
        harness.render(plainOverlay())
        harness.terminal.defaultBackground = 0xF5F5F5
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 0, y: 0) == 0xF5F5F5)
        harness.terminal.feed("\u{1B}]111\u{07}")
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 0, y: 0) == 0xF5F5F5)
    }

    // MARK: - the view's half of the seam

    @Test func theViewsThemeBecomesTheCoresBaseline() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
        var colors = TerminalColors.sheepTerm
        colors.background = 0xF5F5F5
        colors.foreground = 0x101010
        colors.cursor = 0x336699
        view.colors = colors
        #expect(view.terminal.hostBackground == 0xF5F5F5)
        #expect(view.terminal.hostForeground == 0x101010)
        #expect(view.terminal.hostCursorColor == 0x336699)
    }

    @Test func theLayerBackdropFollowsOsc11AndComesBackOnOsc111() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
        view.terminal.feed("\u{1B}]11;#00ff00\u{07}")
        view.renderFrame()
        #expect(layerRGB(view) == 0x00FF00)
        view.terminal.feed("\u{1B}]111\u{07}")
        view.renderFrame()
        #expect(layerRGB(view) == 0x1E2128)
    }

    /// OSC 12 lives in the palette rather than in the frame, so it is the
    /// view that has to push it — and put the theme's cursor back on OSC 112.
    @Test func theCursorColourFollowsOsc12AndComesBackOnOsc112() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
        view.terminal.feed("\u{1B}]12;#ff8800\u{07}")
        view.renderFrame()
        #expect(view.palette.colors.cursor == 0xFF8800)
        view.terminal.feed("\u{1B}]112\u{07}")
        view.renderFrame()
        #expect(view.palette.colors.cursor == TerminalColors.sheepTerm.cursor)
    }

    /// The palette the view pushes must not lose the program's OSC 4 entries:
    /// the renderer only re-applies them when its own record is behind.
    @Test func theViewsPushKeepsTheProgramsPaletteOverrides() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
        view.terminal.feed("\u{1B}]4;1;#123456\u{07}")
        view.terminal.feed("\u{1B}]12;#ff8800\u{07}")
        view.renderFrame()
        #expect(view.palette.rgb(at: 1) == 0x123456)
    }

    /// 0xRRGGBB of the layer's backdrop (sRGB, as `updateLayerBackground` sets it).
    private func layerRGB(_ view: TerminalView) -> UInt32? {
        guard let color = view.layer?.backgroundColor,
              let comps = color.components, comps.count >= 3 else { return nil }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return (byte(comps[0]) << 16) | (byte(comps[1]) << 8) | byte(comps[2])
    }
}
