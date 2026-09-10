// SheepVT — the font set: the four faces, the cell metrics, and glyph fallback.
//
// Ported from SwiftTerm (MIT): `FontSet` in `MacTerminalView.swift` and
// `computeFontDimensions` in `AppleTerminalView.swift`.
//
// ## Conventions (agent B codes against these — they do not change)
//
// * `normal`/`bold`/`italic`/`boldItalic` are **device-pixel** CTFonts: the base
//   NSFont copied at `pointSize * scale`. That is what `GlyphRasterizer` wants,
//   so the caller never scales again.
// * `metrics` is in **points** (the view's coordinate space), snapped to the
//   backing pixel grid for `scale`.
// * Every vertical field in `CellMetrics` is measured **downward from the top of
//   the cell** — `baseline`, `underlinePosition`, `strikethroughPosition`. That
//   matches `GlyphPlacement.offset` ("relative to the cell's top-left"), so the
//   row builder never has to flip a sign. CoreText's own underline position is
//   negative-below-baseline; it is converted here.

import AppKit
import CoreGraphics
import CoreText

/// Everything the renderer needs to lay a monospace grid out, in points.
///
/// Vertical positions are distances **from the top of the cell**, growing
/// downward.
public nonisolated struct CellMetrics: Equatable, Sendable {
    /// Cell size in points, snapped so that `width * scale` and `height * scale`
    /// are whole device pixels.
    public var width: CGFloat
    public var height: CGFloat
    /// Distance from the top of the cell to the text baseline (points).
    public var baseline: CGFloat
    /// Distance from the top of the cell to the centre of the underline (points).
    public var underlinePosition: CGFloat
    /// Underline stroke thickness (points), at least one device pixel.
    public var underlineThickness: CGFloat
    /// Distance from the top of the cell to the centre of the strikethrough.
    public var strikethroughPosition: CGFloat
    /// The backing scale these metrics were snapped for.
    public var scale: CGFloat

    public init(width: CGFloat,
                height: CGFloat,
                baseline: CGFloat,
                underlinePosition: CGFloat,
                underlineThickness: CGFloat,
                strikethroughPosition: CGFloat,
                scale: CGFloat) {
        self.width = width
        self.height = height
        self.baseline = baseline
        self.underlinePosition = underlinePosition
        self.underlineThickness = underlineThickness
        self.strikethroughPosition = strikethroughPosition
        self.scale = scale
    }
}

/// The four faces of one terminal font plus the fallback lookup.
///
/// Immutable: a font or scale change makes a new `FontSet` (and drops every
/// cache keyed on it).
public final class FontSet {
    /// The base font as handed in, at its natural point size.
    public let baseFont: NSFont
    /// Point size of `baseFont` — the *unscaled* size. `CTFontGetSize(normal)`
    /// is `pointSize * metrics.scale`.
    public let pointSize: CGFloat

    // The four device-pixel faces (see the file comment).
    public let normal: CTFont
    public let bold: CTFont
    public let italic: CTFont
    public let boldItalic: CTFont

    public let metrics: CellMetrics

    /// Cache for `font(for:bold:italic:)`.
    private struct FallbackKey: Hashable {
        var scalar: UInt32
        var bold: Bool
        var italic: Bool
    }
    private var fallbackCache: [FallbackKey: CTFont] = [:]

    public init(font: NSFont, scale: CGFloat) {
        let scale = scale > 0 ? scale : 1
        self.baseFont = font
        self.pointSize = font.pointSize

        // 1. Derive the faces at point size, so metrics come from an unscaled font.
        let pointNormal = font as CTFont
        let pointBold = FontSet.derive(pointNormal, traits: .traitBold)
        let pointItalic = FontSet.derive(pointNormal, traits: .traitItalic)
        let pointBoldItalic = FontSet.derive(pointNormal, traits: [.traitBold, .traitItalic])

        // 2. Metrics, following SwiftTerm's `computeFontDimensions`.
        self.metrics = FontSet.metrics(of: pointNormal, scale: scale)

        // 3. The faces the rasteriser sees are copies at device-pixel size.
        let px = self.pointSize * scale
        self.normal = CTFontCreateCopyWithAttributes(pointNormal, px, nil, nil)
        self.bold = CTFontCreateCopyWithAttributes(pointBold, px, nil, nil)
        self.italic = CTFontCreateCopyWithAttributes(pointItalic, px, nil, nil)
        self.boldItalic = CTFontCreateCopyWithAttributes(pointBoldItalic, px, nil, nil)
    }

    // MARK: - faces

    /// The device-pixel face for a style.
    public func face(bold: Bool, italic: Bool) -> CTFont {
        switch (bold, italic) {
        case (false, false): return normal
        case (true, false): return self.bold
        case (false, true): return self.italic
        case (true, true): return boldItalic
        }
    }

    /// A font that has a glyph for `scalar` — `normal`/`bold`/… when they do,
    /// else a cached `CTFontCreateForString` fallback. Never nil: a fallback that
    /// still lacks the glyph is rejected and the requested face is returned.
    public func font(for scalar: Unicode.Scalar, bold: Bool, italic: Bool) -> CTFont {
        let base = face(bold: bold, italic: italic)
        // Printable ASCII is covered by any terminal font; skip the lookup.
        if scalar.value >= 0x20 && scalar.value < 0x7F {
            return base
        }
        let key = FallbackKey(scalar: scalar.value, bold: bold, italic: italic)
        if let cached = fallbackCache[key] {
            return cached
        }
        var result = base
        if FontSet.glyph(scalar, in: base) == 0 {
            let text = String(scalar) as CFString
            let length = CFStringGetLength(text)
            let candidate = CTFontCreateForString(base, text, CFRange(location: 0, length: length))
            if FontSet.glyph(scalar, in: candidate) != 0 {
                result = candidate
            }
        }
        fallbackCache[key] = result
        return result
    }

    /// Glyph id in `font` for `scalar` (0 = notdef / unmapped).
    ///
    /// Handles non-BMP scalars: `CTFontGetGlyphsForCharacters` maps a surrogate
    /// pair to a single glyph in slot 0 and *returns false*, so the return value
    /// is deliberately ignored and slot 0 is what counts.
    public nonisolated static func glyph(_ scalar: Unicode.Scalar, in font: CTFont) -> CGGlyph {
        var chars = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        return glyphs[0]
    }

    /// For a multi-scalar grapheme: a `CTLine` for the cluster, built on the
    /// requested face (CoreText cascades to fallbacks inside the line itself).
    /// The caller rasterises it with `GlyphRasterizer.rasterize(line:…)`.
    public func line(for cluster: String, bold: Bool, italic: Bool) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: face(bold: bold, italic: italic),
            .foregroundColor: NSColor.white.cgColor,
        ]
        let string = NSAttributedString(string: cluster, attributes: attributes)
        return CTLineCreateWithAttributedString(string)
    }

    // MARK: - construction helpers

    private nonisolated static func derive(_ font: CTFont, traits: CTFontSymbolicTraits) -> CTFont {
        let size = CTFontGetSize(font)
        if let derived = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) {
            return derived
        }
        return font
    }

    /// SwiftTerm's `computeFontDimensions`, plus the vertical positions.
    ///
    /// `font` must be at *point* size.
    nonisolated static func metrics(of font: CTFont, scale: CGFloat) -> CellMetrics {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)

        let rawWidth = advanceOfW(in: font)
        let rawHeight = ceil(ascent + descent + leading)

        // Snap to the backing pixel grid: no sub-pixel seams between cells.
        let width = max(1, (rawWidth * scale).rounded() / scale)
        let height = max(1, min(ceil(rawHeight * scale) / scale, 8192))

        // Leading is split above and below the text; the baseline sits below the
        // top half of it.
        let baseline = snap(leading / 2 + ascent, scale: scale)

        // CoreText's underline position is measured up from the baseline and is
        // normally negative. Convert to "down from the top of the cell".
        let ctUnderline = CTFontGetUnderlinePosition(font)
        let underlinePosition = snap(baseline - ctUnderline, scale: scale)
        let underlineThickness = max(1 / scale, snap(CTFontGetUnderlineThickness(font), scale: scale))

        let xHeight = CTFontGetXHeight(font)
        let strikethroughPosition = snap(baseline - xHeight / 2, scale: scale)

        return CellMetrics(width: width,
                           height: height,
                           baseline: baseline,
                           underlinePosition: underlinePosition,
                           underlineThickness: underlineThickness,
                           strikethroughPosition: strikethroughPosition,
                           scale: scale)
    }

    /// Advance of the glyph for "W", in the font's own units (points here).
    nonisolated static func advanceOfW(in font: CTFont) -> CGFloat {
        var glyph = CTFontGetGlyphWithName(font, "W" as CFString)
        if glyph == 0 {
            glyph = FontSet.glyph(Unicode.Scalar(UInt8(ascii: "W")), in: font)
        }
        guard glyph != 0 else { return CTFontGetSize(font) / 2 }
        var advance = CGSize.zero
        var g = glyph
        CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &advance, 1)
        return advance.width
    }

    private nonisolated static func snap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }
}
