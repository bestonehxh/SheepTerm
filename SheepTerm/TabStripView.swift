import SwiftUI
import UniformTypeIdentifiers

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
    /// Chip frames in the scroll view's own space (they move as it
    /// scrolls) — what a drop location is compared against.
    @State private var chipDropFrames: [UUID: CGRect] = [:]
    /// Where a pane header (or a sidebar host) dragged over the strip would
    /// land, for the highlight.
    @State private var dropSpot: StripDropSpot?
    @State private var dropConcluded = false
    /// The dragged chip is below the strip, over the panes.
    @State private var chipOverPanes = false

    private static let chipSpacing: CGFloat = 4

    private static let space = "tabstrip"
    private static let dropSpace = "tabstrip-drop"

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
                // One chip per WORKSPACE (a tab of one or more panes): the
                // focused pane's title and the pane count.
                ForEach(model.workspaces) { workspace in
                    if let tab = model.tab(id: workspace.focused) {
                    // Chips get plain values/closures — observing the whole
                    // AppModel per chip would re-render every chip on any
                    // @Published change.
                    TabItemView(
                        tab: tab,
                        paneCount: workspace.paneCount,
                        isSelected: model.selectedWorkspace?.id == workspace.id,
                        isDropTarget: dropSpot == .chip(workspace.id),
                        onSelect: {
                            model.select(workspace: workspace.id)
                            model.collapseSidebar()
                        },
                        onClose: { model.close(workspace: workspace.id) },
                        onReconnect: { model.reconnect(tab: tab) }
                    )
                    .background(GeometryReader { proxy in
                        Color.clear
                            .preference(key: TabChipFrames.self,
                                        value: [workspace.id: proxy.frame(in: .named(Self.space))])
                            .preference(key: TabChipDropFrames.self,
                                        value: [workspace.id: proxy.frame(in: .named(Self.dropSpace))])
                    })
                    .offset(x: dragOffset(for: workspace.id))
                    .zIndex(dragID == workspace.id ? 10 : 0)
                    // The dragged chip tracks the pointer exactly; only the
                    // neighbours' slide is animated (updateDragTarget).
                    .transaction { t in if dragID == workspace.id { t.animation = nil } }
                    // minimumDistance keeps a click a click: the chip's tap
                    // gesture still selects, the × button still closes.
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                            .onChanged { value in handleDrag(workspace.id, value) }
                            .onEnded { _ in finishDrag() }
                    )
                    .id(workspace.id)
                    }
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
        // Pane headers dropped here (4.2 (7)): on a chip = into that tab, on
        // the empty strip = a tab of its own. One drop target for the whole
        // strip, resolved against the chip frames, so a chip and the strip
        // behind it never compete for the same drop.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(dropSpot == .strip ? Theme.controlFill.opacity(0.6) : Color.clear)
        )
        .coordinateSpace(name: Self.dropSpace)
        .onPreferenceChange(TabChipDropFrames.self) { chipDropFrames = $0 }
        .onDrop(of: [.utf8PlainText], delegate: StripDropDelegate(frames: chipDropFrames, spot: $dropSpot, concluded: $dropConcluded))
        .onChange(of: model.selectedID) { _, _ in
            guard dragID == nil, let id = model.selectedWorkspace?.id else { return }
            withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) }
        }
        // The dragged tab closed under the pointer (its shell exited):
        // SwiftUI never sends onEnded for a gesture whose view is gone, and
        // the drop zone stayed on screen (review finding).
        .onChange(of: model.workspaces.map(\.id)) { _, ids in
            if let dragID, !ids.contains(dragID) { resetDrag() }
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
            dragStartOrder = model.workspaces.map(\.id)
            dragSourceIndex = dragStartOrder.firstIndex(of: id)
            dragTargetIndex = dragSourceIndex
        }
        dragTranslation = value.translation.width
        // Pulled down out of the strip, over the panes (4.2 (7)): the pane
        // tree draws where the tab would merge; the order stays as it was.
        let stripBottom = (dragStartFrames[id]?.maxY ?? 26) + 8
        if value.location.y > stripBottom {
            chipOverPanes = true
            // Straight to the tree, synchronously: the zone it writes to
            // `chipDropZone` is current when the mouse goes up.
            model.activePaneTree?.showChipDrag(ChipDrag(workspace: id, screenPoint: NSEvent.mouseLocation))
            if dragTargetIndex != dragSourceIndex {
                withAnimation(.snappy(duration: 0.14)) { dragTargetIndex = dragSourceIndex }
            }
            return
        }
        if chipOverPanes {
            chipOverPanes = false
            model.activePaneTree?.showChipDrag(nil)
            model.chipDropZone = nil
        }
        guard let target = TabOrder.dragTarget(order: dragStartOrder, frames: dragStartFrames,
                                               dragged: id, translation: dragTranslation),
              target != dragTargetIndex else { return }
        withAnimation(.snappy(duration: 0.14)) { dragTargetIndex = target }
    }

    private func finishDrag() {
        // Released over a pane's drop zone: the whole tab joins that pane.
        let merge = chipOverPanes ? model.chipDropZone : nil
        model.activePaneTree?.showChipDrag(nil)
        model.chipDropZone = nil
        chipOverPanes = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let id = dragID, let merge {
                model.mergeWorkspace(id, beside: merge.pane, merge.direction)
            } else if let id = dragID, let source = dragSourceIndex, let target = dragTargetIndex {
                model.moveTab(id: id, toGap: TabOrder.gap(forFinalIndex: target, from: source))
            }
            resetDrag()
        }
    }

    private func resetDrag() {
        model.activePaneTree?.showChipDrag(nil)
        model.chipDropZone = nil
        chipOverPanes = false
        dragID = nil
        dragTranslation = 0
        dragStartFrames = [:]
        dragStartOrder = []
        dragSourceIndex = nil
        dragTargetIndex = nil
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

private struct TabChipDropFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Where a drop on the strip lands.
nonisolated enum StripDropSpot: Equatable, Sendable {
    /// Into this tab (a workspace id).
    case chip(UUID)
    /// The empty strip: a tab of its own.
    case strip
}

/// Pane headers (`pane:<uuid>`) and sidebar hosts (`host:<uuid>`) dropped
/// on the strip. A pane on a chip joins that tab beside its focused pane; a
/// pane on the empty strip gets a tab of its own. A host on a chip opens
/// beside that tab's focused pane; on the empty strip, in a tab of its own.
/// The pasteboard says which; the pane's own tab is not a target.
private struct StripDropDelegate: DropDelegate {
    let frames: [UUID: CGRect]
    @Binding var spot: StripDropSpot?
    /// Set by performDrop, cleared by the next dropEntered.
    @Binding var concluded: Bool

    private func resolve(_ location: CGPoint) -> StripDropSpot? {
        let model = AppModel.shared
        guard let hit = frames.first(where: { $0.value.contains(location) }) else { return .strip }
        guard let workspace = model.book.workspace(id: hit.key) else { return nil }
        // A pane dropped on its own tab's chip would go nowhere; a full tab
        // takes nothing more.
        if let dragged = PaneHeaderView.draggingSession, workspace.layout.contains(dragged) { return nil }
        if workspace.paneCount >= PaneLayout.maxPanes { return nil }
        return .chip(hit.key)
    }

    /// Only a drag that started inside the app (a pane header, a sidebar
    /// row) and carries exactly one item: text from another app that happens
    /// to read `host:<uuid>` must not open a saved host, and a multi-row
    /// sidebar drag has no single host to mean.
    func validateDrop(info: DropInfo) -> Bool {
        info.itemProviders(for: [.utf8PlainText]).count == 1
            && (InternalDrag.pane != nil || InternalDrag.hosts.count == 1)
    }

    func dropEntered(info: DropInfo) {
        concluded = false
        spot = resolve(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // SwiftUI sends one more update ~300 ms after performDrop (measured,
        // 4.2 (7)); taking it at face value left the strip highlighted.
        guard !concluded else { spot = nil; return nil }
        spot = resolve(info.location)
        return DropProposal(operation: spot == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { spot = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = resolve(info.location)
        spot = nil
        concluded = true
        let providers = info.itemProviders(for: [.utf8PlainText])
        guard let target, providers.count == 1, let provider = providers.first else { return false }
        // Read now, while the drag is still "ours": the load completes after
        // the dragging session has ended and `InternalDrag` is cleared.
        let pane = InternalDrag.pane, hosts = InternalDrag.hosts
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let payload = PaneDragPayload(string) else { return }
            switch payload {
            case .pane(let id): guard pane == id else { return }
            case .host(let id): guard hosts == [id] else { return }
            }
            Task { @MainActor in StripDropDelegate.apply(payload, at: target) }
        }
        return true
    }

    @MainActor
    private static func apply(_ payload: PaneDragPayload, at target: StripDropSpot) {
        let model = AppModel.shared
        switch (payload, target) {
        case (.pane(let session), .chip(let workspace)):
            model.movePane(session, toWorkspace: workspace)
        case (.pane(let session), .strip):
            model.movePaneToNewTab(session)
        case (.host(let id), .chip(let workspace)):
            guard let host = model.savedHost(id: id), let ws = model.book.workspace(id: workspace) else { NSSound.beep(); return }
            model.dropHost(host, beside: ws.focused, .right)
        case (.host(let id), .strip):
            guard let host = model.savedHost(id: id) else { NSSound.beep(); return }
            model.open(host: host)
        }
    }
}

private struct TabChipFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TabItemView: View {
    @ObservedObject var tab: SessionTab
    /// Panes in this tab; the chip says so when there is more than one.
    var paneCount: Int = 1
    let isSelected: Bool
    /// A pane header is being dragged over this chip.
    var isDropTarget = false
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
            Text(paneCount > 1 ? "\(tab.title) · \(paneCount)" : tab.title)
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
                .fill(isDropTarget ? Theme.controlFill
                      : isSelected ? Theme.tabActive : (hovering ? Theme.tabActive.opacity(0.5) : Color.clear))
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
