import SwiftUI

/// Session tabs, rendered inside the window toolbar next to the + button.
struct TabStripView: View {
    @ObservedObject private var model = AppModel.shared
    /// Windowed: the window's own border covers the top bar's first point,
    /// so the chips are nudged 1pt down to centre on the row the eye reads
    /// (see the comment below). Fullscreen has no border — the same nudge
    /// there put the chips 1pt BELOW the icons beside them.
    var compensateWindowBorder = true

    /// The tab being dragged and where the pointer is, in the strip's own
    /// coordinate space. Reordering follows the sidebar's lesson
    /// (ARCHITECTURE §11): no `.onDrag` (its snap-back cannot be switched
    /// off), neighbours do NOT shuffle live — only the dragged chip follows
    /// the pointer and an insertion bar marks the gap — and the move is
    /// committed once, on release, without animation.
    /// GestureState, not State: a drag the system cancels (the chip vanishes
    /// mid-drag, the window loses the mouse) resets itself instead of leaving
    /// a chip parked off its slot.
    @GestureState private var drag: TabDrag?
    @State private var chipFrames: [UUID: CGRect] = [:]

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
            HStack(spacing: 4) {
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
                    .offset(x: drag?.id == tab.id ? drag?.translation ?? 0 : 0)
                    .zIndex(drag?.id == tab.id ? 1 : 0)
                    .opacity(drag?.id == tab.id ? 0.85 : 1)
                    // minimumDistance keeps a click a click: the chip's tap
                    // gesture still selects, the × button still closes.
                    .gesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
                            .updating($drag) { value, state, _ in
                                state = TabDrag(id: tab.id, translation: value.translation.width,
                                                pointerX: value.location.x)
                            }
                            .onEnded { value in commitDrag(tab.id, pointerX: value.location.x) }
                    )
                    .id(tab.id)
                }
            }
            .overlay(alignment: .topLeading) { insertionBar }
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
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) }
        }
        }
    }

    /// The gap the pointer is over, counted before the dragged tab is
    /// removed (`TabOrder`'s convention). Only the OTHER chips are measured:
    /// the dragged chip's reported frame travels with its offset, so it would
    /// count itself depending on which side of the pointer its centre is.
    private func dropGap(dragging id: UUID, pointerX: CGFloat) -> Int {
        let tabs = model.tabs
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return 0 }
        let othersLeft = tabs.filter { tab in
            guard tab.id != id, let frame = chipFrames[tab.id] else { return false }
            return frame.midX < pointerX
        }.count
        return TabOrder.dragGap(othersLeftOfPointer: othersLeft, from: from)
    }

    /// Accent bar in the gap the tab will land in — hidden while the drop
    /// would leave it where it is.
    @ViewBuilder private var insertionBar: some View {
        if let drag, let from = model.tabs.firstIndex(where: { $0.id == drag.id }),
           case let gap = dropGap(dragging: drag.id, pointerX: drag.pointerX),
           TabOrder.destination(from: from, toGap: gap, count: model.tabs.count) != nil {
            let tabs = model.tabs
            let x: CGFloat? = gap < tabs.count
                ? chipFrames[tabs[gap].id].map { $0.minX - 3 }
                : chipFrames[tabs[tabs.count - 1].id].map { $0.maxX + 1 }
            if let x, let reference = chipFrames[drag.id] {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 2, height: reference.height)
                    .offset(x: x, y: reference.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func commitDrag(_ id: UUID, pointerX: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.moveTab(id: id, toGap: dropGap(dragging: id, pointerX: pointerX))
        }
    }
}

private struct TabDrag {
    let id: UUID
    let translation: CGFloat
    let pointerX: CGFloat
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
