// SheepVTRender — the theme and the colour resolver.
//
// `TerminalColors` is the theme as the app states it (0xRRGGBB words); `Palette`
// is the thing the renderer asks "what colour is this cell?". It owns the
// 256-entry table (16 theme colours + the 6×6×6 cube + 24 greys) and folds in
// the OSC 4 overrides a program may have set (`Terminal.palette`).
//
// Everything here is a pure value type: no Metal, no AppKit, `nonisolated` so
// the view, the renderer and the tests can all read it from anywhere.

import SheepVT

// MARK: - theme

nonisolated public struct TerminalColors: Equatable, Sendable {
    /// Default background / foreground, 0xRRGGBB.
    public var background: UInt32
    public var foreground: UInt32
    /// The 16 ANSI colours (0…7 normal, 8…15 bright). Always exactly 16 entries.
    public var ansi: [UInt32]
    /// Drawn over the cell background at `selectionAlpha`.
    public var selectionBackground: UInt32
    public var selectionAlpha: Float
    /// Background tints for search hits.
    public var searchMatch: UInt32
    public var searchMatchAlpha: Float
    public var searchCurrent: UInt32
    public var searchCurrentAlpha: Float
    /// Block / bar / underline cursor colour, and the text inside a block cursor.
    public var cursor: UInt32
    public var cursorText: UInt32

    public init(background: UInt32,
                foreground: UInt32,
                ansi: [UInt32],
                selectionBackground: UInt32,
                selectionAlpha: Float = 0.30,
                searchMatch: UInt32,
                searchMatchAlpha: Float = 0.35,
                searchCurrent: UInt32,
                searchCurrentAlpha: Float = 0.55,
                cursor: UInt32,
                cursorText: UInt32) {
        self.background = background
        self.foreground = foreground
        // A theme that hands over the wrong number of entries is padded from the
        // default rather than trapping in the middle of a frame.
        if ansi.count == 16 {
            self.ansi = ansi
        } else {
            var a = ansi
            while a.count < 16 { a.append(a.isEmpty ? foreground : a[a.count % max(a.count, 1)]) }
            self.ansi = Array(a.prefix(16))
        }
        self.selectionBackground = selectionBackground
        self.selectionAlpha = selectionAlpha
        self.searchMatch = searchMatch
        self.searchMatchAlpha = searchMatchAlpha
        self.searchCurrent = searchCurrent
        self.searchCurrentAlpha = searchCurrentAlpha
        self.cursor = cursor
        self.cursorText = cursorText
    }

    /// SheepTerm's own theme (the values the app ships as theme "sheepterm").
    public static let sheepTerm = TerminalColors(
        background: 0x1E2128,
        foreground: 0xEDEFF3,
        ansi: [0x1C1F26, 0xED7A7A, 0x7DD98C, 0xE8D06B, 0x6CA9E0, 0xE08BC7, 0x6CD1E0, 0xD6DAE2,
               0x565D6B, 0xF29B9B, 0x9BE8A8, 0xF2E29B, 0x93C4F0, 0xF0AEDC, 0x9BE4F0, 0xF2F4F8],
        selectionBackground: 0x5AA5D6,
        selectionAlpha: 0.30,
        searchMatch: 0xE8D06B,
        searchMatchAlpha: 0.35,
        searchCurrent: 0xF2A33C,
        searchCurrentAlpha: 0.55,
        cursor: 0xEDEFF3,
        cursorText: 0x1E2128)
}

// MARK: - resolver

nonisolated public struct Palette: Equatable, Sendable {
    /// SGR 2 (dim) scales the foreground by this much. xterm halves it; 0.6 keeps
    /// dim text readable on the dark ground SheepTerm ships.
    public static let dimFactor: Float = 0.6

    public var colors: TerminalColors {
        didSet { if colors != oldValue { rebuild() } }
    }

    /// OSC 4 overrides straight out of `Terminal.palette` (256 entries, nil = theme).
    private var overrides: [UInt32?]
    /// The resolved 256-colour table: theme/override for 0…15, the cube for
    /// 16…231, the grey ramp for 232…255.
    private var table: [UInt32]

    public init(colors: TerminalColors = .sheepTerm) {
        self.colors = colors
        self.overrides = Array(repeating: nil, count: 256)
        self.table = Palette.baseTable(colors: colors, overrides: Array(repeating: nil, count: 256))
    }

    /// Take the terminal's OSC 4 overrides. Anything that is not 256 entries long
    /// is padded/cropped, so a caller can hand over a short array safely.
    public mutating func apply(overrides: [UInt32?]) {
        var o = overrides
        if o.count < 256 { o.append(contentsOf: Array(repeating: nil, count: 256 - o.count)) }
        if o.count > 256 { o = Array(o.prefix(256)) }
        guard o != self.overrides else { return }
        self.overrides = o
        rebuild()
    }

    private mutating func rebuild() {
        table = Palette.baseTable(colors: colors, overrides: overrides)
    }

    /// The 256-colour table. Indices 0…15 come from the theme (or an OSC 4
    /// override); 16…231 are the 6×6×6 cube with xterm's level ramp
    /// (0, 95, 135, 175, 215, 255); 232…255 are the 24 greys 8, 18, … 238.
    private static func baseTable(colors: TerminalColors, overrides: [UInt32?]) -> [UInt32] {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<16 { t[i] = overrides[i] ?? colors.ansi[i] }
        for i in 16..<232 {
            let n = i - 16
            let r = level(n / 36), g = level((n / 6) % 6), b = level(n % 6)
            t[i] = overrides[i] ?? ((r << 16) | (g << 8) | b)
        }
        for i in 232..<256 {
            let v = UInt32(8 + 10 * (i - 232))
            t[i] = overrides[i] ?? ((v << 16) | (v << 8) | v)
        }
        return t
    }

    private static func level(_ step: Int) -> UInt32 {
        step == 0 ? 0 : UInt32(55 + 40 * step)
    }

    /// The 0xRRGGBB word for a 256-colour index (clamped).
    public func rgb(at index: Int) -> UInt32 {
        table[Swift.min(Swift.max(index, 0), 255)]
    }

    /// 0xRRGGBB → straight (non-premultiplied) RGBA.
    public func rgba(_ rgb: UInt32, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4<Float>(Float((rgb >> 16) & 0xFF) / 255,
                     Float((rgb >> 8) & 0xFF) / 255,
                     Float(rgb & 0xFF) / 255,
                     alpha)
    }

    /// The colour a cell's fg/bg word names, or nil when it is the default.
    /// `bold` brightens palette16 indices 0…7 to 8…15 (xterm's default for the
    /// foreground only).
    private func colorWord(source: ColorSource, value: UInt32, bold: Bool, isForeground: Bool) -> UInt32? {
        switch source {
        case .default:
            return nil
        case .palette16:
            var index = Int(value & 0xF)
            if bold, isForeground, index < 8 { index += 8 }
            return table[index]
        case .palette256:
            return table[Int(value & 0xFF)]
        case .rgb:
            return value & 0xFF_FFFF
        }
    }

    /// Decode a packed colour word (source + value, as `Cell.fg`/`Cell.bg` and
    /// `ExtendedAttributes.underlineColor` store it). nil = the default colour.
    public func color(word: UInt32, bold: Bool = false, isForeground: Bool = true) -> UInt32? {
        let source = ColorSource(rawValue: (word & Cell.sourceMask) >> Cell.sourceShift) ?? .default
        return colorWord(source: source, value: word & Cell.valueMask, bold: bold, isForeground: isForeground)
    }

    /// The default fg/bg after DECSCNM (`reverseVideo`), which swaps them.
    public func defaults(reverseVideo: Bool) -> (fg: UInt32, bg: UInt32) {
        reverseVideo ? (colors.background, colors.foreground) : (colors.foreground, colors.background)
    }

    /// Resolve one cell to the colours the renderer draws.
    ///
    /// `bg` is nil when the cell keeps the default background: the renderer has
    /// already cleared the drawable to it, so no quad is needed. Order of
    /// operations: bold brightening → inverse swap → dim → invisible.
    public func resolve(_ cell: Cell, reverseVideo: Bool) -> (fg: SIMD4<Float>, bg: SIMD4<Float>?) {
        let flags = cell.fg
        let bold = flags & Cell.FgFlag.bold != 0
        let dim = flags & Cell.FgFlag.dim != 0
        let inverse = flags & Cell.FgFlag.inverse != 0
        let invisible = cell.bg & Cell.BgFlag.invisible != 0
        let (defFg, defBg) = defaults(reverseVideo: reverseVideo)

        let fgWord = colorWord(source: cell.fgSource, value: cell.fgValue, bold: bold, isForeground: true)
        let bgWord = colorWord(source: cell.bgSource, value: cell.bgValue, bold: false, isForeground: false)

        var fgRGB: UInt32
        var bgRGB: UInt32?
        if inverse {
            // The cell's background becomes the ink and its foreground the ground;
            // a default on either side falls back to the theme's.
            fgRGB = bgWord ?? defBg
            bgRGB = fgWord ?? defFg
        } else {
            fgRGB = fgWord ?? defFg
            bgRGB = bgWord
        }

        var fg = rgba(fgRGB)
        if dim {
            fg.x *= Palette.dimFactor
            fg.y *= Palette.dimFactor
            fg.z *= Palette.dimFactor
        }
        if invisible {
            fg = rgba(bgRGB ?? defBg)
        }
        return (fg, bgRGB.map { rgba($0) })
    }
}
