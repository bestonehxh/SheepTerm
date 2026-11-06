import AppKit
import SwiftUI

/// Views the console card stands clear of (`SerialArrivalCard.frame`): the
/// connection card, the dangerous-command card, a pane header, the status
/// HUD and the baud hint. A marker, nothing more.
protocol CornerObstacle: NSView {}
extension ConnectionCardView: CornerObstacle {}
extension CommandGuardCardView: CornerObstacle {}
extension PaneHeaderView: CornerObstacle {}
extension ArrowCursorEffectView: CornerObstacle {}
extension BaudHintView: CornerObstacle {}

/// The console card's layer over the terminal area (6.0 (14), design "B";
/// it replaced the shadow chip at the end of the tab strip). `DetailPane`
/// lays it over the workspace — above the status bar, left of the AI panel —
/// so it can cover neither. It draws `model.serialCard.card` only in the
/// window that card names (one card in the app), where `SerialArrivalCard.frame`
/// puts it; with no clear spot it yields (hidden, time paused). One SwiftUI
/// view per window: it goes with the window, no panel or child window.
struct SerialArrivalCardOverlay: View {
    @EnvironmentObject private var model: AppModel
    @State private var windowNumber: Int?
    @State private var obstacles: [CGRect] = []
    @State private var cardSize = CGSize(width: 316, height: 150)
    @State private var probe = SerialCardProbe.Box()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                SerialCardProbe(box: probe) { windowNumber = $0 }
                    .allowsHitTesting(false)
                if let card = model.serialCard.card, card.window == windowNumber {
                    let frame = SerialArrivalCard.frame(area: geo.size, card: cardSize, obstacles: obstacles)
                    let content = SerialArrivalCardContent(card: card, send: { model.serialCardEvent($0) },
                                                           onConnect: { model.connectSerialCard(path: $0) },
                                                           onConnectAll: { model.connectAllSerialCards(split: $0) })
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self, of: { $0.size }) { cardSize = $0 }
                    Group {
                        if let frame, !card.pauses.contains(.hidden) {
                            content
                                .offset(x: frame.minX, y: frame.minY)
                                .transition(.opacity)
                        } else if !card.pauses.contains(.hidden) {
                            // Yielding: still laid out, unseen and untouchable, so its size
                            // follows its rows — a row going can give it its spot back
                            // (Fable round 14: it stayed hidden at the old, taller size).
                            content
                                .opacity(0)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    // Keyed on the generation too: a replacement card that arrives while the
                    // corner is still blocked starts with no pauses and must yield at once.
                    .onChange(of: YieldKey(generation: card.generation, blocked: frame == nil), initial: true) { _, key in
                        model.serialCardEvent(key.blocked ? .pause(.yield) : .resume(.yield))
                    }
                    // What it stands clear of, re-read while it is up (≤ 15 s plus pauses).
                    .task(id: card.generation) {
                        while !Task.isCancelled {
                            let now = probe.obstacles()
                            if now != obstacles { obstacles = now }
                            try? await Task.sleep(for: .milliseconds(400))
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

/// What the yield check watches: the card (by generation) and whether it has a spot.
private struct YieldKey: Equatable {
    let generation: Int
    let blocked: Bool
}

/// Knows the window the overlay is in, and reads the obstacles in the
/// overlay's own (top-left) coordinates: `CornerObstacle` views anywhere in
/// the window, the window's child windows (a connection card's panel) and an
/// open popover (the File Server's).
struct SerialCardProbe: NSViewRepresentable {
    final class Box {
        weak var view: NSView?

        @MainActor func obstacles() -> [CGRect] {
            guard let view, let window = view.window else { return [] }
            var rects: [CGRect] = []
            func walk(_ v: NSView) {
                if v is CornerObstacle {
                    if !v.isHiddenOrHasHiddenAncestor, v.bounds.width > 0, v.bounds.height > 0 {
                        rects.append(v.convert(v.bounds, to: view))
                    }
                    return
                }
                for sub in v.subviews { walk(sub) }
            }
            if let content = window.contentView { walk(content) }
            var others = (window.childWindows ?? []).filter(\.isVisible)
            others += NSApp.windows.filter { $0.isVisible && $0 !== window && String(describing: type(of: $0)).contains("Popover") }
            for other in Set(others.map(ObjectIdentifier.init)).compactMap({ id in others.first { ObjectIdentifier($0) == id } }) {
                let inWindow = window.convertFromScreen(other.frame)
                rects.append(view.convert(inWindow, from: nil))
            }
            return rects.map { $0.intersection(view.bounds) }.filter { !$0.isNull && !$0.isEmpty }
        }
    }

    let box: Box
    let onWindow: (Int?) -> Void

    final class Probe: NSView {
        var onWindow: ((Int?) -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let number = window?.windowNumber
            DispatchQueue.main.async { [weak self] in self?.onWindow?(number) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onWindow = onWindow
        box.view = view
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.onWindow = onWindow
        box.view = view
    }
}

/// Design "B": the cable icon, "Console cable", ×; the device name and kind;
/// the speed menu and Connect. The popups' glass and accent button.
/// Several cables (6.1 (3)): "Console cables · N", a row per cable (name,
/// kind, speed, Connect), then Connect All / Open All in Split.
struct SerialArrivalCardContent: View {
    let card: SerialArrivalCard.Card
    let send: (SerialArrivalCard.Event) -> Void
    let onConnect: (String) -> Void
    let onConnectAll: (_ split: Bool) -> Void
    @FocusState private var fieldFocused: Bool

    private static let rowHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(card.isList ? String(localized: "Console cables · \(card.rows.count)") : String(localized: "Console cable"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { send(.dismiss) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(String(localized: "Dismiss"))
            }
            if card.isList { list } else if let row = card.rows.first { single(row) }
            if let error = card.custom?.error {
                Text(Self.text(error))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.destructive)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: card.isList ? 340 : 280)
        .popupChrome()
        .pointerStyle(.default)
        .onHover { send($0 ? .pause(.hover) : .resume(.hover)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(card.isList ? "Console cables" : "Console cable \(card.rows.first?.detail ?? "")"))
        .accessibilityAction(named: "Open") {
            if card.isList { onConnectAll(false) } else if let row = card.rows.first { onConnect(row.path) }
        }
        .accessibilityAction(named: "Dismiss") { send(.dismiss) }
    }

    /// One cable: the card as it always was.
    @ViewBuilder private func single(_ row: SerialArrivalCard.Row) -> some View {
        Text(row.detail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        HStack(spacing: 10) {
            speedControl(row)
            Spacer(minLength: 0)
            CardButton(String(localized: "Connect"), role: .accent,
                       help: String(localized: "Open this console at \(String(row.baud)) baud")) { onConnect(row.path) }
                .frame(width: 100)
        }
        .padding(.top, 4)
    }

    /// Several: a row each (scrolling past `visibleRows`), then both "all" buttons.
    @ViewBuilder private var list: some View {
        let rows = VStack(spacing: 0) {
            ForEach(card.rows, id: \.path) { row in listRow(row) }
        }
        Group {
            if card.rows.count > SerialArrivalCard.visibleRows {
                ScrollView { rows }
                    .frame(height: Self.rowHeight * CGFloat(SerialArrivalCard.visibleRows))
            } else {
                rows
            }
        }
        .padding(.top, 2)
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            CardButton(String(localized: "Connect All"), role: .neutral,
                       help: String(localized: "Each console in its own tab")) { onConnectAll(false) }
                .fixedSize()
            CardButton(String(localized: "Open All in Split"), role: .accent,
                       help: String(localized: "All consoles in one tab, side by side")) { onConnectAll(true) }
                .fixedSize()
        }
        .padding(.top, 6)
    }

    private func listRow(_ row: SerialArrivalCard.Row) -> some View {
        HStack(spacing: 8) {
            // The device name whole; a long kind ("HPN Serial Port") gives way.
            Text(row.detail)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.detail)
            Spacer(minLength: 4)
            speedControl(row)
            Button(String(localized: "Connect")) { onConnect(row.path) }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .help(String(localized: "Open this console at \(String(row.baud)) baud"))
        }
        .frame(height: Self.rowHeight)
    }

    @ViewBuilder private func speedControl(_ row: SerialArrivalCard.Row) -> some View {
        if let custom = card.custom, SerialArrival.calloutPath(custom.path) == SerialArrival.calloutPath(row.path) {
            customField(custom)
        } else {
            speedMenu(row)
        }
    }

    private func speedMenu(_ row: SerialArrivalCard.Row) -> some View {
        Menu {
            ForEach(SerialArrivalCard.menuRates, id: \.self) { rate in
                Button {
                    send(.pickBaud(path: row.path, rate))
                } label: {
                    if rate == row.baud { Label(String(rate), systemImage: "checkmark") } else { Text(String(rate)) }
                }
            }
            Divider()
            Button(String(localized: "Other…")) { send(.openCustom(path: row.path)) }
        } label: {
            Text(card.isList ? String(row.baud) : "\(String(row.baud)) baud")
                .font(.system(size: card.isList ? 11.5 : 12, weight: .medium).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, card.isList ? 8 : 10)
        .frame(height: card.isList ? 22 : 26)
        .background(Capsule().fill(Color.primary.opacity(0.1)))
        .help(String(localized: "Speed"))
    }

    private func customField(_ custom: SerialArrivalCard.Custom) -> some View {
        TextField(String(localized: "Baud"), text: Binding(get: { custom.text },
                                                           set: { send(.editCustom($0)) }))
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .focused($fieldFocused)
            .focusEffectDisabled()
            .onSubmit { send(.submitCustom) }
            .onExitCommand { send(.cancelCustom) }
            .noAutoFill()
            .padding(.horizontal, 10)
            .frame(width: card.isList ? 90 : 110, height: card.isList ? 22 : 26)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
            .overlay(Capsule().stroke(custom.error == nil ? Theme.accent.opacity(0.7) : Theme.destructive, lineWidth: 1))
            .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    static func text(_ error: SerialArrivalCard.CustomError) -> String {
        switch error {
        case .notANumber: return String(localized: "Type a whole number")
        case .outOfRange: return String(localized: "50 – 4000000 baud")
        }
    }
}
