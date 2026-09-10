// SheepVTRender — the Metal renderer, offscreen.
//
// `MetalRenderer.render(terminal:overlay:into:scale:)` shares the whole encode
// path with the layer version, so rendering into a texture and reading the
// pixels back checks the real pipelines, the real atlas and the real row cache.
// Everything here is skipped with a message when the machine has no Metal
// device (a headless CI box).

import CoreGraphics
import IOSurface
import Metal
import Testing

@testable import SheepVTRender
import SheepVT

// MARK: - helpers

/// One frame's pixels, read back out of a BGRA texture.
struct Framebuffer {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    /// 0xRRGGBB at a pixel.
    func rgb(x: Int, y: Int) -> UInt32 {
        let i = (y * width + x) * 4
        let b = UInt32(bytes[i]), g = UInt32(bytes[i + 1]), r = UInt32(bytes[i + 2])
        return (r << 16) | (g << 8) | b
    }

    /// Every distinct colour in a horizontal band, with counts.
    func histogram(rows: Range<Int>) -> [UInt32: Int] {
        var out: [UInt32: Int] = [:]
        for y in rows {
            for x in 0..<width { out[rgb(x: x, y: y), default: 0] += 1 }
        }
        return out
    }
}

/// A renderer plus the offscreen texture it draws into.
@MainActor
final class RenderHarness {
    let device: MTLDevice
    let renderer: MetalRenderer
    let texture: MTLTexture
    let terminal: Terminal
    let scale: CGFloat = 2
    let cols = 20
    let rows = 3

    init?() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        self.renderer = try MetalRenderer(device: device)
        renderer.fontSet = FontSet(font: .monospacedSystemFont(ofSize: 13, weight: .regular), scale: scale)
        let metrics = renderer.fontSet.metrics
        let width = Int((metrics.width * CGFloat(cols) * scale).rounded())
        let height = Int((metrics.height * CGFloat(rows) * scale).rounded())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalRenderer.pixelFormat,
                                                                  width: max(width, 1),
                                                                  height: max(height, 1),
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
        self.terminal = Terminal(cols: cols, rows: rows, scrollback: 100)
    }

    func render(_ overlay: FrameOverlay) {
        renderer.render(terminal: terminal, overlay: overlay, into: texture, scale: scale)
    }

    func readback() -> Framebuffer {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return Framebuffer(width: texture.width, height: texture.height, bytes: bytes)
    }
}

/// nil (with a message) when the machine has no Metal device.
func makeHarness() throws -> RenderHarness? {
    guard let harness = try RenderHarness() else {
        print("SheepVTRender: no Metal device on this machine — renderer tests skipped")
        return nil
    }
    return harness
}

/// A frame overlay with the cursor out of the way, so a test sees only text.
func plainOverlay() -> FrameOverlay {
    var o = FrameOverlay()
    o.cursorVisible = false
    o.focused = true
    return o
}

// MARK: - tests

@Suite struct RendererTests {
    @Test func rendererBuildsItsPipelinesAndAtlases() throws {
        guard let harness = try makeHarness() else { return }
        #expect(harness.renderer.device === harness.device)
        #expect(harness.renderer.fontSet.metrics.width > 0)
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == 0)
    }

    @Test func aClearFrameIsTheThemeBackground() throws {
        guard let harness = try makeHarness() else { return }
        harness.render(plainOverlay())
        let frame = harness.readback()
        // Nothing was printed: every pixel is the theme ground.
        #expect(frame.rgb(x: 0, y: 0) == 0x1E2128)
        #expect(frame.rgb(x: frame.width - 1, y: frame.height - 1) == 0x1E2128)
    }

    @Test func textPutsForegroundInkOnTheFirstRow() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("interface up")
        harness.render(plainOverlay())
        let frame = harness.readback()
        let cellHeight = Int(harness.renderer.fontSet.metrics.height * harness.scale)
        let firstRow = frame.histogram(rows: 0..<cellHeight)
        let lastRow = frame.histogram(rows: (frame.height - cellHeight)..<frame.height)
        // The text row carries many colours (antialiased ink), the empty one just the ground.
        #expect(firstRow.count > 4)
        #expect(lastRow.count == 1)
        #expect(lastRow[0x1E2128] != nil)
        // Some pixel is close to the theme foreground.
        let brightest = firstRow.keys.max { lum($0) < lum($1) } ?? 0
        #expect(lum(brightest) > 0x90)
    }

    @Test func aSecondIdenticalFrameComesEntirelyFromTheRowCache() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("interface up")
        harness.render(plainOverlay())
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == harness.rows)
        #expect(harness.renderer.lastFrameStats.rowsCached == 0)
        harness.render(plainOverlay())
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows)
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == 0)
        // The glyphs were rasterised once, not twice.
        #expect(harness.renderer.lastFrameStats.glyphsRasterised == 0)
    }

    @Test func newOutputRebuildsOnlyTheRowThatChanged() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("interface up\r\n")
        harness.render(plainOverlay())
        harness.render(plainOverlay())
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows)
        harness.terminal.feed("line protocol up")
        harness.render(plainOverlay())
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == 1)
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows - 1)
    }

    @Test func aHighlightOverrideChangesTheInksHue() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("interface up")
        harness.render(plainOverlay())
        let plain = harness.readback()

        var overlay = plainOverlay()
        let line = harness.terminal.buffer.lineNumber(ofScreenRow: 0)
        let red = FrameOverlay.highlightPresentBit | 0xFF0000
        overlay.highlightOverrides = { l in
            l == line ? [UInt32](repeating: red, count: harness.cols) : nil
        }
        harness.render(overlay)
        let tinted = harness.readback()

        let cellHeight = Int(harness.renderer.fontSet.metrics.height * harness.scale)
        #expect(harness.renderer.lastFrameStats.rowsRebuilt >= 1)   // the key moved
        let before = brightestPixel(plain, rows: 0..<cellHeight)
        let after = brightestPixel(tinted, rows: 0..<cellHeight)
        // Grey ink becomes red ink: red still dominant, blue gone.
        #expect((after >> 16) & 0xFF > (after & 0xFF) + 0x40)
        #expect(before & 0xFF > 0x40)
    }

    @Test func selectionPaintsATintOverTheGround() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("interface up")
        let line = harness.terminal.buffer.lineNumber(ofScreenRow: 0)
        let selection = Selection(terminal: harness.terminal)
        selection.begin(at: Position(line: line, col: 0))
        selection.extend(to: Position(line: line, col: 19))
        var overlay = plainOverlay()
        overlay.selection = selection
        harness.render(overlay)
        let frame = harness.readback()
        // The top-left pixel is no longer the plain ground: the selection tint
        // (0x5AA5D6 at 0.30) has lifted its blue.
        let pixel = frame.rgb(x: 1, y: 1)
        #expect(pixel != 0x1E2128)
        #expect(pixel & 0xFF > 0x1E2128 & 0xFF)
    }

    @Test func aBlockCursorDrawsAFilledCell() throws {
        guard let harness = try makeHarness() else { return }
        var overlay = plainOverlay()
        overlay.cursorVisible = true
        overlay.cursorBlinkOn = true
        harness.render(overlay)
        let frame = harness.readback()
        // The cursor sits at column 0 of row 0 on a fresh terminal.
        #expect(frame.rgb(x: 2, y: 2) == 0xEDEFF3)
        // …and nowhere else.
        #expect(frame.rgb(x: frame.width - 2, y: frame.height - 2) == 0x1E2128)
    }

    @Test func invalidateRowsForcesAFullRebuild() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("interface up")
        harness.render(plainOverlay())
        harness.render(plainOverlay())
        #expect(harness.renderer.lastFrameStats.rowsCached == harness.rows)
        harness.renderer.invalidateRows()
        harness.render(plainOverlay())
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == harness.rows)
    }

    @Test func aThemeChangeRepaintsEverything() throws {
        guard let harness = try makeHarness() else { return }
        harness.render(plainOverlay())
        harness.render(plainOverlay())
        var colors = TerminalColors.sheepTerm
        colors.background = 0x101010
        harness.renderer.palette = Palette(colors: colors)
        harness.render(plainOverlay())
        #expect(harness.renderer.lastFrameStats.rowsRebuilt == harness.rows)
        #expect(harness.readback().rgb(x: 0, y: 0) == 0x101010)
    }

    @Test func osc4RepaintsWithTheProgramsPalette() throws {
        guard let harness = try makeHarness() else { return }
        // Paint the whole first row with ANSI background 1, then move that
        // palette entry with OSC 4 and check the pixels follow.
        harness.terminal.feed("\u{1B}[41m    \u{1B}[0m")
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 2, y: 2) == 0xED7A7A)
        harness.terminal.feed("\u{1B}]4;1;rgb:00/ff/00\u{07}")
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 2, y: 2) == 0x00FF00)
    }

    // P2: `seenCoreDefaults` started nil, so the first frame only *recorded*
    // the core's defaults and never applied them — and afterwards there was no
    // delta left to notice. An OSC 11 that arrives before anything is drawn is
    // the normal case (a program sets its scheme in its first write).
    @Test func osc11BeforeTheFirstFrameReachesThePalette() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("\u{1B}]11;#00ff00\u{07}")
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 0, y: 0) == 0x00FF00)
        #expect(harness.renderer.palette.colors.background == 0x00FF00)
    }

    @Test func osc11AfterTheFirstFrameReachesThePalette() throws {
        guard let harness = try makeHarness() else { return }
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 0, y: 0) == 0x1E2128)
        harness.terminal.feed("\u{1B}]11;#00ff00\u{07}")
        harness.render(plainOverlay())
        #expect(harness.readback().rgb(x: 0, y: 0) == 0x00FF00)
        // OSC 10 moves the text colour on the same path. (The block cursor
        // draws in `colors.cursor`, which is OSC 12's business, so the palette
        // is what this asserts on.)
        harness.terminal.feed("\u{1B}]10;rgb:ff/00/00\u{07}")
        harness.render(plainOverlay())
        #expect(harness.renderer.palette.colors.foreground == 0xFF0000)
    }

    // MARK: - the presentation ring

    @Test func theSurfaceRingCyclesAndRebuildsOnlyOnSizeChange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let presenter = SurfacePresenter(device: device)
        #expect(presenter.nextTexture() == nil)          // nothing prepared yet

        presenter.prepare(pixelSize: CGSize(width: 64, height: 32))
        var seen: [ObjectIdentifier] = []
        for _ in 0..<3 { seen.append(ObjectIdentifier(try #require(presenter.nextTexture()))) }
        #expect(Set(seen).count == 3)                    // three distinct surfaces
        // ...and the ring comes back around instead of growing.
        #expect(ObjectIdentifier(try #require(presenter.nextTexture())) == seen[0])

        // Same size: the surfaces are kept (a resize step that changed nothing).
        presenter.prepare(pixelSize: CGSize(width: 64, height: 32))
        #expect(seen.contains(ObjectIdentifier(try #require(presenter.nextTexture()))))

        // A real size change rebuilds, and the textures follow the pixel size.
        presenter.prepare(pixelSize: CGSize(width: 80, height: 40))
        let resized = try #require(presenter.nextTexture())
        #expect(resized.width == 80 && resized.height == 40)
        #expect(presenter.pixelSize == CGSize(width: 80, height: 40))

        // A hidden view drops the ring entirely.
        presenter.release()
        #expect(presenter.nextTexture() == nil)
    }

    // P2: the fallback used to be `slots[next % count]` — a surface the window
    // server had just been found to be holding. `waitUntilCompleted` waits for
    // our GPU work, not for the compositor, so that frame could tear. No real
    // IOSurface can be forced in use from a test, hence the injected predicate.
    @Test func aBusyRingNeverHandsBackASurfaceTheCompositorHolds() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let presenter = SurfacePresenter(device: device)
        presenter.prepare(pixelSize: CGSize(width: 64, height: 32))

        // Strong references, not identifiers: a surface dropped from the ring
        // would otherwise be freed and the next allocation could land on the
        // same address. In the app the layer holds whatever it is showing.
        final class Busy {
            var held: [IOSurface] = []
            func contains(_ s: IOSurface) -> Bool { held.contains { $0 === s } }
        }
        let busy = Busy()
        presenter.isInUse = { busy.contains($0) }
        busy.held = presenter.ringSurfaces

        // The compositor never lets go: every frame must still land somewhere
        // it is not reading, and the ring must stay inside its budget.
        for _ in 0..<12 {
            let texture = try #require(presenter.nextTexture())
            let surface = try #require(presenter.surface(for: texture))
            #expect(!busy.contains(surface))
            #expect(texture.width == 64 && texture.height == 32)
            busy.held.append(surface)
        }
        #expect(presenter.slotCount > SurfacePresenter.baseSlots)     // it grew
        #expect(presenter.slotCount <= SurfacePresenter.maxSlots)     // within budget

        // A `prepare` at the same size keeps the grown ring rather than
        // rebuilding it back down to three every frame.
        let grown = presenter.slotCount
        presenter.prepare(pixelSize: CGSize(width: 64, height: 32))
        #expect(presenter.slotCount == grown)

        // Once the compositor lets go, the ring goes back to plain round-robin.
        busy.held.removeAll()
        var seen: Set<ObjectIdentifier> = []
        for _ in 0..<grown { seen.insert(ObjectIdentifier(try #require(presenter.nextTexture()))) }
        #expect(seen.count == grown)
    }
}

// MARK: - small helpers

func lum(_ rgb: UInt32) -> UInt32 {
    (((rgb >> 16) & 0xFF) + ((rgb >> 8) & 0xFF) + (rgb & 0xFF)) / 3
}

func brightestPixel(_ frame: Framebuffer, rows: Range<Int>) -> UInt32 {
    frame.histogram(rows: rows).keys.max { lum($0) < lum($1) } ?? 0
}
