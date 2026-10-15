import Foundation

/// The terminal colour schemes, shared by SheepTerm for Mac (`Theme.terminalThemes`) and SheepTerm for Windows (through
/// SheepTermCore), so one theme means the same colours on both. Pure values.
///
/// 5.0 (17): every scheme is held to a readability floor on its own background (WCAG contrast): text ≥ 7, ANSI 1–15 ≥ 4.5,
/// "bright black" (8, dim text: comments, zsh autosuggestions) ≥ 3.5 — dim, but never gone. Colours below it were lifted in
/// lightness only (hue and saturation kept), so each theme still looks like itself. Solarized Dark had bright black EQUAL to
/// its background (contrast 1.0: autosuggestions were invisible). ANSI 0 is a background colour and is exempt.
/// `TerminalPalette.contrast` is the measure; the harness checks every scheme against the floor.
public nonisolated struct TerminalPalette: Equatable, Sendable {
    public let id: String
    public let name: String
    public let background: UInt32
    public let foreground: UInt32
    public let ansi: [UInt32]

    public static let foregroundFloor = 7.0
    public static let colorFloor = 4.5
    public static let dimFloor = 3.5

    public static let all: [TerminalPalette] = [
        // 5.0 (17) readability: was 8 565D6B
        TerminalPalette(
            id: "sheepterm", name: "SheepTerm",
            background: 0x1E2128, foreground: 0xEDEFF3,
            ansi: [0x1C1F26, 0xED7A7A, 0x7DD98C, 0xE8D06B, 0x6CA9E0, 0xE08BC7, 0x6CD1E0, 0xD6DAE2,
                   0x6D7687, 0xF29B9B, 0x9BE8A8, 0xF2E29B, 0x93C4F0, 0xF0AEDC, 0x9BE4F0, 0xF2F4F8]
        ),
        // 5.0 (17) readability: was 8 6272A4
        TerminalPalette(
            id: "dracula", name: "Dracula",
            background: 0x282A36, foreground: 0xF8F8F2,
            ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                   0x6F7EAB, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF]
        ),
        // 5.0 (17) readability: was 1 BF616A, 5 B48EAD, 8 4C566A, 9 BF616A, 13 B48EAD
        TerminalPalette(
            id: "nord", name: "Nord",
            background: 0x2E3440, foreground: 0xD8DEE9,
            ansi: [0x3B4252, 0xCF8990, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB691AF, 0x88C0D0, 0xE5E9F0,
                   0x7D89A2, 0xCF8990, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB691AF, 0x8FBCBB, 0xECEFF4]
        ),
        // 5.0 (17) readability: was foreground ABB2BF, 1 E06C75, 8 5C6370, 9 E06C75
        TerminalPalette(
            id: "onedark", name: "One Dark",
            background: 0x282C34, foreground: 0xB2B9C5,
            ansi: [0x282C34, 0xE17079, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                   0x77808F, 0xE17079, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF]
        ),
        // 5.0 (17) readability: was foreground 839496, 1 DC322F, 4 268BD2, 5 D33682, 8 002B36, 9 CB4B16, 10 586E75, 11 657B83, 13 6C71C4
        TerminalPalette(
            id: "solarized", name: "Solarized Dark",
            background: 0x002B36, foreground: 0xA8B4B6,
            ansi: [0x073642, 0xE56663, 0x859900, 0xB58900, 0x3094DA, 0xDD629D, 0x2AA198, 0xEEE8D5,
                   0x668088, 0xE8652E, 0x78929A, 0x7B9199, 0x839496, 0x8488CD, 0x93A1A1, 0xFDF6E3]
        ),
        // 5.0 (17) readability: was 1 CC241D, 4 458588, 5 B16286, 9 FB4934
        TerminalPalette(
            id: "gruvbox", name: "Gruvbox Dark",
            background: 0x282828, foreground: 0xEBDBB2,
            ansi: [0x282828, 0xE8655F, 0x98971A, 0xD79921, 0x509B9E, 0xBE7C9A, 0x689D6A, 0xA89984,
                   0x928374, 0xFB5441, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2]
        ),
    ]

    /// WCAG 2 contrast ratio of two sRGB colours (1…21).
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func luminance(_ rgb: UInt32) -> Double {
            0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722 * channel(rgb)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
