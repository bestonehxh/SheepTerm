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
    case hostSection    // a sub-heading INSIDE a group: the hosts sharing a label
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

    var isExpandable: Bool { !children.isEmpty || kind == .group || kind == .hostSection }
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
    /// Folded section headings, keyed "<groupID>/<label>" — a label means
    /// nothing on its own now that two groups may both have a "Floor 2".
    @Binding var collapsedHostSections: Set<String>
    let onEditHost: (Host) -> Void
    let onRenameGroup: (HostGroup) -> Void
    let onReorderGroups: () -> Void
    let onDeleteGroup: (HostGroup) -> Void
    let onExportGroup: (HostGroup) -> Void
    let onAddHosts: (HostGroup) -> Void
    let onSetGroupCredential: (HostGroup) -> Void
    /// Deletes without asking: the multi-group menu has already asked once,
    /// for all of them, and one call is one write. `onDeleteGroup` keeps its
    /// own confirmation for the single-group case.
    let onDeleteGroups: (Set<UUID>) -> Void
    /// Section actions that need a text prompt, which only SwiftUI can put on
    /// screen. Everything else a section can do is a store call and stays in
    /// the coordinator, next to the moves.
    let onRenameHostSection: (HostGroup, String) -> Void
    /// A heading for a GROUP, with no hosts in it yet — the group owns its
    /// sections, so creating one is the group's menu item. (There is no
    /// host-side "New Section…" any more: a host points at one of its group's
    /// headings, it does not invent one.)
    let onNewGroupSection: (HostGroup) -> Void

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

    func configure(title text: String, count number: Int?, quiet: Bool = false) {
        title.stringValue = text
        // A heading INSIDE a group sits one level below the group's own row,
        // so it is a little smaller and a little quieter — the only
        // difference, because it is the same kind of row one step down.
        title.font = .systemFont(ofSize: quiet ? 10.5 : 11.5, weight: quiet ? .medium : .semibold)
        title.textColor = quiet ? .secondaryLabelColor : .labelColor
        count.stringValue = number.map(String.init) ?? ""
        count.isHidden = number == nil
        // The count is a bare number beside a name, which VoiceOver reads as
        // "Lab 13" — a row of a list, or thirteen of something? Said out loud
        // once, here, for group rows and heading rows alike.
        if let number {
            setAccessibilityLabel("\(text), \(number) host\(number == 1 ? "" : "s")")
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

    /// The last group header click that reached `singleClick`: which header,
    /// when, and the click chain it belonged to.
    private var lastGroupToggle: (id: String, at: TimeInterval, clicks: Int)?

    private var isDragging = false
    private var pendingRebuild = false

    init(_ parent: SidebarOutline) {
        self.parent = parent
    }

    // MARK: Model

    /// A heading's row id and its collapse key are both scoped to the group:
    /// two groups may each have a "Floor 2" and they fold independently.
    static func sectionRowID(group: UUID, label: String) -> String {
        "section-\(group.uuidString)/\(label)"
    }

    static func collapseKey(group: UUID, label: String) -> String {
        "\(group.uuidString)/\(label)"
    }

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
                // The heading counts as part of a host's name here: it is on
                // screen as a row, and a visible word that finds nothing is
                // the kind of small lie that makes a search feel broken.
                $0.name.matchesSearch(text) || $0.address.matchesSearch(text)
                    || ($0.sectionName?.matchesSearch(text) ?? false)
            }
            // The matching hosts keep their own section label (they are copies
            // of the hosts themselves), so a hit is still shown under its
            // heading instead of appearing to have moved out of it.
            // The declared heading list travels with the copy so the headings
            // that DO have a hit keep the group's own order. Empty ones are
            // dropped when the rows are built — a search shows what matched.
            return hosts.isEmpty ? nil : HostGroup(id: group.id, name: group.name,
                                                   hosts: hosts, sections: group.sections)
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
        var collapsedHostSections: Set<String>
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

        // Groups are flat — `groups` order, nothing above them. The order
        // INSIDE one is `SidebarLayout.rows(for:)` and nothing else: loose
        // hosts first in array order, then the group's headings in its own
        // declared order (see that function for why). This is the only place a
        // heading becomes a row (see ARCHITECTURE §3).
        let searching = !parent.searchText.isEmpty
        for group in filteredGroups {
            let node = item(id: "group-\(group.id.uuidString)", kind: .group)
            node.group = group
            node.title = group.name
            var children: [SidebarItem] = []
            for row in SidebarLayout.rows(for: group) {
                switch row {
                case .host(let host):
                    let item = item(id: "host-\(host.id.uuidString)", kind: .host)
                    item.host = host
                    item.group = group
                    children.append(item)
                case .heading(let label, let hosts):
                    // A search shows what MATCHED: an empty heading matched
                    // nothing, and a row that is always there whatever is
                    // typed reads as a result.
                    if searching, hosts.isEmpty { continue }
                    let heading = item(id: Self.sectionRowID(group: group.id, label: label),
                                       kind: .hostSection)
                    heading.title = label
                    heading.group = group
                    heading.children = hosts.map { host in
                        let item = item(id: "host-\(host.id.uuidString)", kind: .host)
                        item.host = host
                        item.group = group
                        return item
                    }
                    children.append(heading)
                }
            }
            node.children = children
            result.append(node)
        }
        // Rows that no longer exist must leave the cache with them —
        // otherwise every deleted host keeps its item alive for the life
        // of the window. Three levels deep now, so this walks instead of
        // looking one step down.
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
        // Depth-first: with sections the tree is three levels deep, and a
        // one-level walk could not see a host move between a group's loose
        // rows and one of its headings — the outline would keep showing the
        // old arrangement.
        func walk(_ node: SidebarItem, depth: Int) {
            // The count the row DRAWS is part of the signature: a group shows
            // every host in it (loose and in sections) and a heading shows
            // its own, so a host moving between the two reloads both rows.
            let drawn: Int
            switch node.kind {
            case .group: drawn = node.group?.hosts.count ?? node.children.count
            case .hostSection: drawn = node.children.count
            default: drawn = node.children.count
            }
            parts.append(node.host?.sectionName ?? "")
            // The group's DECLARED list: reordering headings or creating an
            // empty one changes no host and no count, so without this the
            // outline kept showing the old arrangement.
            if node.kind == .group { parts.append((node.group?.sections ?? []).joined(separator: "\u{1}")) }
            parts.append("\(depth)|" + node.id + "|" + (node.host?.name ?? node.title)
                         + "|" + (node.host?.address ?? "") + "|" + (node.host?.kind.badge ?? "")
                         + "|" + String(drawn))
            for child in node.children { walk(child, depth: depth + 1) }
        }
        for root in roots { walk(root, depth: 0) }
        parts.append(parent.collapsedGroups.map(\.uuidString).sorted().joined(separator: ","))
        parts.append(parent.collapsedHostSections.sorted().joined(separator: ","))
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
                               collapsedHostSections: parent.collapsedHostSections)
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
        case .hostSection:
            // A search shows everything it matched: folding a heading over a
            // hit is the same mistake as folding a group over one.
            let collapsed = parent.searchText.isEmpty && collapseKey(for: node).map {
                parent.collapsedHostSections.contains($0)
            } ?? false
            if collapsed != !outline.isItemExpanded(node) {
                trace("applyExpansion: forcing section \(node.title) to \(collapsed ? "collapsed" : "expanded")")
            }
            if collapsed { outline.collapseItem(node) } else { outline.expandItem(node) }
        case .group:
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

    private func collapseKey(for node: SidebarItem) -> String? {
        guard node.kind == .hostSection, let group = node.group?.id else { return nil }
        return Self.collapseKey(group: group, label: node.title)
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
        // no longer exists anywhere would sit here forever — and a heading's
        // id is its group and label, so "Floor 2" removed and made again gets
        // the SAME id and would come back selected for no reason the user can
        // see. (A host's id is a UUID, so this only ever bites headings.)
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
        // A heading inside a group: quieter than the group's own row, and it
        // has to fit between 34 pt host rows without looking like one.
        case .hostSection: return 22
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
        case .hostSection:
            let cell = labelCell(outlineView)
            // Its own hosts. The group header above it counts them ALL —
            // loose and filed — so the two numbers answer different
            // questions and both are worth showing.
            cell.configure(title: node.title, count: node.children.count, quiet: true)
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

    /// Keeps section headings out of a MULTI-selection. A heading is not a
    /// thing to act on together with its neighbours: ⌘-clicking one while
    /// hosts are selected leaves the hosts selected, and a plain click on it
    /// (one proposed row) selects it as before.
    func outlineView(_ outlineView: NSOutlineView,
                     selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard proposed.count > 1 else { return proposed }
        return proposed.filteredIndexSet { row in
            // `.section` too — the static "Hosts" / "Recent" headings.
            // `shouldSelectItem` refuses them one at a time, but a
            // shift-drag proposes a RANGE and AppKit hands the whole range
            // here, so a sweep from a host up past "Hosts" used to end with
            // the heading highlighted.
            switch (outlineView.item(atRow: row) as? SidebarItem)?.kind {
            case .hostSection, .section: return false
            default: return true
            }
        }
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
        // back with every heading inside it expanded.
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
        var collapsed: Set<UUID> = []
        // Starts as what is STORED, not empty: a heading inside a collapsed
        // group cannot be asked about. AppKit reports every item under a
        // collapsed parent as not-expanded, so reading them would "discover"
        // that they are all open and throw away the user's folds — measured,
        // and the reason this walk stops at a closed row (ARCHITECTURE §11).
        var collapsedSections = parent.collapsedHostSections
        func scan(_ node: SidebarItem) {
            switch node.kind {
            case .group:
                let open = outline.isItemExpanded(node)
                if let id = node.group?.id, !open { collapsed.insert(id) }
                guard open else { return }
            case .hostSection:
                guard let key = collapseKey(for: node) else { return }
                if outline.isItemExpanded(node) {
                    collapsedSections.remove(key)
                } else {
                    collapsedSections.insert(key)
                }
                return
            default:
                break
            }
            for child in node.children { scan(child) }
        }
        for root in roots { scan(root) }
        let groupsMatch = collapsed == parent.collapsedGroups
        let sectionsMatch = collapsedSections == parent.collapsedHostSections
        guard !groupsMatch || !sectionsMatch else {
            trace("sync: outline already matches (\(collapsed.count) groups, \(collapsedSections.count) sections collapsed)")
            return
        }
        trace("sync: writing \(collapsed.count) groups / \(collapsedSections.count) sections collapsed")
        if !groupsMatch { parent.collapsedGroups = collapsed }
        if !sectionsMatch { parent.collapsedHostSections = collapsedSections }
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
        case .group, .hostSection:
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
            trace("singleClick \(node.kind == .hostSection ? "section" : "group")=\(node.title) clicks=\(clicks) expanded=\(outline.isItemExpanded(node)) swallow=\(brokenPair)")
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
        if isSelectionModifierDown {
            trace("doubleClick \(node.title.isEmpty ? node.id : node.title) — modifier held, selection only")
            return
        }
        // AppKit sends `action` for the first click of a pair and
        // `doubleAction` for the second, so a group header has ALREADY been
        // toggled by singleClick — activating it here folded it straight back
        // and a double click on a group looked like it did nothing.
        // Return still reaches activate() for groups, where toggling is right.
        guard node.kind != .group, node.kind != .hostSection else {
            trace("doubleClick \(node.kind == .hostSection ? "section" : "group")=\(node.title) — skipped, singleClick owns the toggle")
            return
        }
        activate(node)
    }

    /// Opens a row: flash the pill and connect in the same runloop turn —
    /// the old build waited 0.18s before doing anything, which is exactly
    /// the lag that made clicking feel slow.
    func activate(_ node: SidebarItem) {
        switch node.kind {
        case .group, .hostSection:
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

    /// The rows the menu is about, in display order: the selection when the
    /// clicked row is part of it (`menu(for:)` has already made that true),
    /// otherwise just that row.
    private func selectedNodes() -> [SidebarItem] {
        guard let outline else { return [] }
        return outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? SidebarItem }
    }

    /// The "Section ▸" submenu for one or more HOSTS: the headings their group
    /// has (ticked when every one of them is already there) and "No Section".
    /// A selection spanning two groups is offered the union of their headings
    /// and the label is applied per host in its own group — the label is just
    /// a string, so that is well defined.
    ///
    /// No "New Section…" here: **the group owns its sections**, so creating one
    /// is the group's menu item. Filing a host under a heading that does not
    /// exist yet was the one action that let a host invent a row in its group.
    private func sectionSubmenu(for hosts: [Host]) -> NSMenuItem {
        let ids = Set(hosts.map(\.id))
        let item = NSMenuItem(title: "Section", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        // ONE pass in the store, not a group search plus a linear dedupe per
        // selected host: ⌘A then right-click over 2,000 hosts and 800 headings
        // took 3.8 s to put this menu on screen.
        let offered = parent.store.offeredSections(forHostIDs: ids)
        // The nils are KEPT: `compactMap` threw the loose hosts away, so a
        // selection of one filed host and one loose one ticked the heading as
        // though both were under it.
        // FOLDED keys, so a selection spanning two groups whose headings
        // differ only in case or spacing is one heading here too. The nils are
        // KEPT (`map`, not `compactMap`): a selection of one filed host and
        // one loose one ticked the heading as though both were under it.
        let current = Set(hosts.map { HostStore.headingKey($0.sectionName) })
        for label in offered {
            add(submenu, label) { [weak self] in
                self?.parent.store.setSection(label, forHostIDs: ids)
            }
            // `sameHeading`, not `==`: a selection spanning two groups whose
            // headings differ only in case or spacing is under ONE heading as
            // far as the sidebar is concerned, so the offered entry is ticked.
            if current.count == 1, let only = current.first, only != nil,
               only == HostStore.headingKey(label) {
                submenu.items.last?.state = .on
            }
        }
        if !offered.isEmpty { submenu.addItem(.separator()) }
        add(submenu, "No Section") { [weak self] in
            guard let self else { return }
            let filed = self.parent.store.filedCount(ofHostIDs: ids)
            // The same words as Move to Group above, from the one place that
            // copy lives — and the count is HOSTS, not headings.
            guard self.confirmUnfiling(count: filed,
                                       message: HostStore.unfileQuestion(count: filed))
            else { return }
            self.parent.store.setSection(nil, forHostIDs: ids)
        }
        // Every selected host loose: `nil` is the one key that means that.
        if current == [nil] { submenu.items.last?.state = .on }
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
            if selection.allSatisfy({ $0.kind == .group }), node.kind == .group {
                return multiGroupMenu(selection.compactMap(\.group))
            }
            return nil
        }
        switch node.kind {
        case .section:
            return nil
        case .hostSection:
            guard let group = node.group else { return nil }
            let label = node.title
            add(menu, "Rename Section…") { [weak self] in
                self?.parent.onRenameHostSection(group, label)
            }
            menu.addItem(.separator())
            add(menu, "Remove Section") { [weak self] in
                guard let self else { return }
                // From the store, not from the row: a heading row built
                // during a search holds only the hosts that matched.
                let count = HostStore.hostCount(inSection: label,
                                                hosts: self.parent.store.hosts(inGroup: group.id))
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Remove the heading “\(label)”?"
                alert.informativeText = "\(count) host\(count == 1 ? "" : "s") stay in “\(group.name)”."
                alert.addButton(withTitle: "Cancel")   // default, so Return cancels
                alert.addButton(withTitle: "Remove Section")
                // An EMPTY heading is removed without asking: there is
                // nothing to lose track of, and a confirmation for "take away
                // a row with nothing in it" is noise.
                if count > 0 {
                    guard alert.sheepStyled().runModal() == .alertSecondButtonReturn else { return }
                }
                self.parent.store.removeSection(in: group.id, label)
            }
            // Not while a search is on: the rows on screen are the ones that
            // matched, so "up" and "down" would move a heading past rows the
            // user cannot see. (Reordering is disabled for groups mid-search
            // for the same reason — a drag cannot start with text in the
            // field.)
            guard parent.searchText.isEmpty else { return menu }
            menu.addItem(.separator())
            // The group owns the ORDER, so the heading can be moved in it.
            // Disabled at the ends rather than hidden: a menu whose items come
            // and go is harder to learn than one with a greyed item.
            let order = parent.store.sections(in: group.id)
            let at = order.firstIndex { $0 == label || HostStore.sameHeading($0, label) }
            menu.autoenablesItems = false
            add(menu, "Move Up") { [weak self] in
                self?.parent.store.moveSection(in: group.id, label, direction: .up)
            }
            menu.items.last?.isEnabled = (at ?? 0) > 0
            add(menu, "Move Down") { [weak self] in
                self?.parent.store.moveSection(in: group.id, label, direction: .down)
            }
            menu.items.last?.isEnabled = at.map { $0 < order.count - 1 } ?? false
        case .group:
            guard let group = node.group else { return nil }
            add(menu, "Export Group…") { [weak self] in self?.parent.onExportGroup(group) }
            add(menu, "Add Hosts…") { [weak self] in self?.parent.onAddHosts(group) }
            // Not while a search is on: `buildRoots` hides a heading with no
            // matching hosts, so a heading created mid-search would never
            // appear — a menu item that silently does nothing. (Same reason
            // Move Up / Move Down are left out then.)
            if parent.searchText.isEmpty {
                add(menu, "New Section…") { [weak self] in self?.parent.onNewGroupSection(group) }
            }
            add(menu, "Set Credential for Group…") { [weak self] in self?.parent.onSetGroupCredential(group) }
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
            menu.addItem(.separator())
            menu.addItem(sectionSubmenu(for: [host]))
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
                        self?.parent.store.moveHosts(withIDs: [host.id], toGroupID: other.id,
                                                     atIndex: .max, section: nil)
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
                alert.informativeText = "This cannot be undone."
                alert.addButton(withTitle: "Cancel")   // default, so Return cancels
                alert.addButton(withTitle: "Remove")
                guard alert.sheepStyled().runModal() == .alertSecondButtonReturn else { return }
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

    /// Several groups selected. A group has no section of its own any more (a
    /// section lives INSIDE one), so what is left is the order and the
    /// delete — with ONE confirmation naming the groups and the hosts that
    /// would go with them.
    private func multiGroupMenu(_ groups: [HostGroup]) -> NSMenu {
        let menu = NSMenu()
        add(menu, "Reorder Groups…") { [weak self] in self?.parent.onReorderGroups() }
        menu.addItem(.separator())
        // From the STORE, by id: during a search the rows carry FILTERED
        // copies of their groups, and counting those promised "2 hosts go
        // with them" before deleting thirty-five.
        let hostCount = HostStore.hostCount(ofGroupIDs: Set(groups.map(\.id)),
                                            in: parent.store.groups)
        add(menu, "Delete \(groups.count) Groups") { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Delete \(groups.count) groups?"
            alert.informativeText = "\(hostCount) host\(hostCount == 1 ? "" : "s") go with them. "
                + "This cannot be undone."
            alert.addButton(withTitle: "Cancel")   // default, so Return cancels
            alert.addButton(withTitle: "Delete")
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
        // NOT `store.groups`: a group that already holds every selected host
        // is left out, because moving them there does nothing visible.
        let groups = parent.store.moveTargets(forHostIDs: Set(ids))
        if !groups.isEmpty {
            let moveItem = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for group in groups {
                // Int.max is clamped to the group's host count = append, and
                // by id for the same reason the single-host menu is.
                // Loose in the target group: a heading belongs to the group
                // it is in, and carrying "Floor 2" into another group would
                // invent a heading there that nobody asked for.
                add(submenu, group.name) { [weak self] in
                    guard let self else { return }
                    let losing = self.parent.store.headingsLost(movingHostIDs: Set(ids),
                                                                toGroupID: group.id)
                    guard self.confirmUnfiling(
                        count: losing,
                        message: HostStore.unfileQuestion(count: losing)
                    ) else { return }
                    // `keepHeadingWhenStaying`: a selection spanning groups is
                    // about the hosts that CHANGE group — the ones already in
                    // the destination used to be unfiled as a side effect.
                    self.parent.store.moveHosts(withIDs: ids, toGroupID: group.id,
                                                atIndex: .max, section: nil,
                                                keepHeadingWhenStaying: true)
                }
            }
            moveItem.submenu = submenu
            menu.addItem(moveItem)
        }
        menu.addItem(sectionSubmenu(for: hosts))
        menu.addItem(.separator())
        add(menu, "Delete \(hosts.count) Hosts") { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Remove \(hosts.count) hosts?"
            // Two names and a count, not a list: the list pushed this alert
            // into the wide layout, and the number is what matters here.
            let named = hosts.prefix(2).map(\.name).joined(separator: ", ")
            let more = hosts.count > 2 ? " and \(hosts.count - 2) more" : ""
            alert.informativeText = "\(named)\(more). This cannot be undone."
            alert.addButton(withTitle: "Cancel")   // default, so Return cancels
            alert.addButton(withTitle: "Remove")
            guard alert.sheepStyled().runModal() == .alertSecondButtonReturn else { return }
            // ONE write for one confirmed action.
            self.parent.store.removeHosts(withIDs: hosts.map(\.id))
        }
        return menu
    }

    /// Asks before a menu item unfiles SEVERAL hosts at once, and asks
    /// nothing at all below two — one host is a small, obvious change the
    /// user can put back by hand, a dozen is not, and nothing undoes it.
    /// Same shape as "Delete N Hosts": Cancel is the default button, so
    /// Return cancels.
    private func confirmUnfiling(count: Int, message: String) -> Bool {
        guard count > 1 else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        // Short on purpose: past ~3 rendered lines the alert flips to the
        // wide layout and the icon leaves the centre (see `sheepStyled`).
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Cancel")   // default, so Return cancels
        alert.addButton(withTitle: "Continue")
        return alert.sheepStyled().runModal() == .alertSecondButtonReturn
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
        case .hostSection:
            guard parent.searchText.isEmpty, let groupID = node.group?.id,
                  let data = try? JSONEncoder().encode(HostStore.SectionReference(groupID: groupID, name: node.title)),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return "section:\(json)" as NSString
        case .host:
            guard parent.searchText.isEmpty, let id = node.host?.id else { return nil }
            return "host:\(id.uuidString)" as NSString
        default:
            return nil
        }
    }

    /// What a drag carries. A drag of a selected row brings the whole
    /// selection (AppKit writes one pasteboard item per row), so these are
    /// lists — and a MIXED drag is nothing: moving hosts and reordering
    /// groups are two different operations and there is no sensible drop for
    /// both at once.
    private enum Payload {
        case groups([UUID])
        case hosts([UUID])
        case section(HostStore.SectionReference)
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
        var sections: [HostStore.SectionReference] = []
        for text in texts {
            if text.hasPrefix("section:"),
               let section = try? JSONDecoder().decode(HostStore.SectionReference.self,
                                                       from: Data(text.dropFirst(8).utf8)) {
                sections.append(section)
                continue
            }
            let parts = text.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { continue }
            if parts[0] == "group" { groups.append(id) } else if parts[0] == "host" { hosts.append(id) }
        }
        if !sections.isEmpty {
            return sections.count == 1 && groups.isEmpty && hosts.isEmpty ? .section(sections[0]) : nil
        }
        if !groups.isEmpty, hosts.isEmpty { return .groups(groups) }
        if !hosts.isEmpty, groups.isEmpty { return .hosts(hosts) }
        return nil
    }

    /// Where a host drop lands, in terms the STORE understands: the group, an
    /// index into that group's own `hosts` array, and the heading it is filed
    /// under. A child index taken off a section row is a position among that
    /// section's hosts and means nothing to `moveHosts`, so every case is
    /// converted through the host ids that are actually on screen.
    ///
    /// Returns nil only when the position is not inside a group at all.
    private func hostDrop(item: Any?, childIndex index: Int) -> (group: UUID, index: Int, section: String?)? {
        func indexOf(_ host: Host?, in groupID: UUID) -> Int {
            guard let host, let at = parent.store.hostIndex(of: host.id, inGroup: groupID) else {
                return parent.store.hosts(inGroup: groupID).count
            }
            return at
        }

        // For each display row, the id of its FIRST host: a loose row is its
        // own host, a heading row is the first host under it. That id is what
        // turns a child index into a store index (`HostStore.dropIndex`).
        /// A HEADING's own rows, which are all hosts. The group's children go
        /// through `SidebarLayout.childFirstHostIDs` instead — that list has
        /// rows with no host in it (a heading, empty or not) and the rule for
        /// them lives with the layout.
        func firstHostIDs(_ children: [SidebarItem]) -> [UUID?] {
            children.map { child in child.host?.id }
        }

        if let node = item as? SidebarItem {
            switch node.kind {
            case .group:
                guard let group = node.group else { return nil }
                let groupID = group.id
                // ON the header — including a collapsed one — means "the end,
                // loose". Between its children means the position of the row
                // BELOW the line, loose: the group's own children are its
                // loose rows and its headings.
                guard index != NSOutlineViewDropOnItemIndex else {
                    return (groupID, parent.store.hosts(inGroup: groupID).count, nil)
                }
                // From the LAYOUT, not from the rows AppKit is holding: the
                // rule (a heading names no host) belongs with the order it
                // comes from, where it can be tested.
                let at = HostStore.dropIndex(
                    in: parent.store.hosts(inGroup: groupID),
                    childFirstHostIDs: SidebarLayout.childFirstHostIDs(for: group),
                    childIndex: index
                )
                return (groupID, at, nil)
            case .hostSection:
                guard let groupID = node.group?.id else { return nil }
                let label = node.title
                let hosts = parent.store.hosts(inGroup: groupID)
                guard index != NSOutlineViewDropOnItemIndex else {
                    // ON the heading: the end of that heading's own hosts.
                    let last = node.children.last?.host?.id
                    let after = last.flatMap { id in hosts.firstIndex { $0.id == id }.map { $0 + 1 } }
                    return (groupID, after ?? hosts.count, label)
                }
                // Between its hosts: the same "row below the line" rule, over
                // that heading's own rows (all of which ARE hosts, so
                // `firstHostIDs` names every one of them here).
                let at = HostStore.dropIndex(in: hosts,
                                             childFirstHostIDs: firstHostIDs(node.children),
                                             childIndex: index)
                return (groupID, at, label)
            case .host:
                // Dropped ON a host row: that host's slot, and its heading —
                // this retargeting is what removes the dead band over the
                // contents of an expanded group.
                guard let groupID = node.group?.id else { return nil }
                return (groupID, indexOf(node.host, in: groupID), node.host?.sectionName)
            default:
                return nil
            }
        }
        guard item == nil else { return nil }
        // A root-level insertion point: between two groups, above the first,
        // or below the very last row. A host has to land INSIDE a group, so
        // use the group the line is drawn against — the one above it, or the
        // first group when the line sits above them all. No gap may refuse
        // the drop; that dead band is what the retargeting exists to remove.
        // The owner of the gap is `SidebarLayout.rootGapOwner` — pure, tested,
        // and shared with the heading drag so the two cannot disagree.
        guard let gap = rootGap(index) else { return nil }
        return (gap.groupID, gap.aboveEveryGroup ? 0 : parent.store.hosts(inGroup: gap.groupID).count, nil)
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

    /// Where a dragged HEADING lands. This only TRANSLATES AppKit's
    /// (item, childIndex) into a `SidebarLayout.HeadingDropTarget`; the rules
    /// — which heading slot, and where the line is drawn — are
    /// `SidebarLayout.headingSlot`, pure and tested. `validateDrop` and
    /// `acceptDrop` both come through here with the same inputs, so the line
    /// and the landing cannot disagree.
    private func sectionDrop(item: Any?, childIndex index: Int)
        -> (group: UUID, slot: Int, node: SidebarItem, childIndex: Int)? {
        let owner: SidebarItem
        let target: SidebarLayout.HeadingDropTarget
        if let node = item as? SidebarItem {
            guard let group = groupNode(containing: node) else { return nil }
            owner = group
            let droppedOn = index == NSOutlineViewDropOnItemIndex
            switch node.kind {
            case .group:
                target = droppedOn ? .onGroupHeader : .betweenGroupRows(index)
            case .hostSection:
                target = droppedOn ? .onHeading(node.title) : .amongHeadingHosts(node.title)
            case .host:
                if let label = node.host?.sectionName {
                    target = .amongHeadingHosts(label)
                } else {
                    target = .onLooseHost
                }
            default:
                return nil
            }
        } else {
            // A ROOT-level gap, owned the way a host drop owns it: below a
            // group = that group's END; above every group = the first group's
            // TOP (slot 0). It used to be the end in both cases, so a heading
            // dropped above the first group landed at its bottom while a host
            // dropped in the same gap went to its top.
            guard item == nil, let gap = rootGap(index) else { return nil }
            owner = gap.node
            target = gap.aboveEveryGroup ? .betweenGroupRows(0) : .rootGap
        }
        // The REAL group, not the row's copy: no search is running (a heading
        // drag cannot start with text in the field), so they agree — but the
        // store is the one the move will read.
        guard let groupID = owner.group?.id,
              let group = parent.store.groups.first(where: { $0.id == groupID }) else { return nil }
        let landing = SidebarLayout.headingSlot(in: group, target: target)
        return (groupID, landing.slot, owner,
                min(max(0, landing.lineChildIndex), owner.children.count))
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
        case .section(let source):
            // An exact match is right here: the payload carries the ROW's
            // title, and `sections(in:)` is `displayedSections` — the very
            // spellings the rows are drawn from.
            guard parent.store.sections(in: source.groupID).contains(source.name),
                  let drop = sectionDrop(item: item, childIndex: index) else { return [] }
            outlineView.setDropItem(drop.node, dropChildIndex: drop.childIndex)
            return .move
        case .groups(let ids):
            // The dragged rows can be deleted in another window while the drag
            // is in flight; lighting up an insertion line for a move that
            // cannot happen is worse than refusing the drop.
            guard ids.contains(where: { parent.store.location(ofGroup: $0) != nil }) else { return [] }
            // Groups only ever land between other groups, at the root — a
            // group never goes inside a section (a section is inside a GROUP).
            let target: Int
            if let node = item as? SidebarItem {
                // Whatever is under the pointer — the header itself, a heading
                // inside it, or one of its hosts — the insertion point is that
                // group's root row. Retargeting the rows inside is what
                // removes the dead band over an expanded group's contents.
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
        case .hosts(let ids):
            guard ids.contains(where: { parent.store.location(ofHost: $0) != nil }) else { return [] }
            // Every position a host can land in — on a group header, between
            // its loose rows, on a heading, between a heading's hosts, on a
            // host row, or in the root gap under the last group — resolves
            // here. None of them may refuse the drop.
            guard let drop = hostDrop(item: item, childIndex: index) else { return [] }
            let parentNode: SidebarItem?
            let childIndex: Int
            // The INVERSE of `hostDrop`: which row the insertion line goes
            // above, for the store index the drop resolved to. Both halves are
            // pure functions beside each other (`HostStore.dropIndex` and
            // `SidebarLayout.childRow`) because they have to agree — drawing
            // the line somewhere other than where the host lands is the one
            // way a correct drop still looks broken.
            guard let group = parent.store.groups.first(where: { $0.id == drop.group })
            else { return [] }
            if let section = drop.section {
                // By the ROW's spelling, not the dropped-on host's: a host
                // labelled "floor  2" sits under the "Floor 2" row, and the
                // exact-label lookup found no row and refused the drop.
                let rowLabel = SidebarLayout.headingRowLabel(for: section, in: group)
                parentNode = cache[Self.sectionRowID(group: drop.group, label: rowLabel)]
                // The heading's own rows, taken from the LAYOUT: by folded key,
                // so a host spelled "floor  2" under the "Floor 2" row is one
                // of them (`==` left it out and the line jumped to the end).
                let members = SidebarLayout.rows(for: group).compactMap { row -> [Host]? in
                    guard case .heading(let label, let hosts) = row,
                          HostStore.sameHeading(label, section) || label == section else { return nil }
                    return hosts
                }.first ?? []
                var position: [UUID: Int] = [:]
                for (at, host) in group.hosts.enumerated() { position[host.id] = at }
                let at = members.firstIndex { (position[$0.id] ?? 0) >= drop.index }
                childIndex = at ?? members.count
            } else {
                parentNode = cache["group-\(drop.group.uuidString)"]
                childIndex = SidebarLayout.childRow(forStoreIndex: drop.index, in: group)
            }
            guard let parentNode else { return [] }
            outlineView.setDropItem(parentNode,
                                    dropChildIndex: min(max(childIndex, 0), parentNode.children.count))
            return .move
        }
    }

    /// The group a proposed drop location belongs to, whatever was under the
    /// pointer — the group row itself, or one of its hosts.
    private func groupNode(containing item: Any?) -> SidebarItem? {
        guard let node = item as? SidebarItem else { return nil }
        if node.kind == .group { return node }
        // A host row or a heading row — both know their group.
        if node.kind == .host || node.kind == .hostSection,
           let id = node.group?.id { return cache["group-\(id.uuidString)"] }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        // Same gates as validateDrop, re-checked: `true` here tells AppKit the
        // drop landed, and saying so when nothing moved is how a drag ends
        // with the row apparently back where it started and no explanation.
        guard parent.searchText.isEmpty, let payload = payload(info) else { return false }
        switch payload {
        case .section(let source):
            guard let drop = sectionDrop(item: item, childIndex: index) else { return false }
            let oldKey = "\(source.groupID.uuidString)/\(source.name)"
            let wasCollapsed = parent.collapsedHostSections.contains(oldKey)
            let crossGroup = drop.group != source.groupID
            // Asked BEFORE the move: a heading that reads the same already in
            // the destination means the move MERGES into it.
            let merging = crossGroup && parent.store.sections(in: drop.group)
                .contains { HostStore.sameHeading($0, source.name) }
            let revision = parent.store.revision
            guard let label = parent.store.moveSection(source, toGroupID: drop.group,
                                                       atIndex: drop.slot) else { return false }
            // A drop that changed nothing is not a drop: `false` lets AppKit
            // animate the row back, which is what the user sees happen anyway
            // (the store wrote nothing, so no revision was bumped).
            guard parent.store.revision != revision else { return false }
            if crossGroup {
                // The source's key goes either way — that row no longer exists
                // there. Its fold state travels only to a heading this move
                // CREATED; a merged-into heading keeps its own.
                parent.collapsedHostSections.remove(oldKey)
                if wasCollapsed, !merging {
                    parent.collapsedHostSections.insert("\(drop.group.uuidString)/\(label)")
                }
            }
        case .groups(let ids):
            let live = ids.filter { parent.store.location(ofGroup: $0) != nil }
            guard !live.isEmpty, index >= 0 else { return false }
            // Count the groups above the insertion point rather than
            // subtracting fixedSectionCount: the fixed rows are not fixed
            // across time (finishing a session adds the Recent section), so
            // the arithmetic version was one row off whenever they changed
            // between validateDrop and here. Group rows are roots again, so
            // this is a store index already.
            let stop = min(index, roots.count)
            let target = roots[..<stop].filter { $0.kind == .group }.count
            parent.store.moveGroups(withIDs: Set(live), toIndex: target)
        case .hosts(let ids):
            // Resolved the same way validateDrop resolved it, from the node
            // AppKit hands back — never from a raw child index, which for a
            // heading row counts that heading's own hosts and means nothing
            // to the store.
            guard index >= -1, let drop = hostDrop(item: item, childIndex: index),
                  parent.store.location(ofGroup: drop.group) != nil else { return false }
            let live = ids.filter { parent.store.location(ofHost: $0) != nil }
            guard !live.isEmpty else { return false }
            // One call, one save, the sidebar's own order — and the heading
            // the drop landed in travels with them.
            // The returned count is deliberately dropped, and this returns
            // `true` either way: the ids were live a line ago and the group
            // exists, so a zero here means "they were already exactly there"
            // — a drop that lands where the hosts already are is a successful
            // drop, not a failed one, and `false` would animate the rows back
            // as though AppKit had refused them.
            parent.store.moveHosts(withIDs: live, toGroupID: drop.group,
                                   atIndex: drop.index, section: drop.section)
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
