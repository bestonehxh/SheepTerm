// SheepVT — glyph layer tests (agent A's contract: FontSet, GlyphRasterizer,
// GlyphAtlas).
//
// The atlas tests need a Metal device; they are skipped with a message when
// `MTLCreateSystemDefaultDevice()` returns nil (a headless CI box).

import AppKit
import CoreGraphics
import CoreText
import Metal
import Testing
@testable import SheepVTRender

// MARK: - helpers

@MainActor private func monoFont(_ size: CGFloat = 13) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

@MainActor private func menlo(_ size: CGFloat = 13) -> NSFont {
    NSFont(name: "Menlo", size: size) ?? monoFont(size)
}

private func metalDevice() -> MTLDevice? { MTLCreateSystemDefaultDevice() }

/// Highest alpha byte in a BGRA bitmap.
private func maxAlpha(_ bitmap: GlyphBitmap) -> UInt8 {
    var best: UInt8 = 0
    var i = 3
    while i < bitmap.pixels.count {
        best = max(best, bitmap.pixels[i])
        i += 4
    }
    return best
}

/// A solid `w × h` bitmap whose alpha ramps with the pixel index, so a
/// round-trip through the atlas can be checked byte for byte.
private func rampBitmap(width: Int, height: Int, colored: Bool = false) -> GlyphBitmap {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<(width * height) {
        let a = UInt8((i * 7 + 3) % 256)
        pixels[i * 4 + 0] = colored ? UInt8((i * 3) % 256) : a  // B
        pixels[i * 4 + 1] = colored ? UInt8((i * 5) % 256) : a  // G
        pixels[i * 4 + 2] = a                                    // R
        pixels[i * 4 + 3] = a                                    // A
    }
    return GlyphBitmap(width: width,
                       height: height,
                       bearing: .zero,
                       pixels: pixels,
                       isColor: colored)
}

private func readBack(_ atlas: GlyphAtlas) -> [UInt8] {
    let bpp = atlas.format.bytesPerPixel
    var out = [UInt8](repeating: 0, count: atlas.size * atlas.size * bpp)
    out.withUnsafeMutableBytes { raw in
        atlas.texture.getBytes(raw.baseAddress!,
                               bytesPerRow: atlas.size * bpp,
                               from: MTLRegionMake2D(0, 0, atlas.size, atlas.size),
                               mipmapLevel: 0)
    }
    return out
}

// MARK: - metrics

@Suite @MainActor struct FontSetMetricsTests {
    @Test func widthIsTheSnappedAdvanceOfW() {
        let font = monoFont(13)
        let set = FontSet(font: font, scale: 2)
        let raw = FontSet.advanceOfW(in: font as CTFont)
        #expect(raw > 0)
        #expect(set.metrics.width == (raw * 2).rounded() / 2)
        // Snapped: a whole number of device pixels.
        let px = set.metrics.width * 2
        #expect(abs(px - px.rounded()) < 1e-9)
    }

    @Test func heightIsCeilOfAscentDescentLeading() {
        let font = monoFont(13)
        let ct = font as CTFont
        let expected = ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct))
        let set = FontSet(font: font, scale: 2)
        #expect(set.metrics.height == expected)
        let px = set.metrics.height * 2
        #expect(abs(px - px.rounded()) < 1e-9)
    }

    @Test func baselineIsAscentPlusHalfTheLeading() {
        let font = monoFont(13)
        let ct = font as CTFont
        let expected = CTFontGetAscent(ct) + CTFontGetLeading(ct) / 2
        let set = FontSet(font: font, scale: 2)
        // Snapped to the pixel grid, so within half a device pixel.
        #expect(abs(set.metrics.baseline - expected) <= 0.25)
        #expect(set.metrics.baseline > 0)
        #expect(set.metrics.baseline < set.metrics.height)
    }

    @Test func underlineSitsBelowTheBaselineAndIsAtLeastOnePixel() {
        let set = FontSet(font: monoFont(13), scale: 2)
        #expect(set.metrics.underlinePosition > set.metrics.baseline)
        #expect(set.metrics.underlineThickness >= 0.5)
    }

    @Test func strikethroughSitsAboveTheBaselineNearHalfXHeight() {
        let font = monoFont(13)
        let ct = font as CTFont
        let set = FontSet(font: font, scale: 2)
        let expected = set.metrics.baseline - CTFontGetXHeight(ct) / 2
        #expect(abs(set.metrics.strikethroughPosition - expected) <= 0.25)
        #expect(set.metrics.strikethroughPosition < set.metrics.baseline)
    }

    @Test func scaleIsRecordedAndFacesAreInDevicePixels() {
        let set1 = FontSet(font: monoFont(13), scale: 1)
        let set2 = FontSet(font: monoFont(13), scale: 2)
        #expect(set1.metrics.scale == 1)
        #expect(set2.metrics.scale == 2)
        #expect(set1.pointSize == 13)
        #expect(set2.pointSize == 13)
        // The rasteriser gets device-pixel fonts; metrics stay in points.
        #expect(CTFontGetSize(set1.normal) == 13)
        #expect(CTFontGetSize(set2.normal) == 26)
        #expect(CTFontGetSize(set2.boldItalic) == 26)
        // Metrics are in points either way, so they barely move with scale.
        #expect(abs(set1.metrics.width - set2.metrics.width) < 1)
    }

    @Test func metricsAreEquatable() {
        let a = FontSet(font: monoFont(13), scale: 2).metrics
        let b = FontSet(font: monoFont(13), scale: 2).metrics
        let c = FontSet(font: monoFont(14), scale: 2).metrics
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - faces and fallback

@Suite @MainActor struct FontSetFaceTests {
    @Test func boldAndItalicDifferFromNormal() {
        let set = FontSet(font: menlo(13), scale: 2)
        let normalName = CTFontCopyPostScriptName(set.normal) as String
        #expect(CTFontCopyPostScriptName(set.bold) as String != normalName)
        #expect(CTFontCopyPostScriptName(set.italic) as String != normalName)
        #expect(CTFontCopyPostScriptName(set.boldItalic) as String != normalName)
        let boldTraits = CTFontGetSymbolicTraits(set.bold)
        #expect(boldTraits.contains(.traitBold))
        #expect(CTFontGetSymbolicTraits(set.italic).contains(.traitItalic))
    }

    @Test func faceLookupReturnsTheRequestedStyle() {
        let set = FontSet(font: menlo(13), scale: 2)
        #expect(CTFontCopyPostScriptName(set.face(bold: false, italic: false)) as String
                == CTFontCopyPostScriptName(set.normal) as String)
        #expect(CTFontCopyPostScriptName(set.face(bold: true, italic: false)) as String
                == CTFontCopyPostScriptName(set.bold) as String)
        #expect(CTFontCopyPostScriptName(set.face(bold: true, italic: true)) as String
                == CTFontCopyPostScriptName(set.boldItalic) as String)
    }

    @Test func asciiStaysOnTheRequestedFace() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let f = set.font(for: "A", bold: true, italic: false)
        #expect(CTFontCopyPostScriptName(f) as String == CTFontCopyPostScriptName(set.bold) as String)
        #expect(FontSet.glyph("A", in: f) != 0)
    }

    @Test func fallbackFindsAFontForThai() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let scalar: Unicode.Scalar = "\u{0E01}"     // ก
        let f = set.font(for: scalar, bold: false, italic: false)
        #expect(FontSet.glyph(scalar, in: f) != 0)
        // Same size as the face it was derived from: still device pixels.
        #expect(CTFontGetSize(f) == 26)
    }

    @Test func fallbackFindsAFontForCJK() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let scalar: Unicode.Scalar = "\u{4E2D}"     // 中
        let f = set.font(for: scalar, bold: false, italic: false)
        #expect(FontSet.glyph(scalar, in: f) != 0)
    }

    @Test func fallbackFindsAFontForEmoji() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let scalar: Unicode.Scalar = "\u{1F600}"    // 😀
        let f = set.font(for: scalar, bold: false, italic: false)
        #expect(FontSet.glyph(scalar, in: f) != 0)
    }

    @Test func fallbackIsCachedAndStable() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let scalar: Unicode.Scalar = "\u{0E01}"
        let a = set.font(for: scalar, bold: false, italic: false)
        let b = set.font(for: scalar, bold: false, italic: false)
        #expect(CTFontCopyPostScriptName(a) as String == CTFontCopyPostScriptName(b) as String)
        // The cache is keyed on the style too.
        let boldFace = set.font(for: scalar, bold: true, italic: false)
        #expect(FontSet.glyph(scalar, in: boldFace) != 0)
    }

    @Test func fallbackNeverReturnsAFontThatStillLacksTheGlyph() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let baseName = CTFontCopyPostScriptName(set.normal) as String
        // Thai, CJK, emoji, box drawing, and two code points nothing is likely
        // to cover (unassigned plane 15 / plane 16).
        for value: UInt32 in [0x0E01, 0x4E2D, 0x1F600, 0x2500, 0xF_FF80, 0x10_FFFD] {
            let scalar = Unicode.Scalar(value)!
            let f = set.font(for: scalar, bold: false, italic: false)
            // Never nil, never unscaled.
            #expect(CTFontGetSize(f) == 26)
            let hasGlyph = FontSet.glyph(scalar, in: f) != 0
            let isBase = (CTFontCopyPostScriptName(f) as String) == baseName
            // Either the fallback really has the glyph, or we fell back to the
            // requested face: a substitute that still lacks it is rejected.
            #expect(hasGlyph || isBase)
        }
    }

    @Test func glyphIdIsNonZeroForW() {
        let set = FontSet(font: monoFont(13), scale: 2)
        #expect(FontSet.glyph("W", in: set.normal) != 0)
        #expect(FontSet.glyph("W", in: set.bold) != 0)
    }

    @Test func lineForClusterHasRuns() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let line = set.line(for: "e\u{0301}", bold: false, italic: false)   // é, decomposed
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        #expect(!runs.isEmpty)
        #expect(CTLineGetGlyphCount(line) >= 1)
    }
}

// MARK: - rasterizer

@Suite @MainActor struct GlyphRasterizerTests {
    @Test func rasterizeWProducesFullyCoveredInk() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let r = GlyphRasterizer()
        let glyph = FontSet.glyph("W", in: set.normal)
        let bitmap = try! #require(r.rasterize(font: set.normal, glyph: glyph))
        #expect(bitmap.width > 0 && bitmap.height > 0)
        #expect(bitmap.pixels.count == bitmap.width * bitmap.height * 4)
        #expect(maxAlpha(bitmap) == 255)
        #expect(bitmap.isColor == false)
    }

    @Test func rasterizeSpaceHasNoInk() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let r = GlyphRasterizer()
        let glyph = FontSet.glyph(" ", in: set.normal)
        #expect(r.rasterize(font: set.normal, glyph: glyph) == nil)
    }

    @Test func rasterizeEmojiIsColor() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let r = GlyphRasterizer()
        let scalar: Unicode.Scalar = "\u{1F600}"
        let font = set.font(for: scalar, bold: false, italic: false)
        let bitmap = try! #require(r.rasterize(font: font, glyph: FontSet.glyph(scalar, in: font)))
        #expect(bitmap.isColor)
        #expect(maxAlpha(bitmap) > 0)
    }

    @Test func biggerScaleGivesABiggerBitmap() {
        let r = GlyphRasterizer()
        let small = FontSet(font: monoFont(13), scale: 1)
        let big = FontSet(font: monoFont(13), scale: 3)
        let a = try! #require(r.rasterize(font: small.normal, glyph: FontSet.glyph("W", in: small.normal)))
        let b = try! #require(r.rasterize(font: big.normal, glyph: FontSet.glyph("W", in: big.normal)))
        #expect(b.width > a.width)
        #expect(b.height > a.height)
    }

    @Test func fontSmoothingTogglesWithoutChangingGeometry() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let glyph = FontSet.glyph("W", in: set.normal)
        let off = GlyphRasterizer()
        off.fontSmoothing = false
        let on = GlyphRasterizer()
        on.fontSmoothing = true
        let a = try! #require(off.rasterize(font: set.normal, glyph: glyph))
        let b = try! #require(on.rasterize(font: set.normal, glyph: glyph))
        #expect(a.width == b.width && a.height == b.height)
    }

    @Test func rasterizeLineFillsTheCellBox() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let r = GlyphRasterizer()
        let line = set.line(for: "e\u{0301}", bold: false, italic: false)
        let w = Int((set.metrics.width * 2).rounded())
        let h = Int((set.metrics.height * 2).rounded())
        let baselinePx = set.metrics.baseline * 2
        let bitmap = try! #require(r.rasterize(line: line, cellWidthPx: w, cellHeightPx: h, baselinePx: baselinePx))
        #expect(bitmap.width == w)
        #expect(bitmap.height == h)
        #expect(bitmap.pixels.count == w * h * 4)
        #expect(maxAlpha(bitmap) > 0)
        #expect(bitmap.bearing.x == 0)
        #expect(bitmap.bearing.y == -(CGFloat(h) - baselinePx))
    }

    @Test func rasterizeLineOfSpacesIsNil() {
        let set = FontSet(font: monoFont(13), scale: 2)
        let r = GlyphRasterizer()
        let line = set.line(for: "  ", bold: false, italic: false)
        let w = Int((set.metrics.width * 2).rounded())
        let h = Int((set.metrics.height * 2).rounded())
        #expect(r.rasterize(line: line, cellWidthPx: w, cellHeightPx: h, baselinePx: set.metrics.baseline * 2) == nil)
        // Degenerate boxes are rejected too.
        #expect(r.rasterize(line: line, cellWidthPx: 0, cellHeightPx: h, baselinePx: 0) == nil)
    }
}

// MARK: - atlas

@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil,
                "skipped: no Metal device (MTLCreateSystemDefaultDevice() == nil)"))
@MainActor struct GlyphAtlasTests {
    @Test func packsManyRegionsWithoutOverlap() throws {
        let device = try #require(metalDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 1024, maxSize: 8192, format: .grayscale))
        var regions: [AtlasRegion] = []
        for _ in 0..<500 {
            let r = try #require(atlas.ensureRegion(width: 12, height: 26))
            regions.append(r)
        }
        #expect(regions.count == 500)
        // 1-px padding on every side, and inside the texture.
        for r in regions {
            #expect(r.width == 12 && r.height == 26)
            #expect(r.x >= GlyphAtlas.padding && r.y >= GlyphAtlas.padding)
            #expect(r.x + r.width + GlyphAtlas.padding <= atlas.size)
            #expect(r.y + r.height + GlyphAtlas.padding <= atlas.size)
        }
        // No two content rectangles intersect.
        for i in 0..<regions.count {
            for j in (i + 1)..<min(regions.count, i + 40) {
                let a = regions[i], b = regions[j]
                let overlap = a.x < b.x + b.width && b.x < a.x + a.width
                    && a.y < b.y + b.height && b.y < a.y + a.height
                #expect(!overlap)
            }
        }
    }

    @Test func growsWhenFullAndBumpsGeneration() throws {
        let device = try #require(metalDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 128, maxSize: 1024, format: .grayscale))
        #expect(atlas.size == 128)
        #expect(atlas.generation == 0)
        var packed = 0
        while atlas.size == 128, packed < 1000 {
            _ = atlas.ensureRegion(width: 20, height: 30)
            packed += 1
        }
        #expect(atlas.size > 128)
        #expect(atlas.generation >= 1)
        #expect(atlas.texture.width == atlas.size)
    }

    @Test func resetsWhenItCannotGrowAnyFurther() throws {
        let device = try #require(metalDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 128, maxSize: 128, format: .grayscale))
        var sawReset = false
        for _ in 0..<200 {
            let before = atlas.generation
            _ = atlas.ensureRegion(width: 20, height: 30)
            if atlas.generation > before {
                sawReset = true
                break
            }
        }
        #expect(sawReset)
        #expect(atlas.size == 128)                  // could not grow: it reset
        // Packing starts from the origin again.
        let r = try #require(atlas.ensureRegion(width: 20, height: 30))
        #expect(r.y < 64)
    }

    // P3: the reset used to zero the shadow copy one byte at a time (64 MB for
    // an 8192² grey atlas). It is a memset now — this pins the behaviour the
    // bulk form has to keep: every pixel of the old contents really is gone,
    // uploaded, and the packer starts over.
    @Test func resetClearsEveryPixelOfTheAtlas() throws {
        let device = try #require(metalDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 128, maxSize: 128, format: .grayscale))
        // One glyph, uploaded: the texture really has ink in it, so "all zero"
        // below means the reset cleared it and not that nothing was ever there.
        let first = try #require(atlas.ensureRegion(width: 20, height: 30))
        atlas.write(region: first, bitmap: rampBitmap(width: 20, height: 30))
        atlas.flush()
        #expect(readBack(atlas).contains { $0 != 0 })

        // Keep packing until the atlas is full and has to start over.
        var wrote = 1
        while atlas.generation == 0 {
            let before = atlas.generation
            guard let region = atlas.ensureRegion(width: 20, height: 30) else { break }
            guard atlas.generation == before else { break }   // that call reset it
            atlas.write(region: region, bitmap: rampBitmap(width: 20, height: 30))
            wrote += 1
        }
        #expect(wrote > 0)
        #expect(atlas.generation >= 1)              // full and unable to grow: it reset
        atlas.flush()

        // Every byte the old glyphs occupied is back to zero — the region the
        // resetting call handed out was never written to.
        let bytes = readBack(atlas)
        #expect(bytes.count == 128 * 128)
        #expect(bytes.allSatisfy { $0 == 0 })
        // Packing restarted from the top of the atlas.
        let r = try #require(atlas.ensureRegion(width: 20, height: 30))
        #expect(r.y < 64)
    }

    @Test func frozenAtlasRefusesGrowthAndReset() throws {
        let device = try #require(metalDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 128, maxSize: 1024, format: .grayscale))
        atlas.frozen = true
        var misses = 0
        for _ in 0..<200 where atlas.ensureRegion(width: 20, height: 30) == nil {
            misses += 1
        }
        #expect(misses > 0)
        #expect(atlas.size == 128)                  // never grew
        #expect(atlas.generation == 0)              // never reset
    }

    @Test func rejectsGlyphsBiggerThanTheAtlasWillEverBe() throws {
        let device = try #require(metalDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 128, maxSize: 256, format: .grayscale))
        #expect(atlas.ensureRegion(width: 400, height: 10) == nil)
        #expect(atlas.ensureRegion(width: 0, height: 10) == nil)
        #expect(atlas.ensureRegion(width: 10, height: -1) == nil)
    }

    @Test func writeAndFlushRoundTripGrayscalePixels() throws {
        let device = try #require(metalDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 128, maxSize: 256, format: .grayscale))
        let w = 9, h = 7
        let region = try #require(atlas.ensureRegion(width: w, height: h))
        let bitmap = rampBitmap(width: w, height: h)
        atlas.write(region: region, bitmap: bitmap)
        atlas.flush()

        let bytes = readBack(atlas)
        for row in 0..<h {
            for col in 0..<w {
                // Bitmap and atlas are both top-down: rows copy straight across.
                let srcIndex = (row * w + col) * 4 + 3
                let dst = (region.y + row) * atlas.size + (region.x + col)
                #expect(bytes[dst] == bitmap.pixels[srcIndex])
            }
        }
    }

    @Test func writeAndFlushRoundTripColorPixels() throws {
        let device = try #require(metalDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 128, maxSize: 256, format: .bgra))
        let w = 6, h = 5
        let region = try #require(atlas.ensureRegion(width: w, height: h))
        let bitmap = rampBitmap(width: w, height: h, colored: true)
        atlas.write(region: region, bitmap: bitmap)
        atlas.flush()

        let bytes = readBack(atlas)
        for row in 0..<h {
            for col in 0..<w {
                let src = (row * w + col) * 4
                let dst = ((region.y + row) * atlas.size + (region.x + col)) * 4
                for b in 0..<4 {
                    #expect(bytes[dst + b] == bitmap.pixels[src + b])
                }
            }
        }
    }

    @Test func writeReplicatesEdgePixelsIntoThePadding() throws {
        let device = try #require(metalDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 128, maxSize: 256, format: .grayscale))
        let w = 5, h = 4
        let region = try #require(atlas.ensureRegion(width: w, height: h))
        atlas.write(region: region, bitmap: rampBitmap(width: w, height: h))
        atlas.flush()

        let bytes = readBack(atlas)
        func at(_ x: Int, _ y: Int) -> UInt8 { bytes[y * atlas.size + x] }
        // Left/right padding columns copy the edge column of the same row.
        for row in 0..<h {
            let y = region.y + row
            #expect(at(region.x - 1, y) == at(region.x, y))
            #expect(at(region.x + w, y) == at(region.x + w - 1, y))
        }
        // Top/bottom padding rows copy the edge row.
        for col in 0..<w {
            let x = region.x + col
            #expect(at(x, region.y - 1) == at(x, region.y))
            #expect(at(x, region.y + h) == at(x, region.y + h - 1))
        }
    }

    @Test func writeRejectsMismatchedBitmaps() throws {
        let device = try #require(metalDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 64, maxSize: 64, format: .grayscale))
        let region = try #require(atlas.ensureRegion(width: 4, height: 4))
        // Wrong size: ignored, nothing uploaded, no crash.
        atlas.write(region: region, bitmap: rampBitmap(width: 5, height: 4))
        atlas.flush()
        let bytes = readBack(atlas)
        #expect(bytes.allSatisfy { $0 == 0 })
        // Out-of-bounds region: also ignored.
        atlas.write(region: AtlasRegion(x: 60, y: 60, width: 8, height: 8),
                    bitmap: rampBitmap(width: 8, height: 8))
        atlas.flush()
        #expect(readBack(atlas).allSatisfy { $0 == 0 })
    }

    @Test func flushIsIdempotentAndCheapWhenClean() throws {
        let device = try #require(metalDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 64, maxSize: 64, format: .grayscale))
        let region = try #require(atlas.ensureRegion(width: 4, height: 4))
        atlas.write(region: region, bitmap: rampBitmap(width: 4, height: 4))
        atlas.flush()
        let first = readBack(atlas)
        atlas.flush()                                // nothing dirty: no-op
        atlas.flush()
        #expect(readBack(atlas) == first)
    }

    @Test func realGlyphGoesThroughRasterizerIntoTheAtlas() throws {
        let device = try #require(metalDevice())
        let set = FontSet(font: monoFont(13), scale: 2)
        let r = GlyphRasterizer()
        let bitmap = try #require(r.rasterize(font: set.normal, glyph: FontSet.glyph("W", in: set.normal)))
        let atlas = try #require(GlyphAtlas(device: device,
                                            size: 256,
                                            maxSize: GlyphAtlas.recommendedMaxSize(device: device, format: .grayscale),
                                            format: .grayscale))
        let region = try #require(atlas.ensureRegion(width: bitmap.width, height: bitmap.height))
        atlas.write(region: region, bitmap: bitmap)
        atlas.flush()
        let bytes = readBack(atlas)
        var best: UInt8 = 0
        for row in 0..<bitmap.height {
            for col in 0..<bitmap.width {
                best = max(best, bytes[(region.y + row) * atlas.size + region.x + col])
            }
        }
        #expect(best == 255)
    }

    @Test func recommendedMaxSizeIsSaneForBothFormats() throws {
        let device = try #require(metalDevice())
        let gray = GlyphAtlas.recommendedMaxSize(device: device, format: .grayscale)
        let color = GlyphAtlas.recommendedMaxSize(device: device, format: .bgra)
        #expect(gray >= color)
        #expect(gray <= GlyphAtlas.maxTextureDimension(of: device))
        #expect(color <= GlyphAtlas.maxTextureDimension(of: device))
        #expect(gray == 8192 || gray == GlyphAtlas.maxTextureDimension(of: device))
        #expect(GlyphAtlasFormat.grayscale.bytesPerPixel == 1)
        #expect(GlyphAtlasFormat.bgra.bytesPerPixel == 4)
        #expect(GlyphAtlasFormat.grayscale.pixelFormat == .r8Unorm)
        #expect(GlyphAtlasFormat.bgra.pixelFormat == .bgra8Unorm)
    }

    @Test func startingSizeIsClampedToMaxSize() throws {
        let device = try #require(metalDevice())
        let atlas = try #require(GlyphAtlas(device: device, size: 1024, maxSize: 128, format: .bgra))
        #expect(atlas.size == 128)
        #expect(atlas.maxSize == 128)
        #expect(atlas.texture.width == 128)
        #expect(atlas.texture.pixelFormat == .bgra8Unorm)
    }
}
