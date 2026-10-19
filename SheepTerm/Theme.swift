import AppKit
import SheepVTRender
import SwiftUI

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

    /// The schemes live in `TerminalPalettes.swift` (shared with Windows through SheepTermCore).
    static let terminalThemes: [TerminalTheme] = TerminalPalette.all.map {
        TerminalTheme(id: $0.id, name: $0.name, background: $0.background, foreground: $0.foreground, ansi: $0.ansi)
    }

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
            case .regular: return String(localized: "Regular")
            case .medium: return String(localized: "Medium")
            case .semibold: return String(localized: "Semibold")
            case .bold: return String(localized: "Bold")
            }
        }
        /// NSFontManager's weight scale (what `availableMembers` reports).
        var managerWeight: Int {
            switch self {
            case .regular: return 5
            case .medium: return 6
            case .semibold: return 8
            case .bold: return 9
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
        family == systemFontFamily ? String(localized: "SF Mono (System)") : family
    }

    /// Every installed family with a fixed-pitch member, once per launch —
    /// the bundled faces (`TerminalFonts.bundled`) are registered first, so
    /// they are among them. The system font is not, and is offered separately.
    static let availableMonospaceFamilies: [String] = {
        let resources = Bundle.main.resourceURL
        let fontsDir = resources?.appendingPathComponent("Fonts")
        let dir = fontsDir.map { FileManager.default.fileExists(atPath: $0.path) } == true ? fontsDir : resources
        let failed = TerminalFonts.registerBundled(in: dir)
        if !failed.isEmpty { NSLog("SheepTerm: bundled fonts not registered: %@", failed.joined(separator: ", ")) }
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

    /// The View menu / Settings list, curated like SheepTerm for Windows.
    static let terminalFontSections = TerminalFonts.sections(installed: availableMonospaceFamilies)

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
        // The family's own faces first: the nearest weight it really has
        // (`TerminalFonts.nearestWeight` — Medium on a Regular/Bold family is
        // Regular, not Bold). Then the descriptor match, and a family that
        // vanished entirely falls back to the system font, not Helvetica.
        let manager = NSFontManager.shared
        let members = manager.availableMembers(ofFontFamily: family) ?? []
        let upright = members.filter { member in
            let traits = (member.count > 3 ? (member[3] as? UInt) ?? 0 : 0)
            return traits & NSFontTraitMask.italicFontMask.rawValue == 0
        }
        let weights = upright.compactMap { $0.count > 2 ? $0[2] as? Int : nil }
        if let pick = TerminalFonts.nearestWeight(weight.managerWeight, available: weights),
           let member = upright.first(where: { ($0[2] as? Int) == pick }),
           let name = member.first as? String,
           let font = NSFont(name: name, size: size) {
            return font
        }
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
    static var termBackground: SwiftUI.Color { SwiftUI.Color(nsColor: termBackgroundNS) }

    // MARK: Chrome — the terminal follows its theme; the chrome (top bar,
    // sidebar, status bar) is DARK, full stop (4.0 (5)).
    //
    // These were `dynamicColor(light:dark:)` pairs. The light halves went
    // with the Appearance menu: every one of them was a second design that
    // nobody used and nobody measured, while the dark values are the ones
    // the terminal themes, the glass materials and every 10 pt secondary
    // caption were checked against.

    static let chrome = nsColorValue(0x1C1F26)
    static let chromeLine = nsColorValue(0x2E323B)
    /// Opaque fill for controls that sit on a glass chrome surface.
    static let controlFill = nsColorValue(0x30343D)
    static let tabActive = nsColorValue(0x15171C)
    static let tabText = nsColorValue(0xFFFFFF)
    /// 888E9B since 5.0 (17) (was 7D8492: 4.4 on the chrome, 3.3 on a control) — 5.0 / 3.8 now.
    static let dimText = nsColorValue(0x888E9B)
    static let accent = nsColorValue(0x5AA5D6)
    static let ok = nsColorValue(0x7DD98C)
    static let warn = nsColorValue(0xFEBC2E)
    /// Web hosts / web tabs (5.0 web tabs): their own hue beside SSH's
    /// accent blue and serial's amber, so a globe pill never reads as SSH.
    /// Slightly lighter than `accent` (luminance 0.37 vs 0.34) — not used for
    /// any other meaning in the app's own UI.
    static let web = nsColorValue(0xB392F0)
    /// Every red in the app's own UI — error lines, trash buttons, a dropped
    /// session's dot — is the popups' soft red (the user, 2026-10-09: one
    /// tone family, not SwiftUI's saturated `.red`).
    static let destructive = SwiftUI.Color(nsColor: SheepAlert.destructiveRed)

    /// The colour a host's kind badge wears (sidebar, Quick Search, recents).
    static func kindColor(_ kind: ConnectionKind) -> SwiftUI.Color {
        switch kind {
        case .ssh: return accent
        case .serial: return warn
        case .local: return ok
        case .web: return web
        case .unsupported: return dimText
        }
    }

    private static func nsColorValue(_ hex: UInt32) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: nsColor(hex))
    }

    static func apply(to terminalView: TerminalView) {
        let theme = currentTerminalTheme
        // Only touch the font when it actually changed: the setter re-measures
        // the cell, and a re-measure that lands on a different grid reaches the
        // pty / SSH channel as a window-size change — and every shell answers
        // that by printing a fresh prompt. Switching the theme used to leave
        // one stray prompt line in every tab.
        let font = terminalFont
        if terminalView.font.fontName != font.fontName || terminalView.font.pointSize != font.pointSize {
            terminalView.font = font
        }
        // Both setters below no-op when the value is unchanged and ask for a
        // repaint when it is not, so there is nothing to guard here.
        terminalView.fontSmoothing = terminalFontSmoothing

        // Keep the package's search-hit tints and alphas; override only what
        // a SheepTerm theme actually states.
        var colors = TerminalColors.sheepTerm
        colors.background = theme.background
        colors.foreground = theme.foreground
        colors.ansi = theme.ansi
        // Selection: the app accent at 30% over the theme background, text
        // colour untouched — a tinted band, not the opaque grey slab the old
        // fg/bg blend gave. Chosen from a six-way preview, 3.0 (7); the
        // renderer does the blend now, so the colour and the alpha are stated
        // separately instead of pre-blended.
        colors.selectionBackground = 0x5AA5D6
        colors.selectionAlpha = 0.30
        colors.cursor = theme.foreground
        colors.cursorText = theme.background
        // Setting `colors` also hands the theme's foreground, background and
        // cursor to the terminal as the HOST BASELINE: what an OSC 10/11/12
        // query answers when no program has overridden it, and what OSC
        // 110/111/112 and RIS put back. Assigning those three by hand here
        // used to be necessary and is now the same write, one line later.
        terminalView.colors = colors
        // One tint per selection: no echo of the selected word elsewhere
        // (the user, 5.0 (27): the second colour read as a bug).
        terminalView.selectionEchoEnabled = false

        // Right-click menu: the terminal view implements copy:/paste:/selectAll:
        // as responder actions; target nil routes them to the clicked view.
        // Built once per view — it has nothing to do with the theme, and
        // replacing it on every apply() (every theme or font change, for
        // every open tab) can swap the menu out from under an open one.
        guard terminalView.menu == nil else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: String(localized: "Copy"), action: NSSelectorFromString("copy:"), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(localized: "Paste"), action: NSSelectorFromString("paste:"), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Select All"), action: NSSelectorFromString("selectAll:"), keyEquivalent: ""))
        terminalView.menu = menu
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

}
