import AppKit
import SwiftUI

/// The sidebar's row list, as a real NSOutlineView.
///
/// The SwiftUI `List` + `.onDrag`/`.onDrop` version could never be made to
/// feel right: AppKit animates the drag image back to where the drag
/// started on every drop and SwiftUI exposes no way to stop it, so the row
/// always looked like it drifted before landing (see ARCHITECTURE §11).
/// NSOutlineView owns the whole gesture instead — it decides click vs drag
/// with the system threshold, opens the insertion gap itself, and the row
/// is simply *there* when the mouse comes up. Same feel as Reorder Groups.

// MARK: - Items

enum SidebarRowKind {
    case section        // "Connect" / "This Mac" / "Recent" — headers only
    case group          // a TOP-LEVEL group header: selectable, draggable, collapsible
    case subgroup       // a subgroup at any depth, as a folder row › that opens IN PLACE
    case host           // a host inside a group: selectable, draggable
    case staticRow      // Local Shell / a Recent entry / the search target
}

/// One row. A reference type on purpose: NSOutlineView keys expansion and
/// selection on item identity, so the coordinator hands back the *same*
/// instance for the same id on every rebuild.
final class SidebarItem: NSObject {
    let id: String
    var kind: SidebarRowKind
    var title: String = ""
    var host: Host?
    var group: HostGroup?
    var children: [SidebarItem] = []
    /// A group row's number: the hosts it DRAWS, its subgroups' included —
    /// during a search, the ones that matched.
    var count = 0
    /// How deep inside its top-level header a host or folder row sits (0 =
    /// the header's own). Drawn as a SMALL step (`SidebarOutlineCoordinator
    /// .depthStep`), not an outline level: enough to see where an open folder
    /// ends, never the full indent per level the user turned down.
    var depth = 0

    init(id: String, kind: SidebarRowKind) {
        self.id = id
        self.kind = kind
    }

    // nonisolated: NSObject requires these to be callable from any context
    // (e.g. inside AppKit collections); `id` is an immutable Sendable value.
    nonisolated override func isEqual(_ object: Any?) -> Bool {
        (object as? SidebarItem)?.id == id
    }

    nonisolated override var hash: Int { id.hashValue }

    var isExpandable: Bool { kind != .subgroup && (!children.isEmpty || kind == .group) }
}

// MARK: - Representable

struct SidebarOutline: NSViewRepresentable {
    @ObservedObject var store: HostStore
    let model: AppModel
    let searchText: String
    let connectTarget: Host?
    /// Settings → General → Sidebar.
    let showRecents: Bool
    let recentsShown: Int
    /// Folded groups, at every depth.
    @Binding var collapsedGroups: Set<UUID>
    /// OPEN subgroups (folder rows) — shut unless here, each opened and shut
    /// on its own (`SidebarLayout.toggledOpen`). Top-level headers use
    /// `collapsedGroups`.
    @Binding var openSubgroups: Set<UUID>
    let onEditHost: (Host) -> Void
    let onRenameGroup: (HostGroup) -> Void
    let onReorderGroups: () -> Void
    let onDeleteGroup: (HostGroup) -> Void
    let onExportGroup: (HostGroup) -> Void
    let onShareGroup: (HostGroup) -> Void
    let onAddHosts: (HostGroup) -> Void
    /// A group's context menu → Add Host…: one host, the form opened on this group.
    var onAddHost: (HostGroup) -> Void = { _ in }
    let onSetGroupCredential: (HostGroup) -> Void
    /// Deletes without asking: the multi-group menu has already asked once,
    /// for all of them, and one call is one write. `onDeleteGroup` keeps its
    /// own confirmation for the single-group case.
    let onDeleteGroups: (Set<UUID>) -> Void
    /// A group's menu → Add Subgroup…: a subgroup of it, named in a prompt only
    /// SwiftUI can put on screen.
    let onNewSubgroup: (HostGroup) -> Void
    /// View → Group Colors (`GroupTree.groupColorsKey`): the level bars drawn or not.
    var groupColors = GroupTree.groupColorsDefault
    /// The search field's ↑/↓/Return reach the outline through this (the
    /// caret never leaves the field); the coordinator fills it in.
    var keyBridge = SidebarKeyBridge()

    func makeCoordinator() -> SidebarOutlineCoordinator {
        SidebarOutlineCoordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView()
        outline.coordinator = context.coordinator
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.selectionHighlightStyle = .regular
        outline.style = .plain
        outline.floatsGroupRows = false
        outline.usesAutomaticRowHeights = false
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.backgroundColor = .clear
        outline.gridStyleMask = []
        // ⌘-click / ⇧-click extend the selection; plain clicks are unchanged
        // (see the modifier guard in `singleClick`). Drag moves every selected
        // host together, and the context menu acts on all of them.
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(SidebarOutlineCoordinator.singleClick(_:))
        outline.doubleAction = #selector(SidebarOutlineCoordinator.doubleClick(_:))
        outline.registerForDraggedTypes([.string])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        // Rows carry "host:<uuid>" on the pasteboard, which means nothing
        // outside this app — without this a row dragged into TextEdit or Mail
        // dropped a raw internal id there.
        outline.setDraggingSourceOperationMask([], forLocal: false)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = SidebarScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)

        context.coordinator.outline = outline
        context.coordinator.applyGroupColors()
        context.coordinator.rebuild(force: true)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.rebuild(force: false)
        context.coordinator.applyGroupColors()
    }
}

// MARK: - Outline view

/// The sidebar's scroll view: an OVERLAY scroller always — thin, shown only
/// while scrolling — whatever "Show scroll bars" says system-wide, which made
/// a permanent bar down the sidebar's right edge (the user: too strong). The
/// system re-applies its preference by setting `scrollerStyle`, so the setter
/// is pinned rather than the value set once.
final class SidebarScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

/// Adds the two things NSOutlineView leaves to the client: a per-row
/// context menu, and Return-to-connect.
final class SidebarOutlineView: NSOutlineView {
    weak var coordinator: SidebarOutlineCoordinator?

    /// How far a group header's triangle and title sit in from AppKit's
    /// place: AppKit puts the triangle on the edge of the 6 pt highlight box,
    /// so the box looked wider on the right (the user). Moved, not the box.
    /// Design G (6.0 (12)) keeps both where they were — triangle glyph at
    /// 9.5, name at `SidebarMetrics.nameX` (22.5) — and puts the level bar
    /// in the gutter in front of the triangle, so the bar costs no width.
    static let triangleShift: CGFloat = 6
    static let headerShift: CGFloat = 6

    private func isHeader(_ row: Int) -> Bool {
        (item(atRow: row) as? SidebarItem)?.kind == .group
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        if isHeader(row) { frame.origin.x += Self.triangleShift }
        return frame
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        if isHeader(row) {
            frame.origin.x += Self.headerShift
            frame.size.width -= Self.headerShift
        }
        return frame
    }

    // Keyboard focus in the list lights the level bars (`GroupTree.barsActive`).
    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { coordinator?.barActivity.focusedList = true }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { coordinator?.barActivity.focusedList = false }
        return gave
    }

    /// The pointer left the outline mid-drag. `validateDrop` stops firing at
    /// that moment, so the autoscroll speed it last set would stand and the
    /// 60 Hz timer would keep winding the list along — all the while the user
    /// is aiming at something else entirely.
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        coordinator?.stopAutoscroll()
        coordinator?.barActivity.dragging = false
        super.draggingExited(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        coordinator?.barActivity.dragging = true
        return super.draggingEntered(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        coordinator?.barActivity.dragging = false
        super.draggingEnded(sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        coordinator?.barActivity.dragging = false
        super.concludeDragOperation(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let item = item(atRow: row) as? SidebarItem else { return nil }
        // "This Mac" / "Recent" / "Connect" have no menu AND must not disturb
        // anything: `selectRowIndexes` does not consult `shouldSelectItem`, so
        // selecting one here cleared the hosts the user had just picked and
        // then showed no menu at all.
        guard item.kind != .section else { return nil }
        // AppKit's rule, spelled out: a right-click INSIDE the selection acts
        // on the whole selection; one outside it acts on that row alone and
        // takes the selection with it, so what the menu is about to touch is
        // always what is highlighted.
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return coordinator?.contextMenu(for: item)
    }

    override func keyDown(with event: NSEvent) {
        // Return / Enter opens the selection, same as a double click — every
        // selected HOST, in display order, not just `selectedRow`. With three
        // hosts highlighted, Return used to open whichever one AppKit calls
        // the selected row and leave the other two behind.
        if event.keyCode == 36 || event.keyCode == 76 {
            let rows = selectedRowIndexes.sorted()
            let items = rows.compactMap { item(atRow: $0) as? SidebarItem }
            if items.count > 1 {
                // A heading or a group among several rows has no sensible
                // "open": folding one of them while opening the others is not
                // one gesture. Hosts only.
                let hosts = items.filter { $0.kind == .host || $0.kind == .staticRow }
                // `break` to `super.keyDown`, not `return`: swallowing the
                // key silently looks like the app hung. AppKit beeps, which
                // is what "this does nothing" sounds like on a Mac.
                guard hosts.count == items.count else {
                    super.keyDown(with: event)
                    return
                }
                for row in hosts { coordinator?.activate(row) }
                return
            }
            if let item = items.first ?? item(atRow: selectedRow) as? SidebarItem {
                coordinator?.activate(item)
                return
            }
        }
        super.keyDown(with: event)
    }
}

/// Rounded grey boxes (5.0 (27), "Graphite", the user's pick): pointer over
/// = faint, selected = stronger with brighter text, the row being opened
/// flashes stronger still. Drawn here rather
/// than left to AppKit because the sidebar hands focus straight back to the
/// terminal on every click, which would render the system highlight in its
/// washed-out unfocused grey. Hover is drawing only — the tracking area never
/// takes a click (sidebar clicks are timing-sensitive, CLAUDE.md).
final class SidebarRowView: NSTableRowView {
    var activated = false {
        didSet { if activated != oldValue { needsDisplay = true } }
    }
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }
    private var hoverArea: NSTrackingArea?

    /// The box's colour — "Graphite" (the user picked it from six): grey
    /// boxes only, pointer over faint, selected stronger, the row being
    /// opened flashes stronger still. The selected row's text is brightened
    /// by its cell (`SidebarRowHighlight`).
    static func boxColor(selected: Bool, activated: Bool, hovering: Bool) -> NSColor? {
        if activated { return NSColor.white.withAlphaComponent(0.22) }
        if selected { return NSColor.white.withAlphaComponent(0.14) }
        return hovering ? NSColor.white.withAlphaComponent(0.06) : nil
    }

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { tellCells() } }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? SidebarRowHighlight)?.setRowSelected(isSelected)
    }

    private func tellCells() {
        for case let cell as SidebarRowHighlight in subviews { cell.setRowSelected(isSelected) }
    }

    private func fillBox(_ color: NSColor?) {
        guard let color else { return }
        color.setFill()
        // The same 6 pt on both sides for every row; a group header's
        // triangle is moved INTO the box instead (`SidebarOutlineView
        // .frameOfOutlineCell`).
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        // A row that scrolled out from under a still pointer must not stay lit.
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            hovering = bounds.contains(point)
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        fillBox(Self.boxColor(selected: true, activated: activated, hovering: hovering))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Section rows have no AppKit selection style (`.none`), so their box
        // — hover and selected alike — is drawn here too (the user: sections
        // as well). Other rows: the hover box and the flash of an activated
        // row when not selected (double-clicking the already-selected row).
        if selectionHighlightStyle == .none {
            fillBox(Self.boxColor(selected: isSelected, activated: activated, hovering: hovering))
            return
        }
        guard !isSelected else { return }
        fillBox(Self.boxColor(selected: false, activated: activated, hovering: hovering))
    }
}

// MARK: - Cell views

/// A cell whose text brightens while its row is selected (Graphite).
protocol SidebarRowHighlight: AnyObject {
    func setRowSelected(_ selected: Bool)
}

/// Where a row's parts go (6.0 (12), design G + the user's spacing), in
/// points from the row's left edge, for a top-level group; each level is one
/// `step` further in. The level bar sits in the GUTTER at `barX` (it costs no
/// width), the arrow right after it (glyph at `arrowX`), the name where it
/// always was (`nameX`). A group's hosts start under its ARROW (`hostX`) —
/// This Mac / Recent's hosts too. Every row's text stops `trailing` short of
/// the row's right edge. The highlight box keeps its own 6 pt inset.
enum SidebarMetrics {
    static let barX: CGFloat = 4.5
    static let barWidth: CGFloat = 3
    static let barHeight: CGFloat = 14
    static let step: CGFloat = 14
    /// The header triangle's glyph (AppKit's, shifted `headerShift`).
    static let arrowX: CGFloat = 9.5
    /// A top-level group's name.
    static let nameX: CGFloat = 22.5
    /// A top-level group's hosts' badges (and This Mac / Recent's): under the arrow.
    static let hostX: CGFloat = 10
    static let trailing: CGFloat = 9
    /// From a group's name back to its bar.
    static let barToName: CGFloat = nameX - barX
    /// A label field draws its text this far in from its frame (measured on
    /// screen); the places above are where the TEXT starts.
    static let labelInset: CGFloat = 2.5
}

/// A group row's level bar: 3 × 14 pt, radius 1.5, the level's colour
/// (`GroupTree.levelColor`), dim until the user works in the sidebar
/// (`GroupTree.barOpacity`).
final class SidebarLevelBar: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 1.5
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private(set) var level = 0
    private(set) var shown = true

    func configure(level: Int, active: Bool, shown: Bool) {
        self.level = level
        self.shown = shown
        isHidden = level < 1
        let rgb = GroupTree.levelColor(depth: max(1, level))
        layer?.backgroundColor = NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                                         green: CGFloat((rgb >> 8) & 0xFF) / 255,
                                         blue: CGFloat(rgb & 0xFF) / 255, alpha: 1).cgColor
        alphaValue = GroupTree.barOpacity(active: active, depth: level, shown: shown)
    }

    func setActive(_ active: Bool, animated: Bool, shown: Bool? = nil) {
        if let shown { self.shown = shown }
        let target = GroupTree.barOpacity(active: active, depth: level, shown: self.shown)
        let fade = animated ? GroupTree.barFade(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) : 0
        guard fade > 0 else { alphaValue = target; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            animator().alphaValue = target
        }
    }
}

/// A cell that draws a level bar (group header, subgroup row).
protocol SidebarLevelBarCell: AnyObject {
    var levelBar: SidebarLevelBar { get }
}

extension NSView {
    /// The x in THIS view's coordinates that is `inset` short of the row
    /// view's right edge (the cell's own frame stops wherever AppKit puts
    /// the column, not where the row ends).
    func sidebarTextLimit(inset: CGFloat) -> CGFloat {
        guard let row = superview else { return bounds.maxX - inset }
        return convert(NSPoint(x: row.bounds.maxX - inset, y: 0), from: row).x
    }
}

/// Badge + name + address. `hitTest` returns nil so every mouse event
/// belongs to the outline view — that is what makes a click land on the
/// first try and a drag start without a hitch.
final class SidebarHostCell: NSView, SidebarRowHighlight {
    private let badgePill = NSView()
    private let badge = NSTextField(labelWithString: "")
    /// A web host's globe, in place of the text badge (same pill).
    private let symbolView = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        badge.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        badge.alignment = .center
        badgePill.wantsLayer = true
        badgePill.layer?.cornerRadius = 4
        name.font = .systemFont(ofSize: 12.5)
        name.lineBreakMode = .byTruncatingTail
        detail.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        for view in [badgePill, name, detail] { addSubview(view) }
        badgePill.addSubview(badge)
        badgePill.addSubview(symbolView)
        symbolView.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var rowSelected = false

    func setRowSelected(_ selected: Bool) {
        rowSelected = selected
        name.textColor = selected ? .white : .labelColor
        detail.textColor = selected ? NSColor.white.withAlphaComponent(0.72) : .secondaryLabelColor
    }

    func configure(badge text: String, color: NSColor, name title: String, detail subtitle: String?,
                   symbol: String? = nil) {
        badge.stringValue = text
        badge.textColor = color
        badge.isHidden = symbol != nil
        symbolView.isHidden = symbol == nil
        if let symbol {
            symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
            symbolView.contentTintColor = color
        }
        badgePill.layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
        name.stringValue = title
        detail.stringValue = subtitle ?? ""
        detail.isHidden = (subtitle ?? "").isEmpty
        setRowSelected(rowSelected)
        needsLayout = true
    }

    /// Rows sit one indentation step in from their group header; pulled
    /// back so the badge starts UNDER the header's arrow
    /// (`SidebarMetrics.hostX` — this cell starts 38 pt into the row).
    private static let leading: CGFloat = SidebarMetrics.hostX - 38
    /// Extra lead for a host inside an open folder (`SidebarItem.depth`).
    var indent: CGFloat = 0 { didSet { if indent != oldValue { needsLayout = true; needsDisplay = true } } }

    override func layout() {
        super.layout()
        let leading = Self.leading + indent
        let textSize = badge.intrinsicContentSize
        let badgeWidth = max(28, textSize.width + 8)
        let badgeHeight: CGFloat = 14
        badgePill.frame = NSRect(x: leading,
                                 y: ((bounds.height - badgeHeight) / 2).rounded(),
                                 width: badgeWidth, height: badgeHeight)
        // The label is only as tall as its glyphs; centre it inside the pill so
        // the caption sits on the middle line instead of riding the top edge.
        let labelHeight = textSize.height.rounded(.up)
        badge.frame = NSRect(x: 0, y: ((badgeHeight - labelHeight) / 2).rounded(),
                             width: badgeWidth, height: labelHeight)
        symbolView.frame = NSRect(x: 0, y: 0, width: badgeWidth, height: badgeHeight)
        let textX = leading + badgeWidth + 8
        let textWidth = max(0, sidebarTextLimit(inset: SidebarMetrics.trailing) - textX)
        if detail.isHidden {
            name.frame = NSRect(x: textX, y: (bounds.height - 16) / 2, width: textWidth, height: 16)
        } else {
            name.frame = NSRect(x: textX, y: bounds.height / 2 - 1, width: textWidth, height: 16)
            detail.frame = NSRect(x: textX, y: bounds.height / 2 - 14, width: textWidth, height: 13)
        }
    }
}


/// A subgroup's row (6.0 (12)): a disclosure arrow like a group header's
/// (› shut, ⌄ open — the user: the same arrow, no folder icon), the name, and
/// its subtree's host count beside it. A click opens it IN PLACE: its hosts
/// and subgroups follow it one small step in (`SidebarItem.depth`), so the
/// sidebar never indents a full level per depth (the user: no stair of
/// indents, no second page).
final class SidebarFolderCell: NSView, SidebarRowHighlight, SidebarLevelBarCell {
    let levelBar = SidebarLevelBar()
    private let arrow = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // A host name's size and weight, not a header's: the bold top-level
        // header is the only bold row, so a subgroup never reads as one.
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        count.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
        for view in [levelBar, arrow, title, count] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var rowSelected = false

    func setRowSelected(_ selected: Bool) {
        rowSelected = selected
        title.textColor = selected ? .white : .labelColor
        count.textColor = selected ? NSColor.white.withAlphaComponent(0.6) : .tertiaryLabelColor
        arrow.contentTintColor = selected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
    }

    func configure(title text: String, count number: Int, open: Bool) {
        arrow.image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        title.stringValue = text
        count.stringValue = String(number)
        setAccessibilityLabel(String(localized: "\(text), \(number) hosts"))
        setRowSelected(rowSelected)
        needsLayout = true
    }

    /// The NAME's place for a subgroup of a top-level group: one step past
    /// the header's name (this cell starts 38 pt into the row) — its arrow
    /// one step past the header's arrow, its bar in front of the arrow.
    private static let leading: CGFloat = SidebarMetrics.nameX + SidebarMetrics.step - 38 - SidebarMetrics.labelInset
    /// Extra lead for a subgroup inside an open one (`SidebarItem.depth`).
    var indent: CGFloat = 0 { didSet { if indent != oldValue { needsLayout = true; needsDisplay = true } } }

    override func layout() {
        super.layout()
        let textX = Self.leading + indent
        let barX = textX + SidebarMetrics.labelInset - SidebarMetrics.barToName
        levelBar.frame = NSRect(x: barX, y: ((bounds.height - SidebarMetrics.barHeight) / 2).rounded(),
                                width: SidebarMetrics.barWidth, height: SidebarMetrics.barHeight)
        // The arrow's glyph where a header's sits relative to its bar
        // (`SidebarMetrics.arrowX`); the 12 pt frame centres a 7.5 pt glyph.
        let arrowX = barX + (SidebarMetrics.arrowX - SidebarMetrics.barX) - 2.25
        arrow.frame = NSRect(x: arrowX, y: (bounds.height - 12) / 2, width: 12, height: 12)
        // Measured from the text, not the field: a reused cell's field still
        // has the previous row's size here.
        // `fittingSize`, the width the field itself asks for: a label cell
        // draws its text inset from both sides, and a frame as wide as the
        // glyphs (or the intrinsic width) still cut every name short —
        // "Buildin…" (the user, twice). Full name unless the row runs out.
        let measured = ceil(title.fittingSize.width)
        let limit = sidebarTextLimit(inset: SidebarMetrics.trailing)
        let countWidth = ceil(count.fittingSize.width)
        let titleWidth = min(measured, max(0, limit - textX - countWidth - 5))
        title.frame = NSRect(x: textX, y: (bounds.height - 16) / 2, width: titleWidth, height: 16)
        count.frame = NSRect(x: textX + titleWidth + 5, y: (bounds.height - 13) / 2,
                             width: max(0, limit - textX - titleWidth - 5), height: 13)
    }
}

/// Group header (bold name + host count) and section header share one cell.
final class SidebarLabelCell: NSView, SidebarRowHighlight, SidebarLevelBarCell {
    /// A group header's bar, left of AppKit's triangle; hidden on a heading.
    let levelBar = SidebarLevelBar()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        count.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
        count.textColor = .tertiaryLabelColor
        addSubview(levelBar)
        addSubview(title)
        addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var rowSelected = false
    private var quiet = false

    func setRowSelected(_ selected: Bool) {
        rowSelected = selected
        title.textColor = selected ? .white : (quiet ? .secondaryLabelColor : .labelColor)
        count.textColor = selected ? NSColor.white.withAlphaComponent(0.6) : .tertiaryLabelColor
    }

    func configure(title text: String, count number: Int?, quiet: Bool = false) {
        self.quiet = quiet
        title.stringValue = text
        // A heading INSIDE a group sits one level below the group's own row,
        // so it is a little smaller and a little quieter — the only
        // difference, because it is the same kind of row one step down.
        title.font = .systemFont(ofSize: quiet ? 10.5 : 11.5, weight: quiet ? .medium : .semibold)
        setRowSelected(rowSelected)
        count.stringValue = number.map(String.init) ?? ""
        count.isHidden = number == nil
        // The count is a bare number beside a name, which VoiceOver reads as
        // "Lab 13" — a row of a list, or thirteen of something? Said out loud
        // once, here, for group rows and heading rows alike.
        if let number {
            setAccessibilityLabel(String(localized: "\(text), \(number) hosts"))
        } else {
            setAccessibilityLabel(text)
        }
        needsLayout = true
    }

    /// Header text hugs the disclosure triangle: NSOutlineView reserves a
    /// full indentation step for it, which left the group name floating
    /// away from its own chevron.
    private static let leading: CGFloat = -12

    override func layout() {
        super.layout()
        let x = Self.leading
        levelBar.frame = NSRect(x: x + SidebarMetrics.labelInset - SidebarMetrics.barToName,
                                y: ((bounds.height - SidebarMetrics.barHeight) / 2).rounded(),
                                width: SidebarMetrics.barWidth, height: SidebarMetrics.barHeight)
        let limit = sidebarTextLimit(inset: SidebarMetrics.trailing)
        let countWidth = count.isHidden ? 0 : ceil(count.fittingSize.width) + 5
        let titleWidth = min(ceil(title.intrinsicContentSize.width) + 1, max(0, limit - x - countWidth))
        title.frame = NSRect(x: x, y: (bounds.height - 15) / 2, width: titleWidth, height: 15)
        count.frame = NSRect(x: x + titleWidth + 5, y: (bounds.height - 13) / 2,
                             width: max(0, limit - x - titleWidth - 5), height: 13)
    }
}

// MARK: - Coordinator

@MainActor
final class SidebarOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var parent: SidebarOutline
    weak var outline: SidebarOutlineView?

    /// The row the search field's arrows selected (cleared as soon as the
    /// selection becomes anything else — a click, a rebuild that dropped it).
    /// Return in the field only opens a host the ARROWS picked, never one that
    /// was merely left selected by an earlier click.
    private var arrowSelectedID: String?
    private var arrowMoving = false

    private func installKeyBridge() {
        parent.keyBridge.move = { [weak self] delta in self?.moveArrowSelection(delta) }
        parent.keyBridge.activateSelection = { [weak self] in self?.activateArrowSelection() ?? false }
        parent.keyBridge.barActivity.onChange = { [weak self] active in self?.setBarsActive(active) }
    }

    /// Per row, in display order: can a host be opened from it.
    private func hostRowFlags(_ outline: NSOutlineView) -> [Bool] {
        (0..<outline.numberOfRows).map { row in
            let kind = (outline.item(atRow: row) as? SidebarItem)?.kind
            return kind == .host || kind == .staticRow
        }
    }

    /// ↓ / ↑ in the search field. Selection only (what an arrow key does in
    /// any list); the keyboard stays in the field, nothing is opened.
    var barActivity: SidebarBarActivity { parent.keyBridge.barActivity }

    /// Fades every visible level bar to the new state; rows made later take
    /// it when they are configured.
    private func setBarsActive(_ active: Bool) {
        outline?.enumerateAvailableRowViews { row, _ in
            for case let cell as SidebarLevelBarCell in row.subviews {
                cell.levelBar.setActive(active, animated: true)
            }
        }
    }

    private var drawnGroupColors = GroupTree.groupColorsDefault
    /// Group Colors switched: every visible bar shows or hides at once (no
    /// row moves — the bar has its own place in the gutter).
    func applyGroupColors() {
        guard parent.groupColors != drawnGroupColors else { return }
        drawnGroupColors = parent.groupColors
        outline?.enumerateAvailableRowViews { row, _ in
            for case let cell as SidebarLevelBarCell in row.subviews {
                cell.levelBar.setActive(barActivity.active, animated: false, shown: drawnGroupColors)
            }
        }
    }

    private func moveArrowSelection(_ delta: Int) {
        guard let outline else { return }
        let current = arrowSelectedID.flatMap { cache[$0] }.map { outline.row(forItem: $0) }
            .flatMap { $0 >= 0 ? $0 : nil }
        guard let row = SearchNav.step(current: current, delta: delta, eligible: hostRowFlags(outline)),
              let item = outline.item(atRow: row) as? SidebarItem else { return }
        arrowMoving = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        arrowMoving = false
        arrowSelectedID = item.id
        outline.scrollRowToVisible(row)
    }

    private func activateArrowSelection() -> Bool {
        guard let outline, let id = arrowSelectedID, let node = cache[id],
              outline.row(forItem: node) >= 0, outline.isRowSelected(outline.row(forItem: node)) else { return false }
        activate(node)
        return true
    }

    private var roots: [SidebarItem] = []
    private var cache: [String: SidebarItem] = [:]
    private var signature = ""
    private var activatedID: String?
    /// The selected rows, in display order. A LIST because the sidebar is
    /// multi-select now: one entry is the ordinary case, and the same
    /// bookkeeping has to survive a rebuild either way.
    private var selectedIDs: [String] = []
    /// Set while we drive the outline ourselves, so expansion callbacks
    /// don't write the state they are replaying back into UserDefaults.
    private var applyingExpansion = false
    /// Set while `restoreSelection` moves the highlight, so the selection
    /// callback doesn't mistake our own bookkeeping for a user choice.
    private var restoringSelection = false
    /// True between the drag starting and the drag ending in THIS outline,
    /// with a rebuild owed once it is over.
    /// How far the sidebar's cells draw outside their own bounds: the host
    /// badge sits at x = -14 and a group title at x = -12 (the two `leading`
    /// constants), so a snapshot has to reach past the left edge to catch them.
    static let cellOverhang: CGFloat = 16

    /// Repeating while the pointer sits in the hot zone at either end of the
    /// list. `validateDrop` only fires when the pointer MOVES, and a drag held
    /// still against the bottom edge is exactly when the list has to keep
    /// coming — hence a timer rather than a scroll per callback.
    private var autoscrollTimer: Timer?
    /// Points per tick, signed: negative scrolls toward the top.
    private var autoscrollStep: CGFloat = 0
    /// How deep the hot zone at each end is, and how fast it can get.
    private static let autoscrollZone: CGFloat = 28
    private static let autoscrollMaxStep: CGFloat = 14

    /// Temporary tracer for the "a double click sometimes does nothing"
    /// report: set `SHEEPTERM_CLICKLOG=1` and the sidebar prints every step of
    /// a group toggle to stderr. Off by default and free when off.
    static let clickLog = ProcessInfo.processInfo.environment["SHEEPTERM_CLICKLOG"] == "1"

    func trace(_ what: @autoclosure () -> String) {
        guard SidebarOutlineCoordinator.clickLog else { return }
        FileHandle.standardError.write("[sidebar \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] \(what())\n".data(using: .utf8)!)
    }


    private var isDragging = false
    private var pendingRebuild = false

    init(_ parent: SidebarOutline) {
        self.parent = parent
        super.init()
        installKeyBridge()
    }

    // MARK: Model

    private func item(id: String, kind: SidebarRowKind) -> SidebarItem {
        if let existing = cache[id] {
            existing.kind = kind
            existing.children = []
            return existing
        }
        let fresh = SidebarItem(id: id, kind: kind)
        cache[id] = fresh
        return fresh
    }

    /// The hosts a search shows, per group id — every group when the field is
    /// empty. A host matches on its name or address, or on the name of the
    /// SUBGROUP it is in (what a section name did before nested groups: a
    /// visible word that finds nothing is the kind of small lie that makes a
    /// search feel broken). A group with no match in its subtree is not drawn.
    private func shownHosts() -> [UUID: [Host]] {
        let text = parent.searchText
        var out: [UUID: [Host]] = [:]
        for group in parent.store.groups where out[group.id] == nil {
            guard !text.isEmpty else { out[group.id] = group.hosts; continue }
            let byName = group.parentID != nil && group.name.matchesSearch(text)
            out[group.id] = byName ? group.hosts
                : group.hosts.filter { $0.name.matchesSearch(text) || $0.address.matchesSearch(text) }
        }
        return out
    }


    /// Everything rebuild() reads. Comparing this is what lets an unrelated
    /// publish cost nothing.
    private struct InputStamp: Equatable {
        var revision: Int
        var search: String
        var showRecents: Bool
        var recentsShown: Int
        var collapsed: Set<UUID>
        var open: Set<UUID>
    }
    private var lastStamp: InputStamp?

    private func buildRoots() -> [SidebarItem] {
        var result: [SidebarItem] = []

        if let target = parent.connectTarget {
            let section = item(id: "section-connect", kind: .section)
            section.title = String(localized: "Connect")
            let row = item(id: "connect-target", kind: .staticRow)
            row.host = target
            section.children = [row]
            result.append(section)
        }

        do {
            let local = item(id: "section-local", kind: .section)
            local.title = String(localized: "This Mac")
            let shell = item(id: "local", kind: .staticRow)
            shell.title = String(localized: "Local Shell")
            local.children = [shell]
            result.append(local)

            if parent.showRecents && parent.searchText.isEmpty && !parent.store.recents.isEmpty {
                let recent = item(id: "section-recent", kind: .section)
                recent.title = String(localized: "Recent")
                let shown = min(max(parent.recentsShown, 1), HostStore.maxRecents)
                recent.children = parent.store.recents.prefix(shown).map { host in
                    let row = item(id: "recent-\(host.id.uuidString)", kind: .staticRow)
                    row.host = host
                    return row
                }
                result.append(recent)
            }
        }

        // The groups, TWO levels deep at most however deep they go: a
        // top-level group header (collapsible) whose rows are its own hosts,
        // then its subgroups as folder rows; an OPEN folder's hosts and
        // folders follow it at the same level, and so on down — one indent,
        // whatever the depth. A folder is SHUT unless its id is in
        // `openSubgroups` (`SidebarLayout.toggledOpen`). A search
        // shows every group with a match flat, titled with its path.
        let searching = !parent.searchText.isEmpty
        let shown = shownHosts()
        let all = parent.store.groups
        let subgroups = SidebarLayout.childMap(all)
        var counted: [UUID: Int] = [:]
        var visiting = Set<UUID>()
        func subtreeCount(_ group: HostGroup) -> Int {
            if let known = counted[group.id] { return known }
            // A list `repair` has not seen (mid-merge) could hold a cycle.
            guard visiting.insert(group.id).inserted else { return 0 }
            defer { visiting.remove(group.id) }
            let total = group.hosts.count + (subgroups[group.id] ?? []).reduce(0) { $0 + subtreeCount($1) }
            counted[group.id] = total
            return total
        }
        func hostRow(_ host: Host, in group: HostGroup) -> SidebarItem {
            let row = item(id: "host-\(host.id.uuidString)", kind: .host)
            row.host = host
            row.group = group
            row.depth = 0
            return row
        }
        var placed = Set<UUID>()
        func rows(of group: HostGroup, depth: Int = 0) -> [SidebarItem] {
            guard placed.insert(group.id).inserted else { return [] }
            var out: [SidebarItem] = []
            for row in SidebarLayout.rows(for: group, subgroups: subgroups[group.id] ?? []) {
                switch row {
                case .host(let host):
                    let row = hostRow(host, in: group)
                    row.depth = depth
                    out.append(row)
                case .group(let sub):
                    let folder = item(id: "sub-\(sub.id.uuidString)", kind: .subgroup)
                    folder.group = sub
                    folder.title = sub.name
                    folder.count = subtreeCount(sub)
                    folder.depth = depth
                    out.append(folder)
                    if parent.openSubgroups.contains(sub.id) { out += rows(of: sub, depth: depth + 1) }
                }
            }
            return out
        }
        if searching {
            for entry in GroupTree.preorder(all) {
                let hosts = shown[entry.group.id] ?? []
                guard !hosts.isEmpty else { continue }
                let node = item(id: "group-\(entry.group.id.uuidString)", kind: .group)
                node.group = entry.group
                node.title = GroupTree.shownPath(of: entry.group.id, in: all)
                node.children = hosts.map { hostRow($0, in: entry.group) }
                node.count = hosts.count
                result.append(node)
            }
        } else {
            for group in GroupTree.children(of: nil, in: all) {
                let node = item(id: "group-\(group.id.uuidString)", kind: .group)
                node.group = group
                node.title = group.name
                node.children = rows(of: group)
                node.count = subtreeCount(group)
                result.append(node)
            }
        }
        // Rows that no longer exist must leave the cache with them —
        // otherwise every deleted host keeps its item alive for the life
        // of the window. Any depth, so this walks.
        var live: Set<String> = []
        func mark(_ node: SidebarItem) {
            live.insert(node.id)
            for child in node.children { mark(child) }
        }
        for root in result { mark(root) }
        cache = cache.filter { live.contains($0.key) }
        return result
    }

    /// Cheap "did anything visible change" check — updateNSView runs on every
    /// @Published touch in the app and a reload mid-drag would be fatal.
    private func currentSignature(_ roots: [SidebarItem]) -> String {
        var parts: [String] = [parent.searchText]
        // Depth-first, so a host or a subgroup moving between two groups at
        // any depth changes the walk.
        func walk(_ node: SidebarItem, depth: Int) {
            // The count the row DRAWS is part of the signature: a group shows
            // every host in its subtree, so a move between two of its
            // subgroups reloads it too.
            let drawn = node.kind == .group || node.kind == .subgroup ? node.count : node.children.count
            parts.append("\(depth).\(node.depth)|" + node.id + "|" + (node.host?.name ?? node.title)
                         + "|" + (node.host?.address ?? "") + "|" + (node.host?.kind.badge ?? "")
                         + "|" + String(drawn))
            for child in node.children { walk(child, depth: depth + 1) }
        }
        for root in roots { walk(root, depth: 0) }
        parts.append(parent.collapsedGroups.map(\.uuidString).sorted().joined(separator: ","))
        parts.append(parent.openSubgroups.map(\.uuidString).sorted().joined(separator: ","))
        return parts.joined(separator: "\n")
    }

    func rebuild(force: Bool) {
        guard let outline else { return }
        // Nothing may move while AppKit is tracking a drag. It holds row
        // indexes into the layout it last asked us about, and buildRoots()
        // rewrites the very `children` arrays validateDrop is indexing — a
        // session finishing mid-drag (which appends to Recent, so the stamp
        // really does change) was enough to reload the outline out from under
        // the drop. Owe the rebuild instead and pay it in draggingSession
        // ended, which AppKit always calls, cancelled drags included.
        if isDragging {
            pendingRebuild = true
            return
        }
        // Cheap gate first. buildRoots() allocates a SidebarItem per node and
        // currentSignature() joins a String from every row — at 2,000 hosts
        // that is ~2.3 ms and ~75 KB of garbage, and updateNSView runs on
        // EVERY AppModel publish, so a divider drag paid it per frame.
        let stamp = InputStamp(revision: parent.store.revision,
                               search: parent.searchText,
                               showRecents: parent.showRecents,
                               recentsShown: parent.recentsShown,
                               collapsed: parent.collapsedGroups,
                               open: parent.openSubgroups)
        if !force, stamp == lastStamp { return }
        lastStamp = stamp

        let fresh = buildRoots()
        let newSignature = currentSignature(fresh)
        guard force || newSignature != signature else {
            trace("rebuild: signature unchanged, keeping the outline as it is")
            roots = fresh
            return
        }
        trace("rebuild: RELOAD + applyExpansion (force=\(force))")
        signature = newSignature
        roots = fresh
        // Read the wanted row BEFORE the reload: reloadData trims a selection
        // whose row index no longer exists and posts the change straight back
        // into outlineViewSelectionDidChange, so by the time we get here
        // `selectedID` is already whatever landed under the old row number.
        let wanted = selectedIDs
        outline.reloadData()
        applyExpansion()
        restoreSelection(wanted)
    }

    private func applyExpansion() {
        guard let outline else { return }
        applyingExpansion = true
        for root in roots { apply(root, in: outline) }
        applyingExpansion = false
    }

    /// Applies the stored fold state to one row and everything under it.
    ///
    /// **AppKit rule, measured:** `expandItem`/`collapseItem` do NOTHING for
    /// an item inside a COLLAPSED parent, and `isItemExpanded` reports every
    /// such item as not-expanded whatever it was. So this walks parents before
    /// children (a heading can only be folded once its group is open), and
    /// `outlineViewItemDidExpand` calls it again for the subtree the user just
    /// opened — that is the only moment the children can be applied at all.
    private func apply(_ node: SidebarItem, in outline: NSOutlineView) {
        switch node.kind {
        case .section:
            outline.expandItem(node)
        case .group:
            // A search shows everything it matched: folding a group over a
            // hit hides it.
            let collapsed = !parent.searchText.isEmpty
                ? false
                : parent.collapsedGroups.contains(node.group?.id ?? UUID())
            if collapsed != !outline.isItemExpanded(node) {
                trace("applyExpansion: forcing \(node.title) to \(collapsed ? "collapsed" : "expanded")")
            }
            if collapsed {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
        default:
            return
        }
        for child in node.children { apply(child, in: outline) }
    }

    /// Puts the highlight back on `wanted`, and keeps remembering it even
    /// when the row is off screen — a search that hides it or a group folded
    /// over it must not count as the user deselecting, or clearing the filter
    /// (reopening the group) would come back blank.
    private func restoreSelection(_ wanted: [String]) {
        guard let outline, !wanted.isEmpty else { return }
        var rows = IndexSet()
        for id in wanted {
            guard let node = cache[id] else { continue }
            let row = outline.row(forItem: node)
            if row >= 0 { rows.insert(row) }
        }
        restoringSelection = true
        if rows.isEmpty {
            outline.deselectAll(nil)
        } else {
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }
        restoringSelection = false
        // With rows found, the ids are kept whole: a row folded away inside a
        // collapsed group is off screen, not gone, and its highlight must come
        // back when the group reopens (see `outlineViewSelectionDidChange`).
        //
        // With NONE found, keep only the ids the cache still knows. An id that
        // no longer exists anywhere would sit here forever.
        selectedIDs = rows.isEmpty ? wanted.filter { cache[$0] != nil } : wanted
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return roots.count }
        return (item as? SidebarItem)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return roots[index] }
        return (item as! SidebarItem).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.isExpandable ?? false
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as? SidebarItem)?.kind {
        case .section: return 22
        case .group: return 24
        case .subgroup: return 24
        default: return 34
        }
    }

    private static let rowID = NSUserInterfaceItemIdentifier("row")
    private static let labelID = NSUserInterfaceItemIdentifier("label")
    private static let hostID = NSUserInterfaceItemIdentifier("host")
    private static let folderID = NSUserInterfaceItemIdentifier("folder")
    /// One open folder deeper = this much further in (see `SidebarItem.depth`).
    static let depthStep: CGFloat = SidebarMetrics.step

    /// The level of the group a header or subgroup row stands for, in the
    /// REAL tree (a search header named by its path keeps its own level's
    /// colour); 1 when the group is gone mid-rebuild.
    private func groupLevel(_ node: SidebarItem) -> Int {
        guard let id = node.group?.id else { return 1 }
        return GroupTree.depth(of: id, in: parent.store.groups)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = outlineView.makeView(withIdentifier: Self.rowID, owner: self) as? SidebarRowView
            ?? { let fresh = SidebarRowView(); fresh.identifier = Self.rowID; return fresh }()
        // Every property is set on both paths: a recycled row still carries
        // the previous row's flash and highlight style.
        row.activated = (item as? SidebarItem)?.id == activatedID
        let kind = (item as? SidebarItem)?.kind
        row.selectionHighlightStyle = kind == .section ? .none : .regular
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarItem else { return nil }
        switch node.kind {
        case .section:
            let cell = labelCell(outlineView)
            cell.configure(title: node.title, count: nil)
            cell.levelBar.configure(level: 0, active: barActivity.active, shown: false)
            return cell
        case .group:
            let cell = labelCell(outlineView)
            cell.configure(title: node.title, count: node.count)
            cell.levelBar.configure(level: groupLevel(node), active: barActivity.active, shown: parent.groupColors)
            return cell
        case .subgroup:
            let cell = outlineView.makeView(withIdentifier: Self.folderID, owner: self) as? SidebarFolderCell
                ?? { let fresh = SidebarFolderCell(); fresh.identifier = Self.folderID; return fresh }()
            cell.configure(title: node.title, count: node.count,
                           open: node.group.map { parent.openSubgroups.contains($0.id) } ?? false)
            cell.indent = Self.depthStep * CGFloat(node.depth)
            cell.levelBar.configure(level: groupLevel(node), active: barActivity.active, shown: parent.groupColors)
            return cell
        case .host, .staticRow:
            let cell = hostCell(outlineView)
            cell.indent = Self.depthStep * CGFloat(node.depth)
            if let host = node.host {
                let isConnectTarget = node.id == "connect-target"
                if isConnectTarget, host.pingTargets != nil {
                    cell.configure(badge: "", color: NSColor(Theme.ok), name: host.name,
                                   detail: String(localized: "ping tab · press ↩"), symbol: "waveform.path.ecg")
                    return cell
                }
                cell.configure(
                    badge: host.kind.badge,
                    color: NSColor(Theme.kindColor(host.kind)),
                    name: isConnectTarget && host.kind == .web ? String(localized: "Open \(host.address)") : host.name,
                    detail: isConnectTarget
                        ? (host.kind == .web ? String(localized: "web tab · press ↩ to open") : String(localized: "port \(String(host.port)) · press ↩ to connect"))
                        : (host.address.isEmpty ? nil : host.kind == .web ? WebAddress.shortLabel(host.address) : host.address),
                    symbol: host.kind == .web ? "globe" : nil
                )
            } else {
                cell.configure(badge: "ZSH", color: NSColor(Theme.ok), name: node.title, detail: nil)
            }
            return cell
        }
    }

    private func labelCell(_ outlineView: NSOutlineView) -> SidebarLabelCell {
        if let reused = outlineView.makeView(withIdentifier: Self.labelID, owner: self) as? SidebarLabelCell {
            return reused
        }
        let cell = SidebarLabelCell()
        cell.identifier = Self.labelID
        return cell
    }

    private func hostCell(_ outlineView: NSOutlineView) -> SidebarHostCell {
        if let reused = outlineView.makeView(withIdentifier: Self.hostID, owner: self) as? SidebarHostCell {
            return reused
        }
        let cell = SidebarHostCell()
        cell.identifier = Self.hostID
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarItem)?.kind != .section
    }

    /// Keeps the fixed headings out of a MULTI-selection.
    func outlineView(_ outlineView: NSOutlineView,
                     selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard proposed.count > 1 else { return proposed }
        return proposed.filteredIndexSet { row in
            // `.section` too — the static "Hosts" / "Recent" headings.
            // `shouldSelectItem` refuses them one at a time, but a
            // shift-drag proposes a RANGE and AppKit hands the whole range
            // here, so a sweep from a host up past "Hosts" used to end with
            // the heading highlighted.
            (outlineView.item(atRow: row) as? SidebarItem)?.kind != .section
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        (item as? SidebarItem)?.kind != .section
    }

    /// "This Mac" / "Recent" / "Connect" are always open, so they get no
    /// disclosure triangle — only the groups, which really do fold.
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        (item as? SidebarItem)?.kind == .group
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection, let outline else { return }
        if !arrowMoving { arrowSelectedID = nil }
        let ids = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarItem)?.id }
        if !ids.isEmpty {
            selectedIDs = ids
            return
        }
        // No selection any more. AppKit also drops the highlight when the
        // selected row is folded away inside a collapsed group — that is the
        // row disappearing, not the user picking something else, so the ids
        // stay and the highlight returns when the group reopens.
        // EVERY remaining id has to be off screen for this to be "the rows
        // were folded away" rather than "the user deselected": with one
        // visible row still selected, an empty selection is a real deselect,
        // and keeping the ids brought the highlight back on the next rebuild.
        let live = selectedIDs.compactMap { cache[$0] }
        if !live.isEmpty, live.allSatisfy({ outline.row(forItem: $0) < 0 }) { return }
        selectedIDs = []
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        trace("didCollapse \((notification.userInfo?["NSObject"] as? SidebarItem)?.title ?? "?")")
        syncCollapsedFromOutline()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        let opened = notification.userInfo?["NSObject"] as? SidebarItem
        trace("didExpand \(opened?.title ?? "?") applying=\(applyingExpansion)")
        // The rows inside it could not be folded while it was closed (AppKit
        // ignores expand/collapse under a collapsed parent), so their stored
        // state has to be applied NOW — otherwise a group opened by hand comes
        // back with every subgroup inside it expanded.
        if !applyingExpansion, let opened, let outline, !opened.children.isEmpty {
            applyingExpansion = true
            for child in opened.children { apply(child, in: outline) }
            applyingExpansion = false
        }
        syncCollapsedFromOutline()
        // Expanding by hand doesn't go through rebuild() (the signature is
        // unchanged), so this is the only place that can bring back the
        // highlight of a row that was hidden inside the group.
        if !applyingExpansion { restoreSelection(selectedIDs) }
    }

    /// Writes what the outline actually shows back into the app's collapsed
    /// set. Reading the truth out of the outline (instead of tracking each
    /// expand/collapse event) keeps the two in step no matter how the row
    /// was folded — clicked header, disclosure triangle, or keyboard — and
    /// that set is what the collapse-all button toggles against, so a drift
    /// here made the button look dead on its first press.
    func syncCollapsedFromOutline() {
        guard !applyingExpansion, parent.searchText.isEmpty, let outline else { return }
        // Starts as what is STORED, not empty: a subgroup inside a collapsed
        // group cannot be asked about. AppKit reports every item under a
        // collapsed parent as not-expanded, so reading them would "discover"
        // that they are all folded (or, the old way, open) and throw away the
        // user's folds — measured, and the reason this walk stops at a closed
        // row (ARCHITECTURE §11). Ids of groups that are gone are pruned by
        // SidebarView, not here.
        var collapsed = parent.collapsedGroups
        func scan(_ node: SidebarItem) {
            if node.kind == .group, let id = node.group?.id {
                let open = outline.isItemExpanded(node)
                if open { collapsed.remove(id) } else { collapsed.insert(id) }
                guard open else { return }
            }
            for child in node.children { scan(child) }
        }
        for root in roots { scan(root) }
        guard collapsed != parent.collapsedGroups else {
            trace("sync: outline already matches (\(collapsed.count) groups collapsed)")
            return
        }
        trace("sync: writing \(collapsed.count) groups collapsed")
        parent.collapsedGroups = collapsed
        signature = currentSignature(roots)
    }

    // MARK: Clicks

    /// ⌘ or ⇧ held: AppKit has already changed the SELECTION by the time
    /// `action` fires, and that is all the gesture means. Without this a
    /// ⌘-click on a group header toggled it and a ⇧-click ran the row's
    /// action — the two things a selection gesture must never do.
    private var isSelectionModifierDown: Bool {
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        return flags.contains(.command) || flags.contains(.shift)
    }

    @objc func singleClick(_ sender: Any?) {
        guard let outline, outline.clickedRow >= 0,
              let node = outline.item(atRow: outline.clickedRow) as? SidebarItem else { return }
        if isSelectionModifierDown {
            trace("singleClick \(node.title.isEmpty ? node.id : node.title) — modifier held, selection only")
            return
        }
        switch node.kind {
        case .group, .subgroup:
            // EVERY click toggles, however fast they come — a header or a
            // folder has no "open" for a double click to mean, and the user
            // found that a quick open-then-shut needed a third click (the
            // second arrived as a `doubleAction` and was skipped, or as a
            // chained click and was swallowed). `doubleClick` toggles too.
            // This replaces the 3.x "one gesture, one toggle" rule, which
            // swallowed exactly those clicks.
            trace("singleClick \(node.kind == .subgroup ? "folder" : "group")=\(node.title) clicks=\(NSApp.currentEvent?.clickCount ?? 1)")
            toggle(node)
        case .host, .staticRow:
            // Hand focus straight back to the terminal so the input-source
            // indicator keeps following the session (ARCHITECTURE §8).
            parent.model.focusActiveTerminal()
        case .section:
            break
        }
    }

    @objc func doubleClick(_ sender: Any?) {
        guard let outline, outline.clickedRow >= 0,
              let node = outline.item(atRow: outline.clickedRow) as? SidebarItem else { return }
        if isSelectionModifierDown {
            trace("doubleClick \(node.title.isEmpty ? node.id : node.title) — modifier held, selection only")
            return
        }
        // AppKit sends `action` for the first click of a pair and
        // `doubleAction` for the second, so a group header has ALREADY been
        // toggled by singleClick — activating it here folded it straight back
        // and a double click on a group looked like it did nothing.
        // Return still reaches activate() for groups, where toggling is right.
        if node.kind == .group || node.kind == .subgroup {
            trace("doubleClick \(node.kind == .subgroup ? "folder" : "group")=\(node.title) — toggles, like every click")
            toggle(node)
            return
        }
        activate(node)
    }

    /// Folds a header, or opens/shuts a folder row in place. A folder is not
    /// an outline item with children (that is what would indent it), so its
    /// state is `openSubgroups` and the rows are rebuilt.
    func toggle(_ node: SidebarItem) {
        guard let outline else { return }
        switch node.kind {
        case .group:
            if outline.isItemExpanded(node) {
                outline.animator().collapseItem(node)
            } else {
                outline.animator().expandItem(node)
            }
            syncCollapsedFromOutline()
        case .subgroup:
            guard let id = node.group?.id else { return }
            parent.openSubgroups = SidebarLayout.toggledOpen(id, in: parent.openSubgroups, groups: parent.store.groups)
            let shut = !parent.openSubgroups.contains(id)
            // AFTER the click has finished, not inside it: a reload during
            // the mouse-up changed the rows, but the window drew them only on
            // the NEXT event — the user saw nothing until a second click
            // (CLICKLOG: every first click toggled). Group headers never had
            // this: AppKit's own collapse animates on its own schedule.
            DispatchQueue.main.async { [weak self] in
                guard let self, let outline = self.outline else { return }
                self.rebuild(force: true)
                outline.needsDisplay = true
                outline.window?.displayIfNeeded()
                self.trace("toggle folder \(node.title) → \(shut ? "shut" : "open"), \(outline.numberOfRows) rows")
            }
        default:
            break
        }
    }

    /// Opens a row: flash the pill and connect in the same runloop turn —
    /// the old build waited 0.18s before doing anything, which is exactly
    /// the lag that made clicking feel slow.
    func activate(_ node: SidebarItem) {
        switch node.kind {
        case .group, .subgroup:
            toggle(node)
        case .host, .staticRow:
            flash(node)
            if let host = node.host {
                parent.model.open(host: host)
            } else {
                parent.model.newLocalTab()
            }
            parent.model.collapseSidebar()
        case .section:
            break
        }
    }

    private func flash(_ node: SidebarItem) {
        guard let outline else { return }
        // Put out a flash still running on another row first: its timer bails
        // out as soon as activatedID has moved on, so opening a second row
        // within the 0.15 s left the first one stuck dark until a reload
        // happened to recycle it.
        clearFlash()
        activatedID = node.id
        let row = outline.row(forItem: node)
        if row >= 0 { (outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.activated = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.activatedID == node.id else { return }
            self.clearFlash()
        }
    }

    private func clearFlash() {
        guard let id = activatedID else { return }
        activatedID = nil
        guard let outline, let node = cache[id] else { return }
        let row = outline.row(forItem: node)
        if row >= 0 { (outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.activated = false }
    }

    // MARK: Context menu

    /// The rows the menu is about, in display order: the selection when the
    /// clicked row is part of it (`menu(for:)` has already made that true),
    /// otherwise just that row.
    private func selectedNodes() -> [SidebarItem] {
        guard let outline else { return [] }
        return outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? SidebarItem }
    }

    /// "Move to Group ▸" for hosts: every group in tree order, indented by
    /// depth, except one that already holds all of them. By id, not by name:
    /// `move(host:toGroupNamed:)` CREATES a group when the name is gone, so a
    /// rename between opening this menu and picking from it forked a second
    /// group. Int.max is clamped to the group's host count = append. nil when
    /// there is nowhere to go — a dead arrow onto an empty submenu.
    private func hostMoveSubmenu(for ids: [UUID]) -> NSMenuItem? {
        let targets = parent.store.moveTargets(forHostIDs: Set(ids))
        guard !targets.isEmpty else { return nil }
        let item = NSMenuItem(title: String(localized: "Move to Group"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for target in targets {
            add(submenu, target.group.name) { [weak self] in
                // A selection spanning groups is about the hosts that CHANGE
                // group; the ones already in the destination stay put.
                self?.parent.store.moveHosts(withIDs: ids, toGroupID: target.group.id,
                                             atIndex: .max, skippingHostsAlreadyThere: true)
            }
            submenu.items.last?.indentationLevel = target.depth - 1
        }
        item.submenu = submenu
        return item
    }

    /// "Move to ▸" for groups: Top Level, then every group they fit under
    /// (`HostStore.groupMoveTargets` — never into themselves, never past the
    /// depth cap), indented by depth; each lands as the LAST subgroup there.
    private func groupMoveSubmenu(for ids: Set<UUID>) -> NSMenuItem? {
        let targets = parent.store.groupMoveTargets(forGroupIDs: ids)
        let allTopLevel = parent.store.groups.filter { ids.contains($0.id) }.allSatisfy { $0.parentID == nil }
        guard !targets.isEmpty || !allTopLevel else { return nil }
        let item = NSMenuItem(title: String(localized: "Move to"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if !allTopLevel {
            add(submenu, String(localized: "Top Level")) { [weak self] in
                self?.parent.store.moveGroups(withIDs: ids, toParent: nil, atIndex: .max)
            }
            if !targets.isEmpty { submenu.addItem(.separator()) }
        }
        for target in targets {
            add(submenu, target.group.name) { [weak self] in
                self?.parent.store.moveGroups(withIDs: ids, toParent: target.group.id, atIndex: .max)
            }
            submenu.items.last?.indentationLevel = target.depth - 1
        }
        item.submenu = submenu
        return item
    }

    func contextMenu(for node: SidebarItem) -> NSMenu? {
        let menu = NSMenu()
        // More than one row selected, all of one kind: the menu acts on all
        // of them; a mixed one gets no menu at all.
        let selection = selectedNodes()
        if selection.count > 1, selection.contains(where: { $0.id == node.id }) {
            // All hosts, or all groups. A MIXED selection gets no menu at
            // all: acting on ONE row while several are highlighted is the one
            // outcome nobody can predict.
            if selection.allSatisfy({ $0.kind == .host }), node.kind == .host {
                return multiHostMenu(selection.compactMap(\.host))
            }
            if selection.allSatisfy({ $0.kind == .group || $0.kind == .subgroup }),
               node.kind == .group || node.kind == .subgroup {
                return multiGroupMenu(selection.compactMap(\.group))
            }
            return nil
        }
        switch node.kind {
        case .section:
            return nil
        case .group, .subgroup:
            // A folder row is a group as much as a header is, and gets the
            // same menu.
            guard let id = node.group?.id, let group = parent.store.groups.first(where: { $0.id == id }) else { return nil }
            add(menu, String(localized: "Export Group…")) { [weak self] in self?.parent.onExportGroup(group) }
            add(menu, String(localized: "Share Link…")) { [weak self] in self?.parent.onShareGroup(group) }
            add(menu, String(localized: "Add Host…")) { [weak self] in self?.parent.onAddHost(group) }
            add(menu, String(localized: "Add Hosts…")) { [weak self] in self?.parent.onAddHosts(group) }
            // Not while a search is on: `buildRoots` hides a group with no
            // matching host, so one created mid-search would never appear —
            // a menu item that silently does nothing. Not at the depth cap
            // either: greyed, so the menu does not change shape.
            if parent.searchText.isEmpty {
                menu.autoenablesItems = false
                add(menu, String(localized: "Add Subgroup…")) { [weak self] in self?.parent.onNewSubgroup(group) }
                menu.items.last?.isEnabled = GroupTree.canAddChild(to: group.id, in: parent.store.groups)
            }
            add(menu, String(localized: "Set Credential for Group…")) { [weak self] in self?.parent.onSetGroupCredential(group) }
            menu.addItem(.separator())
            add(menu, String(localized: "Rename Group…")) { [weak self] in self?.parent.onRenameGroup(group) }
            if let move = groupMoveSubmenu(for: [group.id]) { menu.addItem(move) }
            if group.parentID == nil {
                add(menu, String(localized: "Reorder Groups…")) { [weak self] in self?.parent.onReorderGroups() }
            }
            menu.addItem(.separator())
            add(menu, String(localized: "Delete Group")) { [weak self] in self?.parent.onDeleteGroup(group) }
        case .host:
            guard let host = node.host else { return nil }
            add(menu, String(localized: "Connect")) { [weak self] in
                self?.parent.model.open(host: host)
                self?.parent.model.collapseSidebar()
            }
            add(menu, String(localized: "Open in Split")) { [weak self] in
                self?.parent.model.openInSplit(host: host)
                self?.parent.model.collapseSidebar()
            }
            if host.kind == .ssh {
                add(menu, String(localized: "Open File")) { [weak self] in
                    self?.parent.model.openFiles(host, proto: FilesPlan.sshHostProto)
                    self?.parent.model.collapseSidebar()
                }
            }
            if (host.kind == .ssh || host.kind == .telnet), let targets = PingPlan.addresses(for: host.address) {
                add(menu, String(localized: "Ping")) { [weak self] in
                    self?.parent.model.openPing(targets)
                    self?.parent.model.collapseSidebar()
                }
            }
            add(menu, String(localized: "Edit Host…")) { [weak self] in self?.parent.onEditHost(host) }
            if let move = hostMoveSubmenu(for: [host.id]) {
                menu.addItem(.separator())
                menu.addItem(move)
            }
            menu.addItem(.separator())
            add(menu, String(localized: "Remove Host")) { [weak self] in
                guard let self else { return }
                let alert = SheepAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Remove “\(host.name)”?")
                alert.informativeText = String(localized: "This cannot be undone.")
                alert.addButton(withTitle: String(localized: "Cancel"))   // default, so Return cancels
                alert.addButton(withTitle: String(localized: "Remove"))
                guard alert.sheepStyled().runModal() == .alertSecondButtonReturn else { return }
                self.parent.store.removeHost(host)
            }
        case .staticRow:
            guard let host = node.host else { return nil }
            add(menu, String(localized: "Connect")) { [weak self] in
                self?.parent.model.open(host: host)
                self?.parent.model.collapseSidebar()
            }
            if node.id.hasPrefix("recent-") {
                // Not for a recent of a host that is already saved (no second copy).
                if host.kind == .ssh || host.kind == .telnet || host.kind == .web,
                   !RecentSave.isSaved(host, in: parent.store.groups.flatMap(\.hosts)) {
                    add(menu, String(localized: "Save as Host…")) { [weak self] in self?.parent.model.saveRecentAsHost(host) }
                }
                menu.addItem(.separator())
                add(menu, String(localized: "Remove from Recent")) { [weak self] in self?.parent.store.removeRecent(host) }
            }
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// Several groups selected: move them together, reorder, or delete —
    /// with ONE confirmation naming the groups and what goes with them.
    private func multiGroupMenu(_ groups: [HostGroup]) -> NSMenu {
        let menu = NSMenu()
        let ids = Set(groups.map(\.id))
        if let move = groupMoveSubmenu(for: ids) { menu.addItem(move) }
        add(menu, String(localized: "Reorder Groups…")) { [weak self] in self?.parent.onReorderGroups() }
        menu.addItem(.separator())
        // From the STORE, by id, over the whole subtrees: what the delete
        // actually takes.
        let hostCount = HostStore.hostCount(ofGroupIDs: ids, in: parent.store.groups)
        let subgroups = HostStore.subgroupCount(ofGroupIDs: ids, in: parent.store.groups)
        add(menu, String(localized: "Delete \(groups.count) Groups")) { [weak self] in
            guard let self else { return }
            let alert = SheepAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Delete \(groups.count) groups?")
            alert.informativeText = subgroups == 0
                ? String(localized: "\(hostCount) hosts go with them. This cannot be undone.")
                : String(localized: "\(hostCount) hosts and \(subgroups) subgroups go with them. This cannot be undone.")
            alert.addButton(withTitle: String(localized: "Cancel"))   // default, so Return cancels
            alert.addButton(withTitle: String(localized: "Delete"))
            guard alert.sheepStyled().runModal() == .alertSecondButtonReturn else { return }
            // Asked once, for all of them — and ONE write, with their hosts
            // cleaned out of Recent.
            self.parent.onDeleteGroups(Set(groups.map(\.id)))
        }
        return menu
    }

    /// Several hosts selected: move them all, or delete them all — one
    /// confirmation naming the count, never one dialog per host.
    private func multiHostMenu(_ hosts: [Host]) -> NSMenu {
        let menu = NSMenu()
        let ids = hosts.map(\.id)
        if let move = hostMoveSubmenu(for: ids) { menu.addItem(move) }
        menu.addItem(.separator())
        add(menu, String(localized: "Delete \(hosts.count) Hosts")) { [weak self] in
            guard let self else { return }
            let alert = SheepAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Remove \(hosts.count) hosts?")
            // Two names and a count, not a list: the list pushed this alert
            // into the wide layout, and the number is what matters here.
            let named = hosts.prefix(2).map(\.name).joined(separator: ", ")
            let more = hosts.count - 2
            alert.informativeText = more > 0
                ? String(localized: "\(named) and \(more) more. This cannot be undone.")
                : String(localized: "\(named). This cannot be undone.")
            alert.addButton(withTitle: String(localized: "Cancel"))   // default, so Return cancels
            alert.addButton(withTitle: String(localized: "Remove"))
            guard alert.sheepStyled().runModal() == .alertSecondButtonReturn else { return }
            // ONE write for one confirmed action.
            self.parent.store.removeHosts(withIDs: hosts.map(\.id))
        }
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, action: @escaping () -> Void) {
        let item = MenuAction(title: title, run: action)
        menu.addItem(item)
    }

    // MARK: Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarItem else { return nil }
        switch node.kind {
        case .group, .subgroup:
            guard parent.searchText.isEmpty, let id = node.group?.id else { return nil }
            return "group:\(id.uuidString)" as NSString
        case .host:
            guard parent.searchText.isEmpty, let id = node.host?.id else { return nil }
            return "host:\(id.uuidString)" as NSString
        default:
            return nil
        }
    }

    /// What a drag carries. A drag of a selected row brings the whole
    /// selection (AppKit writes one pasteboard item per row), so these are
    /// lists — and a MIXED drag is nothing: moving hosts and moving groups
    /// are two different operations and there is no sensible drop for both
    /// at once.
    private enum Payload {
        case groups([UUID])
        case hosts([UUID])
    }

    private func payload(_ info: NSDraggingInfo) -> Payload? {
        let strings = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }
        // A drag from another app arrives as one plain string with no items
        // of ours in it; keep reading that the way this always has.
        let texts = strings.isEmpty
            ? [info.draggingPasteboard.string(forType: .string)].compactMap { $0 }
            : strings
        var groups: [UUID] = []
        var hosts: [UUID] = []
        for text in texts {
            let parts = text.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { continue }
            if parts[0] == "group" { groups.append(id) } else if parts[0] == "host" { hosts.append(id) }
        }
        if !groups.isEmpty, hosts.isEmpty { return .groups(groups) }
        if !hosts.isEmpty, groups.isEmpty { return .hosts(hosts) }
        return nil
    }

    /// A header's rows as the pure layout sees them (`SidebarLayout.FlatRow`).
    private func flatRows(_ header: SidebarItem) -> [SidebarLayout.FlatRow] {
        header.children.compactMap { row in
            switch row.kind {
            case .host:
                guard let id = row.host?.id, let group = row.group?.id else { return nil }
                return .host(id, group: group)
            case .subgroup:
                guard let id = row.group?.id, let parent = row.group?.parentID else { return nil }
                return .folder(id, parent: parent)
            default:
                return nil
            }
        }
    }

    /// The top-level header a row sits under (every row below a header is
    /// one of its direct children — open folders do not nest).
    private func header(of node: SidebarItem) -> SidebarItem? {
        if node.kind == .group { return node }
        return roots.first { $0.kind == .group && $0.children.contains { $0 === node } }
    }

    /// Where a host drop lands, in terms the STORE understands: the group and
    /// an index into that group's own `hosts` array, plus where AppKit draws
    /// it. The rules for a line between rows are `SidebarLayout.hostLanding`
    /// (pure, tested). nil only when the position is not inside a group.
    private func hostDrop(item: Any?, childIndex index: Int)
        -> (group: UUID, index: Int, dropItem: SidebarItem?, dropChildIndex: Int)? {
        let all = parent.store.groups
        if let node = item as? SidebarItem {
            switch node.kind {
            case .group:
                guard let id = node.group?.id else { return nil }
                // ON the header — including a collapsed one — means "the end
                // of its own hosts".
                guard index != NSOutlineViewDropOnItemIndex else {
                    return (id, parent.store.hosts(inGroup: id).count, node, NSOutlineViewDropOnItemIndex)
                }
                let landing = SidebarLayout.hostLanding(rows: flatRows(node), at: index, header: id, groups: all)
                return (landing.group, landing.index, node, min(max(index, 0), node.children.count))
            case .subgroup:
                // ON a folder row: into that subgroup, after its hosts.
                guard let id = node.group?.id else { return nil }
                return (id, parent.store.hosts(inGroup: id).count, node, NSOutlineViewDropOnItemIndex)
            case .host:
                // ON a host row: that host's slot, the line above it.
                guard let header = header(of: node), let at = header.children.firstIndex(where: { $0 === node }),
                      let id = header.group?.id else { return nil }
                let landing = SidebarLayout.hostLanding(rows: flatRows(header), at: at, header: id, groups: all)
                return (landing.group, landing.index, header, at)
            default:
                return nil
            }
        }
        guard item == nil else { return nil }
        // A root-level insertion point: between two groups, above the first,
        // or below the very last row. A host has to land INSIDE a group, so
        // use the group the line is drawn against — the one above it, or the
        // first group when the line sits above them all
        // (`SidebarLayout.rootGapOwner`). No gap may refuse the drop.
        guard let gap = rootGap(index) else { return nil }
        return gap.aboveEveryGroup
            ? (gap.groupID, 0, gap.node, 0)
            : (gap.groupID, parent.store.hosts(inGroup: gap.groupID).count, gap.node, NSOutlineViewDropOnItemIndex)
    }

    /// The group a ROOT-level drop line belongs to, and whether the line is
    /// above every group — `SidebarLayout.rootGapOwner` over the root rows.
    private func rootGap(_ index: Int) -> (groupID: UUID, node: SidebarItem, aboveEveryGroup: Bool)? {
        let stop = index == NSOutlineViewDropOnItemIndex ? roots.count : index
        guard let gap = SidebarLayout.rootGapOwner(rootIsGroup: roots.map { $0.kind == .group }, index: stop)
        else { return nil }
        let groupNodes = roots.filter { $0.kind == .group }
        guard groupNodes.indices.contains(gap.groupOrdinal),
              let groupID = groupNodes[gap.groupOrdinal].group?.id else { return nil }
        return (groupID, groupNodes[gap.groupOrdinal], gap.aboveEveryGroup)
    }

    /// Where dragged GROUPS land: under `parent` (nil = top level) at `slot`
    /// among its subgroups, and where AppKit draws it. `validateDrop` and
    /// `acceptDrop` both come through here with the same inputs. nil = no
    /// drop here (into itself, or past the depth cap).
    ///
    /// - ON a header or a folder row: into it, as its last subgroup.
    /// - Between a header's rows: `SidebarLayout.groupLanding` (pure, tested).
    /// - ON a host row: as if between rows, just above it.
    /// - A root gap: the top level, between the headers there.
    private func groupDrop(_ ids: Set<UUID>, item: Any?, childIndex index: Int)
        -> (parent: UUID?, slot: Int, dropItem: SidebarItem?, dropChildIndex: Int)? {
        let all = parent.store.groups
        var target: (parent: UUID?, slot: Int, dropItem: SidebarItem?, dropChildIndex: Int)
        if let node = item as? SidebarItem {
            switch node.kind {
            case .subgroup:
                guard let id = node.group?.id else { return nil }
                target = (id, GroupTree.children(of: id, in: all).count, node, NSOutlineViewDropOnItemIndex)
            case .group where index == NSOutlineViewDropOnItemIndex:
                guard let id = node.group?.id else { return nil }
                target = (id, GroupTree.children(of: id, in: all).count, node, NSOutlineViewDropOnItemIndex)
            case .group:
                guard let id = node.group?.id else { return nil }
                let landing = SidebarLayout.groupLanding(rows: flatRows(node), at: index, header: id, groups: all)
                target = (landing.parent, landing.slot, node, min(max(index, 0), node.children.count))
            case .host:
                guard let header = header(of: node), let at = header.children.firstIndex(where: { $0 === node }),
                      let id = header.group?.id else { return nil }
                let landing = SidebarLayout.groupLanding(rows: flatRows(header), at: at, header: id, groups: all)
                target = (landing.parent, landing.slot, header, at)
            default:
                return nil
            }
        } else {
            guard item == nil else { return nil }
            let rootIsGroup = roots.map { $0.kind == .group }
            let groupRows = rootIsGroup.indices.filter { rootIsGroup[$0] }
            let stop = index == NSOutlineViewDropOnItemIndex ? roots.count : min(max(index, 0), roots.count)
            let slot = SidebarLayout.rootGroupSlot(rootIsGroup: rootIsGroup, index: stop)
            // The line is drawn ABOVE the slot-th group row (or after the last
            // row), never among the fixed rows above the groups.
            target = (nil, slot, nil, slot < groupRows.count ? groupRows[slot] : roots.count)
        }
        guard GroupTree.canMove(ids, under: target.parent, in: all) else { return nil }
        return target
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Dragging toward an edge has to bring the list with it, or a row can
        // only ever be dropped somewhere already on screen. AppKit's own
        // `autoscroll(with:)` is fed by the mouse-dragged events of a plain
        // click-drag; a dragging SESSION delivers `draggingUpdated` instead and
        // no such event ever arrives, so the scroll has to be driven here.
        updateAutoscroll(outlineView, info)
        // A filtered list shows a subset of each group's hosts, so a child
        // index taken off it means nothing in the real order. Our own rows
        // refuse to start a drag while the field has text, but a drag from
        // another window (or any app, `.string` is registered) still arrives.
        guard parent.searchText.isEmpty, let payload = payload(info) else { return [] }
        switch payload {
        case .groups(let ids):
            // The dragged rows can be deleted in another window while the drag
            // is in flight; lighting up an insertion line for a move that
            // cannot happen is worse than refusing the drop.
            let live = Set(ids.filter { parent.store.location(ofGroup: $0) != nil })
            guard !live.isEmpty, let drop = groupDrop(live, item: item, childIndex: index) else { return [] }
            outlineView.setDropItem(drop.dropItem, dropChildIndex: drop.dropChildIndex)
            return .move
        case .hosts(let ids):
            guard ids.contains(where: { parent.store.location(ofHost: $0) != nil }) else { return [] }
            // Every position a host can land in resolves here, with the line
            // drawn where it lands. None of them may refuse the drop.
            guard let drop = hostDrop(item: item, childIndex: index) else { return [] }
            outlineView.setDropItem(drop.dropItem, dropChildIndex: drop.dropChildIndex)
            return .move
        }
    }


    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        // Same gates as validateDrop, re-checked: `true` here tells AppKit the
        // drop landed, and saying so when nothing moved is how a drag ends
        // with the row apparently back where it started and no explanation.
        guard parent.searchText.isEmpty, let payload = payload(info) else { return false }
        switch payload {
        case .groups(let ids):
            let live = Set(ids.filter { parent.store.location(ofGroup: $0) != nil })
            // AppKit hands back the item and index `validateDrop` set, so this
            // resolves to the same landing.
            guard !live.isEmpty, let drop = groupDrop(live, item: item, childIndex: index) else { return false }
            // A subgroup dropped INTO a group is put where it can be seen.
            if let into = drop.parent {
                parent.collapsedGroups.remove(into)
                if parent.store.groups.first(where: { $0.id == into })?.parentID != nil,
                   !parent.openSubgroups.contains(into) {
                    parent.openSubgroups = SidebarLayout.toggledOpen(into, in: parent.openSubgroups, groups: parent.store.groups)
                }
            }
            parent.store.moveGroups(withIDs: live, toParent: drop.parent, atIndex: drop.slot)
        case .hosts(let ids):
            // Resolved the same way validateDrop resolved it, from the node
            // AppKit hands back.
            guard index >= -1, let drop = hostDrop(item: item, childIndex: index),
                  parent.store.location(ofGroup: drop.group) != nil else { return false }
            let live = ids.filter { parent.store.location(ofHost: $0) != nil }
            guard !live.isEmpty else { return false }
            // One call, one save, the sidebar's own order. The returned count
            // is deliberately dropped, and this returns `true` either way: a
            // zero here means "they were already exactly there" — a drop that
            // lands where the hosts already are is a successful drop, and
            // `false` would animate the rows back as though AppKit had
            // refused them.
            parent.store.moveHosts(withIDs: live, toGroupID: drop.group, atIndex: drop.index)
        }
        // The drag is still open here — AppKit ends the session only after the
        // destination is done — so this normally just books the rebuild and
        // draggingSession/endedAt pays it a moment later. Asking for it here
        // anyway keeps the call correct whichever way that order goes.
        rebuild(force: true)
        return true
    }

    /// Sets the scroll speed from how close the pointer is to an edge, and
    /// starts or stops the timer that applies it. Speed ramps with depth into
    /// the zone so a drag can creep or race, the way a Finder list does.
    private func updateAutoscroll(_ outlineView: NSOutlineView, _ info: NSDraggingInfo) {
        guard let clip = outlineView.enclosingScrollView?.contentView else { return stopAutoscroll() }
        let point = clip.convert(info.draggingLocation, from: nil)
        let visible = clip.bounds
        let fromTop = point.y - visible.minY
        let fromBottom = visible.maxY - point.y
        let zone = SidebarOutlineCoordinator.autoscrollZone
        let maxStep = SidebarOutlineCoordinator.autoscrollMaxStep

        if fromTop < zone, fromTop > -zone {
            autoscrollStep = -maxStep * min(1, max(0.15, (zone - fromTop) / zone))
        } else if fromBottom < zone, fromBottom > -zone {
            autoscrollStep = maxStep * min(1, max(0.15, (zone - fromBottom) / zone))
        } else {
            return stopAutoscroll()
        }
        guard autoscrollTimer == nil else { return }
        autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self, weak outlineView] _ in
            MainActor.assumeIsolated {
                guard let self, let outlineView else { return }
                self.stepAutoscroll(outlineView)
            }
        }
        // The drag runs the event loop in its own mode; without this the timer
        // never fires while the mouse is down.
        if let autoscrollTimer { RunLoop.main.add(autoscrollTimer, forMode: .eventTracking) }
    }

    private func stepAutoscroll(_ outlineView: NSOutlineView) {
        guard let scroll = outlineView.enclosingScrollView else { return stopAutoscroll() }
        let clip = scroll.contentView
        let maxY = max(0, (clip.documentView?.bounds.height ?? 0) - clip.bounds.height)
        let target = min(max(0, clip.bounds.origin.y + autoscrollStep), maxY)
        guard target != clip.bounds.origin.y else { return }   // already at the end
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scroll.reflectScrolledClipView(clip)
    }

    func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        autoscrollStep = 0
    }

    /// AppKit is about to track a drag started from these rows; `rebuild`
    /// stays out of the way until it is over (see the guard there).
    ///
    /// It also fixes the picture under the pointer. AppKit builds that from a
    /// snapshot of the CELL view, and both cells here deliberately draw to the
    /// LEFT of their own origin — the host badge at x = -14 and the group title
    /// at x = -12, so each lines up under the header above it instead of
    /// floating an indentation step to the right. Everything outside the cell's
    /// bounds is clipped out of a snapshot, so the badge (and the first
    /// character or two of a group name) was simply missing from the row you
    /// were dragging. The row view is the ancestor that does contain it.
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        isDragging = true
        // The pane tree and the tab strip accept `host:<uuid>` only for the
        // rows THIS drag carries (see `InternalDrag`).
        InternalDrag.hosts = Set(draggedItems.compactMap { ($0 as? SidebarItem)?.host?.id })
        session.enumerateDraggingItems(options: [], for: outlineView,
                                       classes: [NSPasteboardItem.self],
                                       searchOptions: [:]) { item, index, _ in
            guard index < draggedItems.count else { return }
            let row = outlineView.row(forItem: draggedItems[index])
            guard row >= 0,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
            // Only the PICTURE is replaced. `draggingFrame` is AppKit's and
            // stays that way: setting it here threw the image to the middle of
            // the screen, and it was never what was wrong — the frame was
            // right, the snapshot inside it was short.
            // Only the LEFT edge overhangs; `insetBy` would widen both sides and
            // hang 16 transparent points off the right of the picture.
            var rect = cell.bounds
            rect.origin.x -= SidebarOutlineCoordinator.cellOverhang
            rect.size.width += SidebarOutlineCoordinator.cellOverhang
            guard rect.width > 0, rect.height > 0,
                  let rep = cell.bitmapImageRepForCachingDisplay(in: rect) else { return }
            cell.cacheDisplay(in: rect, to: rep)
            let picture = NSImage(size: rect.size)
            picture.addRepresentation(rep)
            let component = NSDraggingImageComponent(key: .icon)
            component.contents = picture
            // Negative x so the extra strip sits to the LEFT of the frame,
            // which is where the badge and the group title actually draw.
            component.frame = NSRect(x: -SidebarOutlineCoordinator.cellOverhang, y: 0,
                                     width: rect.width, height: rect.height)
            item.imageComponentsProvider = { [component] }
        }
    }

    /// Always called, drop or cancel — including the Escape key and a drop
    /// outside the window — so the deferred rebuild can never be stranded.
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        InternalDrag.hosts = []
        stopAutoscroll()
        guard pendingRebuild else { return }
        pendingRebuild = false
        rebuild(force: true)
    }
}

/// NSMenuItem that runs a closure — the sidebar's menus are built on the fly
/// from the row that was right-clicked.
///
/// The closure lives on a small separate target, NOT on the item itself.
/// NSMenuItem holds its `target` strongly, so `target = self` made every item
/// retain itself: the items outlived their menu forever, and each one holds a
/// captured Host or HostGroup. Every right-click leaked the whole menu.
final class MenuAction: NSMenuItem {
    /// Owned by the item through `representedObject`, and referenced by it as
    /// `target` — the item holds the trampoline, the trampoline holds only
    /// the closure, so the pair dies with the menu.
    private final class Trampoline: NSObject {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    init(title: String, run: @escaping () -> Void) {
        let trampoline = Trampoline(run: run)
        super.init(title: title, action: #selector(Trampoline.fire), keyEquivalent: "")
        target = trampoline
        representedObject = trampoline
    }

    // NSMenuItem's designated inits are nonisolated; silence the
    // isolation-mismatch errors by overriding them explicitly.
    nonisolated override init(title: String, action: Selector?, keyEquivalent: String) {
        fatalError("use init(title:run:)")
    }

    nonisolated required init(coder: NSCoder) { fatalError("not used") }
}
