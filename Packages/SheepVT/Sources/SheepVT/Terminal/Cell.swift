// SheepVT — one grid cell, 12 bytes.
//
// Layout borrowed from xterm.js (three UInt32 words) with foot's idea of a
// 2-bit "where did this colour come from" field, so a renderer or the
// highlighter can tell a device-set colour from a default one with one
// compare. Anything rare (grapheme clusters longer than one scalar,
// underline colour/style, hyperlinks) lives in per-row side tables, never
// in the cell. `MemoryLayout<Cell>.stride` is asserted to be 12 in the tests.

/// Where a cell's foreground/background colour came from.
public enum ColorSource: UInt32, Sendable {
    /// No SGR colour set — the theme's default fg/bg applies.
    case `default` = 0
    /// SGR 30–37 / 90–97 (fg) or 40–47 / 100–107 (bg): value = 0…15.
    case palette16 = 1
    /// SGR 38;5;n / 48;5;n: value = 0…255.
    case palette256 = 2
    /// SGR 38;2;r;g;b / 48;2;r;g;b: value = 0xRRGGBB.
    case rgb = 3
}

public struct Cell: Equatable, Sendable {
    // MARK: content word
    // bits 0–20  code point (0 = empty)
    // bit  21    combined: the full grapheme is in Row.combined[col]; the code
    //            point bits keep the base scalar so ASCII-only scanners still work
    // bits 22–23 width: 0 = spacer after a wide char, 1 = normal, 2 = wide
    public var content: UInt32

    // MARK: fg word / bg word
    // bits 0–23  colour value (index or 0xRRGGBB)
    // bits 24–25 ColorSource
    // bits 26–31 flags (see Flags); fg and bg carry different flag sets
    public var fg: UInt32
    public var bg: UInt32

    public static let codeMask: UInt32 = 0x1F_FFFF
    public static let combinedBit: UInt32 = 1 << 21
    public static let widthShift: UInt32 = 22
    public static let widthMask: UInt32 = 0x3 << 22

    public static let valueMask: UInt32 = 0x00FF_FFFF
    public static let sourceShift: UInt32 = 24
    public static let sourceMask: UInt32 = 0x3 << 24
    public static let flagsMask: UInt32 = 0xFC00_0000

    /// Flags stored in the top 6 bits of `fg`.
    public enum FgFlag {
        public static let bold: UInt32      = 1 << 26
        public static let dim: UInt32       = 1 << 27
        public static let italic: UInt32    = 1 << 28
        public static let underline: UInt32 = 1 << 29
        public static let blink: UInt32     = 1 << 30
        public static let inverse: UInt32   = 1 << 31
    }
    /// Flags stored in the top 6 bits of `bg`.
    public enum BgFlag {
        public static let invisible: UInt32     = 1 << 26
        public static let strikethrough: UInt32 = 1 << 27
        public static let overline: UInt32      = 1 << 28
        /// DECSCA — protected from selective erase (DECSED/DECSEL).
        public static let protected: UInt32     = 1 << 29
        /// Row.extended[col] holds underline style/colour and/or a hyperlink id.
        public static let hasExtended: UInt32   = 1 << 30
    }

    public init(content: UInt32, fg: UInt32, bg: UInt32) {
        self.content = content; self.fg = fg; self.bg = bg
    }

    /// Empty cell: no character, width 1, default colours. This is the value
    /// of freshly allocated rows and of erased cells when the pen has no bg.
    public static let empty = Cell(content: 1 << widthShift, fg: 0, bg: 0)

    /// Build a cell from a code point and width with the given attribute words.
    @inlinable
    public init(code: UInt32, width: UInt32, fg: UInt32, bg: UInt32) {
        self.content = (code & Cell.codeMask) | ((width & 0x3) << Cell.widthShift)
        self.fg = fg; self.bg = bg
    }

    @inlinable public var code: UInt32 {
        get { content & Cell.codeMask }
        set { content = (content & ~Cell.codeMask) | (newValue & Cell.codeMask) }
    }
    @inlinable public var width: Int {
        get { Int((content & Cell.widthMask) >> Cell.widthShift) }
        set { content = (content & ~Cell.widthMask) | ((UInt32(newValue) & 0x3) << Cell.widthShift) }
    }
    @inlinable public var isCombined: Bool {
        get { content & Cell.combinedBit != 0 }
        set { if newValue { content |= Cell.combinedBit } else { content &= ~Cell.combinedBit } }
    }
    /// True for a cell that holds no character (code 0 and width 1).
    @inlinable public var isEmpty: Bool { content & (Cell.codeMask | Cell.widthMask) == (1 << Cell.widthShift) }
    /// True for the trailing half of a wide character.
    @inlinable public var isSpacer: Bool { content & Cell.widthMask == 0 }

    @inlinable public var fgSource: ColorSource { ColorSource(rawValue: (fg & Cell.sourceMask) >> Cell.sourceShift)! }
    @inlinable public var bgSource: ColorSource { ColorSource(rawValue: (bg & Cell.sourceMask) >> Cell.sourceShift)! }
    @inlinable public var fgValue: UInt32 { fg & Cell.valueMask }
    @inlinable public var bgValue: UInt32 { bg & Cell.valueMask }
    @inlinable public var fgFlags: UInt32 { fg & Cell.flagsMask }
    /// Kept although nothing reads it yet: half of a symmetric pair on a
    /// public value type, and free (inlined, one mask). Deleting it would only
    /// mean writing it again the first time a caller needs the background half.
    @inlinable public var bgFlags: UInt32 { bg & Cell.flagsMask }
    @inlinable public var hasExtended: Bool { bg & Cell.BgFlag.hasExtended != 0 }
    @inlinable public var isProtected: Bool { bg & Cell.BgFlag.protected != 0 }

    /// The two attribute words with the character removed — what an erase
    /// with this pen would leave behind (background-colour erase keeps bg and
    /// its flags; fg is reset to default because there is nothing to colour).
    @inlinable public var eraseCell: Cell { Cell(content: 1 << Cell.widthShift, fg: 0, bg: bg & (Cell.valueMask | Cell.sourceMask)) }

    /// Pack a colour word from source + value, keeping the flag bits of `flags`.
    @inlinable
    public static func colorWord(source: ColorSource, value: UInt32, flags: UInt32 = 0) -> UInt32 {
        (flags & flagsMask) | (source.rawValue << sourceShift) | (value & valueMask)
    }
}

/// Rare per-cell attributes kept in `Row.extended` (flagged by `BgFlag.hasExtended`).
public struct ExtendedAttributes: Equatable, Sendable {
    public enum UnderlineStyle: UInt8, Sendable { case none = 0, single, double, curly, dotted, dashed }
    public var underlineStyle: UnderlineStyle = .none
    /// SGR 58 colour as a packed colour word (source + value), 0 = follow fg.
    public var underlineColor: UInt32 = 0
    /// OSC 8 hyperlink id (index into Terminal.hyperlinks), 0 = none.
    public var hyperlinkID: UInt32 = 0
    public init() {}
    public var isDefault: Bool { underlineStyle == .none && underlineColor == 0 && hyperlinkID == 0 }
}
