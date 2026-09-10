// SheepVT — how many columns a code point occupies.
//
// Structure follows SwiftTerm's `Utilities.columnWidth` (MIT) and foot's
// wcwidth: a table for everything below U+3000 built once at first use, and a
// computed path (general category + binary search over the East Asian
// Wide/Fullwidth ranges) above it. The table is the common case — Latin,
// Greek, Cyrillic, Hebrew, Arabic, Thai, box drawing, Hangul jamo — so a
// print costs one array load.

public enum UnicodeWidth {
    /// Scalars below this are answered from `lowPlane`; above it the width is computed.
    /// 0x3000 keeps the table at 12 KiB while covering every non-CJK script.
    public static let tableLimit: UInt32 = 0x3000

    /// Precomputed widths for U+0000…U+2FFF. Built once, lazily.
    static let lowPlane: [UInt8] = table(0, Int(tableLimit))

    // The three blocks above `tableLimit` that real terminal traffic actually
    // lands in. `compute` is not cheap — the general-category and
    // emoji-presentation queries are out-of-line calls into the stdlib's
    // Unicode data (`_swift_stdlib_getGeneralCategory`,
    // `_swift_stdlib_getBinaryProperties`), and a profile of a Thai/CJK/emoji
    // stream spent ~12% of its time in exactly those two — so the answers are
    // precomputed here as well. Every entry is `compute(i)` verbatim, so this
    // is a pure memo: it cannot change what `width` returns.
    //
    // Each block is its own `static let` and therefore built only if something
    // in it is actually printed: a Thai session never builds the CJK table, a
    // CJK session never builds the emoji one. Together they are 64 KiB.

    /// U+3000…U+9FFF — CJK symbols, kana, CJK Unified Ideographs, Yi. 28 KiB.
    static let cjkPlane: [UInt8] = table(0x3000, 0xA000)
    /// U+A000…U+FFFF — Hangul syllables, CJK compatibility, halfwidth and
    /// fullwidth forms, the specials block. 24 KiB.
    static let highPlane: [UInt8] = table(0xA000, 0x1_0000)
    /// U+1F000…U+1FAFF — the emoji planes (incl. regional indicators and the
    /// symbol blocks around them). 11 KiB.
    static let emojiPlane: [UInt8] = table(0x1_F000, 0x1_FB00)

    private static func table(_ lo: Int, _ hi: Int) -> [UInt8] {
        var t = [UInt8](repeating: 1, count: hi - lo)
        for i in lo..<hi { t[i - lo] = UInt8(compute(UInt32(i))) }
        return t
    }

    /// 0 = zero-width (combining mark, format character, control), 1 = normal,
    /// 2 = East Asian Wide/Fullwidth or emoji presentation.
    public static func width(_ scalar: UInt32) -> Int {
        // ASCII fast path: printable ASCII is one column, C0 and DEL are zero.
        if scalar < 0x80 { return (scalar >= 0x20 && scalar < 0x7F) ? 1 : 0 }
        if scalar < tableLimit { return Int(lowPlane[Int(scalar)]) }
        if scalar < 0xA000 { return Int(cjkPlane[Int(scalar) - 0x3000]) }
        if scalar < 0x1_0000 { return Int(highPlane[Int(scalar) - 0xA000]) }
        if scalar >= 0x1_F000 && scalar < 0x1_FB00 { return Int(emojiPlane[Int(scalar) - 0x1_F000]) }
        return compute(scalar)
    }

    // MARK: - the slow path

    /// Zero-width ranges that are not (or not reliably) covered by the general
    /// category test: the bidi/format block, the line/paragraph separators and
    /// the invisible-operator block.
    static let zeroWidthRanges: [(lo: UInt32, hi: UInt32)] = [
        (0x200B, 0x200F),   // ZWSP, ZWNJ, ZWJ, LRM, RLM
        (0x2028, 0x202E),   // line/paragraph separator, bidi embedding controls
        (0x2060, 0x2064),   // word joiner, invisible operators
        (0x1160, 0x11FF),   // Hangul jamo medial/final — combine with the leading jamo
        (0xD7B0, 0xD7FF),   // Hangul jamo extended-B
    ]

    static func compute(_ scalar: UInt32) -> Int {
        // Controls: C0, DEL and C1 (0xA0 NO-BREAK SPACE is *not* a control).
        if scalar < 0x20 { return 0 }
        if scalar < 0x7F { return 1 }
        if scalar < 0xA0 { return 0 }

        for r in zeroWidthRanges where scalar >= r.lo && scalar <= r.hi { return 0 }

        // Lone surrogates and out-of-range values are printed as one column
        // (the caller has already substituted U+FFFD for malformed input).
        guard let us = Unicode.Scalar(scalar) else { return 1 }

        let props = us.properties
        switch props.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark:
            return 0
        case .format:
            // SOFT HYPHEN is the one format character that is drawn.
            return scalar == 0x00AD ? 1 : 0
        case .lineSeparator, .paragraphSeparator:
            return 0
        case .control, .surrogate:
            return 0
        default:
            break
        }

        // Emoji that default to the emoji (colour, square) presentation are wide
        // even when they are not in the East Asian Wide table.
        if props.isEmojiPresentation { return 2 }

        if isEastAsianWide(scalar) { return 2 }
        return 1
    }

    /// Binary search over `UnicodeWidthData.eastAsianWide` (sorted, disjoint).
    static func isEastAsianWide(_ scalar: UInt32) -> Bool {
        let ranges = UnicodeWidthData.eastAsianWide
        if scalar < ranges[0].lo || scalar > ranges[ranges.count - 1].hi { return false }
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = ranges[mid]
            if scalar < r.lo { hi = mid - 1 }
            else if scalar > r.hi { lo = mid + 1 }
            else { return true }
        }
        return false
    }
}
