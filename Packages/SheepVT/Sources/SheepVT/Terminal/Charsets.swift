// SheepVT — the three ISO-2022 character sets we actually need.
//
// Only VT100 sets: US ASCII (`ESC ( B`), DEC Special Graphics / line drawing
// (`ESC ( 0`) and UK (`ESC ( A`). The national replacement sets exist but no
// device SheepTerm talks to designates them; anything else designates ASCII.
//
// The line-drawing table is xterm's output from vttest (same values as
// xterm.js `Charsets.ts`, MIT), not the vt102 manual — where the two differ
// xterm wins, because that is what curses apps are drawn against.

public enum Charset: UInt8, Sendable {
    /// `ESC ( B` — no translation.
    case ascii = 0
    /// `ESC ( 0` — DEC Special Character and Line Drawing Set.
    case decSpecialGraphics = 1
    /// `ESC ( A` — United Kingdom: `#` becomes `£`.
    case uk = 2
}

public enum Charsets {

    /// Lowest code point the line-drawing table covers.
    public static let graphicsLow: UInt32 = 0x60
    /// Highest code point the line-drawing table covers.
    public static let graphicsHigh: UInt32 = 0x7E

    /// DEC Special Graphics for 0x60…0x7E, indexed by `cp - 0x60`.
    ///
    ///     ` a b c d e f g h i j k l m n o
    ///     ◆ ▒ ␉ ␌ ␍ ␊ ° ± ␤ ␋ ┘ ┐ ┌ └ ┼ ⎺
    ///     p q r s t u v w x y z { | } ~
    ///     ⎻ ─ ⎼ ⎽ ├ ┤ ┴ ┬ │ ≤ ≥ π ≠ £ ·
    public static let decSpecialGraphics: [UInt32] = [
        0x25C6, // ` ◆ diamond
        0x2592, // a ▒ checker board
        0x2409, // b ␉ HT symbol
        0x240C, // c ␌ FF symbol
        0x240D, // d ␍ CR symbol
        0x240A, // e ␊ LF symbol
        0x00B0, // f ° degree
        0x00B1, // g ± plus/minus
        0x2424, // h ␤ NL symbol
        0x240B, // i ␋ VT symbol
        0x2518, // j ┘ lower right corner
        0x2510, // k ┐ upper right corner
        0x250C, // l ┌ upper left corner
        0x2514, // m └ lower left corner
        0x253C, // n ┼ crossing lines
        0x23BA, // o ⎺ horizontal line scan 1
        0x23BB, // p ⎻ horizontal line scan 3
        0x2500, // q ─ horizontal line scan 5
        0x23BC, // r ⎼ horizontal line scan 7
        0x23BD, // s ⎽ horizontal line scan 9
        0x251C, // t ├ left tee
        0x2524, // u ┤ right tee
        0x2534, // v ┴ bottom tee
        0x252C, // w ┬ top tee
        0x2502, // x │ vertical bar
        0x2264, // y ≤ less than or equal
        0x2265, // z ≥ greater than or equal
        0x03C0, // { π pi
        0x2260, // | ≠ not equal
        0x00A3, // } £ pound sterling
        0x00B7, // ~ · centered dot
    ]

    /// Map one code point through a designated charset. Only 7-bit codes are
    /// ever replaced; everything else (and every unmapped code) passes through.
    @inlinable
    public static func translate(_ cp: UInt32, charset: Charset) -> UInt32 {
        switch charset {
        case .ascii:
            return cp
        case .decSpecialGraphics:
            guard cp >= graphicsLow, cp <= graphicsHigh else { return cp }
            return decSpecialGraphics[Int(cp - graphicsLow)]
        case .uk:
            return cp == 0x23 ? 0x00A3 : cp
        }
    }

    /// The charset a designation final byte selects (`B`, `0`, `A`); anything
    /// else falls back to ASCII rather than dropping the sequence.
    public static func designation(for final: UInt8) -> Charset {
        switch final {
        case UInt8(ascii: "0"): return .decSpecialGraphics
        case UInt8(ascii: "A"): return .uk
        default: return .ascii
        }
    }
}

public extension Charset {
    /// Convenience spelling of `Charsets.translate(_:charset:)`.
    @inlinable
    func translate(_ cp: UInt32) -> UInt32 { Charsets.translate(cp, charset: self) }
}
