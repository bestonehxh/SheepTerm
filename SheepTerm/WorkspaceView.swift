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

    func makeNSView(context: Context) -> PaneTreeView {
        let view = PaneTreeView()
        view.onDividerMoved = { split, index, position in
            AppModel.shared.moveDivider(workspace: workspace.id, split: split, index: index, to: position)
        }
        view.onEqualize = { AppModel.shared.evenOutPanes(workspace: workspace.id) }
        return view
    }

    func updateNSView(_ view: PaneTreeView, context: Context) {
        view.apply(workspace, selected: selectedSession)
        // The keyboard belongs to the focused pane (see `focusFocusedPane`).
        DispatchQueue.main.async { view.focusFocusedPane() }
    }

    static func dismantleNSView(_ view: PaneTreeView, coordinator: ()) {
        view.detachAll()
        if AppModel.shared.activePaneTree === view { AppModel.shared.activePaneTree = nil }
    }
}

/// The AppKit side: leaf containers placed by `PaneLayout.rects`, divider
/// strips between siblings. Flipped, so the model's top-left geometry maps
/// straight onto view coordinates.
final class PaneTreeView: NSView {
    /// The gap between panes (variant C): it IS the divider — nothing is
    /// drawn in it, the chrome background shows through.
    static let dividerThickness: CGFloat = 4
    static let dividerGrabWidth: CGFloat = 9

    var onDividerMoved: ((UUID, Int, CGFloat) -> Void)?
    var onEqualize: (() -> Void)?

    private var state: WorkspaceState?
    private var selected: UUID?
    private var leaves: [UUID: PaneLeafView] = [:]
    private var dividers: [PaneDividerView] = []
    /// The drop zone being shown, if any (a drag over us, or a chip drag).
    private let zoneView = DropZoneView()
    /// The zone on screen belongs to a tab-chip drag (cleared when it ends).
    private var chipZoneShown = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Pane headers write `pane:<uuid>`, sidebar rows `host:<uuid>`.
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func terminalView(for session: UUID) -> TerminalView? {
        leaves[session]?.terminalView
    }

    /// Give the keyboard to the workspace's focused pane, with the restraint
    /// the single-tab view always had: never take it from a text field or
    /// the sidebar outline.
    func focusFocusedPane() {
        guard let state, let focused = terminalView(for: state.focused), let window = focused.window else { return }
        // A connection question up in the focused pane (4.2 (9)): the keyboard
        // goes to its card instead of the terminal — same restraint.
        if let host = leaves[state.focused]?.host, host.hasPrompt {
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
            focused.setNeedsFrame()
            return
        }
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
            guard let host = AppModel.shared.terminalHost(ofSession: id) else { continue }
            let leaf = PaneLeafView(host: host, session: id)
            leaves[id] = leaf
            // Below the dividers, so their 9 pt grab stays theirs; a leaf
            // added on top of them had left about 4 pt (review finding).
            if let first = dividers.first { addSubview(leaf, positioned: .below, relativeTo: first) } else { addSubview(leaf) }
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

    private func layoutPanes() {
        guard let state, bounds.width > 1, bounds.height > 1 else { return }
        let several = state.paneCount > 1
        // Several panes: rounded cards on a tray. The tray is `tabActive`,
        // the darkest chrome tone — `chrome` itself is two steps from the
        // terminal background and the 4 pt gaps vanished (measured on the
        // first build). One pane: no background of our own, exactly as before.
        layer?.backgroundColor = several ? NSColor(Theme.tabActive).cgColor : nil
        for (id, leaf) in leaves {
            leaf.showsHeader = several
            // With several panes the pointer only reaches a pane's device once
            // that pane holds the keyboard (first click focuses; the wheel
            // scrolls our own scrollback). A lone pane: exactly as before.
            leaf.terminalView.pointerNeedsFocus = several
            leaf.setFocused(id == selected)
            leaf.updateCard()
        }
        if let zoomed = state.zoomed, let leaf = leaves[zoomed] {
            for (id, other) in leaves where id != zoomed { other.hide() }
            leaf.show()
            leaf.frame = bounds
            leaf.insets = NSEdgeInsets()
            for divider in dividers { divider.removeFromSuperview() }
            dividers.removeAll()
            return
        }
        let rects = state.layout.rects(in: bounds, divider: Self.dividerThickness)
        for (id, leaf) in leaves {
            guard let rect = rects[id] else { leaf.hide(); continue }
            leaf.show()
            // Rounded, not `integral`: integral grows the rect and ate into
            // the 4 pt gap.
            leaf.frame = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width.rounded(), height: rect.height.rounded())
            // The 4 pt gap keeps text off the neighbour; the header is the
            // top inset (PaneLeafView adds it).
            leaf.insets = NSEdgeInsets()
        }
        let strips = state.layout.dividerRects(in: bounds, divider: Self.dividerThickness)
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
            // The gap is four points; the grab area is a little wider.
            let grab = Self.dividerGrabWidth
            divider.frame = divider.axis == .horizontal
                ? CGRect(x: strip.rect.minX - (grab - strip.rect.width) / 2, y: strip.rect.minY, width: grab, height: strip.rect.height)
                : CGRect(x: strip.rect.minX, y: strip.rect.minY - (grab - strip.rect.height) / 2, width: strip.rect.width, height: grab)
        }
    }

    // MARK: - drop zones

    /// The panes as they are on screen: the zoomed one alone, else the layout.
    private func paneFrames() -> [UUID: CGRect] {
        guard let state else { return [:] }
        if let zoomed = state.zoomed, leaves[zoomed] != nil { return [zoomed: bounds] }
        return state.layout.rects(in: bounds, divider: Self.dividerThickness)
    }

    /// Where a drop of `payload` at `point` (our coordinates) would go; nil
    /// when it would be refused, so no zone is drawn for it.
    private func zone(for payload: PaneDragPayload, at point: CGPoint) -> (pane: UUID, direction: PaneDirection)? {
        guard let state, let target = PaneLayout.dropTarget(at: point, frames: paneFrames()) else { return nil }
        switch payload {
        case .pane(let session):
            // Over itself = nowhere; from another tab only while there is room.
            guard session != target.pane,
                  state.layout.contains(session) || state.paneCount < PaneLayout.maxPanes else { return nil }
        case .host(let id):
            guard state.paneCount < PaneLayout.maxPanes, AppModel.shared.savedHost(id: id) != nil else { return nil }
        }
        return target
    }

    private func showZone(_ zone: (pane: UUID, direction: PaneDirection)?) {
        guard let zone, let rect = paneFrames()[zone.pane] else {
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
            return
        }
        var target: (pane: UUID, direction: PaneDirection)?
        if let state, let window, drag.workspace != state.id,
           let source = AppModel.shared.book.workspace(id: drag.workspace),
           source.paneCount + state.paneCount <= PaneLayout.maxPanes {
            let point = convert(window.convertPoint(fromScreen: drag.screenPoint), from: nil)
            target = PaneLayout.dropTarget(at: point, frames: paneFrames())
        }
        chipZoneShown = true
        AppModel.shared.chipDropZone = target
        showZone(target)
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
        let rects = state.layout.rects(in: bounds, divider: Self.dividerThickness)
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

/// One session's slot: hosts its `TerminalView` and, when the tab has more
/// than one pane, a header above it.
final class PaneLeafView: NSView {
    let host: SessionTerminalHost
    let session: UUID
    var terminalView: TerminalView { host.terminalView }
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

    init(host: SessionTerminalHost, session: UUID) {
        self.host = host
        self.session = session
        header = PaneHeaderView(session: session)
        super.init(frame: .zero)
        header.isHidden = true
        header.onClick = { [weak self] in
            guard let self, let window = self.window else { return }
            // The terminal's focus hook hands the keyboard on to a
            // connection question's card when one is up.
            window.makeFirstResponder(self.terminalView)
        }
        host.terminalView.autoresizingMask = [.width, .height]
        addSubview(host.terminalView)
        addSubview(header)
        // The title and the connection status change under us (OSC titles,
        // reconnects); DetailPane does not re-render for a SessionTab's own
        // changes, so the header watches the tab itself.
        if let tab = AppModel.shared.tab(id: session) {
            titleWatch = tab.$title.combineLatest(tab.$statusInfo)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] title, status in
                    guard let self, let tab else { return }
                    self.header.setTitle(title, detail: PaneHeaderView.detail(of: tab, title: title, status: status),
                                         dot: PaneHeaderView.dotColor(of: tab, status: status))
                }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let top = insets.top + (showsHeader ? PaneHeaderView.height : 0)
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PaneHeaderView.height)
        terminalView.frame = CGRect(x: insets.left, y: top,
                                    width: max(0, bounds.width - insets.left - insets.right),
                                    height: max(0, bounds.height - top - insets.bottom))
    }

    func setFocused(_ focused: Bool) {
        header.isFocused = focused
    }

    /// Variant C with a header: a rounded card in the terminal's own colour
    /// (the theme can change, so this is re-read on every layout). Without
    /// one: no card, the pane is the bare terminal as before.
    func updateCard() {
        wantsLayer = true
        guard let layer else { return }
        if showsHeader {
            layer.cornerRadius = 6
            layer.masksToBounds = true
            layer.backgroundColor = Theme.termBackgroundNS.cgColor
        } else {
            layer.cornerRadius = 0
            layer.masksToBounds = false
            layer.backgroundColor = nil
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
            host.cancelSafePaste(reason: .sessionEnded)
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
        host.cancelSafePaste(reason: .sessionEnded)
        terminalView.removeFromSuperview()
    }
}

/// A pane's header bar (only with ≥ 2 panes): title + status, a close
/// button, click to focus, drag (≥ 4 pt) to move the pane — onto another
/// pane's edge, a tab chip, or the empty tab strip. The drag carries
/// `pane:<uuid>` and never leaves the app.
final class PaneHeaderView: NSView, NSDraggingSource {
    static let height: CGFloat = 20
    static let dotSize: CGFloat = 7
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
        closeButton.toolTip = "Close Pane"
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
            if address.isEmpty { return status }
            if address == title { return down ? "disconnected" : nil }
            return down ? "\(address) · disconnected" : address
        case .serial:
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
        case .serial: return down ? SheepAlert.destructiveRed : NSColor(Theme.warn)
        }
    }

    func setTitle(_ title: String, detail: String?, dot: NSColor) {
        self.title = title
        self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
        self.dot = dot
        applyColors()
        closeButton.setAccessibilityLabel("Close \(title)")
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
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let button: CGFloat = 20
        closeButton.frame = CGRect(x: bounds.width - button - 2, y: (bounds.height - 18) / 2, width: button, height: 18)
        let textHeight = titleField.intrinsicContentSize.height
        let textX = 8 + Self.dotSize + 6
        titleField.frame = CGRect(x: textX, y: (bounds.height - textHeight) / 2,
                                  width: max(0, closeButton.frame.minX - textX - 4), height: textHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.chrome).withAlphaComponent(0.95).setFill()
        bounds.fill()
        // Drawn, not a layer: the drag image is a cacheDisplay snapshot,
        // which only sees what draw(_:) paints.
        dot.setFill()
        NSBezierPath(ovalIn: CGRect(x: 8, y: (bounds.height - Self.dotSize) / 2,
                                    width: Self.dotSize, height: Self.dotSize)).fill()
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
        item.setDraggingFrame(bounds, contents: snapshot())
        Self.draggingSession = session
        InternalDrag.pane = session
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if !dragging { onClick?() }
        dragging = false
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
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
