import AppKit
import Combine
import SheepVTRender
import SwiftUI

/// Split panes (4.2 (7)): the detail pane of one workspace — every session
/// of the tab laid out by its `PaneLayout`, dividers the user can drag, and
/// (only when there is more than one pane) "variant C": the panes become
/// rounded cards on a chrome background, 4 pt apart, each with a slim header
/// inside its top edge that shows which one has the keyboard and can be
/// dragged — onto another pane's edge, onto a tab chip, or onto the empty
/// tab strip. A lone pane looks exactly as it always has.
///
/// One representable per workspace; the AppKit tree inside (`PaneTreeView`)
/// is rebuilt from the layout on every change but REUSES the per-session
/// containers, so a `TerminalView` is never recreated — it is reparented at
/// most, which is the same attach/detach a tab switch has always done.
struct WorkspaceView: NSViewRepresentable {
    let workspace: WorkspaceState
    let selectedSession: UUID?
    /// ContentView's leading pane inset (`PaneTreeView.leadingInset`).
    var leadingInset: CGFloat = 0

    func makeNSView(context: Context) -> PaneTreeView {
        let view = PaneTreeView()
        view.onDividerMoved = { split, index, position in
            AppModel.shared.moveDivider(workspace: workspace.id, split: split, index: index, to: position)
        }
        view.onEqualize = { AppModel.shared.evenOutPanes(workspace: workspace.id) }
        return view
    }

    func updateNSView(_ view: PaneTreeView, context: Context) {
        view.leadingInset = leadingInset
        view.apply(workspace, selected: selectedSession)
        // The keyboard belongs to the focused pane (see `focusFocusedPane`).
        DispatchQueue.main.async { view.focusFocusedPane() }
    }

    static func dismantleNSView(_ view: PaneTreeView, coordinator: ()) {
        view.detachAll()
        if AppModel.shared.activePaneTree === view { AppModel.shared.activePaneTree = nil }
    }
}

/// What a pane holds: a session's terminal (`SessionTerminalHost`) or a web
/// page (`WebTabController`). The pane tree only places `paneView`, hands
/// the keyboard to `keyView`, and tells the content when it leaves the
/// screen — the same view is reparented, never recreated.
@MainActor
protocol PaneContent: AnyObject {
    /// The view the pane hosts.
    var paneView: NSView { get }
    /// What gets the keyboard when the pane is focused.
    var keyView: NSView { get }
    /// A connection / certificate card is up in this pane.
    var hasPrompt: Bool { get }
    var promptHasKeyboard: Bool { get }
    @discardableResult func focusPrompt() -> Bool
    /// Off screen (hidden pane, tab switched away, moved): stop anything
    /// that must not run unseen (Safe Paste).
    func paneDidHide()
    /// Several panes: the first click only focuses (terminals).
    func setPointerNeedsFocus(_ needsFocus: Bool)
    /// The pane was reparented with the keyboard still on it.
    func refreshFocusAppearance()
}

extension PaneContent {
    /// A card's veil is over this pane's view right now (connection card,
    /// dangerous-command card, certificate card): the tree veils the strips
    /// round it too (`PaneVeil`).
    var veilsPane: Bool {
        paneView.subviews.contains { ($0 as? ConnectionOverlayView)?.veiled == true }
    }
}

extension SessionTerminalHost: PaneContent {
    var paneView: NSView { terminalView }
    var keyView: NSView { terminalView }
    func paneDidHide() { cancelSafePaste(reason: .sessionEnded) }
    func setPointerNeedsFocus(_ needsFocus: Bool) { terminalView.pointerNeedsFocus = needsFocus }
    func refreshFocusAppearance() { terminalView.setNeedsFrame() }
}

/// The AppKit side: leaf containers placed by `PaneLayout.rects`, divider
/// strips between siblings. Flipped, so the model's top-left geometry maps
/// straight onto view coordinates.
final class PaneTreeView: NSView {
    /// The split look "D3" (the user chose it from mockups, 2026-10-28; it
    /// replaced variant C) — its numbers live in `PaneVeil.D3` (shared with
    /// the veil's strips and the harness), ≥ 2 panes only:
    /// The gap between cards: it IS the divider — nothing is drawn in it, the
    /// backdrop shows through. 5 pt (variant C: 3); the grab area is wider.
    static let dividerThickness: CGFloat = PaneVeil.D3.gap
    static let dividerGrabWidth: CGFloat = 9
    /// The same 5 pt between the cards and the tree's edges (variant C's
    /// cards met the window sides).
    static let outerMargin: CGFloat = PaneVeil.D3.margin
    /// Behind the cards: near-black #060708, darker than any terminal theme.
    static let backdrop = NSColor(srgbRed: 6 / 255, green: 7 / 255, blue: 8 / 255, alpha: 1)

    /// Where the panes go inside a tree of `size`: the tree minus its margin
    /// (`PaneVeil.margin` — Terminal.app's round a lone / zoomed terminal,
    /// none round a lone web pane, D3's 5 pt round split cards).
    static func cardArea(_ size: CGSize, margin: PaneVeil.Margin) -> CGRect {
        PaneVeil.inset(CGRect(origin: .zero, size: size), by: margin)
    }

    private var cardArea: CGRect { Self.cardArea(bounds.size, margin: margin) }

    var onDividerMoved: ((UUID, Int, CGFloat) -> Void)?
    var onEqualize: (() -> Void)?

    private var state: WorkspaceState?
    private var selected: UUID?
    private var leaves: [UUID: PaneLeafView] = [:]
    private var dividers: [PaneDividerView] = []
    /// The connection card's veil over the strips round a connecting pane's
    /// terminal (`PaneVeil`). Above the leaves, below the dividers.
    private let veilView = PaneVeilView()
    /// The margin round the one visible pane (a lone / zoomed terminal).
    private var margin = PaneVeil.Margin.zero
    /// The drop zone being shown, if any (a drag over us, or a chip drag).
    private let zoneView = DropZoneView()
    /// The zone on screen belongs to a tab-chip drag (cleared when it ends).
    private var chipZoneShown = false
    /// The chip that follows a tab chip pulled down over the panes
    /// (the same look as a dragged pane header).
    private let chipGhost: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleNone
        view.setAccessibilityElement(false)
        view.alphaValue = 0.92
        return view
    }()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(veilView)
        // Pane headers write `pane:<uuid>`, sidebar rows `host:<uuid>`.
        registerForDraggedTypes([.string])
        NotificationCenter.default.addObserver(self, selector: #selector(veilChanged),
                                               name: ConnectionOverlayView.veilDidChange, object: nil)
    }

    @objc private func veilChanged() { layoutVeil() }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func keyView(for session: UUID) -> NSView? {
        leaves[session]?.content.keyView
    }

    /// Give the keyboard to the workspace's focused pane, with the restraint
    /// the single-tab view always had: never take it from a text field or
    /// the sidebar outline.
    func focusFocusedPane() {
        guard let state, let focused = keyView(for: state.focused), let window = focused.window else { return }
        // A connection question up in the focused pane (4.2 (9)): the keyboard
        // goes to its card instead of the terminal — same restraint.
        if let host = leaves[state.focused]?.content, host.hasPrompt {
            if host.promptHasKeyboard { return }
            guard !keyboardIsElsewhere(in: window) else { return }
            host.focusPrompt()
            return
        }
        if window.firstResponder === focused {
            // A pane dragged to another tab is reparented with the keyboard
            // still on it — no become/resign, so nothing asked for the frame
            // that draws its cursor solid again (measured: the moved pane
            // kept a hollow cursor).
            leaves[state.focused]?.content.refreshFocusAppearance()
            return
        }
        // Inside the pane already (a web page's own field, the web bar).
        if let responder = window.firstResponder as? NSView, let pane = leaves[state.focused]?.content.paneView,
           responder.isDescendant(of: pane) { return }
        guard !keyboardIsElsewhere(in: window) else { return }
        window.makeFirstResponder(focused)
    }

    /// The restraint: the keyboard is in a text field (the sidebar search, a
    /// find bar) or the sidebar outline, and must stay there. The one text
    /// field that does NOT count is another pane's connection-prompt card in
    /// this tree (4.2 (9)): a split opened beside a pane whose card had the
    /// keyboard kept it there while the new pane showed as focused.
    private func keyboardIsElsewhere(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder is NSOutlineView { return true }
        guard let editor = responder as? NSTextView else { return false }
        var view = editor.delegate as? NSView
        while let current = view {
            if current is ConnectionCardView { return !current.isDescendant(of: self) }
            view = current.superview
        }
        return true
    }

    /// A new tab's tree is handed to the window AFTER updateNSView's async
    /// turn has already run (measured: a pane dropped on another tab's chip
    /// found no window there and kept a hollow cursor), so focus again on
    /// arrival.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.focusFocusedPane() } }
        watchClicks(window != nil)
    }

    private var clickMonitor: Any?

    /// Left presses in this tree's window, while it is in one: a press
    /// outside a terminal drops its selection (`SelectionDrop`, 6.0 (14)).
    private func watchClicks(_ on: Bool) {
        if on, clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.dropSelections(for: event)
                return event
            }
        } else if !on, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    /// Every terminal on screen in this tree with a selection: dropped when
    /// the press is elsewhere in the window (another pane, a header, the tab
    /// strip, the sidebar, the status bar, the backdrop).
    private func dropSelections(for event: NSEvent) {
        guard let window else { return }
        for leaf in leaves.values where leaf.window === window && !leaf.isHiddenOrHasHiddenAncestor {
            guard let terminal = leaf.terminalView as? TerminalView, terminal.hasSelection else { continue }
            if SelectionDrop.clears(click: event.locationInWindow, terminal: terminal.convert(terminal.bounds, to: nil),
                                    sameWindow: event.window === window) {
                terminal.selection.clear()
                terminal.setNeedsFrame()
            }
        }
    }

    /// Show `workspace`: containers for new sessions, departed ones detached,
    /// every frame recomputed.
    func apply(_ workspace: WorkspaceState, selected: UUID?) {
        state = workspace
        self.selected = selected
        AppModel.shared.activePaneTree = self
        let wanted = Set(workspace.sessions)
        for (id, leaf) in leaves where !wanted.contains(id) {
            leaf.detach()
            leaf.removeFromSuperview()
            leaves[id] = nil
        }
        for id in workspace.sessions where leaves[id] == nil {
            guard let content = AppModel.shared.paneContent(ofSession: id) else { continue }
            let leaf = PaneLeafView(content: content, session: id)
            leaves[id] = leaf
            // Below the veil, and so below the dividers (always added above
            // it), so their 9 pt grab stays theirs; a leaf added on top of
            // them had left about 4 pt (review finding).
            addSubview(leaf, positioned: .below, relativeTo: veilView)
        }
        needsLayout = true
        layoutPanes()
    }

    func detachAll() {
        for leaf in leaves.values {
            leaf.detach()
            leaf.removeFromSuperview()
        }
        leaves.removeAll()
    }

    override func layout() {
        super.layout()
        layoutPanes()
    }

    /// The tree's padding from the detail column's left edge (ContentView's
    /// pane inset) — where the tree starts when the left sidebar is closed.
    var leadingInset: CGFloat = 0

    /// `session`'s pane's left edge in WINDOW coordinates as it would be with
    /// the left sidebar closed (the tree then starts at `leadingInset` and is
    /// as much wider as the sidebar is wide now). nil = not in this tree.
    func closedLeft(ofSession session: UUID) -> CGFloat? {
        guard let state, window != nil else { return nil }
        let left = convert(CGPoint.zero, to: nil).x
        let grow = max(0, left - leadingInset)
        if state.zoomed != nil { return leadingInset + margin.left }
        let rects = state.layout.rects(in: Self.cardArea(CGSize(width: bounds.width + grow, height: bounds.height), margin: margin),
                                       divider: Self.dividerThickness)
        guard let rect = rects[session] else { return nil }
        return leadingInset + rect.minX.rounded()
    }

    /// Space between a split terminal's text and its card's sides: 10 pt —
    /// the cards meet the window's sides, so the left card's text sits where
    /// a lone pane's is, and where Terminal.app's is (measured).
    static let paneTextInset: CGFloat = 10

    /// The veil over every connecting pane's strips (`PaneVeil`): the
    /// margin round a lone / zoomed terminal, and a split card below its
    /// header row (its 1 px border and text inset, clipped to the card's D3
    /// corners); the card's own veil covers the terminal itself. The 5 pt
    /// backdrop between and round split cards is no pane's and stays as is.
    private func layoutVeil() {
        veilView.frame = bounds
        var areas: [(area: CGRect, strips: [CGRect], corner: CGFloat)] = []
        for leaf in leaves.values where !leaf.isHidden && leaf.superview === self && leaf.content.veilsPane {
            let zoomedOrLone = state?.zoomed == leaf.session || (state?.paneCount ?? 0) == 1
            let area = zoomedOrLone ? PaneVeil.outset(leaf.frame, by: margin) : leaf.frame
            let terminal = leaf.terminalFrame.offsetBy(dx: leaf.frame.minX, dy: leaf.frame.minY)
            let header = leaf.headerFrame.map { $0.offsetBy(dx: leaf.frame.minX, dy: leaf.frame.minY) }
            let strips = PaneVeil.strips(area: area, terminal: terminal, header: header)
            // A split card is rounded; the margin round a zoomed card is not.
            areas.append((area, strips, leaf.showsHeader && !zoomedOrLone ? PaneLeafView.cornerRadius : 0))
        }
        veilView.show(areas)
    }

    private func layoutPanes() {
        guard let state, bounds.width > 1, bounds.height > 1 else { return }
        let several = state.paneCount > 1
        // Several panes (D3, 2026-10-28): the cards sit on a near-black
        // backdrop, 5 pt apart and 5 pt in from the edges. Zoomed: the one card
        // sits in a lone terminal's margin (`PaneVeil.margin`, inside the tree
        // since 6.0 (12)), which keeps the terminal's colour as it did when it
        // was DetailPane's padding. One pane: no background of our own.
        layer?.backgroundColor = !several ? nil
            : state.zoomed != nil ? Theme.termBackgroundNS.cgColor : Self.backdrop.cgColor
        for (id, leaf) in leaves {
            leaf.showsHeader = several
            // With several panes the pointer only reaches a pane's device once
            // that pane holds the keyboard (first click focuses; the wheel
            // scrolls our own scrollback). A lone pane: exactly as before.
            leaf.content.setPointerNeedsFocus(several)
            leaf.setFocused(id == selected)
            leaf.updateCard()
        }
        let visible = state.zoomed.flatMap { leaves[$0] } ?? (several ? nil : leaves.values.first)
        margin = PaneVeil.margin(paneCount: state.paneCount, zoomed: state.zoomed != nil,
                                 visibleIsTerminal: visible?.content is SessionTerminalHost)
        if let zoomed = state.zoomed, let leaf = leaves[zoomed] {
            for (id, other) in leaves where id != zoomed { other.hide() }
            leaf.show()
            leaf.frame = cardArea
            leaf.insets = NSEdgeInsets()
            for divider in dividers { divider.removeFromSuperview() }
            dividers.removeAll()
            layoutVeil()
            return
        }
        let rects = state.layout.rects(in: cardArea, divider: Self.dividerThickness)
        for (id, leaf) in leaves {
            guard let rect = rects[id] else { leaf.hide(); continue }
            leaf.show()
            // Rounded, not `integral`: integral grows the rect and ate into
            // the 4 pt gap.
            leaf.frame = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width.rounded(), height: rect.height.rounded())
            // A terminal's text sat flush on the card's edge (4 pt from the
            // neighbour); give it the lone pane's breathing room inside the
            // card. A web page keeps the whole card. The header is the top
            // inset (PaneLeafView adds it).
            // Split cards only: a lone pane's margin is DetailPane's already —
            // adding this too put its text 18 pt in (the user, 5.0 (54)).
            leaf.insets = several && leaf.content is SessionTerminalHost
                ? NSEdgeInsets(top: 0, left: Self.paneTextInset, bottom: 0, right: Self.paneTextInset)
                : NSEdgeInsets()
        }
        let strips = state.layout.dividerRects(in: cardArea, divider: Self.dividerThickness)
        while dividers.count > strips.count { dividers.removeLast().removeFromSuperview() }
        while dividers.count < strips.count {
            let divider = PaneDividerView()
            divider.onDrag = { [weak self] divider, point in self?.dividerDragged(divider, to: point) }
            divider.onDragEnd = { [weak self] divider in self?.dividerDragEnded(divider) }
            divider.onDoubleClick = { [weak self] in self?.onEqualize?() }
            addSubview(divider, positioned: zoneView.superview == nil ? .above : .below,
                       relativeTo: zoneView.superview == nil ? nil : zoneView)
            dividers.append(divider)
        }
        let axes = Dictionary(uniqueKeysWithValues: state.layout.splits.map { ($0.id, $0.axis) })
        for (divider, strip) in zip(dividers, strips) {
            divider.split = strip.split
            divider.index = strip.index
            // From the model, not the strip's shape (a split under 4 pt tall
            // had guessed wrong).
            divider.axis = axes[strip.split] ?? (strip.rect.width < strip.rect.height ? .horizontal : .vertical)
            // The gap is three points; the grab area is a little wider.
            let grab = Self.dividerGrabWidth
            divider.frame = divider.axis == .horizontal
                ? CGRect(x: strip.rect.minX - (grab - strip.rect.width) / 2, y: strip.rect.minY, width: grab, height: strip.rect.height)
                : CGRect(x: strip.rect.minX, y: strip.rect.minY - (grab - strip.rect.height) / 2, width: strip.rect.width, height: grab)
        }
        layoutVeil()
    }

    // MARK: - drop zones

    /// The panes as they are on screen: the zoomed one alone, else the layout.
    private func paneFrames() -> [UUID: CGRect] {
        guard let state else { return [:] }
        if let zoomed = state.zoomed, leaves[zoomed] != nil { return [zoomed: cardArea] }
        return state.layout.rects(in: cardArea, divider: Self.dividerThickness)
    }

    /// Where a drop of `payload` at `point` (our coordinates) would go; nil
    /// when it would be refused, so no zone is drawn for it. Anywhere in a
    /// pane counts while ANY side of it takes the drop: the nearest side
    /// that does (`PaneLayout.dropTarget(at:frames:allowed:)`, 6.0 (13)) —
    /// a refused nearest edge used to blank that half of the pane.
    private func zone(for payload: PaneDragPayload, at point: CGPoint) -> (pane: UUID, direction: PaneDirection)? {
        guard let state else { return nil }
        let frames = dropFrames(for: payload)
        zoneFrames = frames
        let book = AppModel.shared.book
        let source: WorkspaceBook.DropSource
        switch payload {
        case .pane(let session):
            // From another tab only while there is room (move says so too).
            guard state.layout.contains(session) || state.paneCount < PaneLayout.maxPanes else { return nil }
            source = .pane(session)
        case .host(let id):
            guard state.paneCount < PaneLayout.maxPanes, AppModel.shared.savedHost(id: id) != nil else { return nil }
            source = .newSession
        }
        // Over itself = nowhere; never one off the grid (PaneLayout.isGrid)
        // or one that would squeeze a Ping pane (keepsWhole): the trial says.
        return PaneLayout.dropTarget(at: point, frames: frames) { book.accepts(source, beside: $0, $1) }
    }

    /// The frames a drop is aimed at. A pane moved within its own tab is
    /// measured against the tab WITHOUT it: with two panes the other one
    /// fills the tab, so anywhere in the right half means the whole right
    /// half (the owner, 6.0 (2): a drop mid-pane did not snap to a side).
    private func dropFrames(for payload: PaneDragPayload) -> [UUID: CGRect] {
        guard let state, state.zoomed == nil, case .pane(let session) = payload,
              state.layout.contains(session), state.paneCount > 1 else { return paneFrames() }
        var without = state.layout
        without.remove(session, keepingWhole: AppModel.shared.book.compactSessions)
        // Measured in the margin the tree would have without it (a lone
        // terminal left behind gets Terminal.app's, not D3's 5 pt).
        let rest = without.count == 1 ? without.leaves.first.flatMap { leaves[$0] } : nil
        let restMargin = PaneVeil.margin(paneCount: without.count, zoomed: false,
                                         visibleIsTerminal: rest?.content is SessionTerminalHost)
        return without.rects(in: Self.cardArea(bounds.size, margin: restMargin), divider: Self.dividerThickness)
    }

    /// What `showZone` draws against (set by `zone`).
    private var zoneFrames: [UUID: CGRect]?

    private func showZone(_ zone: (pane: UUID, direction: PaneDirection)?) {
        guard let zone, let rect = (zoneFrames ?? paneFrames())[zone.pane] else {
            zoneFrames = nil
            zoneView.removeFromSuperview()
            return
        }
        zoneView.frame = PaneLayout.dropZoneRect(rect, zone.direction).integral
        if zoneView.superview == nil { addSubview(zoneView, positioned: .above, relativeTo: nil) }
    }

    /// One item, ours, or nothing: a multi-row sidebar drag is not a drop
    /// on a pane, and neither is text from another app.
    private func payload(of info: NSDraggingInfo) -> PaneDragPayload? {
        let board = info.draggingPasteboard
        guard board.pasteboardItems?.count == 1, let string = board.string(forType: .string),
              let payload = PaneDragPayload(string), InternalDrag.covers(payload) else { return nil }
        return payload
    }

    private func dragUpdate(_ info: NSDraggingInfo) -> NSDragOperation {
        let point = convert(info.draggingLocation, from: nil)
        let target = payload(of: info).flatMap { zone(for: $0, at: point) }
        showZone(target)
        return target == nil ? [] : .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { showZone(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { showZone(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { showZone(nil) }
        let point = convert(sender.draggingLocation, from: nil)
        guard let payload = payload(of: sender), let target = zone(for: payload, at: point) else { return false }
        // After AppKit has finished with the drag: the move reparents
        // terminal views, which is no business of a drag callback.
        DispatchQueue.main.async {
            let model = AppModel.shared
            switch payload {
            case .pane(let session):
                model.movePane(session, beside: target.pane, target.direction)
            case .host(let id):
                guard let host = model.savedHost(id: id) else { NSSound.beep(); return }
                model.dropHost(host, beside: target.pane, target.direction)
            }
        }
        return true
    }

    /// A tab chip dragged below the strip: draw the zone under the pointer
    /// and hand it to the strip, which merges on release. The chip of the
    /// tab shown here, or a merge past the limit, has no zone.
    func showChipDrag(_ drag: ChipDrag?) {
        guard let drag else {
            if chipZoneShown {
                chipZoneShown = false
                AppModel.shared.chipDropZone = nil
                showZone(nil)
            }
            chipGhost.removeFromSuperview()
            return
        }
        showChipGhost(for: drag)
        var target: (pane: UUID, direction: PaneDirection)?
        if let state, let window, drag.workspace != state.id,
           let source = AppModel.shared.book.workspace(id: drag.workspace),
           source.paneCount + state.paneCount <= PaneLayout.maxPanes {
            let point = convert(window.convertPoint(fromScreen: drag.screenPoint), from: nil)
            // The nearest side the merge takes (off the grid / squeezing a
            // Ping pane = not taken), the same rule as a header drop.
            let book = AppModel.shared.book
            target = PaneLayout.dropTarget(at: point, frames: paneFrames()) {
                book.accepts(.workspace(drag.workspace), beside: $0, $1)
            }
        }
        chipZoneShown = true
        zoneFrames = nil        // a chip merge aims at the panes as shown
        AppModel.shared.chipDropZone = target
        showZone(target)
        if chipGhost.superview != nil { addSubview(chipGhost, positioned: .above, relativeTo: nil) }
    }

    /// The ghost sits where a dragged pane header's image would: the pointer
    /// near its dot. Its dot wears the dragged tab's focused session colour.
    private func showChipGhost(for drag: ChipDrag) {
        guard let window else { return }
        if chipGhost.superview == nil {
            let model = AppModel.shared
            let tab = model.book.workspace(id: drag.workspace).flatMap { model.tab(id: $0.focused) }
            let dot = tab.map { PaneHeaderView.dotColor(of: $0, status: $0.statusInfo) } ?? NSColor(Theme.dimText)
            var favicon: NSImage?
            if let tab, case .web = tab.content { favicon = tab.favicon }
            chipGhost.image = PaneHeaderView.chipImage(title: tab?.title ?? "", dot: dot, favicon: favicon)
            addSubview(chipGhost, positioned: .above, relativeTo: nil)
        }
        let point = convert(window.convertPoint(fromScreen: drag.screenPoint), from: nil)
        let size = TabChipMetrics.dragSize
        chipGhost.frame = CGRect(x: point.x - 16, y: point.y - size.height / 2, width: size.width, height: size.height)
    }

    /// The position of the divider being dragged, committed on release.
    private var dividerDragPosition: (split: UUID, index: Int, position: CGFloat)?

    /// A divider at `point` (in our coordinates): the boundary's share along
    /// the split it belongs to — the length WITHOUT the gaps, which is what
    /// the fractions divide (with the gaps counted the divider jumped on the
    /// first event). Applied to our own copy of the layout while the mouse
    /// is down; the model hears about it once, on release — every event
    /// through `@Published book` re-rendered the whole app (review finding).
    private func dividerDragged(_ divider: PaneDividerView, to point: CGPoint) {
        guard var state, let split = divider.split,
              let count = state.layout.splits.first(where: { $0.id == split })?.fractions.count else { return }
        // The split's own rect = the union of its children's rects.
        let rects = state.layout.rects(in: cardArea, divider: Self.dividerThickness)
        let members = state.layout.leaves(ofSplit: split)
        let union = members.compactMap { rects[$0] }.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, union.width > 0, union.height > 0 else { return }
        let gaps = CGFloat(count - 1) * Self.dividerThickness
        let before = CGFloat(divider.index) * Self.dividerThickness
        let position = divider.axis == .horizontal
            ? (point.x - union.minX - before) / max(1, union.width - gaps)
            : (point.y - union.minY - before) / max(1, union.height - gaps)
        guard state.layout.moveDivider(ofSplit: split, index: divider.index, to: position) else { return }
        self.state = state
        dividerDragPosition = (split, divider.index, position)
        layoutPanes()
    }

    private func dividerDragEnded(_ divider: PaneDividerView) {
        guard let drag = dividerDragPosition else { return }
        dividerDragPosition = nil
        onDividerMoved?(drag.split, drag.index, drag.position)
    }
}

/// The card veil on the strips round a connecting pane's terminal: one
/// clipping layer per pane (rounded like a split card), a 45 % black strip
/// per side — the colour of `ConnectionOverlayView`'s own veil, so the pane
/// reads as one dimmed surface. Never takes the mouse.
final class PaneVeilView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ areas: [(area: CGRect, strips: [CGRect], corner: CGFloat)]) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for item in areas where !item.strips.isEmpty {
            let clip = CALayer()
            clip.frame = item.area
            clip.cornerRadius = item.corner
            clip.masksToBounds = item.corner > 0
            for rect in item.strips {
                let strip = CALayer()
                strip.frame = rect
                strip.backgroundColor = ConnectionOverlayView.veilColor.cgColor
                clip.addSublayer(strip)
            }
            layer.addSublayer(clip)
        }
        CATransaction.commit()
    }
}

/// One session's slot: hosts its `TerminalView` (or a web tab's view) and,
/// when the tab has more than one pane, a header above it.
final class PaneLeafView: NSView {
    let content: PaneContent
    let session: UUID
    var terminalView: NSView { content.paneView }
    /// Space between the pane's edge and the terminal (set by the tree).
    var insets = NSEdgeInsets() {
        didSet { needsLayout = true }
    }
    /// Only with two panes or more: a lone pane looks exactly as it always has.
    var showsHeader = false {
        didSet {
            guard showsHeader != oldValue else { return }
            header.isHidden = !showsHeader
            needsLayout = true
        }
    }
    private let header: PaneHeaderView
    private var titleWatch: AnyCancellable?

    init(content: PaneContent, session: UUID) {
        self.content = content
        self.session = session
        header = PaneHeaderView(session: session)
        super.init(frame: .zero)
        header.isHidden = true
        header.onClick = { [weak self] in
            guard let self, let window = self.window else { return }
            // The terminal's focus hook hands the keyboard on to a
            // connection question's card when one is up.
            window.makeFirstResponder(self.content.keyView)
        }
        content.paneView.autoresizingMask = [.width, .height]
        addSubview(content.paneView)
        addSubview(header)
        // The title and the connection status change under us (OSC titles,
        // reconnects); DetailPane does not re-render for a SessionTab's own
        // changes, so the header watches the tab itself.
        if let tab = AppModel.shared.tab(id: session) {
            titleWatch = tab.$title.combineLatest(tab.$statusInfo, tab.$favicon)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] title, status, favicon in
                    guard let self, let tab else { return }
                    self.header.setTitle(title, detail: PaneHeaderView.detail(of: tab, title: title, status: status),
                                         dot: PaneHeaderView.dotColor(of: tab, status: status))
                    self.header.isWeb = { if case .web = tab.content { return true } else { return false } }()
                    self.header.favicon = favicon
                }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // A card's 1 px border runs round its edge; the pane's view stays
        // inside it, so the border is never drawn over the terminal picture.
        let edge = showsHeader ? Self.borderWidth : 0
        header.frame = CGRect(x: edge, y: edge, width: max(0, bounds.width - 2 * edge), height: PaneHeaderView.height - edge)
        terminalView.frame = terminalFrame
    }

    /// Where the terminal goes in this pane (own coordinates, y down) — the
    /// same D3 geometry the veil's strips are cut from (`PaneVeil.cardLayout`).
    var terminalFrame: CGRect {
        PaneVeil.cardLayout(size: bounds.size, headed: showsHeader, left: insets.left, right: insets.right).content
    }

    /// The header row, when shown (own coordinates): the full-width 24 pt band
    /// at the card's top, border included — it stays bright under a veil.
    var headerFrame: CGRect? {
        PaneVeil.cardLayout(size: bounds.size, headed: showsHeader).header
    }

    private var isFocused = false

    func setFocused(_ focused: Bool) {
        isFocused = focused
        header.isFocused = focused
    }

    /// D3 (2026-10-28): rounded 8, filled with the terminal's own colour (the
    /// theme can change, so this is re-read on every layout), a 1 px inner
    /// border — white 9 %, accent 60 % on the focused pane — so the edge
    /// shows even on an almost-black theme. Without a header: no card, the
    /// pane is the bare terminal as before.
    static let cornerRadius: CGFloat = PaneVeil.D3.cornerRadius
    static let borderWidth: CGFloat = PaneVeil.D3.border
    static let borderColor = NSColor.white.withAlphaComponent(0.09)
    static var focusedBorderColor: NSColor { NSColor(Theme.accent).withAlphaComponent(0.6) }

    func updateCard() {
        wantsLayer = true
        guard let layer else { return }
        if showsHeader {
            layer.cornerRadius = Self.cornerRadius
            layer.masksToBounds = true
            layer.backgroundColor = Theme.termBackgroundNS.cgColor
            layer.borderWidth = Self.borderWidth
            layer.borderColor = (isFocused ? Self.focusedBorderColor : Self.borderColor).cgColor
        } else {
            layer.cornerRadius = 0
            layer.masksToBounds = false
            layer.backgroundColor = nil
            layer.borderWidth = 0
            layer.borderColor = nil
        }
    }

    /// Zoom (or a layout that has no room) hides the pane: the same rule as
    /// a tab switch — a paste in flight into an invisible terminal is unsafe,
    /// and its progress HUD would be invisible too (review finding, 4.2 (7)).
    ///
    /// The terminal also leaves the view tree: a hidden `TerminalView` still
    /// in the window kept its display link, surfaces and row cache and
    /// rendered every frame of output (review finding) — `window == nil` is
    /// what stops it, as for a hidden tab.
    func hide() {
        if !isHidden {
            content.paneDidHide()
            if terminalView.superview === self { terminalView.removeFromSuperview() }
        }
        isHidden = true
    }

    /// Back on screen: the terminal rejoins below the header.
    func show() {
        if terminalView.superview !== self {
            terminalView.frame = bounds
            addSubview(terminalView, positioned: .below, relativeTo: header)
            needsLayout = true
        }
        isHidden = false
    }

    /// The pane is leaving the window: a paste in flight into an invisible
    /// terminal is unsafe (same rule as a tab switch).
    ///
    /// Only if the terminal is still OURS: a pane dragged to another tab is
    /// adopted by that tab's new tree, and SwiftUI may build the new tree
    /// before it dismantles the old one — an unconditional
    /// `removeFromSuperview` here then pulled the terminal out of its new
    /// home and the tab showed nothing (measured, 4.2 (7)).
    func detach() {
        guard terminalView.superview === self else { return }
        content.paneDidHide()
        terminalView.removeFromSuperview()
    }
}

/// A pane's header bar (only with ≥ 2 panes): title + status, a close
/// button, click to focus, drag (≥ 4 pt) to move the pane — onto another
/// pane's edge, a tab chip, or the empty tab strip. The drag carries
/// `pane:<uuid>` and never leaves the app.
final class PaneHeaderView: NSView, NSDraggingSource {
    /// D3 (2026-10-28): a 24 pt transparent row (variant C: 20, chrome band)
    /// holding a capsule chip — dot, title, dim detail — like the tab strip's.
    static let height: CGFloat = PaneVeil.D3.headerHeight
    static let dotSize: CGFloat = 7
    static let chipHeight: CGFloat = 18
    /// Header padding left of the chip; the chip's own padding; dot → text.
    static let chipLeading: CGFloat = 6
    static let chipPadding: CGFloat = 9
    static let dotGap: CGFloat = 6
    static let chipFill = NSColor.white.withAlphaComponent(ChipHover.headerRestingOpacity)
    /// Under the pointer (6.0 (14)): the chip lights up, the × gets the tab
    /// chip's round disc (`ChipHover`, shared with the tab strip).
    static let hoverChipFill = NSColor.white.withAlphaComponent(ChipHover.headerChipOpacity)
    static let closeDiscFill = NSColor.labelColor.withAlphaComponent(ChipHover.closeDiscOpacity)
    static var focusedChipFill: NSColor { NSColor(Theme.accent).withAlphaComponent(0.2) }
    /// The session whose header is being dragged right now (the tab strip
    /// uses it to leave the pane's own chip unhighlighted).
    private(set) static var draggingSession: UUID?

    let session: UUID
    var onClick: (() -> Void)?
    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            applyColors()
        }
    }

    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private var mouseDownPoint: CGPoint?
    private var dragging = false
    /// The pointer is over the header / over its × (redrawn on change).
    private var hovering = false
    private var overClose = false
    private var title = ""
    private var detail: String?
    /// The status dot's colour (see `dotColor`).
    private var dot = NSColor(Theme.dimText)

    init(session: UUID) {
        self.session = session
        super.init(frame: .zero)
        titleField.font = .systemFont(ofSize: 11)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.maximumNumberOfLines = 1
        addSubview(titleField)
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 11)
        closeButton.target = self
        closeButton.action = #selector(closePane)
        closeButton.contentTintColor = NSColor(Theme.dimText)
        addSubview(closeButton)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The second, dimmer half of the header: the address of a remote
    /// session (plus "disconnected" when it is) — unless the title already
    /// IS the address (a host saved by IP) — a serial line's status, nothing
    /// for a local shell (its title already says "This Mac").
    static func detail(of tab: SessionTab, title: String, status: String?) -> String? {
        let down = status?.hasPrefix("disconnected") == true
        switch tab.content {
        case .local:
            return nil
        case .ssh(let controller):
            let address = controller.host.address
            if address.isEmpty { return StatusInfoDisplay.text(status) }
            if address == title { return down ? String(localized: "disconnected") : nil }
            return down ? String(localized: "\(address) · disconnected") : address
        case .serial:
            return StatusInfoDisplay.text(status)
        case .web(let controller):
            let host = WebAddress.displayHost(of: controller.currentURL)
            return host == title ? nil : host
        case .files, .ping:
            return status
        }
    }

    /// The dot wears the tab chip's colours (`TabItemView.indicatorColor`):
    /// local green, SSH blue, serial yellow, a dropped remote session red.
    static func dotColor(of tab: SessionTab, status: String?) -> NSColor {
        let down = status?.hasPrefix("disconnected") == true
        switch tab.content {
        case .local: return NSColor(Theme.ok)
        case .ssh: return down ? SheepAlert.destructiveRed : NSColor(Theme.accent)
        case .serial(let c): return down ? SheepAlert.destructiveRed : NSColor(c.isTelnet ? Theme.accent : Theme.warn)
        case .web: return NSColor(Theme.web)
        case .files: return down ? SheepAlert.destructiveRed : NSColor(Theme.accent)
        case .ping: return NSColor(Theme.ok)
        }
    }

    /// A web tab: its site's icon (else a globe) instead of the status dot.
    var isWeb = false {
        didSet { if isWeb != oldValue { needsDisplay = true } }
    }
    var favicon: NSImage? {
        didSet { if favicon !== oldValue { needsDisplay = true } }
    }

    func setTitle(_ title: String, detail: String?, dot: NSColor) {
        self.title = title
        self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
        self.dot = dot
        applyColors()
        closeButton.setAccessibilityLabel(String(localized: "Close \(title)"))
    }

    private func applyColors() {
        let color = NSColor(isFocused ? Theme.tabText : Theme.dimText)
        let font = NSFont.systemFont(ofSize: 11)
        let text = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        if let detail {
            text.append(NSAttributedString(string: "  \(detail)",
                                           attributes: [.font: font, .foregroundColor: color.withAlphaComponent(0.6)]))
        }
        titleField.attributedStringValue = text
        needsLayout = true      // the chip is as wide as the text
        needsDisplay = true
    }

    /// The dot's left edge (the chip's padding in from its left).
    private var markX: CGFloat { Self.chipLeading + Self.chipPadding }

    /// The capsule round dot + title + detail, as wide as they need and no
    /// wider than the room left of the ×.
    private var chipRect: CGRect {
        let textX = markX + Self.dotSize + Self.dotGap
        let width = textX + titleField.frame.width + Self.chipPadding - Self.chipLeading
        return CGRect(x: Self.chipLeading, y: (bounds.height - Self.chipHeight) / 2, width: max(0, width), height: Self.chipHeight)
    }

    override func layout() {
        super.layout()
        let button: CGFloat = 20
        closeButton.frame = CGRect(x: bounds.width - button - 2, y: (bounds.height - 18) / 2, width: button, height: 18)
        let textHeight = titleField.intrinsicContentSize.height
        let textX = markX + Self.dotSize + Self.dotGap
        let room = max(0, closeButton.frame.minX - 4 - Self.chipPadding - textX)
        titleField.frame = CGRect(x: textX, y: (bounds.height - textHeight) / 2,
                                  // Measured from the string: the field's own intrinsic width
                                  // follows its current (narrow) frame and kept the chip short.
                                  width: min(ceil(titleField.attributedStringValue.size().width) + 4, room), height: textHeight)
        needsDisplay = true
    }

    // MARK: hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { pointerMoved(event) }
    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override func mouseExited(with event: NSEvent) { setHover(false, overClose: false) }

    private func pointerMoved(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHover(bounds.contains(point), overClose: closeButton.frame.contains(point))
    }

    private func setHover(_ hovering: Bool, overClose: Bool) {
        guard hovering != self.hovering || overClose != self.overClose else { return }
        self.hovering = hovering
        self.overClose = overClose
        needsDisplay = true
    }

    /// The chip's fill: the focused pane's accent, else lit under the pointer.
    static func chipFill(focused: Bool, hovering: Bool) -> NSColor {
        focused ? focusedChipFill : hovering ? hoverChipFill : chipFill
    }

    /// The ×'s disc: centred on the button, the tab chip's size.
    static func closeDisc(around button: CGRect) -> CGRect {
        let side = ChipHover.closeDiscSize
        return CGRect(x: button.midX - side / 2, y: button.midY - side / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Transparent row: only the chip is filled (the card shows round it).
        let chip = chipRect
        Self.chipFill(focused: isFocused, hovering: hovering).setFill()
        NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2).fill()
        if overClose {
            Self.closeDiscFill.setFill()
            NSBezierPath(ovalIn: Self.closeDisc(around: closeButton.frame)).fill()
        }
        let markX = self.markX
        if isWeb, let favicon {
            let side: CGFloat = 12
            favicon.draw(in: CGRect(x: markX + (Self.dotSize - side) / 2, y: (bounds.height - side) / 2, width: side, height: side),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                         hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
            return
        }
        if isWeb, let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
            let tinted = NSImage(size: globe.size, flipped: false) { rect in
                globe.draw(in: rect)
                self.dot.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let size = globe.size
            tinted.draw(in: CGRect(x: markX + (Self.dotSize - size.width) / 2, y: (bounds.height - size.height) / 2,
                                   width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        dot.setFill()
        NSBezierPath(ovalIn: CGRect(x: markX, y: (bounds.height - Self.dotSize) / 2,
                                    width: Self.dotSize, height: Self.dotSize)).fill()
    }

    /// Right-click on a pane's header: Unsplit (the pane leaves for a tab of
    /// its own, like Tabs → Unsplit or a drop on the empty strip), Close
    /// Pane, and on a web pane Save as Host….
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add(String(localized: "Unsplit"), #selector(unsplit))
        if isWeb { add(String(localized: "Save as Host…"), #selector(saveAsHost)) }
        menu.addItem(.separator())
        add(String(localized: "Close Pane"), #selector(closePane))
        return menu
    }

    @objc private func unsplit() {
        AppModel.shared.movePaneToNewTab(session)
    }

    @objc private func saveAsHost() {
        guard let tab = AppModel.shared.tab(id: session) else { return }
        AppModel.shared.saveWebTabAsHost(tab)
    }

    @objc private func closePane() {
        guard let tab = AppModel.shared.tab(id: session) else { return }
        AppModel.shared.close(tab: tab)
    }

    // MARK: click or drag

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: PaneDragPayload.pane(session).string as NSString)
        // A tab-chip-sized image, not the whole header (as wide as the
        // pane): the pointer holds it near its dot, as if picking up a tab.
        let size = TabChipMetrics.dragSize
        item.setDraggingFrame(CGRect(x: start.x - 16, y: start.y - size.height / 2,
                                     width: size.width, height: size.height),
                              contents: Self.chipImage(title: title, dot: dot, favicon: isWeb ? favicon : nil))
        Self.draggingSession = session
        InternalDrag.pane = session
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if !dragging { onClick?() }
        dragging = false
    }

    /// The drag image: a tab chip of the fixed `TabChipMetrics.dragSize`
    /// (every pane the same), with the session's dot or site icon and the
    /// title, cut short with … when it is long. Also the ghost that follows a
    /// tab chip pulled down over the panes (`PaneTreeView.showChipGhost`).
    static func chipImage(title: String, dot: NSColor, favicon: NSImage?) -> NSImage {
        let size = TabChipMetrics.dragSize
        let fill = NSColor(Theme.controlFill), text = NSColor(Theme.tabText), dotSize = Self.dotSize
        return NSImage(size: size, flipped: true) { rect in
            let chip = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            fill.setFill()
            chip.fill()
            NSColor.white.withAlphaComponent(0.18).setStroke()
            chip.lineWidth = 1
            chip.stroke()
            let markX: CGFloat = 10
            if let favicon {
                favicon.draw(in: CGRect(x: markX, y: (rect.height - 12) / 2, width: 12, height: 12),
                             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                dot.setFill()
                NSBezierPath(ovalIn: CGRect(x: markX, y: (rect.height - dotSize) / 2,
                                            width: dotSize, height: dotSize)).fill()
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: TabChipMetrics.font,
                .foregroundColor: text,
                .paragraphStyle: style,
            ]
            let textX = markX + dotSize + 7
            let textHeight = ceil(TabChipMetrics.font.boundingRectForFont.height)
            (title as NSString).draw(with: CGRect(x: textX, y: (rect.height - textHeight) / 2,
                                                  width: rect.width - textX - 10, height: textHeight),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: attributes)
            return true
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Self.draggingSession = nil
        InternalDrag.pane = nil
        dragging = false
        mouseDownPoint = nil
    }
}

/// What is being dragged INSIDE the app right now. A drop target takes a
/// `pane:`/`host:` string only when it matches — the same text dragged in
/// from a web page or a document must not move a pane or, worse, open a
/// saved host with its Keychain credential (review finding, 4.2 (7)). The
/// pane header sets `pane`; the sidebar sets `hosts` for the rows it drags
/// (one, or a multi-selection) and clears them when the session ends.
enum InternalDrag {
    static var pane: UUID?
    static var hosts: Set<UUID> = []

    static func covers(_ payload: PaneDragPayload) -> Bool {
        switch payload {
        case .pane(let id): return pane == id
        case .host(let id): return hosts.contains(id)
        }
    }
}

/// The translucent half-pane that says where a drop will land. Never takes
/// a click or a drag of its own.
final class DropZoneView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(Theme.accent).withAlphaComponent(0.28).cgColor
        layer?.borderColor = NSColor(Theme.accent).withAlphaComponent(0.8).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The strip between two siblings: the 4 pt gap (drawn by nobody), a 9 pt
/// grab area, the resize cursor, drag to move, double-click to even out.
final class PaneDividerView: NSView {
    var split: UUID?
    var index = 0
    var axis: PaneAxis = .horizontal
    var onDrag: ((PaneDividerView, CGPoint) -> Void)?
    var onDragEnd: ((PaneDividerView) -> Void)?
    var onDoubleClick: (() -> Void)?

    override var isFlipped: Bool { true }

    // Nothing to draw: the gap between the cards is the divider (variant C).

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        guard let parent = superview else { return }
        var current = event
        while current.type != .leftMouseUp {
            let point = parent.convert(current.locationInWindow, from: nil)
            if current.type == .leftMouseDragged { onDrag?(self, point) }
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            current = next
        }
        onDragEnd?(self)
    }
}
