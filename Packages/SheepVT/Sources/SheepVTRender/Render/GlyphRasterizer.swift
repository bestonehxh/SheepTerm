// SheepVT — CoreText glyph rasterisation into CPU bitmaps for the atlas.
//
// Ported from SwiftTerm `CoreTextGlyphRasterizer.swift` (MIT). The ink is always
// drawn **white**: colour is applied in the shader, never baked into the bitmap
// (the one exception is a colour glyph — an emoji — which carries its own).

import CoreGraphics
import CoreText
import Foundation

/// One rasterised glyph, ready for `GlyphAtlas.write`.
public nonisolated struct GlyphBitmap: Sendable {
    /// Size in device pixels.
    public var width: Int
    public var height: Int
    /// Bottom-left corner of the bitmap relative to the pen origin (the point on
    /// the baseline where the glyph starts), in device pixels, y up.
    public var bearing: CGPoint
    /// BGRA, premultiplied, row 0 = **top** (a CGBitmapContext's first scanline is the top of the image).
    public var pixels: [UInt8]
    /// True when any pixel has r != g != b: it belongs in the BGRA atlas.
    public var isColor: Bool

    public init(width: Int, height: Int, bearing: CGPoint, pixels: [UInt8], isColor: Bool) {
        self.width = width
        self.height = height
        self.bearing = bearing
        self.pixels = pixels
        self.isColor = isColor
    }
}

/// Draws glyphs and clusters into `GlyphBitmap`s.
///
/// The fonts handed in must already be at device-pixel size (`FontSet` scales
/// them); this type never applies `scale` itself.
public final class GlyphRasterizer {
    /// `CGContext.setShouldSmoothFonts` — the user's font-smoothing toggle.
    public var fontSmoothing: Bool = false

    public init() {}

    // MARK: - single glyph

    /// Rasterise one glyph. Returns nil when the glyph has no ink (a space, or a
    /// glyph whose bounding box is empty).
    public func rasterize(font: CTFont, glyph: CGGlyph) -> GlyphBitmap? {
        var glyphVar = glyph
        let rect = CTFontGetBoundingRectsForGlyphs(font, .default, &glyphVar, nil, 1)
        if !rect.width.isFinite || !rect.height.isFinite || rect.width <= 0 || rect.height <= 0 {
            return nil
        }

        let minX = floor(rect.origin.x)
        let minY = floor(rect.origin.y)
        let maxX = ceil(rect.origin.x + rect.size.width)
        let maxY = ceil(rect.origin.y + rect.size.height)
        let width = Int(maxX - minX)
        let height = Int(maxY - minY)
        if width <= 0 || height <= 0 {
            return nil
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = GlyphRasterizer.makeContext(base: raw.baseAddress,
                                                            width: width,
                                                            height: height,
                                                            smoothing: fontSmoothing) else {
                return false
            }
            var positions = [CGPoint(x: -minX, y: -minY)]
            CTFontDrawGlyphs(font, &glyphVar, &positions, 1, context)
            return true
        }
        if !drew {
            return nil
        }

        return GlyphBitmap(width: width,
                           height: height,
                           bearing: CGPoint(x: minX, y: minY),
                           pixels: pixels,
                           isColor: GlyphRasterizer.detectColor(pixels))
    }

    // MARK: - cluster

    /// Rasterise a `CTLine` (a multi-scalar grapheme, the rare path) into a
    /// bitmap the size of the cell(s) it occupies.
    ///
    /// `baselinePx` is the distance from the **top** of that box down to the
    /// baseline, matching `CellMetrics.baseline` scaled to device pixels.
    /// Returns nil when the line leaves no ink.
    public func rasterize(line: CTLine, cellWidthPx: Int, cellHeightPx: Int, baselinePx: CGFloat) -> GlyphBitmap? {
        guard cellWidthPx > 0, cellHeightPx > 0 else { return nil }
        let width = cellWidthPx
        let height = cellHeightPx
        // CoreGraphics is y-up: the baseline sits `height - baselinePx` above the
        // bottom of the box.
        let baselineFromBottom = CGFloat(height) - baselinePx

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = GlyphRasterizer.makeContext(base: raw.baseAddress,
                                                            width: width,
                                                            height: height,
                                                            smoothing: fontSmoothing) else {
                return false
            }
            context.textPosition = CGPoint(x: 0, y: baselineFromBottom)
            CTLineDraw(line, context)
            return true
        }
        if !drew {
            return nil
        }
        guard GlyphRasterizer.hasInk(pixels) else { return nil }

        return GlyphBitmap(width: width,
                           height: height,
                           bearing: CGPoint(x: 0, y: -baselineFromBottom),
                           pixels: pixels,
                           isColor: GlyphRasterizer.detectColor(pixels))
    }

    // MARK: - helpers

    private nonisolated static func makeContext(base: UnsafeMutableRawPointer?,
                                                width: Int,
                                                height: Int,
                                                smoothing: Bool) -> CGContext? {
        guard let base else { return nil }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: base,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            return nil
        }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.setAllowsFontSmoothing(smoothing)
        context.setShouldSmoothFonts(smoothing)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        return context
    }

    /// BGRA premultiplied: bytes are B, G, R, A.
    nonisolated static func detectColor(_ pixels: [UInt8]) -> Bool {
        var idx = 0
        while idx + 3 < pixels.count {
            let b = pixels[idx]
            let g = pixels[idx + 1]
            let r = pixels[idx + 2]
            if r != g || g != b {
                return true
            }
            idx += 4
        }
        return false
    }

    nonisolated static func hasInk(_ pixels: [UInt8]) -> Bool {
        var idx = 3
        while idx < pixels.count {
            if pixels[idx] != 0 { return true }
            idx += 4
        }
        return false
    }
}
