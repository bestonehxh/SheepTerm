// SheepVTRender — TerminalView.snapshotPNG: the presented IOSurface becomes a PNG
// with the same pixels; anything that is not a surface gives nil.

import AppKit
import IOSurface
import Testing

@testable import SheepVTRender

@Suite struct SnapshotTests {

    @Test func aPresentedSurfaceBecomesAPNGWithItsPixels() throws {
        let w = 8, h = 4
        let surface = try #require(IOSurface(properties: [
            .width: w, .height: h, .bytesPerElement: 4, .pixelFormat: UInt32(0x42475241),
        ]))
        surface.lock(options: [], seed: nil)
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let p = base + y * surface.bytesPerRow + x * 4
                p[0] = 0x30; p[1] = 0x20; p[2] = 0x10; p[3] = 0xFF   // BGRA → #102030
            }
        }
        surface.unlock(options: [], seed: nil)
        let png = try #require(TerminalView.pngData(fromLayerContents: surface))
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == w && rep.pixelsHigh == h)
        // Raw bytes, no colour conversion: the PNG must carry the surface's values.
        let data = try #require(rep.bitmapData)
        let p = data + 2 * rep.bytesPerRow + 3 * (rep.bitsPerPixel / 8)
        #expect([p[0], p[1], p[2]] == [0x10, 0x20, 0x30])
        #expect(rep.colorSpace.colorSpaceModel == .rgb && rep.colorSpace.localizedName?.contains("sRGB") == true)
    }

    @Test func nothingPresentedGivesNil() {
        #expect(TerminalView.pngData(fromLayerContents: nil) == nil)
        #expect(TerminalView.pngData(fromLayerContents: NSImage()) == nil)
        #expect(TerminalView.pngData(fromLayerContents: "x") == nil)
    }
}
