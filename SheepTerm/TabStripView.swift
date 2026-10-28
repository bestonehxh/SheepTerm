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
    /// The chips' frames as they were when a drop drag came over the strip,
    /// before any slid aside for the ghost — a measured frame follows the
    /// `.offset`, so the live ones would move under the pointer. Drop space
    /// for hit-testing, the chips' own space for placing the ghost.
    @State private var dropBaseFrames: [UUID: CGRect] = [:]
    @State private var ghostBaseFrames: [UUID: CGRect] = [:]
    /// The dragged chip is below the strip, over the panes.
    @State private var chipOverPanes = false
    /// Bumped on every strip-width change; only the last one reveals.
    @State private var widthSettle = 0

    private static let chipSpacing: CGFloat = 4
    /// How far the chips past a drop gap slide to make room for the ghost.
    static let ghostShift = TabChipMetrics.dragSize.width + chipSpacing
    private static let serialShadowID = "serial-shadow"

    private static let space = "tabstrip"
    private static let dropSpace = "tabstrip-drop"

    var body: some View {
        // ScrollViewReader so the active tab is brought into view: with many
        // tabs it could sit off-screen with nothing to scroll it back. See
        // `reveal` for when and why it waits a turn.
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
                            // A click on the tab that is already selected
                            // changes no selection, so onChange below never
                            // hears of it — and it may be half under the edge.
                            if model.selectedWorkspace?.id == workspace.id { reveal(scroller) }
                            model.select(workspace: workspace.id)
                            model.collapseSidebar()
                        },
                        onClose: { model.requestClose(workspace: workspace.id) },
                        onReconnect: { model.reconnect(tab: tab) },
                        onDuplicate: { model.duplicate(tab: tab) },
                        onCopyAllOutput: { model.copyAllOutput(tab: tab) }
                    )
                    .background(GeometryReader { proxy in
                        Color.clear
                            .preference(key: TabChipFrames.self,
                                        value: [workspace.id: proxy.frame(in: .named(Self.space))])
                            .preference(key: TabChipDropFrames.self,
                                        value: [workspace.id: proxy.frame(in: .named(Self.dropSpace))])
                    })
                    .offset(x: dragOffset(for: workspace.id) + ghostShift(for: workspace.id))
                    // Pulled down over the panes: the panes' chip ghost
                    // follows the pointer instead (PaneTreeView.showChipGhost).
                    .opacity(dragID == workspace.id && chipOverPanes ? 0 : 1)
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
                // A USB serial cable just plugged in (5.0 (29)).
                if let shadow = model.serialShadow {
                    SerialShadowChip(name: shadow.name,
                                     onOpen: { model.openSerialShadow() },
                                     onDismiss: { model.dismissSerialShadow() })
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .offset(x: ghostGap == nil ? 0 : Self.ghostShift)
                        .id(Self.serialShadowID)
                }
            }
            // Pointer over the chips = the window is not movable, or the
            // window server turns a chip drag into a window drag (see
            // NonWindowDraggingArea).
            .background(NonWindowDraggingArea())
            // A pane header between chips or past the last (6.0 (3)): the
            // chips from that gap on slide right (an offset — their measured
            // frames stay put) and the ghost of the new tab fills the hole.
            .overlay(alignment: .topLeading) {
                if let gap = ghostGap, let ghost = StripDropGhost.current(), let origin = ghostOrigin(gap) {
                    StripDropGhostChip(ghost: ghost)
                        .offset(x: origin.x, y: origin.y)
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.14), value: dropSpot)
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(TabChipFrames.self) { chipFrames = $0 }
            .frame(maxHeight: .infinity)
            .padding(.top, compensateWindowBorder ? 2 : 0)
        }
        // Fill the top bar's height rather than a fixed 24, so the chips are
        // centred against the buttons either side of them instead of against
        // a box that is shorter than the bar.
        .frame(maxHeight: .infinity)
        // The strip narrowed (sidebar or AI panel opened, window resized):
        // the active tab may now be past its edge. The new width arrives at
        // the START of the panel's 0.15 s animation, while the scroll view is
        // still wide — scrolling then left the tab 12 pt short (measured) —
        // so wait for the last change to settle; a live resize scrolls once,
        // when it stops.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _ in
            widthSettle += 1
            let mine = widthSettle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if widthSettle == mine { reveal(scroller) }
            }
        }
        // Pane headers dropped here (4.2 (7)): on a chip = into that tab, on
        // a gap between chips or the empty strip = a tab of its own there
        // (shown by the ghost chip). One drop target for the whole strip,
        // resolved against the chip frames, so a chip and the strip behind it
        // never compete for the same drop.
        .coordinateSpace(name: Self.dropSpace)
        .onPreferenceChange(TabChipDropFrames.self) { chipDropFrames = $0 }
        .onDrop(of: [.utf8PlainText], delegate: StripDropDelegate(frames: chipDropFrames, base: $dropBaseFrames,
                                                                   chipFrames: chipFrames, ghostBase: $ghostBaseFrames,
                                                                   spot: $dropSpot, concluded: $dropConcluded))
        // Brought into view when it appears past a full strip (review 5.0 (29)).
        .onChange(of: model.serialShadow?.path) { _, path in
            guard path != nil else { return }
            // A turn later, like `reveal`: the chip has no frame yet.
            DispatchQueue.main.async {
                guard dragID == nil, model.serialShadow != nil else { return }
                withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(Self.serialShadowID) }
            }
        }
        .onChange(of: model.selectedID) { _, _ in reveal(scroller) }
        // The dragged tab closed under the pointer (its shell exited):
        // SwiftUI never sends onEnded for a gesture whose view is gone, and
        // the drop zone stayed on screen (review finding).
        .onChange(of: model.workspaces.map(\.id)) { old, ids in
            if let dragID, !ids.contains(dragID) { resetDrag() }
            // A tab closed to the left of the active one slides it left, maybe
            // past the edge. Count only: a drag-reorder is not a reason to
            // scroll away from where the user dropped.
            if old.count != ids.count { reveal(scroller) }
        }
        }
    }

    /// Scroll the active tab wholly into view (the minimum amount; none when
    /// it already is). Waits one main-queue turn: when the selection changes,
    /// the chip has not been laid out yet — a new tab has no frame at all,
    /// and the selected chip turns semibold (wider) in the same update — so
    /// scrolling at once measured the old geometry and left the tab half
    /// under the strip's edge (6.0 (2)). Never during a chip drag.
    private func reveal(_ scroller: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard dragID == nil, let id = model.selectedWorkspace?.id else { return }
            withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) }
        }
    }

    /// The gap a pane header (or sidebar host) is over, if any.
    private var ghostGap: Int? {
        if case .gap(let gap) = dropSpot { return gap }
        return nil
    }

    /// A chip at or past the open drop gap slides right by the ghost's width.
    private func ghostShift(for id: UUID) -> CGFloat {
        guard let gap = ghostGap, let index = model.workspaces.firstIndex(where: { $0.id == id }), index >= gap else { return 0 }
        return Self.ghostShift
    }

    /// Where the ghost goes in the chips' own space: the left edge of the
    /// chip at `gap` (before it slides), or past the last chip.
    private func ghostOrigin(_ gap: Int) -> CGPoint? {
        let ids = model.workspaces.map(\.id)
        let frames = ghostBaseFrames.isEmpty ? chipFrames : ghostBaseFrames
        guard let reference = ids.first.flatMap({ frames[$0] }) else { return nil }
        let y = reference.midY - TabChipMetrics.dragSize.height / 2
        if gap < ids.count, let frame = frames[ids[gap]] { return CGPoint(x: frame.minX, y: y) }
        guard let last = ids.last.flatMap({ frames[$0] }) else { return nil }
        return CGPoint(x: last.maxX + Self.chipSpacing, y: y)
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
    func makeNSView(context: Context) -> WindowDragGateView { WindowDragGateView(frame: .zero) }
    func updateNSView(_ nsView: WindowDragGateView, context: Context) {}
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
    /// A tab of its own in this gap (`TabOrder`'s convention; the count =
    /// after the last chip).
    case gap(Int)
}

/// Pane headers (`pane:<uuid>`) and sidebar hosts (`host:<uuid>`) dropped
/// on the strip. A pane on a chip joins that tab beside its focused pane; a
/// pane on the empty strip gets a tab of its own. A host on a chip opens
/// beside that tab's focused pane; on the empty strip, in a tab of its own.
/// The pasteboard says which; the pane's own tab is not a target.
private struct StripDropDelegate: DropDelegate {
    let frames: [UUID: CGRect]
    /// `frames` as they were when the drag came over the strip (see
    /// `TabStripView.dropBaseFrames`).
    @Binding var base: [UUID: CGRect]
    /// The chips' own-space frames, and their copy taken with `base` (the
    /// ghost's place; taken here, before the first shift — an onChange of
    /// the spot came a frame late and put the ghost over a slid chip).
    let chipFrames: [UUID: CGRect]
    @Binding var ghostBase: [UUID: CGRect]
    @Binding var spot: StripDropSpot?
    /// Set by performDrop, cleared by the next dropEntered.
    @Binding var concluded: Bool

    private func resolve(_ location: CGPoint) -> StripDropSpot? {
        let model = AppModel.shared
        let ids = model.workspaces.map(\.id)
        let measured = ids.compactMap { (base.isEmpty ? frames : base)[$0] }
        guard measured.count == ids.count else { return .gap(ids.count) }
        let open: Int? = { if case .gap(let gap) = spot { return gap }; return nil }()
        let hit = TabOrder.stripHit(x: location.x, frames: measured, open: open,
                                    shift: TabStripView.ghostShift, spacing: 4)
        // A sidebar host opens past the last tab (or into a chip's tab).
        let isPane = PaneHeaderView.draggingSession != nil
        switch hit {
        case .gap(let gap):
            return .gap(isPane ? gap : ids.count)
        case .chip(let index):
            if let joined = chipSpot(ids[index]) { return joined }
            guard isPane else { return nil }
            // A chip that takes no more (its own tab, a full one): the gap on
            // the near side of it.
            let frame = measured[index].offsetBy(dx: open.map { index >= $0 ? TabStripView.ghostShift : 0 } ?? 0, dy: 0)
            return .gap(location.x < frame.midX ? index : index + 1)
        }
    }

    private func chipSpot(_ id: UUID) -> StripDropSpot? {
        let model = AppModel.shared
        guard let workspace = model.book.workspace(id: id) else { return nil }
        // A pane dropped on its own tab's chip would go nowhere; a full tab
        // takes nothing more.
        if let dragged = PaneHeaderView.draggingSession, workspace.layout.contains(dragged) { return nil }
        if workspace.paneCount >= PaneLayout.maxPanes { return nil }
        // A move that would squeeze a Ping pane is refused (PaneLayout.keepsWhole).
        if let dragged = PaneHeaderView.draggingSession {
            var trial = model.book
            if !trial.move(session: dragged, toWorkspace: id) { return nil }
        } else if !InternalDrag.hosts.isEmpty, !model.book.canSplit(beside: workspace.focused, .right) {
            // A sidebar host into a tab whose layout would squeeze a Ping
            // pane: no chip zone (it lit, then beeped — review 6.0 (2)).
            return nil
        }
        return .chip(id)
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
        if spot == nil {
            base = frames
            ghostBase = chipFrames
        }
        spot = resolve(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // SwiftUI sends one more update ~300 ms after performDrop (measured,
        // 4.2 (7)); taking it at face value left the strip highlighted.
        guard !concluded else { spot = nil; return nil }
        spot = resolve(info.location)
        return DropProposal(operation: spot == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        spot = nil
        base = [:]
        ghostBase = [:]
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = resolve(info.location)
        spot = nil
        base = [:]
        ghostBase = [:]
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
        case (.pane(let session), .gap(let gap)):
            model.movePaneToNewTab(session, toGap: gap)
        case (.host(let id), .chip(let workspace)):
            guard let host = model.savedHost(id: id), let ws = model.book.workspace(id: workspace) else { NSSound.beep(); return }
            model.dropHost(host, beside: ws.focused, .right)
        case (.host(let id), .gap):
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
    var onDuplicate: () -> Void = {}
    var onCopyAllOutput: () -> Void = {}
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
        case .ssh: return isDisconnected ? Theme.destructive : Theme.accent
        case .serial(let c): return isDisconnected ? Theme.destructive : c.isTelnet ? Theme.accent : Theme.warn
        case .web: return Theme.web
        case .files: return isDisconnected ? Theme.destructive : Theme.accent
        case .ping: return Theme.ok
        }
    }

    private var isWeb: Bool {
        if case .web = tab.content { return true }
        return false
    }

    private var isFiles: Bool {
        if case .files = tab.content { return true }
        return false
    }

    private var isPing: Bool {
        if case .ping = tab.content { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 7) {
            // A web tab wears its site's icon (else a globe), the others the dot.
            if isWeb, let icon = tab.favicon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 12, height: 12)
            } else if isWeb || isFiles || isPing {
                Image(systemName: isPing ? "waveform.path.ecg" : isFiles ? "folder" : "globe")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(indicatorColor)
                    .frame(width: 9, height: 9)
            } else {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 7, height: 7)
            }
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
        .accessibilityValue(StatusInfoDisplay.text(tab.statusInfo) ?? "")
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
                if case .ssh = tab.content {
                    Button("Duplicate") { onDuplicate() }
                    Button("Open File") {
                        AppModel.shared.selectedID = tab.id
                        AppModel.shared.openFilesForSelectedTab()
                    }
                    Button("Ping") { AppModel.shared.pingTab(tab) }
                }
                Toggle("Highlight", isOn: $tab.highlightEnabled)
                Divider()
                Button("Copy All Output") { onCopyAllOutput() }
                Divider()
            case .web:
                Button("Reload") { onReconnect() }
                Button("Save as Host…") { AppModel.shared.saveWebTabAsHost(tab) }
                Divider()
            case .files:
                Button("Reconnect") { onReconnect() }
                Divider()
            case .ping:
                Button("Restart All") { onReconnect() }
                Divider()
            case .local:
                Button("Copy All Output") { onCopyAllOutput() }
                Divider()
            }
            Button("Close Tab") { onClose() }
        }
    }
}

/// One look for every dragged pane and every drop ghost, so the eye reads
/// "a tab" whatever is moving: a chip's height, a typical chip's width, the
/// session's dot and its own title, cut short with … when it is long.
enum TabChipMetrics {
    static let dragSize = CGSize(width: 180, height: 24)
    static let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
}

/// What the ghost chip shows: the dragged pane's dot and title, or the
/// dragged sidebar host's name.
struct StripDropGhost {
    let title: String
    let color: Color

    @MainActor
    static func current() -> StripDropGhost? {
        let model = AppModel.shared
        if let session = PaneHeaderView.draggingSession, let tab = model.tab(id: session) {
            return StripDropGhost(title: tab.title,
                                  color: Color(nsColor: PaneHeaderView.dotColor(of: tab, status: tab.statusInfo)))
        }
        if InternalDrag.hosts.count == 1, let id = InternalDrag.hosts.first, let host = model.savedHost(id: id) {
            return StripDropGhost(title: host.name, color: Theme.dimText)
        }
        return nil
    }
}

/// The tab a drop on the strip would create. It wears the USB serial
/// shadow chip's look (the user: not a dashed outline) — clear white, a
/// hairline edge, a soft glow that breathes (still with Reduce Motion).
/// Never takes a click: the drop lands on the strip behind it.
private struct StripDropGhostChip: View {
    let ghost: StripDropGhost
    @State private var glowUp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ghost.color)
                .frame(width: 7, height: 7)
            Text(ghost.title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: TabChipMetrics.dragSize.width, height: TabChipMetrics.dragSize.height)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
        .shadow(color: Color.white.opacity(reduceMotion ? 0.6 : (glowUp ? 0.7 : 0.2)), radius: 6)
        .foregroundStyle(Color.white)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { glowUp = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The dashed "shadow" tab for a USB serial cable that was just plugged in
/// (5.0 (29), the user's option 1): click = open that console; it goes on
/// its own after 15 s, when the cable is pulled, or with its ×.
private struct SerialShadowChip: View {
    let name: String
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @State private var hovering = false
    @State private var glowUp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cable.connector")
                .font(.system(size: 10.5, weight: .semibold))
            Text(name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .frame(maxWidth: 190)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        // Clear white like the sidebar's selected row, a hairline edge and a
        // soft white glow that breathes so it is noticed (the user; still
        // when Reduce Motion is on). Only while the shadow is up (≤ 15 s).
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.2 : 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
        .shadow(color: Color.white.opacity(reduceMotion ? 0.6 : (glowUp ? 0.7 : 0.2)), radius: 6)
        .foregroundStyle(Color.white)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { glowUp = true }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpen() }
        .help("Open \(name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open serial console \(name)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .accessibilityAction(named: "Dismiss") { onDismiss() }
    }
}
