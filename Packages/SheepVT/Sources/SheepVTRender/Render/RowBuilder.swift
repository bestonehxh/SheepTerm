// SheepVTRender — one row of the grid → GPU instances.
//
// This is the only place that knows what a frame looks like, and it knows
// nothing about Metal: give it a `Row`, the overlays and a glyph source and it
// hands back four flat arrays the renderer concatenates and uploads. That makes
// every drawing rule (wide chars, combining marks, inverse, dim, underline
// styles, selection, search tints, the highlight overlay, the cursor) testable
// without a GPU — `RowBuilderTests` drives it through a fake glyph source.
//
// Coordinate space: **points, origin at the top-left of the viewport**, y down.
// `screenRow` 0 is the top visible row. `Shaders.swift` flips Y into clip space.

import CoreGraphics
import SheepVT

// MARK: - GPU instance layouts

/// A flat coloured quad: cell backgrounds, selection and search tints, the
/// cursor, and every decoration (underline, strikethrough, overline). 32 bytes,
/// matching `BackgroundInstance` in `Shaders.source`.
nonisolated public struct BackgroundInstance: Equatable, Sendable {
    public var position: SIMD2<Float>
    public var size: SIMD2<Float>
    public var color: SIMD4<Float>

    public init(position: SIMD2<Float>, size: SIMD2<Float>, color: SIMD4<Float>) {
        self.position = position
        self.size = size
        self.color = color
    }

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, color: SIMD4<Float>) {
        self.init(position: SIMD2<Float>(Float(x), Float(y)),
                  size: SIMD2<Float>(Float(width), Float(height)),
                  color: color)
    }
}

/// One textured quad out of an atlas. 48 bytes, matching `GlyphInstance` in
/// `Shaders.source`.
nonisolated public struct GlyphInstance: Equatable, Sendable {
    public var position: SIMD2<Float>
    public var size: SIMD2<Float>
    public var uvOrigin: SIMD2<Float>
    public var uvSize: SIMD2<Float>
    public var color: SIMD4<Float>

    public init(position: SIMD2<Float>,
                size: SIMD2<Float>,
                uvOrigin: SIMD2<Float>,
                uvSize: SIMD2<Float>,
                color: SIMD4<Float>) {
        self.position = position
        self.size = size
        self.uvOrigin = uvOrigin
        self.uvSize = uvSize
        self.color = color
    }
}

// MARK: - glyphs

/// Where a rasterised glyph sits, in the atlas and in the cell.
///
/// `uvOrigin`/`uvSize` are normalised atlas coordinates, top-down like the quad
/// (`GlyphAtlas.write` already flips the rasteriser's bottom-up bitmap).
/// `offset`/`size` are points relative to the cell's top-left corner.
nonisolated public struct GlyphPlacement: Sendable {
    public var atlas: GlyphAtlasFormat
    public var uvOrigin: SIMD2<Float>
    public var uvSize: SIMD2<Float>
    public var offset: SIMD2<Float>
    public var size: SIMD2<Float>

    public init(atlas: GlyphAtlasFormat,
                uvOrigin: SIMD2<Float>,
                uvSize: SIMD2<Float>,
                offset: SIMD2<Float>,
                size: SIMD2<Float>) {
        self.atlas = atlas
        self.uvOrigin = uvOrigin
        self.uvSize = uvSize
        self.offset = offset
        self.size = size
    }
}

/// What the row builder needs from the glyph cache. The renderer implements it
/// over `FontSet`/`GlyphRasterizer`/`GlyphAtlas`; the tests implement it with a
/// dictionary.
public protocol GlyphSource: AnyObject {
    /// Atlas placement of a rendered glyph, rasterising on first use.
    /// nil when the glyph has no ink (a space, an unmapped code point, or an
    /// atlas that has run out of room).
    func glyph(_ scalar: Unicode.Scalar, bold: Bool, italic: Bool) -> GlyphPlacement?
    /// The same for a multi-scalar grapheme cluster (`Row.combined`), laid
    /// out from the cell's left edge across `span` cells (1 or 2).
    func glyph(cluster: String, span: Int, bold: Bool, italic: Bool) -> GlyphPlacement?
}

// MARK: - overlays

/// Everything that colours a frame beside the grid itself. The view builds one
/// per frame and hands the same value to every row.
public struct FrameOverlay {
    /// The selection model (may be inactive — the builder asks it per line).
    public var selection: Selection?
    /// Every match to tint with `searchMatch`.
    public var searchMatches: [SearchMatch] = []
    /// The one match to tint with `searchCurrent` instead.
    public var currentMatch: SearchMatch?
    /// The highlight overlay, or nil when highlighting is off.
    public var highlight: HighlightOverlay?
    /// Search tints for a line (column range, isCurrent), precomputed by the
    /// renderer once per frame; nil = derive from `searchMatches`.
    public var searchTints: ((Int) -> [(Range<Int>, Bool)])?
    /// Filled in by `MetalRenderer` each frame: `highlight.overrides(line:in:)`
    /// needs the `Terminal`, which the row builder deliberately does not have.
    /// The view sets `highlight`; the renderer turns it into this closure. Tests
    /// can set it directly to exercise the override rules without agent D.
    public var highlightOverrides: ((Int) -> [UInt32]?)?
    public var cursorVisible: Bool = true
    public var cursorBlinkOn: Bool = true
    public var focused: Bool = true
    /// DECSCNM: the default fg and bg are swapped for the whole screen.
    public var reverseVideo: Bool = false

    public init() {}

    /// The highlight bit pattern: `0` = no override, else
    /// `0x8000_0000 | bold << 24 | 0xRRGGBB`.
    public static let highlightPresentBit: UInt32 = 0x8000_0000
    public static let highlightBoldBit: UInt32 = 1 << 24
}

// MARK: - the builder

public struct RowBuilder {
    public var palette: Palette
    public var metrics: CellMetrics
    public let glyphs: any GlyphSource

    public init(palette: Palette, metrics: CellMetrics, glyphs: any GlyphSource) {
        self.palette = palette
        self.metrics = metrics
        self.glyphs = glyphs
    }

    /// How many rows had to derive their search tints from `searchMatches`
    /// themselves — the O(matches)-per-row fallback in `build`. A frame built
    /// by `MetalRenderer` must never add to this (it always installs
    /// `FrameOverlay.searchTints`); the tests assert exactly that. MainActor,
    /// like everything else in this target, so it needs no synchronisation.
    static var searchTintFallbacks = 0

    /// The four instance arrays for one row, in draw order:
    /// backgrounds → decorations → gray glyphs → colour glyphs.
    nonisolated public struct Output: Sendable {
        public var backgrounds: [BackgroundInstance] = []
        public var grayGlyphs: [GlyphInstance] = []
        public var colorGlyphs: [GlyphInstance] = []
        public var decorations: [BackgroundInstance] = []
        public init() {}
        public var isEmpty: Bool {
            backgrounds.isEmpty && grayGlyphs.isEmpty && colorGlyphs.isEmpty && decorations.isEmpty
        }
    }

    /// The three shapes a cursor takes, once its blink style is folded away.
    nonisolated public enum CursorShape: Sendable {
        case block, underline, bar
        public init(_ style: CursorStyle) {
            switch style {
            case .blinkBlock, .steadyBlock: self = .block
            case .blinkUnderline, .steadyUnderline: self = .underline
            case .blinkBar, .steadyBar: self = .bar
            }
        }
    }

    /// Build one row.
    ///
    /// - Parameters:
    ///   - row: the grid row, or nil for a line that was never materialised
    ///     (blank — selection, search and the cursor still apply to it).
    ///   - line: scroll-invariant line number, the key overlays are addressed by.
    ///   - screenRow: 0-based viewport row, which fixes the row's y.
    ///   - cols: how many columns the viewport shows.
    ///   - cursor: the cursor's column and style when it is on this row, nil
    ///     otherwise. `MetalRenderer` also passes nil through the off half of
    ///     the blink, so that a row which paints no cursor keys on nothing
    ///     about it; the `cursorVisible`/`cursorBlinkOn` checks below stay put
    ///     for callers (the tests) that hand over a cursor regardless.
    public func build(row: Row?,
                      line: Int,
                      screenRow: Int,
                      cols: Int,
                      overlay: FrameOverlay,
                      cursor: (col: Int, style: CursorStyle)?) -> Output {
        var out = Output()
        guard cols > 0 else { return out }

        let cellW = metrics.width
        let cellH = metrics.height
        let top = CGFloat(screenRow) * cellH
        let reverse = overlay.reverseVideo
        let overrides = overlay.highlightOverrides?(line)

        @inline(__always)
        func cell(_ col: Int) -> Cell {
            guard let row, col < row.cols else { return .empty }
            return row[col]
        }

        // 1 — cell backgrounds. A cell that keeps the default background draws
        // nothing: the drawable was already cleared to it.
        for col in 0..<cols {
            let c = cell(col)
            // The trailing half of a wide char is covered by its head's quad.
            if c.isSpacer { continue }
            guard let bg = palette.resolve(c, reverseVideo: reverse).bg else { continue }
            let span = c.width == 2 ? 2 : 1
            out.backgrounds.append(BackgroundInstance(x: CGFloat(col) * cellW,
                                                      y: top,
                                                      width: cellW * CGFloat(span),
                                                      height: cellH,
                                                      color: bg))
        }

        // 2 — selection, then search tints, over the cell colours.
        if let range = overlay.selection?.columnRange(onLine: line), !range.isEmpty {
            out.backgrounds.append(tint(range: range, top: top,
                                        rgb: palette.colors.selectionBackground,
                                        alpha: palette.colors.selectionAlpha,
                                        cols: cols))
        }
        // Search tints: the renderer hands over this line's ranges (built
        // once per frame); without that closure, scan the matches. That scan
        // is O(matches) for every row rebuilt, so `MetalRenderer` installs the
        // closure on every frame — even when no match is on screen — and this
        // branch is only for callers that never build a map (the tests).
        let tints: [(Range<Int>, Bool)]
        if let perLine = overlay.searchTints {
            tints = perLine(line)
        } else {
            RowBuilder.searchTintFallbacks &+= 1
            tints = overlay.searchMatches.compactMap { match in
                columnRange(of: match, onLine: line, cols: cols).map { ($0, overlay.currentMatch == match) }
            }
        }
        for (range, isCurrent) in tints {
            out.backgrounds.append(tint(range: range, top: top,
                                        rgb: isCurrent ? palette.colors.searchCurrent : palette.colors.searchMatch,
                                        alpha: isCurrent ? palette.colors.searchCurrentAlpha : palette.colors.searchMatchAlpha,
                                        cols: cols))
        }

        // 3 — the cursor. Everything but a focused block is a thin quad drawn
        // with the decorations; a focused block is a filled quad under the glyph,
        // which is then re-emitted in `cursorText`.
        var blockCursorCol = -1
        if var cursor, overlay.cursorVisible, overlay.cursorBlinkOn,
           cursor.col >= 0, cursor.col < cols {
            let shape = CursorShape(cursor.style)
            // On the trailing half of a wide char the cursor covers the whole
            // character: snap to its head so the glyph gets `cursorText`.
            if cursor.col > 0, cell(cursor.col).isSpacer { cursor.col -= 1 }
            let c = cell(cursor.col)
            let span = CGFloat(c.width == 2 ? 2 : 1)
            let x = CGFloat(cursor.col) * cellW
            let color = palette.rgba(palette.colors.cursor)
            if !overlay.focused {
                // A hairline hollow rectangle: four quads, one device pixel thick.
                let t = 1 / Swift.max(metrics.scale, 1)
                let w = cellW * span
                out.decorations.append(BackgroundInstance(x: x, y: top, width: w, height: t, color: color))
                out.decorations.append(BackgroundInstance(x: x, y: top + cellH - t, width: w, height: t, color: color))
                out.decorations.append(BackgroundInstance(x: x, y: top, width: t, height: cellH, color: color))
                out.decorations.append(BackgroundInstance(x: x + w - t, y: top, width: t, height: cellH, color: color))
            } else {
                switch shape {
                case .block:
                    blockCursorCol = cursor.col
                    out.backgrounds.append(BackgroundInstance(x: x, y: top,
                                                              width: cellW * span, height: cellH,
                                                              color: color))
                case .bar:
                    let w = Swift.max(1, (cellW * 0.15).rounded())
                    out.decorations.append(BackgroundInstance(x: x, y: top, width: w, height: cellH, color: color))
                case .underline:
                    let h = Swift.max(1, metrics.underlineThickness * 2)
                    out.decorations.append(BackgroundInstance(x: x, y: top + cellH - h,
                                                              width: cellW * span, height: h,
                                                              color: color))
                }
            }
        }

        // 4 — decorations and glyphs, left to right.
        var col = 0
        while col < cols {
            let c = cell(col)
            if c.isSpacer {                     // trailing half of a wide char
                col += 1
                continue
            }
            let span = c.width == 2 ? 2 : 1
            let x = CGFloat(col) * cellW
            var fg = palette.resolve(c, reverseVideo: reverse).fg

            // The highlight overlay never clobbers a colour the device chose.
            var overrideBold = false
            if let overrides, col < overrides.count, c.fgSource == .default {
                let word = overrides[col]
                if word & FrameOverlay.highlightPresentBit != 0 {
                    fg = palette.rgba(word & 0xFF_FFFF)
                    overrideBold = word & FrameOverlay.highlightBoldBit != 0
                }
            }
            if col == blockCursorCol {
                fg = palette.rgba(palette.colors.cursorText)
            }

            appendDecorations(&out, cell: c, row: row, col: col, x: x, top: top,
                              width: cellW * CGFloat(span), fg: fg)

            // The glyph itself.
            let code = c.code
            let invisible = c.bg & Cell.BgFlag.invisible != 0
            if code != 0, code != 32, !invisible {
                let bold = overrideBold || (c.fg & Cell.FgFlag.bold != 0)
                let italic = c.fg & Cell.FgFlag.italic != 0
                var placement: GlyphPlacement?
                var isCluster = false
                if c.isCombined, let cluster = row?.combinedString(at: col) {
                    placement = glyphs.glyph(cluster: cluster, span: span, bold: bold, italic: italic)
                    isCluster = true
                } else if let scalar = Unicode.Scalar(code) {
                    placement = glyphs.glyph(scalar, bold: bold, italic: italic)
                }
                if let p = placement {
                    // A wide glyph is centred in its two-cell slot (SwiftTerm's
                    // `glyphSlotFit`); a normal one sits on its bearing; a
                    // cluster was laid out from the cell's left edge already.
                    let gx: CGFloat = isCluster ? x
                        : span == 2 ? x + (cellW * 2 - CGFloat(p.size.x)) / 2
                        : x + CGFloat(p.offset.x)
                    let instance = GlyphInstance(position: SIMD2<Float>(Float(gx), Float(top + CGFloat(p.offset.y))),
                                                 size: p.size,
                                                 uvOrigin: p.uvOrigin,
                                                 uvSize: p.uvSize,
                                                 color: p.atlas == .bgra ? SIMD4<Float>(1, 1, 1, fg.w) : fg)
                    switch p.atlas {
                    case .grayscale: out.grayGlyphs.append(instance)
                    case .bgra: out.colorGlyphs.append(instance)
                    }
                }
            }
            col += span
        }

        return out
    }

    // MARK: - helpers

    private func tint(range: Range<Int>, top: CGFloat, rgb: UInt32, alpha: Float, cols: Int) -> BackgroundInstance {
        let lo = Swift.max(range.lowerBound, 0)
        let hi = Swift.min(range.upperBound, cols)
        return BackgroundInstance(x: CGFloat(lo) * metrics.width,
                                  y: top,
                                  width: CGFloat(Swift.max(hi - lo, 0)) * metrics.width,
                                  height: metrics.height,
                                  color: palette.rgba(rgb, alpha: alpha))
    }

    /// The half-open column range a match covers on `line`, nil when it does not
    /// touch the line. `SearchMatch` bounds are inclusive cells and may span
    /// several (soft-wrapped) lines.
    private func columnRange(of match: SearchMatch, onLine line: Int, cols: Int) -> Range<Int>? {
        guard line >= match.start.line, line <= match.end.line else { return nil }
        let lo = line == match.start.line ? match.start.col : 0
        let hi = line == match.end.line ? match.end.col + 1 : cols
        let range = Swift.max(lo, 0)..<Swift.min(hi, cols)
        return range.isEmpty ? nil : range
    }

    /// Underline (five styles), strikethrough and overline for one cell.
    private func appendDecorations(_ out: inout Output,
                                   cell c: Cell,
                                   row: Row?,
                                   col: Int,
                                   x: CGFloat,
                                   top: CGFloat,
                                   width: CGFloat,
                                   fg: SIMD4<Float>) {
        let ext = c.hasExtended ? row?.extended(at: col) : nil
        var style: ExtendedAttributes.UnderlineStyle = ext?.underlineStyle ?? .none
        if style == .none, c.fg & Cell.FgFlag.underline != 0 { style = .single }

        let thickness = Swift.max(metrics.underlineThickness, 1 / Swift.max(metrics.scale, 1))

        if style != .none {
            var color = fg
            if let word = ext?.underlineColor, word != 0, let rgb = palette.color(word: word) {
                color = palette.rgba(rgb)
            }
            let y = underlineY(thickness: thickness)
            switch style {
            case .none:
                break
            case .single:
                out.decorations.append(BackgroundInstance(x: x, y: top + y, width: width, height: thickness, color: color))
            case .double, .curly:
                // A curly underline degrades to two lines rather than a shader of
                // its own: at 13 pt the wave is two pixels tall anyway.
                let gap = thickness * 2
                let y2 = Swift.min(y + gap, metrics.height - thickness)
                out.decorations.append(BackgroundInstance(x: x, y: top + y, width: width, height: thickness, color: color))
                out.decorations.append(BackgroundInstance(x: x, y: top + y2, width: width, height: thickness, color: color))
            case .dotted, .dashed:
                let dash = style == .dotted ? thickness : Swift.max(width / 3, thickness)
                let step = dash * 2
                var dx: CGFloat = 0
                while dx < width {
                    let w = Swift.min(dash, width - dx)
                    out.decorations.append(BackgroundInstance(x: x + dx, y: top + y, width: w, height: thickness, color: color))
                    dx += step
                }
            }
        }

        if c.bg & Cell.BgFlag.strikethrough != 0 {
            out.decorations.append(BackgroundInstance(x: x, y: top + strikethroughY(thickness: thickness),
                                                      width: width, height: thickness, color: fg))
        }
        if c.bg & Cell.BgFlag.overline != 0 {
            out.decorations.append(BackgroundInstance(x: x, y: top, width: width, height: thickness, color: fg))
        }
    }

    /// `CellMetrics.underlinePosition` is the *centre* of the underline measured
    /// from the cell's top edge; the quad's top is half a stroke above it. A
    /// value that would put the stroke outside the cell falls back to just under
    /// the baseline (and, for a negative one, to CoreText's below-the-baseline
    /// convention) rather than drawing off the row.
    private func underlineY(thickness: CGFloat) -> CGFloat {
        let centre = metrics.underlinePosition
        if centre > 0 { return clampStroke(centre, thickness: thickness) }
        if centre < 0 { return clampStroke(metrics.baseline - centre, thickness: thickness) }
        return clampStroke(metrics.baseline + thickness, thickness: thickness)
    }

    private func strikethroughY(thickness: CGFloat) -> CGFloat {
        let centre = metrics.strikethroughPosition
        if centre > 0 { return clampStroke(centre, thickness: thickness) }
        return clampStroke(metrics.baseline * 0.65, thickness: thickness)
    }

    /// Turn a stroke centre into the quad's top edge, kept inside the cell.
    private func clampStroke(_ centre: CGFloat, thickness: CGFloat) -> CGFloat {
        let limit = Swift.max(metrics.height - thickness, 0)
        return Swift.min(Swift.max(centre - thickness / 2, 0), limit)
    }
}
