import AppKit
import SwiftUI

/// How the app's chrome (sidebar, tab bar) is painted. Stored under
/// "chromeStyle"; `glass` is the default.
///
/// This picks the MATERIAL only. The layout is the same either way: the
/// sidebar is a full-height column that owns the traffic-light row and the
/// tab bar sits over the detail pane alone. Classic just paints that same
/// layout with the flat `Theme.chrome` tile instead of glass.
enum ChromeStyle: String, CaseIterable, Identifiable {
    case glass
    case classic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glass: return "Liquid Glass"
        case .classic: return "Solid Color"
        }
    }

    /// Every reader is a SwiftUI view holding `@AppStorage(storageKey)`, so the
    /// chrome re-renders the moment the setting changes.
    static let storageKey = "chromeStyle"
}

/// The chrome surfaces that can be painted. The status bar is deliberately
/// never glass: it is a dense strip of 11pt dim monospace, not a floating
/// control layer, and glass only costs it contrast.
enum ChromeZone {
    case sidebar, topBar, statusBar
    /// Every sheet the app puts up. One zone for all of them so they cannot
    /// drift apart — a sheet that paints itself is the thing this file exists
    /// to prevent.
    case sheet

    func isGlass(_ style: ChromeStyle) -> Bool {
        style == .glass && self != .statusBar
    }
}

/// Background for one chrome surface. Uses `.background { }` (the view builder
/// form) at every call site — unlike the ShapeStyle form it does not expand
/// into the titlebar safe area, so the `ignoresSafeAreaEdges: []` guard the
/// flat version needed is unnecessary here.
struct ChromeBackground: View {
    let zone: ChromeZone
    @AppStorage(ChromeStyle.storageKey) private var style = ChromeStyle.glass

    var body: some View {
        if zone.isGlass(style) {
            // `.popover` at a sheet's size: `.sidebar` is tuned for a tall
            // narrow column and goes flat and grey over a 700 pt panel, and
            // `.headerView` is a thin strip's material. `.hudWindow` is
            // darker than the sidebar in light mode, which made a sheet look
            // like a different app's window.
            VisualEffectBackground(material: material)
        } else {
            Theme.chrome
        }
    }

    private var material: NSVisualEffectView.Material {
        switch zone {
        case .sidebar: return .sidebar
        case .sheet: return .popover
        case .topBar, .statusBar: return .headerView
        }
    }
}

/// Fill for a control sitting ON a chrome surface (the sidebar search field,
/// the ⌘K palette's field). A translucent tint over glass reads muddy — the
/// glass shows through the control and it stops looking like a field — so on
/// a glass surface the fill goes opaque instead.
struct ControlFill: View {
    let zone: ChromeZone
    var cornerRadius: CGFloat = 7
    @AppStorage(ChromeStyle.storageKey) private var style = ChromeStyle.glass

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(zone.isGlass(style) ? Theme.controlFill : Color.primary.opacity(0.07))
    }
}

/// The chrome every sheet wears. One modifier, applied to every sheet body,
/// so a new sheet is glass by construction and the setting reaches all of
/// them at once.
///
/// `presentationBackground` (macOS 13.3+) replaces the system's own sheet
/// material — which is what makes a sheet look like a sheet and not like a
/// panel with a tinted rectangle drawn inside it.
extension View {
    func sheepSheetChrome() -> some View {
        presentationBackground { ChromeBackground(zone: .sheet) }
    }
}

extension NSAlert {
    /// Every alert in the app goes through here, and what it is for is the
    /// RULE written below — there is nothing to set.
    ///
    /// **Layout.** NSAlert picks the wide layout (icon on the left) as soon
    /// as the text block needs more than about three rendered lines; the
    /// compact one (icon centred above the text) is what we want. Measured
    /// with a throwaway alert at the real width: a one-line `messageText`
    /// (≈30 characters) with an `informativeText` of ≈45 stays compact, and
    /// 66 characters of informative text flips it. So counts go on the
    /// message line and the detail stays one short line. Two places cannot
    /// be short and are deliberately left wide: an import's hygiene report
    /// (it names changes to the user's own data) and the Replace/Keep dialog
    /// (accessory checkbox plus a diff).
    ///
    /// **Appearance.** Nothing to do: the app sets `NSApp.appearance` to
    /// `.darkAqua` once at launch (4.0 (5)) and an alert's own window
    /// inherits it. An explicit assignment here was a no-op with a comment
    /// claiming otherwise, which is worse than no code at all.
    ///
    /// It stays a function so there is ONE place to change if either of those
    /// ever stops being true, and so every `runModal()` in the app reads the
    /// same.
    @discardableResult
    func sheepStyled() -> NSAlert { self }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        // The app is dark only (4.0 (5)); a visual-effect view takes its
        // light/dark from the window it lands in, and a sheet or panel that
        // inherits from somewhere else would come up as LIGHT glass under
        // dark text.
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
