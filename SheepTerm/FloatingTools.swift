import AppKit
import Combine
import SwiftUI

/// Cards that float over the terminal area when asked for (6.1 (9)): a
/// tab's Stopwatch, and Rack Fill in the middle. Nothing shows until the
/// user opens it (tab / pane menu, Tabs ▸ Stopwatch, Tabs ▸ Rack Fill, or
/// the optional bar buttons); each is dragged by its top and closed with ×.
/// A stopwatch lives with its tab; the game lives as long as the app.
@MainActor final class FloatingTools: ObservableObject {
    static let shared = FloatingTools()

    @Published var stopwatches: [UUID: Stopwatch] = [:]
    /// Tabs whose stopwatch card is up.
    @Published var shown: Set<UUID> = []
    @Published var collapsed: Set<UUID> = []
    /// Where a card sits: its offset from the area's top-right corner.
    @Published var offsets: [String: CGSize] = [:]
    @Published var rackFillShown = false

    func toggleStopwatch(for session: UUID) {
        if shown.contains(session) { shown.remove(session) } else { shown.insert(session) }
    }

    func update(_ session: UUID, _ change: (inout Stopwatch) -> Void) {
        var watch = stopwatches[session] ?? Stopwatch()
        change(&watch)
        stopwatches[session] = watch
    }

    /// A tab's stopwatch state, taken out (a reconnect hands it to the successor).
    struct Carried {
        var watch: Stopwatch?
        var shown: Bool
        var collapsed: Bool
        var offset: CGSize?
    }

    func take(_ session: UUID) -> Carried {
        let carried = Carried(watch: stopwatches[session], shown: shown.contains(session),
                              collapsed: collapsed.contains(session), offset: offsets["sw:\(session)"])
        forget(session)
        return carried
    }

    func give(_ carried: Carried, to session: UUID) {
        stopwatches[session] = carried.watch
        if carried.shown { shown.insert(session) }
        if carried.collapsed { collapsed.insert(session) }
        offsets["sw:\(session)"] = carried.offset
    }

    /// A tab closed: its stopwatch goes with it.
    func forget(_ session: UUID) {
        stopwatches[session] = nil
        shown.remove(session)
        collapsed.remove(session)
        offsets["sw:\(session)"] = nil
    }
}

/// Where the bar buttons go (Optimize ▸ Tab Bar): off by default (the owner),
/// top bar right when on.
enum ToolButtonPlace: String, CaseIterable, Identifiable {
    case off, topBar, bottomBar
    var id: String { rawValue }
    static let stopwatchKey = "stopwatchButtonPlace"
    static let rackFillKey = "rackFillButtonPlace"
}

/// The layer over the terminal area: the selected tab's stopwatch, Rack Fill.
struct FloatingToolsOverlay: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var tools = FloatingTools.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Every pane of the tab shown, not only the focused one (Fable: clicking
                // the other pane hid a running watch); each its own spot, stepped down.
                let sessions = (model.selectedWorkspace?.sessions ?? []).filter(tools.shown.contains)
                ForEach(Array(sessions.enumerated()), id: \.element) { index, session in
                    FloatingCard(key: "sw:\(session)", area: geo.size,
                                 // Side by side right to left, a new row when the width runs out —
                                 // never two exactly on top of each other (Fable).
                                 defaultOffset: Stopwatch.cardSpot(index, area: geo.size), centred: false) {
                        StopwatchCard(session: session, title: sessions.count > 1 ? model.tab(id: session)?.title : nil)
                    }
                }
                if tools.rackFillShown {
                    FloatingCard(key: "rackfill", area: geo.size, defaultOffset: .zero, centred: true) {
                        RackFillCard()
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

/// A draggable card: dragged by anywhere that is not a control; kept inside the area.
private struct FloatingCard<Content: View>: View {
    let key: String
    let area: CGSize
    let defaultOffset: CGSize
    let centred: Bool
    @ViewBuilder let content: () -> Content
    @ObservedObject private var tools = FloatingTools.shared
    @State private var size = CGSize(width: 240, height: 200)
    @State private var dragStart: CGSize?

    var body: some View {
        let offset = tools.offsets[key] ?? defaultOrigin
        content()
            .fixedSize()
            .popupChrome()
            // Measured with its chrome, so the clamp keeps the whole glass inside (Fable).
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
            .offset(x: clampX(area.width - size.width - offset.width), y: clampY(offset.height))
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let start = dragStart ?? offset
                    if dragStart == nil { dragStart = offset }
                    // Stored as drawn (clamped): no dead zone after hitting an edge (Fable).
                    let x = clampX(area.width - size.width - (start.width - value.translation.width))
                    let y = clampY(start.height + value.translation.height)
                    tools.offsets[key] = CGSize(width: area.width - size.width - x, height: y)
                }
                .onEnded { _ in dragStart = nil })
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var defaultOrigin: CGSize {
        centred ? CGSize(width: max(0, (area.width - size.width) / 2), height: max(12, (area.height - size.height) / 2))
                : defaultOffset
    }

    private func clampX(_ x: CGFloat) -> CGFloat { min(max(8, x), max(8, area.width - size.width - 8)) }
    private func clampY(_ y: CGFloat) -> CGFloat { min(max(8, y), max(8, area.height - size.height - 8)) }
}

// MARK: Stopwatch

struct StopwatchCard: View {
    let session: UUID
    /// The pane's title, when the tab shows more than one watch.
    var title: String? = nil
    @ObservedObject private var tools = FloatingTools.shared
    @State private var editing: Int?
    @State private var draft = ""
    @FocusState private var noteFocused: Bool
    /// The open note field has had the focus (so losing it is a click-away, not its setup).
    @State private var noteArmed = false

    private var watch: Stopwatch { tools.stopwatches[session] ?? Stopwatch() }
    private var isCollapsed: Bool { tools.collapsed.contains(session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(Theme.dimText)
                Text(title ?? String(localized: "Stopwatch")).font(.system(size: 11)).foregroundStyle(Theme.dimText).lineLimit(1)
                if isCollapsed { time(size: 13) }
                Spacer(minLength: 8)
                iconButton(isCollapsed ? "chevron.down" : "minus", help: isCollapsed ? "Expand" : "Collapse") {
                    if isCollapsed { tools.collapsed.remove(session) } else { tools.collapsed.insert(session) }
                }
                iconButton("xmark", help: "Close") { tools.shown.remove(session) }
            }
            if !isCollapsed {
                time(size: 28)
                HStack(spacing: 6) {
                    pill(watch.isRunning ? "Pause" : (watch.hasStarted ? "Resume" : "Start"), accent: !watch.isRunning) {
                        tools.update(session) { $0.isRunning ? $0.pause(at: Date()) : $0.start(at: Date()) }
                    }
                    pill("Lap", accent: false) { tools.update(session) { $0.lap(at: Date()) } }
                        .disabled(!watch.hasStarted)
                    pill("Reset", accent: false) { tools.update(session) { $0.reset() } }
                        .disabled(!watch.hasStarted)
                }
                // A lap with a word in one click (the owner: Up, Down, Upgrade …).
                HStack(spacing: 4) {
                    ForEach(Stopwatch.quickNotes, id: \.self) { note in
                        Button(note) { tools.update(session) { $0.lap(at: Date(), note: note) } }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Self.color(Stopwatch.tone(note)))
                            .padding(.horizontal, 6).frame(height: 18)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                            .disabled(!watch.hasStarted)
                            .help(String(localized: "A lap noted “\(note)”"))
                    }
                }
                if !watch.laps.isEmpty { laps }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 250, alignment: .leading)
    }

    private func time(size: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: watch.isRunning ? 0.1 : 3600)) { context in
            Text(Stopwatch.text(watch.elapsed(at: context.date)))
                .font(.system(size: size, weight: .semibold).monospacedDigit())
        }
    }

    private var laps: some View {
        VStack(spacing: 0) {
            Divider().padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(watch.laps.reversed()) { lap in
                        HStack(spacing: 6) {
                            Text("\(lap.id)").font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.dimText).frame(width: 18, alignment: .trailing)
                            if editing == lap.id {
                                TextField("Note", text: $draft)
                                    .textFieldStyle(.plain).font(.system(size: 11))
                                    .focused($noteFocused)
                                    .onAppear { DispatchQueue.main.async { noteFocused = true } }
                                    .onSubmit { commitNote(lap.id) }
                                    .onExitCommand { editing = nil }
                                    // Clicking elsewhere keeps what was typed (Fable).
                                    .onChange(of: noteFocused) { _, now in
                                        if now { noteArmed = true } else if noteArmed, editing == lap.id { commitNote(lap.id) }
                                    }
                            } else {
                                Text(lap.note.isEmpty ? "—" : lap.note)
                                    .font(.system(size: 11, weight: lap.note.isEmpty ? .regular : .medium))
                                    .foregroundStyle(lap.note.isEmpty ? Theme.dimText : Self.color(Stopwatch.tone(lap.note)))
                                    .lineLimit(1)
                                    .onTapGesture(count: 2) {
                                        // Another lap's note open: keep what was typed there first (Fable).
                                        if let open = editing { commitNote(open) }
                                        draft = lap.note; noteArmed = false; editing = lap.id
                                    }
                                    .help(String(localized: "Double-click to write a note"))
                            }
                            Spacer(minLength: 4)
                            Text(Stopwatch.text(lap.total)).font(.system(size: 11).monospacedDigit())
                            Text("+" + Stopwatch.text(lap.split)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.dimText)
                        }
                        .frame(height: 18)
                    }
                }
            }
            .frame(height: min(CGFloat(watch.laps.count), 5) * 20)
        }
    }

    private func commitNote(_ id: Int) {
        tools.update(session) { $0.setNote(draft, lap: id) }
        editing = nil
        noteArmed = false
    }

    static func color(_ tone: Stopwatch.Tone) -> Color {
        switch tone {
        case .good: return Theme.ok
        case .bad: return Theme.destructive
        case .work: return Theme.accent
        case .plain: return Theme.tabText
        }
    }

    private func pill(_ title: LocalizedStringKey, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 22)
                .background(Capsule().fill(accent ? Theme.accent.opacity(0.25) : Color.white.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent ? Theme.accent : Theme.tabText)
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.dimText)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Rack Fill

struct RackFillCard: View {
    @ObservedObject private var tools = FloatingTools.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(Theme.dimText)
                Text("Rack Fill").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { tools.rackFillShown = false } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.dimText).help("Close").accessibilityLabel("Close")
            }
            // The same game as Home's tile (`RackFillSession`), bigger.
            RackFillView().frame(width: 340, height: 400)
        }
        .padding(12)
    }
}

/// The optional bar buttons (Optimize ▸ Tab Bar; off by default).
struct ToolBarButtons: View {
    let place: ToolButtonPlace
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var tools = FloatingTools.shared
    @AppStorage(ToolButtonPlace.stopwatchKey) private var stopwatchPlace = ToolButtonPlace.off
    @AppStorage(ToolButtonPlace.rackFillKey) private var rackFillPlace = ToolButtonPlace.off

    var body: some View {
        HStack(spacing: 4) {
            if stopwatchPlace == place {
                Button {
                    if let session = model.selectedID { tools.toggleStopwatch(for: session) } else { NSSound.beep() }
                } label: {
                    ChromeSymbol("stopwatch")
                }
                .buttonStyle(ChromeIconButtonStyle(tint: model.selectedID.map(tools.shown.contains) == true ? Theme.accent : nil))
                .help("Stopwatch for this tab")
                .accessibilityLabel("Stopwatch")
                .disabled(model.selectedID == nil)
            }
            if rackFillPlace == place {
                Button { tools.rackFillShown.toggle() } label: {
                    ChromeSymbol("square.grid.3x3.square")
                }
                .buttonStyle(ChromeIconButtonStyle(tint: tools.rackFillShown ? Theme.accent : nil))
                .help("Rack Fill")
                .accessibilityLabel("Rack Fill")
            }
        }
    }
}
