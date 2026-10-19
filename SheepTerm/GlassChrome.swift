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
        case .glass: return String(localized: "Liquid Glass")
        case .classic: return String(localized: "Solid Color")
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

// Alerts: see SheepAlert.swift. The NSAlert extension that lived here
// (`sheepStyled()`, and the rule "keep every message short enough for
// NSAlert's centred compact layout") went with NSAlert itself in 4.1 (38).

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

/// The host forms' one column (Add Host, New SSH Connection, Edit Host, the
/// web form): every field and popup is this wide, so the right edges line up
/// and a long popup title (a device family) cannot push past the fields.
enum SheetLayout {
    /// Fixed, so the field column starts at the same x in every host form
    /// and does not jump when Add Host switches SSH ↔ Web. Wide enough for
    /// the longest label ("Credential name").
    static let labelWidth: CGFloat = 100
    /// labelWidth + the form's column gap + this = the 360 pt inside the
    /// 20 pt padding, so the fields end where Cancel / Add end.
    static let fieldWidth: CGFloat = 252
    /// The forms' fixed width (their padding is 20 each side).
    static let width: CGFloat = 400
}

extension View {
    /// One row of a host form: `label` in the form's label column, this
    /// control (its own label hidden) filling the field column at
    /// `SheetLayout.fieldWidth` — so every field and popup ends at one edge.
    func formRow(_ label: LocalizedStringKey) -> some View {
        LabeledContent {
            labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(width: SheetLayout.fieldWidth, alignment: .leading)
        } label: {
            SheetLabel(label)
        }
    }
}

/// Add Host's SSH | Web switch, centred above the form.
struct HostKindSwitch: View {
    @Binding var kind: ConnectionKind

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Picker("", selection: $kind) {
                Text("SSH").tag(ConnectionKind.ssh)
                Text("Web").tag(ConnectionKind.web)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        }
    }
}

/// A pop-up menu that FILLS its field column (`formRow`). SwiftUI's menu
/// `Picker` on macOS always sizes to its current title, so in the host forms
/// "Enter manually", "Auto (recommended)" and "Quick Connect" came out three
/// different widths beside full-width text fields (the user, 2026-10-15).
/// The same NSPopUpButton look, stretched.
struct FormPopup<Value: Hashable>: NSViewRepresentable {
    enum Item {
        case option(String, Value)
        case separator
    }

    @Binding var selection: Value
    let items: [Item]

    init(selection: Binding<Value>, items: [Item]) {
        _selection = selection
        self.items = items
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onPick = { index in
            guard index < items.count, case .option(_, let value) = items[index] else { return }
            selection = value
        }
        let signature = items.map { item -> String in
            if case .option(let title, _) = item { return title }
            return "\u{0}separator"
        }
        if context.coordinator.signature != signature {
            context.coordinator.signature = signature
            button.removeAllItems()
            for item in items {
                switch item {
                case .option(let title, _):
                    // Through a menu item, not addItem(withTitle:), which
                    // silently drops a second item with the same title.
                    button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
                case .separator:
                    button.menu?.addItem(.separator())
                }
            }
        }
        // A selection that is not an option (a deleted credential's id):
        // show the first option and write it back, so what Save stores is
        // what the form shows (`FormPopupRule`).
        let options: [(row: Int, value: Value)] = items.enumerated().compactMap { row, item in
            if case .option(_, let value) = item { return (row, value) }
            return nil
        }
        let resolved = FormPopupRule.resolve(selection: selection, options: options.map(\.value))
        if let index = resolved.index {
            let row = options[index].row
            if button.indexOfSelectedItem != row { button.selectItem(at: row) }
        }
        if let corrected = resolved.writeBack {
            DispatchQueue.main.async { selection = corrected }
        }
    }

    final class Coordinator: NSObject {
        var signature: [String] = []
        var onPick: ((Int) -> Void)?
        @objc func picked(_ sender: NSPopUpButton) { onPick?(sender.indexOfSelectedItem) }
    }
}

/// A host form's label at the fixed label-column width, trailing.
struct SheetLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).lineLimit(1).frame(width: SheetLayout.labelWidth, alignment: .trailing)
    }
}
