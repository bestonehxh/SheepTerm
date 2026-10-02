import SwiftUI

/// Session tabs, rendered inside the window toolbar next to the + button.
struct TabStripView: View {
    @ObservedObject private var model = AppModel.shared
    /// Windowed: the window's own border covers the top bar's first point,
    /// so the chips are nudged 1pt down to centre on the row the eye reads
    /// (see the comment below). Fullscreen has no border — the same nudge
    /// there put the chips 1pt BELOW the icons beside them.
    var compensateWindowBorder = true

    /// Drag state, the way SheepText's tab bar does it (4.2 (1)): the real
    /// tab order stays put while dragging; the dragged chip follows the
    /// pointer with no animation, its neighbours slide aside (`.snappy`)
    /// once it crosses their midpoint, and the order is committed once, on
    /// release, without animation. Offsets only — never a live reorder of
    /// `model.tabs` (the sidebar's lesson, ARCHITECTURE §11), and never
    /// `.onDrag` (snap-back). Frames are captured when the drag begins, so a
    /// chip's own offset can never feed back into the geometry.
    @State private var dragID: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var dragStartFrames: [UUID: CGRect] = [:]
    @State private var dragStartOrder: [UUID] = []
    @State private var dragSourceIndex: Int?
    @State private var dragTargetIndex: Int?
    @State private var chipFrames: [UUID: CGRect] = [:]

    private static let chipSpacing: CGFloat = 4

    private static let space = "tabstrip"

    var body: some View {
        // ScrollViewReader so a newly created or ⌘-selected tab is brought
        // into view: with many tabs the active one could sit off-screen with
        // nothing to scroll it back.
        ScrollViewReader { scroller in
        ScrollView(.horizontal, showsIndicators: false) {
            // maxHeight so the chips CENTRE in the strip, plus 2pt of top
            // padding — which shifts them down 1pt, because a centred box
            // absorbs half of it.
            //
            // The 1pt is not arbitrary: the top bar's frame starts at the
            // window's very top, but its first point is covered by the
            // window's own border, so centring in the FRAME lands one point
            // above the row the eye actually reads — the one the traffic
            // lights sit on. Measured against them, not against the frame.
            HStack(spacing: Self.chipSpacing) {
                ForEach(model.tabs) { tab in
                    // Chips get plain values/closures — observing the whole
                    // AppModel per chip would re-render every chip on any
                    // @Published change.
                    TabItemView(
                        tab: tab,
                        isSelected: model.selectedID == tab.id,
                        onSelect: {
                            model.selectedID = tab.id
                            model.collapseSidebar()
                        },
                        onClose: { model.close(tab: tab) },
                        onReconnect: { model.reconnect(tab: tab) }
                    )
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: TabChipFrames.self,
                                               value: [tab.id: proxy.frame(in: .named(Self.space))])
                    })
                    .offset(x: dragOffset(for: tab.id))
                    .zIndex(dragID == tab.id ? 10 : 0)
                    // The dragged chip tracks the pointer exactly; only the
                    // neighbours' slide is animated (updateDragTarget).
                    .transaction { t in if dragID == tab.id { t.animation = nil } }
                    // minimumDistance keeps a click a click: the chip's tap
                    // gesture still selects, the × button still closes.
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                            .onChanged { value in handleDrag(tab.id, value) }
                            .onEnded { _ in finishDrag() }
                    )
                    .id(tab.id)
                }
            }
            // Pointer over the chips = the window is not movable, or the
            // window server turns a chip drag into a window drag (see
            // NonWindowDraggingArea).
            .background(NonWindowDraggingArea())
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(TabChipFrames.self) { chipFrames = $0 }
            .frame(maxHeight: .infinity)
            .padding(.top, compensateWindowBorder ? 2 : 0)
        }
        // Fill the top bar's height rather than a fixed 24, so the chips are
        // centred against the buttons either side of them instead of against
        // a box that is shorter than the bar.
        .frame(maxHeight: .infinity)
        .onChange(of: model.selectedID) { _, id in
            guard dragID == nil, let id else { return }
            withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) }
        }
        }
    }

    /// The dragged chip: the pointer's travel. A neighbour between the
    /// source and the target slot: one chip-width (plus the gap) towards the
    /// hole the dragged chip left. Everything else: where it is.
    private func dragOffset(for id: UUID) -> CGFloat {
        guard let dragID, let source = dragSourceIndex, let target = dragTargetIndex else { return 0 }
        if id == dragID { return dragTranslation }
        guard let index = dragStartOrder.firstIndex(of: id),
              let width = dragStartFrames[dragID]?.width else { return 0 }
        let step = width + Self.chipSpacing
        if target > source, index > source, index <= target { return -step }
        if target < source, index >= target, index < source { return step }
        return 0
    }

    private func handleDrag(_ id: UUID, _ value: DragGesture.Value) {
        if dragID == nil {
            dragID = id
            dragStartFrames = chipFrames
            dragStartOrder = model.tabs.map(\.id)
            dragSourceIndex = dragStartOrder.firstIndex(of: id)
            dragTargetIndex = dragSourceIndex
        }
        dragTranslation = value.translation.width
        guard let target = TabOrder.dragTarget(order: dragStartOrder, frames: dragStartFrames,
                                               dragged: id, translation: dragTranslation),
              target != dragTargetIndex else { return }
        withAnimation(.snappy(duration: 0.14)) { dragTargetIndex = target }
    }

    private func finishDrag() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let id = dragID, let source = dragSourceIndex, let target = dragTargetIndex {
                model.moveTab(id: id, toGap: TabOrder.gap(forFinalIndex: target, from: source))
            }
            dragID = nil
            dragTranslation = 0
            dragStartFrames = [:]
            dragStartOrder = []
            dragSourceIndex = nil
            dragTargetIndex = nil
        }
    }
}

/// Keeps the window from moving while the pointer is over the tab strip.
///
/// The strip sits in the window's titlebar row, and there the WINDOW SERVER
/// starts a window drag on mouse-down before the app sees the event — so
/// pressing a chip and moving dragged the whole window and the reorder
/// gesture never began (4.1 (37); only real HID events show it — events
/// posted straight to the app skip the window server and "worked"). Measured
/// with real drags, none of these stopped it: an AppKit view with
/// `mouseDownCanMoveWindow == false` under the chips, the same as an
/// NSControl, with or without taking hit-tests, nor removing the bar's
/// `WindowDragGesture`. What the window server does honour is
/// `NSWindow.isMovable`, so it is switched off while the pointer is over the
/// strip (a tracking area — no hit-testing, the chips keep every click) and
/// back on when it leaves; the empty bar around the strip still drags the
/// window.
private struct NonWindowDraggingArea: NSViewRepresentable {
    final class View: NSView {
        private weak var trackedWindow: NSWindow?
        private var tracking: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            window?.isMovable = false
            trackedWindow = window
        }

        override func mouseExited(with event: NSEvent) {
            trackedWindow?.isMovable = true
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // Never leave a window immovable behind us.
            trackedWindow?.isMovable = true
            super.viewWillMove(toWindow: newWindow)
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {}
}

private struct TabChipFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TabItemView: View {
    @ObservedObject var tab: SessionTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onReconnect: () -> Void
    @State private var hovering = false

    /// Prefix, not equality: a session that burned its auto-reconnect budget
    /// reports "disconnected — auto-reconnect limit reached", and an exact
    /// compare left that permanently dead tab wearing its connected colour.
    /// (StatusBarView has always used hasPrefix; this was the odd one out.)
    private var isDisconnected: Bool {
        tab.statusInfo?.hasPrefix("disconnected") == true
    }

    private var indicatorColor: Color {
        switch tab.content {
        case .local: return Theme.ok
        case .ssh: return isDisconnected ? Color.red : Theme.accent
        case .serial: return isDisconnected ? Color.red : Theme.warn
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 7, height: 7)
            Text(tab.title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 190)
                .fixedSize(horizontal: true, vertical: false)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.tabActive : (hovering ? Theme.tabActive.opacity(0.5) : Color.clear))
        )
        .foregroundStyle(isSelected ? Theme.tabText : Theme.dimText)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        // The chip is an HStack with a tap gesture, so VoiceOver saw a pile
        // of unrelated labels rather than one selectable tab.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.statusInfo ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Switches to this session")
        // children: .ignore above also swallows the × button, so VoiceOver had
        // no way to close a tab from the strip at all — the whole chip read as
        // one element whose only action was "switch to it".
        .accessibilityAction(named: "Close Tab") { onClose() }
        .onHover { hovering = $0 }
        .contextMenu {
            switch tab.content {
            case .ssh, .serial:
                Button("Reconnect") { onReconnect() }
                Toggle("Highlight", isOn: $tab.highlightEnabled)
                Divider()
            case .local:
                EmptyView()
            }
            Button("Close Tab") { onClose() }
        }
    }
}
