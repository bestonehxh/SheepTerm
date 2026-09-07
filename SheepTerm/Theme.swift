import AppKit
import SwiftUI
import SwiftTerm

/// A complete terminal color scheme: background, default text, ANSI 16.
struct TerminalTheme: Identifiable {
    let id: String
    let name: String
    let background: UInt32
    let foreground: UInt32
    let ansi: [UInt32]
}

enum Theme {
    // MARK: Terminal themes

    static let terminalThemes: [TerminalTheme] = [
        TerminalTheme(
            id: "sheepterm", name: "SheepTerm",
            // Foreground brightened from D6DAE2 in 3.0 (8) to match the
            // Claude app's text (luminance 238 vs 220) — same reason as the
            // 15 pt default: contrast that survives the scaled display.
            // Background lifted from 15171C in 3.0 (10): a near-black ground
            // makes bright strokes bloom on an LCD, and this display already
            // resamples everything. 1E2128 keeps 14:1 contrast with EDEFF3
            // and measured 5% fewer grey fringe pixels after the resample.
            background: 0x1E2128, foreground: 0xEDEFF3,
            ansi: [0x1C1F26, 0xED7A7A, 0x7DD98C, 0xE8D06B, 0x6CA9E0, 0xE08BC7, 0x6CD1E0, 0xD6DAE2,
                   0x565D6B, 0xF29B9B, 0x9BE8A8, 0xF2E29B, 0x93C4F0, 0xF0AEDC, 0x9BE4F0, 0xF2F4F8]
        ),
        TerminalTheme(
            id: "dracula", name: "Dracula",
            background: 0x282A36, foreground: 0xF8F8F2,
            ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                   0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF]
        ),
        TerminalTheme(
            id: "nord", name: "Nord",
            background: 0x2E3440, foreground: 0xD8DEE9,
            ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                   0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4]
        ),
        TerminalTheme(
            id: "onedark", name: "One Dark",
            background: 0x282C34, foreground: 0xABB2BF,
            ansi: [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                   0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF]
        ),
        TerminalTheme(
            id: "solarized", name: "Solarized Dark",
            background: 0x002B36, foreground: 0x839496,
            ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                   0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]
        ),
        TerminalTheme(
            id: "gruvbox", name: "Gruvbox Dark",
            background: 0x282828, foreground: 0xEBDBB2,
            ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                   0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2]
        ),
    ]

    // MARK: Terminal font — Settings → Terminal and View → Terminal Font
    //
    // Family, size, weight and smoothing are user settings; the default is
    // SF Mono 13 Medium, smoothing off. They exist because of the display,
    // not the renderer: this Mac's stock mode (1470 x 956 on a 2560 x 1664
    // panel) resamples the whole screen by 0.87 before it reaches the eye, and
    // a larger or heavier face survives that far better than a thin one —
    // Termius draws ~14 pt with 2–3 px stems. The rendering itself was verified
    // pixel-perfect at 2x against 2.3 (15); see ARCHITECTURE.md §6 and §11
    // before "fixing" sharpness anywhere in code.

    static let fontFamilyKey = "terminalFontFamily"
    static let fontSizeKey = "terminalFontSize"
    static let fontWeightKey = "terminalFontWeight"
    static let fontSmoothingKey = "terminalFontSmoothing"
    /// OFF since 3.0 (12). macOS "font smoothing" dilates every glyph by a
    /// fraction of a pixel before antialiasing; on light text over a dark
    /// ground that reads as a grey halo around each stroke. Measured on this
    /// Mac at 2x: SF Mono 13 Medium with smoothing draws 3 px stems with a
    /// 4 px fringe, without it 2 px stems and a clean edge — the same stem
    /// width and edge profile as the Claude app's text (stems 2 px, grey/ink
    /// 0.64 vs 0.63). Chromium apps get that look from
    /// `-webkit-font-smoothing: antialiased`; this is the AppKit equivalent.
    static let defaultFontSmoothing = false
    /// Sentinel for the system monospaced font (SF Mono via
    /// `monospacedSystemFont`, which is not listed as an installable family).
    static let systemFontFamily = ""
    /// 13 — tried 15 in 3.0 (8)–(10) to match the Claude app's text density
    /// (30 px glyphs, 3 px stems), but that reads as too large in a terminal
    /// that lives in a 1470-point-wide window; the weight (Medium) and the
    /// lifted ground carry the legibility instead. 3.0 (11).
    static let defaultFontSize: Double = 13
    static let fontSizeRange: ClosedRange<Double> = 9...24
    /// Medium since 3.0 (10): on the resampled display it leaves 18% fewer
    /// grey fringe pixels than Regular at the same size (0.62 vs 0.76 in the
    /// simulation) while still reading as a normal, not bold, face.
    static let defaultFontWeight = TerminalFontWeight.medium

    enum TerminalFontWeight: String, CaseIterable, Identifiable {
        case regular, medium, semibold, bold
        var id: String { rawValue }
        var label: String {
            switch self {
            case .regular: return "Regular"
            case .medium: return "Medium"
            case .semibold: return "Semibold"
            case .bold: return "Bold"
            }
        }
        var nsWeight: NSFont.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
    }

    static func fontFamilyLabel(_ family: String) -> String {
        family == systemFontFamily ? "SF Mono (System)" : family
    }

    /// Every installed family with a fixed-pitch member, once per launch.
    /// The system font is not among them and is offered separately.
    static let availableMonospaceFamilies: [String] = {
        let manager = NSFontManager.shared
        let fixed = NSFontTraitMask.fixedPitchFontMask.rawValue
        return manager.availableFontFamilies.filter { family in
            guard !family.hasPrefix(".") else { return false }
            let members = manager.availableMembers(ofFontFamily: family) ?? []
            return members.contains { member in
                (member.count > 3 ? (member[3] as? UInt) ?? 0 : 0) & fixed != 0
            }
        }
    }()

    static var terminalFontFamily: String {
        let saved = UserDefaults.standard.string(forKey: fontFamilyKey) ?? systemFontFamily
        // A family that has since been uninstalled falls back to the system font.
        return saved == systemFontFamily || availableMonospaceFamilies.contains(saved) ? saved : systemFontFamily
    }

    static func clampFontSize(_ size: Double) -> Double {
        min(max(size.rounded(), fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    static var terminalFontSize: CGFloat {
        let saved = UserDefaults.standard.double(forKey: fontSizeKey)
        return CGFloat(clampFontSize(saved > 0 ? saved : defaultFontSize))
    }

    static var terminalFontWeight: TerminalFontWeight {
        UserDefaults.standard.string(forKey: fontWeightKey).flatMap(TerminalFontWeight.init) ?? defaultFontWeight
    }

    static var terminalFontSmoothing: Bool {
        UserDefaults.standard.object(forKey: fontSmoothingKey) as? Bool ?? defaultFontSmoothing
    }

    static var terminalFont: NSFont {
        let size = terminalFontSize, weight = terminalFontWeight
        let family = terminalFontFamily
        guard family != systemFontFamily else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight.nsWeight)
        }
        // Ask for the family at the requested weight; a family that lacks that
        // weight gets its closest face, and a family that vanished entirely
        // falls back to the system font rather than to Helvetica.
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.nsWeight.rawValue],
        ])
        if let font = NSFont(descriptor: descriptor, size: size), font.familyName == family {
            return font
        }
        return NSFont(name: family, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight.nsWeight)
    }

    static var currentTerminalTheme: TerminalTheme {
        let id = UserDefaults.standard.string(forKey: "terminalTheme") ?? "sheepterm"
        return terminalThemes.first { $0.id == id } ?? terminalThemes[0]
    }

    static var termBackgroundNS: NSColor { nsColor(currentTerminalTheme.background) }
    static var termForegroundNS: NSColor { nsColor(currentTerminalTheme.foreground) }
    static var termBackground: SwiftUI.Color { SwiftUI.Color(nsColor: termBackgroundNS) }

    // MARK: Chrome — the terminal follows its theme; the chrome (top bar,
    // sidebar, status bar) follows the app's Light/Dark appearance.

    static let chrome = dynamicColor(light: 0xE9EBEF, dark: 0x1C1F26)
    static let chromeLine = dynamicColor(light: 0xD3D7DD, dark: 0x2E323B)
    /// Opaque fill for controls that sit on a glass chrome surface.
    static let controlFill = dynamicColor(light: 0xFDFDFE, dark: 0x30343D)
    static let tabActive = dynamicColor(light: 0xFFFFFF, dark: 0x15171C)
    static let tabText = dynamicColor(light: 0x1B1E24, dark: 0xFFFFFF)
    static let dimText = dynamicColor(light: 0x5B6472, dark: 0x7D8492)
    static let accent = dynamicColor(light: 0x2C7FB8, dark: 0x5AA5D6)
    static let ok = dynamicColor(light: 0x2B7A46, dark: 0x7DD98C)
    static let warn = dynamicColor(light: 0x9A6A00, dark: 0xFEBC2E)

    private static func dynamicColor(light: UInt32, dark: UInt32) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        })
    }

    static func apply(to terminalView: TerminalView) {
        let theme = currentTerminalTheme
        // Only touch the font when it actually changed: SwiftTerm's setter
        // always re-measures and calls resize(), which reaches the pty / SSH
        // channel as a window-size change even when the grid is the same —
        // and every shell answers that by printing a fresh prompt. Switching
        // the theme used to leave one stray prompt line in every tab.
        let font = terminalFont
        if terminalView.font.fontName != font.fontName || terminalView.font.pointSize != font.pointSize {
            terminalView.font = font
        }
        // SwiftTerm's setter only stores the flag; the next full paint picks
        // it up, so ask for one when it actually changed.
        let smoothing = terminalFontSmoothing
        if terminalView.fontSmoothing != smoothing {
            terminalView.fontSmoothing = smoothing
            terminalView.needsDisplay = true
        }
        terminalView.nativeBackgroundColor = nsColor(theme.background)
        terminalView.nativeForegroundColor = nsColor(theme.foreground)
        terminalView.installColors(theme.ansi.map(termColor))
        // Selection: the app accent at 30% over the theme background, text
        // colour untouched — a tinted band, not the opaque grey slab the
        // old fg/bg blend gave (SwiftTerm's own default is a hard dark teal
        // that fights every theme). Chosen from a six-way preview, 3.0 (7).
        terminalView.selectedTextBackgroundColor =
            nsColor(theme.background).blended(withFraction: 0.30, of: nsColor(0x5AA5D6))
            ?? NSColor.selectedTextBackgroundColor
        terminalView.selectedTextForegroundColor = nsColor(theme.foreground)

        // Right-click menu: SwiftTerm implements copy:/paste:/selectAll: as
        // responder actions; target nil routes them to the clicked view.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Select All", action: NSSelectorFromString("selectAll:"), keyEquivalent: ""))
        terminalView.menu = menu

        // Cap SwiftTerm's kitty image cache (default 320 MB per tab): a hostile
        // or buggy host could otherwise inflate RAM for every open tab.
        terminalView.getTerminal().options.kittyImageCacheLimitBytes = 32 * 1024 * 1024
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    /// Pure conversion — safe to call from anywhere, so say so (installColors
    /// maps over it from a nonisolated context).
    nonisolated private static func termColor(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16((hex >> 16) & 0xFF) * 257,
            green: UInt16((hex >> 8) & 0xFF) * 257,
            blue: UInt16(hex & 0xFF) * 257
        )
    }
}
