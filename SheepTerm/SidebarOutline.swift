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
    case group          // a HostGroup: selectable, draggable, collapsible
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

    var isExpandable: Bool { !children.isEmpty || kind == .group }
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
    @Binding var collapsedGroups: Set<UUID>
    let onEditHost: (Host) -> Void
    let onRenameGroup: (HostGroup) -> Void
    let onReorderGroups: () -> Void
    let onDeleteGroup: (HostGroup) -> Void
    let onExportGroup: (HostGroup) -> Void

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
        outline.allowsMultipleSelection = false
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

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)

        context.coordinator.outline = outline
        context.coordinator.rebuild(force: true)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.rebuild(force: false)
    }
}

// MARK: - Outline view

/// Adds the two things NSOutlineView leaves to the client: a per-row
/// context menu, and Return-to-connect.
final class SidebarOutlineView: NSOutlineView {
    weak var coordinator: SidebarOutlineCoordinator?

    /// The pointer left the outline mid-drag. `validateDrop` stops firing at
    /// that moment, so the autoscroll speed it last set would stand and the
    /// 60 Hz timer would keep winding the list along — all the while the user
    /// is aiming at something else entirely.
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        coordinator?.stopAutoscroll()
        super.draggingExited(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let item = item(atRow: row) as? SidebarItem else { return nil }
        return coordinator?.contextMenu(for: item)
    }

    override func keyDown(with event: NSEvent) {
        // Return / Enter on a selected row opens it, same as a double click.
        if event.keyCode == 36 || event.keyCode == 76 {
            if let item = item(atRow: selectedRow) as? SidebarItem {
                coordinator?.activate(item)
                return
            }
        }
        super.keyDown(with: event)
    }
}

/// Selected row = accent pill; the row being opened flashes darker. The
/// pill is drawn here rather than left to AppKit because the sidebar hands
/// focus straight back to the terminal on every click, which would render
/// the system highlight in its washed-out unfocused grey.
final class SidebarRowView: NSTableRowView {
    var activated = false {
        didSet { if activated != oldValue { needsDisplay = true } }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let inset = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        NSColor(Theme.accent).withAlphaComponent(activated ? 0.5 : 0.22).setFill()
        path.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // An activated row flashes even when the click did not change the
        // selection (double-clicking the already-selected row).
        if activated && !isSelected {
            let inset = bounds.insetBy(dx: 6, dy: 1)
            NSColor(Theme.accent).withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6).fill()
        }
    }
}

// MARK: - Cell views

/// Badge + name + address. `hitTest` returns nil so every mouse event
/// belongs to the outline view — that is what makes a click land on the
/// first try and a drag start without a hitch.
final class SidebarHostCell: NSView {
    private let badgePill = NSView()
    private let badge = NSTextField(labelWithString: "")
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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(badge text: String, color: NSColor, name title: String, detail subtitle: String?) {
        badge.stringValue = text
        badge.textColor = color
        badgePill.layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
        name.stringValue = title
        detail.stringValue = subtitle ?? ""
        detail.isHidden = (subtitle ?? "").isEmpty
        needsLayout = true
    }

    /// Rows sit one indentation step in from their group header; pull them
    /// back so the badge starts just under the header text instead of
    /// halfway across the sidebar.
    private static let leading: CGFloat = -14

    override func layout() {
        super.layout()
        let textSize = badge.intrinsicContentSize
        let badgeWidth = max(28, textSize.width + 8)
        let badgeHeight: CGFloat = 14
        badgePill.frame = NSRect(x: Self.leading,
                                 y: ((bounds.height - badgeHeight) / 2).rounded(),
                                 width: badgeWidth, height: badgeHeight)
        // The label is only as tall as its glyphs; centre it inside the pill so
        // the caption sits on the middle line instead of riding the top edge.
        let labelHeight = textSize.height.rounded(.up)
        badge.frame = NSRect(x: 0, y: ((badgeHeight - labelHeight) / 2).rounded(),
                             width: badgeWidth, height: labelHeight)
        let textX = Self.leading + badgeWidth + 8
        let textWidth = max(0, bounds.width - textX - 6)
        if detail.isHidden {
            name.frame = NSRect(x: textX, y: (bounds.height - 16) / 2, width: textWidth, height: 16)
        } else {
            name.frame = NSRect(x: textX, y: bounds.height / 2 - 1, width: textWidth, height: 16)
            detail.frame = NSRect(x: textX, y: bounds.height / 2 - 14, width: textWidth, height: 13)
        }
    }
}

/// Group header (bold name + host count) and section header share one cell.
final class SidebarLabelCell: NSView {
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        count.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
        count.textColor = .tertiaryLabelColor
        addSubview(title)
        addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(title text: String, count number: Int?) {
        title.stringValue = text
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = .labelColor
        count.stringValue = number.map(String.init) ?? ""
        count.isHidden = number == nil
        needsLayout = true
    }

    /// Header text hugs the disclosure triangle: NSOutlineView reserves a
    /// full indentation step for it, which left the group name floating
    /// away from its own chevron.
    private static let leading: CGFloat = -12

    override func layout() {
        super.layout()
        let x = Self.leading
        let titleWidth = min(ceil(title.intrinsicContentSize.width) + 1, max(0, bounds.width - 30))
        title.frame = NSRect(x: x, y: (bounds.height - 15) / 2, width: titleWidth, height: 15)
        count.frame = NSRect(x: x + titleWidth + 5, y: (bounds.height - 13) / 2,
                             width: max(0, bounds.width - titleWidth - 5), height: 13)
    }
}

// MARK: - Coordinator

@MainActor
final class SidebarOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var parent: SidebarOutline
    weak var outline: SidebarOutlineView?

    private var roots: [SidebarItem] = []
    private var cache: [String: SidebarItem] = [:]
    private var signature = ""
    private var activatedID: String?
    private var selectedID: String?
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

    /// The last group header click that reached `singleClick`: which header,
    /// when, and the click chain it belonged to.
    private var lastGroupToggle: (id: String, at: TimeInterval, clicks: Int)?

    private var isDragging = false
    private var pendingRebuild = false

    init(_ parent: SidebarOutline) {
        self.parent = parent
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

    private var filteredGroups: [HostGroup] {
        let text = parent.searchText
        guard !text.isEmpty else { return parent.store.groups }
        return parent.store.groups.compactMap { group in
            let hosts = group.hosts.filter {
                $0.name.matchesSearch(text) || $0.address.matchesSearch(text)
            }
            return hosts.isEmpty ? nil : HostGroup(id: group.id, name: group.name, hosts: hosts)
        }
    }

    /// Root rows above the groups — they never take part in a drag.
    private var fixedSectionCount = 0

    /// Everything rebuild() reads. Comparing this is what lets an unrelated
    /// publish cost nothing.
    private struct InputStamp: Equatable {
        var revision: Int
        var search: String
        var showRecents: Bool
        var recentsShown: Int
        var collapsed: Set<UUID>
    }
    private var lastStamp: InputStamp?

    private func buildRoots() -> [SidebarItem] {
        var result: [SidebarItem] = []

        if let target = parent.connectTarget {
            let section = item(id: "section-connect", kind: .section)
            section.title = "Connect"
            let row = item(id: "connect-target", kind: .staticRow)
            row.host = target
            section.children = [row]
            result.append(section)
        }

        let local = item(id: "section-local", kind: .section)
        local.title = "This Mac"
        let shell = item(id: "local", kind: .staticRow)
        shell.title = "Local Shell"
        local.children = [shell]
        result.append(local)

        if parent.showRecents && parent.searchText.isEmpty && !parent.store.recents.isEmpty {
            let recent = item(id: "section-recent", kind: .section)
            recent.title = "Recent"
            let shown = min(max(parent.recentsShown, 1), HostStore.maxRecents)
            recent.children = parent.store.recents.prefix(shown).map { host in
                let row = item(id: "recent-\(host.id.uuidString)", kind: .staticRow)
                row.host = host
                return row
            }
            result.append(recent)
        }

        fixedSectionCount = result.count

        for group in filteredGroups {
            let node = item(id: "group-\(group.id.uuidString)", kind: .group)
            node.group = group
            node.title = group.name
            node.children = group.hosts.map { host in
                let row = item(id: "host-\(host.id.uuidString)", kind: .host)
                row.host = host
                row.group = group
                return row
            }
            result.append(node)
        }
        // Rows that no longer exist must leave the cache with them —
        // otherwise every deleted host keeps its item alive for the life
        // of the window.
        var live: Set<String> = []
        for root in result {
            live.insert(root.id)
            for child in root.children { live.insert(child.id) }
        }
        cache = cache.filter { live.contains($0.key) }
        return result
    }

    /// Cheap "did anything visible change" check — updateNSView runs on every
    /// @Published touch in the app and a reload mid-drag would be fatal.
    private func currentSignature(_ roots: [SidebarItem]) -> String {
        var parts: [String] = [parent.searchText]
        for root in roots {
            parts.append(root.id + ":" + root.title)
            for child in root.children {
                parts.append(child.id + "|" + (child.host?.name ?? child.title)
                             + "|" + (child.host?.address ?? "") + "|" + (child.host?.kind.badge ?? ""))
            }
        }
        parts.append(parent.collapsedGroups.map(\.uuidString).sorted().joined(separator: ","))
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
                               collapsed: parent.collapsedGroups)
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
        let wanted = selectedID
        outline.reloadData()
        applyExpansion()
        restoreSelection(wanted)
    }

    private func applyExpansion() {
        guard let outline else { return }
        applyingExpansion = true
        for root in roots {
            switch root.kind {
            case .section:
                outline.expandItem(root)
            case .group:
                let collapsed = !parent.searchText.isEmpty
                    ? false
                    : parent.collapsedGroups.contains(root.group?.id ?? UUID())
                if collapsed != !outline.isItemExpanded(root) {
                    trace("applyExpansion: forcing \(root.title) to \(collapsed ? "collapsed" : "expanded")")
                }
                if collapsed {
                    outline.collapseItem(root)
                } else {
                    outline.expandItem(root)
                }
            default:
                break
            }
        }
        applyingExpansion = false
    }

    /// Puts the highlight back on `wanted`, and keeps remembering it even
    /// when the row is off screen — a search that hides it or a group folded
    /// over it must not count as the user deselecting, or clearing the filter
    /// (reopening the group) would come back blank.
    private func restoreSelection(_ wanted: String?) {
        guard let outline, let wanted else { return }
        let row = cache[wanted].map { outline.row(forItem: $0) } ?? -1
        restoringSelection = true
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        restoringSelection = false
        selectedID = wanted
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
        default: return 34
        }
    }

    private static let rowID = NSUserInterfaceItemIdentifier("row")
    private static let labelID = NSUserInterfaceItemIdentifier("label")
    private static let hostID = NSUserInterfaceItemIdentifier("host")

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = outlineView.makeView(withIdentifier: Self.rowID, owner: self) as? SidebarRowView
            ?? { let fresh = SidebarRowView(); fresh.identifier = Self.rowID; return fresh }()
        // Every property is set on both paths: a recycled row still carries
        // the previous row's flash and highlight style.
        row.activated = (item as? SidebarItem)?.id == activatedID
        row.selectionHighlightStyle = (item as? SidebarItem)?.kind == .section ? .none : .regular
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarItem else { return nil }
        switch node.kind {
        case .section:
            let cell = labelCell(outlineView)
            cell.configure(title: node.title, count: nil)
            return cell
        case .group:
            let cell = labelCell(outlineView)
            cell.configure(title: node.title, count: node.group?.hosts.count)
            return cell
        case .host, .staticRow:
            let cell = hostCell(outlineView)
            if let host = node.host {
                let isConnectTarget = node.id == "connect-target"
                cell.configure(
                    badge: host.kind.badge,
                    color: NSColor(host.kind == .serial ? Theme.warn : Theme.accent),
                    name: host.name,
                    detail: isConnectTarget
                        ? "port \(host.port) · press ↩ to connect"
                        : (host.address.isEmpty ? nil : host.address)
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

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        (item as? SidebarItem)?.kind != .section
    }

    /// "This Mac" / "Recent" / "Connect" are always open, so they get no
    /// disclosure triangle — only the groups, which really do fold.
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        (item as? SidebarItem)?.kind != .section
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection, let outline else { return }
        if let node = outline.item(atRow: outline.selectedRow) as? SidebarItem {
            selectedID = node.id
            return
        }
        // No selection any more. AppKit also drops the highlight when the
        // selected row is folded away inside a collapsed group — that is the
        // row disappearing, not the user picking something else, so the id
        // stays and the highlight returns when the group reopens.
        if let selectedID, let node = cache[selectedID], outline.row(forItem: node) < 0 { return }
        selectedID = nil
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        trace("didCollapse \((notification.userInfo?["NSObject"] as? SidebarItem)?.title ?? "?")")
        syncCollapsedFromOutline()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        trace("didExpand \((notification.userInfo?["NSObject"] as? SidebarItem)?.title ?? "?") applying=\(applyingExpansion)")
        syncCollapsedFromOutline()
        // Expanding by hand doesn't go through rebuild() (the signature is
        // unchanged), so this is the only place that can bring back the
        // highlight of a row that was hidden inside the group.
        if !applyingExpansion { restoreSelection(selectedID) }
    }

    /// Writes what the outline actually shows back into the app's collapsed
    /// set. Reading the truth out of the outline (instead of tracking each
    /// expand/collapse event) keeps the two in step no matter how the row
    /// was folded — clicked header, disclosure triangle, or keyboard — and
    /// that set is what the collapse-all button toggles against, so a drift
    /// here made the button look dead on its first press.
    func syncCollapsedFromOutline() {
        guard !applyingExpansion, parent.searchText.isEmpty, let outline else { return }
        var collapsed: Set<UUID> = []
        for root in roots where root.kind == .group {
            if let id = root.group?.id, !outline.isItemExpanded(root) { collapsed.insert(id) }
        }
        guard collapsed != parent.collapsedGroups else {
            trace("sync: outline already matches (\(collapsed.count) collapsed)")
            return
        }
        trace("sync: writing \(collapsed.count) collapsed (was \(parent.collapsedGroups.count))")
        parent.collapsedGroups = collapsed
        signature = currentSignature(roots)
    }

    // MARK: Clicks

    @objc func singleClick(_ sender: Any?) {
        guard let outline, outline.clickedRow >= 0,
              let node = outline.item(atRow: outline.clickedRow) as? SidebarItem else { return }
        switch node.kind {
        case .group:
            // Whole header toggles, same as before the rewrite — which makes a
            // DOUBLE click two toggles whenever AppKit does not classify the
            // pair as one. It classifies by the system's double-click interval,
            // so a pair landing a little slower than that arrives here twice,
            // the header folds straight back, and the gesture looks like it did
            // nothing at all. (`doubleAction` skipping groups only covers the
            // pairs AppKit *does* classify.) One header, one gesture, one
            // toggle: a repeat on the same header inside that interval is the
            // same gesture, not a second one.
            // What the log of a real session showed. macOS keeps ONE click
            // chain going while you keep clicking: `action` arrives with
            // clickCount 1, 3, 5, 7… and `doubleAction` with 2, 4, 6…, so
            // double-clicking a header several times in a row is one chain,
            // and every odd count in it is a NEW double click that has to
            // toggle. A blanket "ignore a repeat inside the double-click
            // interval" swallowed all of them — the first double click worked
            // and the rest did nothing, which is the "sometimes" in the
            // report.
            //
            // The pair that genuinely has to be swallowed looks different: two
            // clicks that macOS did NOT chain (both clickCount 1) landing
            // inside the interval, which is what a double click becomes when
            // the pointer drifts a couple of points between the two. Without
            // this the header toggles twice and lands back where it started.
            let now = ProcessInfo.processInfo.systemUptime
            let clicks = NSApp.currentEvent?.clickCount ?? 1
            let brokenPair = clicks <= 1
                && lastGroupToggle?.id == node.id
                && lastGroupToggle?.clicks ?? 0 <= 1
                && now - (lastGroupToggle?.at ?? 0) < NSEvent.doubleClickInterval
            trace("singleClick group=\(node.title) clicks=\(clicks) expanded=\(outline.isItemExpanded(node)) swallow=\(brokenPair)")
            guard !brokenPair else { return }   // and do NOT move the mark:
            // a swallowed click that became the new reference slid the window
            // forward, so a third click still inside it was swallowed too, and
            // a run of separate clicks collapsed into one toggle. The mark
            // belongs to the click that actually toggled.
            lastGroupToggle = (node.id, now, clicks)
            if outline.isItemExpanded(node) {
                outline.animator().collapseItem(node)
            } else {
                outline.animator().expandItem(node)
            }
            syncCollapsedFromOutline()
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
        // AppKit sends `action` for the first click of a pair and
        // `doubleAction` for the second, so a group header has ALREADY been
        // toggled by singleClick — activating it here folded it straight back
        // and a double click on a group looked like it did nothing.
        // Return still reaches activate() for groups, where toggling is right.
        guard node.kind != .group else {
            trace("doubleClick group=\(node.title) — skipped, singleClick owns the toggle")
            return
        }
        activate(node)
    }

    /// Opens a row: flash the pill and connect in the same runloop turn —
    /// the old build waited 0.18s before doing anything, which is exactly
    /// the lag that made clicking feel slow.
    func activate(_ node: SidebarItem) {
        switch node.kind {
        case .group:
            guard let outline else { return }
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
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

    func contextMenu(for node: SidebarItem) -> NSMenu? {
        let menu = NSMenu()
        switch node.kind {
        case .section:
            return nil
        case .group:
            guard let group = node.group else { return nil }
            add(menu, "Export Group…") { [weak self] in self?.parent.onExportGroup(group) }
            menu.addItem(.separator())
            add(menu, "Rename Group…") { [weak self] in self?.parent.onRenameGroup(group) }
            add(menu, "Reorder Groups…") { [weak self] in self?.parent.onReorderGroups() }
            menu.addItem(.separator())
            add(menu, "Delete Group") { [weak self] in self?.parent.onDeleteGroup(group) }
        case .host:
            guard let host = node.host, let group = node.group else { return nil }
            add(menu, "Connect") { [weak self] in
                self?.parent.model.open(host: host)
                self?.parent.model.collapseSidebar()
            }
            add(menu, "Edit Host…") { [weak self] in self?.parent.onEditHost(host) }
            // With only one group there is nowhere to move to; the item and
            // its separator would just be a dead arrow onto an empty submenu.
            let others = parent.store.groups.filter { $0.id != group.id }
            if !others.isEmpty {
                menu.addItem(.separator())
                let moveItem = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for other in others {
                    // By id, not by name: `move(host:toGroupNamed:)` CREATES a
                    // group when the name is gone, so a rename between opening
                    // this menu and picking from it forked a second group.
                    // Int.max is clamped to the group's host count = append.
                    add(submenu, other.name) { [weak self] in
                        self?.parent.store.moveHost(withID: host.id, toGroupID: other.id, atIndex: .max)
                    }
                }
                moveItem.submenu = submenu
                menu.addItem(moveItem)
            }
            menu.addItem(.separator())
            add(menu, "Remove Host") { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Remove “\(host.name)”?"
                alert.informativeText = "This cannot be undone. Saved credentials are not affected."
                alert.addButton(withTitle: "Cancel")   // default, so Return cancels
                alert.addButton(withTitle: "Remove")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                self.parent.store.removeHost(host)
            }
        case .staticRow:
            guard let host = node.host else { return nil }
            add(menu, "Connect") { [weak self] in
                self?.parent.model.open(host: host)
                self?.parent.model.collapseSidebar()
            }
            if node.id.hasPrefix("recent-") {
                menu.addItem(.separator())
                add(menu, "Remove from Recent") { [weak self] in self?.parent.store.removeRecent(host) }
            }
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func add(_ menu: NSMenu, _ title: String, action: @escaping () -> Void) {
        let item = MenuAction(title: title, run: action)
        menu.addItem(item)
    }

    // MARK: Drag & drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarItem else { return nil }
        switch node.kind {
        case .group:
            guard parent.searchText.isEmpty, let id = node.group?.id else { return nil }
            return "group:\(id.uuidString)" as NSString
        case .host:
            guard parent.searchText.isEmpty, let id = node.host?.id else { return nil }
            return "host:\(id.uuidString)" as NSString
        default:
            return nil
        }
    }

    private enum Payload {
        case group(UUID)
        case host(UUID)
    }

    private func payload(_ info: NSDraggingInfo) -> Payload? {
        guard let text = info.draggingPasteboard.string(forType: .string) else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        return parts[0] == "group" ? .group(id) : parts[0] == "host" ? .host(id) : nil
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
        case .group(let id):
            // The dragged row can be deleted in another window while the drag
            // is in flight; lighting up an insertion line for a move that
            // cannot happen is worse than refusing the drop.
            guard parent.store.location(ofGroup: id) != nil else { return [] }
            // Groups only ever land between other groups, at the root.
            let target: Int
            if let node = item as? SidebarItem {
                // Whatever is under the pointer — the header itself or one of
                // its hosts — the insertion point is that group's root row.
                // Retargeting the host rows too is what removes the dead band
                // that used to sit over every expanded group's contents.
                guard let owner = groupNode(containing: node),
                      let position = roots.firstIndex(of: owner) else { return [] }
                target = (node.kind == .group && index == NSOutlineViewDropOnItemIndex)
                    ? position
                    : position + 1
            } else {
                target = index == NSOutlineViewDropOnItemIndex
                    ? roots.count
                    : min(max(index, fixedSectionCount), roots.count)
            }
            outlineView.setDropItem(nil, dropChildIndex: target)
            return .move
        case .host(let id):
            guard parent.store.location(ofHost: id) != nil else { return [] }
            let groupNode: SidebarItem
            let target: Int
            if let owner = self.groupNode(containing: item) {
                groupNode = owner
                if let node = item as? SidebarItem, node.kind == .host {
                    // Dropped ON a host row: land in that host's slot.
                    target = owner.children.firstIndex(of: node) ?? owner.children.count
                } else if index == NSOutlineViewDropOnItemIndex {
                    // Dropped ON the header — including a collapsed one,
                    // whose children are built either way — means "the end".
                    target = owner.children.count
                } else {
                    target = index
                }
            } else if item == nil {
                // A root-level insertion point: between two groups, above the
                // first, or below the very last row. A host has to land INSIDE
                // a group, and returning [] here made the bottom of the list
                // (and every group boundary) refuse the drop. Use the group
                // the line is drawn against — the one above it, or the first
                // group when the line sits above them all.
                let stop = min(max(index == NSOutlineViewDropOnItemIndex ? roots.count : index, 0), roots.count)
                if let above = roots[..<stop].last(where: { $0.kind == .group }) {
                    groupNode = above
                    target = above.children.count
                } else if let first = roots.first(where: { $0.kind == .group }) {
                    groupNode = first
                    target = 0
                } else {
                    return []
                }
            } else {
                // A section header or one of its static rows — Recent and
                // This Mac are not places a host can live.
                return []
            }
            outlineView.setDropItem(groupNode, dropChildIndex: min(max(target, 0), groupNode.children.count))
            return .move
        }
    }

    /// The group a proposed drop location belongs to, whatever was under the
    /// pointer — the group row itself, or one of its hosts.
    private func groupNode(containing item: Any?) -> SidebarItem? {
        guard let node = item as? SidebarItem else { return nil }
        if node.kind == .group { return node }
        if node.kind == .host, let id = node.group?.id { return cache["group-\(id.uuidString)"] }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        // Same gates as validateDrop, re-checked: `true` here tells AppKit the
        // drop landed, and saying so when nothing moved is how a drag ends
        // with the row apparently back where it started and no explanation.
        guard parent.searchText.isEmpty, let payload = payload(info), index >= 0 else { return false }
        switch payload {
        case .group(let id):
            guard parent.store.location(ofGroup: id) != nil else { return false }
            // Count the groups above the insertion point rather than
            // subtracting fixedSectionCount: the fixed rows are not fixed
            // across time (finishing a session adds the Recent section), so
            // the arithmetic version was one row off whenever they changed
            // between validateDrop and here.
            let stop = min(index, roots.count)
            let groupIndex = roots[..<stop].filter { $0.kind == .group }.count
            parent.store.moveGroup(withID: id, toIndex: groupIndex)
        case .host(let id):
            guard let groupID = (item as? SidebarItem)?.group?.id,
                  parent.store.location(ofHost: id) != nil,
                  parent.store.location(ofGroup: groupID) != nil else { return false }
            parent.store.moveHost(withID: id, toGroupID: groupID, atIndex: index)
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
private final class MenuAction: NSMenuItem {
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
