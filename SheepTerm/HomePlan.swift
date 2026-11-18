import Foundation

/// Home (6.1): a board of widgets the user picks — Recent, a group (its
/// subgroups included), hosts by type (a filter of types), or the hosts
/// behind a Jump Server — kept in UserDefaults so the next launch looks the
/// same. Since 6.1 (4) (the owner: "แบ่งเป็นแบบ iPhone ... จำกัดพื้นที่ จะได้สวย")
/// the board is a fixed 4-column grid, centred, of tiles in four sizes
/// (`Size`): a tile is as tall as its size, never as long as its list — what
/// does not fit is "+N more". Pure: the harness checks it
/// (`Tests/tests/HomeTests.swift`).
enum HomePlan {
    static let storageKey = "homeWidgets"
    /// The board's columns before 6.1 (4) (1–3): read once, to size an old board's tiles.
    static let columnsKey = "homeColumns"
    /// `Widget.limit` for "All" before 6.1 (4) (0).
    static let allRows = 0

    // MARK: The grid (6.1 (4))

    /// Columns of the grid before 6.1 (7), and `pack`'s default.
    nonisolated static let gridColumns = 4
    /// The search bar and the adding row: at most this wide, centred (6.1 (7),
    /// the owner: the search need not stretch with the board).
    nonisolated static let boardWidth: CGFloat = 680
    /// The board itself takes the width it is given (6.1 (7), the owner: the
    /// sides sat empty): as many columns of at least `minCellWidth` as fit,
    /// 2…6 (the owner: 8 was too many), never wider than `maxBoardWidth`. Narrower = fewer columns; the
    /// tiles flow down and the page scrolls.
    nonisolated static let minCellWidth: CGFloat = 150
    nonisolated static let columnRange = 2...6
    nonisolated static let maxBoardWidth: CGFloat = 1200
    /// The page's margin left and right (top 28, bottom 40).
    nonisolated static let sideMargin: CGFloat = 40

    /// An EVEN count (2, 4, 6; the owner: "ให้มันสมดุลตลอด"): most tiles are two
    /// columns wide, so rows come out whole instead of one odd column left over.
    nonisolated static func columns(forWidth width: CGFloat) -> Int {
        let fit = Int(((width + gap) / (minCellWidth + gap)).rounded(.down))
        let even = fit - fit % 2
        return min(max(even, columnRange.lowerBound), columnRange.upperBound)
    }
    // MARK: Scale (6.2 (2))

    /// Home grows with the room it has (6.2 (2), the owner on a 4K display:
    /// the board sat small in the middle). The WHOLE page — search, action
    /// row, tiles, text, icons, gaps — is drawn at `scale(forWidth:)` times
    /// its size: every literal inside Home is multiplied by it (the
    /// `homeScale` environment value), so text is drawn at its real size and
    /// clicks land where they show. Never `scaleEffect` (see ARCHITECTURE §34).
    nonisolated static let scaleStep: CGFloat = 0.05
    nonisolated static let maxScale: CGFloat = 2

    /// The factor for a Home `width` wide (what the sidebar / AI panel
    /// leave): 1 while the board and its margins fit at 1 (the room ≤
    /// `maxBoardWidth`) — a MacBook window looks exactly as before; above,
    /// the scaled board plus its scaled margins fill the width, stepped DOWN
    /// to a multiple of `scaleStep` (a resize relays out only at a step),
    /// at most `maxScale` (the board centred beyond it).
    nonisolated static func scale(forWidth width: CGFloat) -> CGFloat {
        let raw = width / (maxBoardWidth + 2 * sideMargin)
        guard raw > 1 else { return 1 }
        // Whole steps, divided back: 26 / 20 is 1.3, 26 × 0.05 is not quite.
        let perUnit = (1 / scaleStep).rounded()
        return min((raw * perUnit + 1e-9).rounded(.down) / perUnit, maxScale)
    }

    /// Columns for a board `width` wide drawn at `scale`: decided on the
    /// unscaled width, so a scaled board has the columns it would at 1.
    nonisolated static func columns(forWidth width: CGFloat, scale: CGFloat) -> Int {
        columns(forWidth: width / max(scale, 1))
    }

    /// One grid row's height and the gap between cells.
    nonisolated static let unitHeight: CGFloat = 140
    nonisolated static let gap: CGFloat = 12
    /// One host row inside a tile.
    nonisolated static let rowHeight: CGFloat = 24
    /// A tile's own room: its padding (12 + 12) and header (18 + 4), and the
    /// "+N more" line (16 + 4).
    nonisolated static let tileChrome: CGFloat = 46
    nonisolated static let moreLine: CGFloat = 20

    /// A tile's size, in grid cells (columns × rows).
    nonisolated enum Size: String, Codable, CaseIterable {
        /// 1 × 1: the count, big.
        case small
        /// 2 × 1: three rows.
        case medium
        /// 2 × 2: nine rows.
        case large
        /// 4 × 1: two columns of three rows.
        case wide

        var columns: Int { switch self { case .small: 1; case .medium, .large: 2; case .wide: 4 } }
        var rows: Int { self == .large ? 2 : 1 }
        /// Rows side by side (a wide tile: two columns of rows).
        var listColumns: Int { self == .wide ? 2 : 1 }
        /// Host rows a tile holds whole (`small` shows a count instead).
        var capacity: Int { rowsFitting(with: 0) }
        /// Rows beside the "+N more" line, when the list is longer.
        var capacityWithMore: Int { rowsFitting(with: HomePlan.moreLine) }
        private func rowsFitting(with extra: CGFloat) -> Int {
            guard self != .small else { return 0 }
            return Int(((height - HomePlan.tileChrome - extra) / HomePlan.rowHeight).rounded(.down)) * listColumns
        }
        /// The tile's height on the board.
        var height: CGFloat { unitHeight * CGFloat(rows) + gap * CGFloat(rows - 1) }
        /// …on a board drawn at `scale` (6.2 (2)). Every row inside grows by
        /// the same factor, so `capacity` stays what it is at 1.
        func height(scale: CGFloat) -> CGFloat { height * scale }
    }

    enum Source: Codable, Equatable, Hashable {
        case recent
        case group(UUID)
        /// One connection type (6.1, before the filter); read as `.types([kind])`.
        case type(String)
        /// Hosts whose `HostType` is in this set (6.0 (33)): `HostType` raw values.
        case types([String])
        /// The hosts a Jump Server reaches.
        case jumpServer(UUID)
        // 6.1 (8), the owner ("ชอบหมดเลย เอาทั้งหมด"): widgets that are not a host list.
        /// The time here (and the zones picked, `Widget.zones`).
        case clock
        /// The tabs open now, with their state; a click goes there.
        case sessions
        /// Every Ping tab's targets: up / down and the latest reply.
        case ping
        /// USB console cables plugged in now; Connect from the tile.
        case cables
        /// Saved snippets; a click types one into a session.
        case snippets
        /// The latest session logs; a click opens one read-only.
        case logs
        /// The File Server: which servers run, and transfers as they go.
        case fileServer
        /// A few lines of the user's own (`Widget.note`).
        case note
        /// Rack Fill: a turn-based block puzzle for a quiet minute.
        case rackFill
        /// A workspace as folders (6.1 (33), the owner: "ก้อนใหญ่ๆ อย่าง
        /// Workspace และก้อนในเป็น Group … เป็นแค่โฟลเดอร์ก่อนแล้วเปิดเข้าไปอีกตอนกด"):
        /// its top-level groups; a click goes into one — its subgroups as
        /// folders, its hosts as rows (`workspaceLevel`).
        case workspace(UUID)

        /// A host list (Recent, a group, by type, via a Jump Server): rows of hosts, +N more.
        var isHostList: Bool {
            switch self {
            case .recent, .group, .type, .types, .jumpServer: return true
            default: return false
            }
        }
    }

    /// The widgets the Add Widget menu offers beyond host lists, in its order.
    static let extraSources: [Source] = [.clock, .sessions, .ping, .cables, .snippets, .logs, .fileServer, .note, .rackFill]

    /// Time zones a Clock tile can add (IANA ids), in the menu's order.
    static let clockZones = ["UTC", "Asia/Bangkok", "Asia/Singapore", "Asia/Hong_Kong", "Asia/Tokyo", "Australia/Sydney",
                             "Asia/Kolkata", "Asia/Dubai", "Europe/London", "Europe/Berlin", "America/New_York", "America/Los_Angeles"]

    /// "Asia/Bangkok" → "Bangkok"; "UTC" stays.
    static func clockCity(_ id: String) -> String {
        (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }

    /// Whether the board shows a widget of `source` with workspace `selection`
    /// chosen (nil = All Workspaces, which shows everything): a group's widget
    /// only when its top-level group is in `visibleRoots`, a Workspace tile
    /// only on its own workspace, every other kind always. Add Widget offers
    /// only what passes (6.1 (62), UI review: a group of another workspace
    /// could be added, was saved, and never showed).
    static func shows(_ source: Source, selection: UUID?, visibleRoots: Set<UUID>?, groups: [HostGroup]) -> Bool {
        switch source {
        case .workspace(let id): return selection.map { $0 == id } ?? true
        case .group(let id):
            guard let visibleRoots else { return true }
            return visibleRoots.contains(WorkspacePlan.root(of: id, in: groups))
        default: return true
        }
    }

    /// A new widget's size: what it reads best at.
    static func defaultSize(_ source: Source) -> Size {
        switch source {
        case .clock, .cables: return .small
        case .rackFill, .note, .workspace: return .large
        case .fileServer, .sessions, .ping, .snippets, .logs: return .medium
        default: return .medium
        }
    }

    struct Widget: Codable, Equatable, Identifiable {
        var id = UUID()
        var source: Source
        /// Before 6.1 (4): columns it spanned and rows it showed — read only
        /// to size a board saved then (`size(of:oldColumns:)`).
        var width: Int = 1
        var limit: Int? = nil
        /// The tile's size (6.1 (4)); nil = a board from before, sized by `size(of:oldColumns:)`.
        var size: Size? = nil
        /// A Note tile's text (6.1 (8)).
        var note: String? = nil
        /// A Clock tile's extra zones, IANA ids (6.1 (8)).
        var zones: [String]? = nil
    }

    /// A tile's size: its own, else what it was before 6.1 (4) — the full
    /// width of the old board = wide; a long list (10 rows or more, All, or a
    /// group's every host) = large; the rest medium.
    static func size(of widget: Widget, oldColumns: Int = 2) -> Size {
        if let size = widget.size { return size }
        if widget.width >= min(max(oldColumns, 1), 3), widget.width > 1 || oldColumns == 1 { return .wide }
        let rows: Int? = {
            if let limit = widget.limit { return limit == allRows ? nil : limit }
            switch widget.source {
            case .recent: return 5
            case .type, .types: return 10
            case .group, .jumpServer: return nil
            default: return 5
            }
        }()
        return (rows ?? .max) >= 10 ? .large : .medium
    }

    /// What a tile lists: every host when they fit, else as many as fit
    /// beside the "+N more" line.
    nonisolated static func fit(_ count: Int, in size: Size) -> (shown: Int, more: Int) {
        guard size != .small else { return (0, count) }
        if count <= size.capacity { return (count, 0) }
        let shown = size.capacityWithMore
        return (shown, count - shown)
    }

    /// Where each tile sits, in cells (column, row), reading order, packed
    /// like a phone's home screen: each takes the first spot, row by row,
    /// left to right, where it fits — a small tile fills a hole a larger one
    /// left. Never wider than the grid.
    nonisolated static func pack(_ sizes: [Size], columns: Int = gridColumns) -> [(column: Int, row: Int)] {
        var taken = Set<[Int]>()
        var out: [(column: Int, row: Int)] = []
        for size in sizes {
            let w = min(size.columns, columns), h = size.rows
            var row = 0
            search: while true {
                for column in 0...(columns - w) {
                    let cells = (0..<h).flatMap { dy in (0..<w).map { dx in [column + dx, row + dy] } }
                    if cells.allSatisfy({ !taken.contains($0) }) {
                        cells.forEach { taken.insert($0) }
                        out.append((column, row))
                        break search
                    }
                }
                row += 1
            }
        }
        return out
    }

    /// The grid's columns in use — the board is centred on these (6.1 (8), the
    /// owner: an empty last column left the right margin wider than the left).
    nonisolated static func usedColumns(_ sizes: [Size], columns: Int = gridColumns) -> Int {
        zip(sizes, pack(sizes, columns: columns)).map { $1.column + min($0.columns, columns) }.max() ?? 0
    }

    /// The grid's rows in use.
    nonisolated static func rowCount(_ sizes: [Size], columns: Int = gridColumns) -> Int {
        zip(sizes, pack(sizes, columns: columns)).map { $1.row + $0.rows }.max() ?? 0
    }

    /// What a Mac that never edited Home shows (6.0 (33), the user: groups by
    /// default): Recent across the top, then every top-level group, all hosts.
    /// The ids are FIXED (Fable round 4): the default board is rebuilt on
    /// every render until the first edit saves it, and a fresh UUID each time
    /// lost "Show all", the picked row and that first edit.
    /// 6.1 (8), the owner: few tiles, not cluttered — Recent, Clock, Console,
    /// Sessions and each top-level group. Ping, File Server, Snippets, Logs,
    /// Note and Rack Fill wait in Add Widget (6.1 (13), the owner: Rack Fill
    /// off the default board).
    static func defaultWidgets(groups: [HostGroup]) -> [Widget] {
        [Widget(id: recentWidgetID, source: .recent, width: 3, size: .large),
         Widget(id: clockWidgetID, source: .clock, size: .small),
         Widget(id: consoleWidgetID, source: .cables, size: .small),
         Widget(id: sessionsWidgetID, source: .sessions, size: .medium)]
            + GroupTree.children(of: nil, in: groups).map { Widget(id: $0.id, source: .group($0.id), size: .medium) }
    }
    static let recentWidgetID = UUID(uuidString: "00000000-0000-4000-8000-0000000000E1")!
    static let clockWidgetID = UUID(uuidString: "00000000-0000-4000-8000-0000000000E2")!
    static let consoleWidgetID = UUID(uuidString: "00000000-0000-4000-8000-0000000000E3")!
    static let sessionsWidgetID = UUID(uuidString: "00000000-0000-4000-8000-0000000000E4")!

    /// Tiles a build before 6.1 (33) cannot read (a Workspace tile) live
    /// under their own key with their place on the board (6.1 (48)): such a
    /// build decodes `homeWidgets` whole, so ONE tile it does not know reset
    /// its board to the default — and its next edit synced that back here.
    static let newerKey = "homeWidgetsNewer"

    struct Placed: Codable, Equatable {
        var at: Int
        var widget: Widget
    }

    /// One tile this build cannot read is left out, not the whole board.
    private struct Lossy: Decodable {
        var widget: Widget?
        init(from decoder: Decoder) throws { widget = try? Widget(from: decoder) }
    }
    private struct LossyPlaced: Decodable {
        var placed: Placed?
        init(from decoder: Decoder) throws { placed = try? Placed(from: decoder) }
    }

    static func load(_ data: Data?, newer: Data? = nil, groups: [HostGroup] = []) -> [Widget] {
        let placed = (newer.flatMap { try? JSONDecoder().decode([LossyPlaced].self, from: $0) } ?? []).compactMap(\.placed).sorted { $0.at < $1.at }
        guard let data, let read = try? JSONDecoder().decode([Lossy].self, from: data) else {
            return defaultWidgets(groups: groups) + placed.map(\.widget)
        }
        var widgets = read.compactMap(\.widget)
        for tile in placed where !widgets.contains(where: { $0.id == tile.widget.id }) {
            widgets.insert(tile.widget, at: min(max(tile.at, 0), widgets.count))
        }
        return widgets
    }

    private static func isNewer(_ widget: Widget) -> Bool {
        if case .workspace = widget.source { return true }
        return false
    }

    /// The board for `storageKey`: every tile an older build reads.
    static func save(_ widgets: [Widget]) -> Data? { try? JSONEncoder().encode(widgets.filter { !isNewer($0) }) }

    /// The rest, for `newerKey`. None is an EMPTY list, never a removed
    /// key: Sync does not carry a removal (a missing setting is "unknown"),
    /// so the last Workspace tile taken off here stayed on the other Mac
    /// and came back with its next edit. Only Reset Home removes the key.
    static func saveNewer(_ widgets: [Widget]) -> Data? {
        let placed = widgets.enumerated().filter { isNewer($0.element) }.map { Placed(at: $0.offset, widget: $0.element) }
        return try? JSONEncoder().encode(placed)
    }

    /// The types a Source filters on, as `HostType`s.
    static func types(of source: Source) -> [HostType] {
        switch source {
        case .type(let kind): return HostType(rawValue: kind).map { [$0] } ?? []
        case .types(let kinds): return kinds.compactMap(HostType.init(rawValue:))
        default: return []
        }
    }

    /// The hosts a widget lists, in sidebar order (Recent: newest first).
    static func hosts(for source: Source, groups: [HostGroup], recents: [Host]) -> [Host] {
        switch source {
        case .recent:
            return recents
        case .group(let id):
            let ids = Set(GroupTree.subtreeIDs(of: id, in: groups))
            return groups.filter { ids.contains($0.id) }.flatMap(\.hosts)
        case .type, .types:
            let wanted = Set(types(of: source))
            return groups.flatMap(\.hosts).filter { $0.hostType.map(wanted.contains) ?? false }
        case .jumpServer(let id):
            let all = groups.flatMap(\.hosts)
            return all.filter {
                if case .saved(let bastion) = JumpTarget.resolve(host: $0, saved: all, groups: groups) { return bastion.id == id }
                return false
            }
        case .clock, .sessions, .ping, .cables, .snippets, .logs, .fileServer, .note, .rackFill, .workspace:
            return []
        }
    }

    // MARK: A workspace as folders (6.1 (33))

    /// One level of a Workspace tile: where it is (`crumbs`, outermost
    /// first; empty = the workspace itself), the folders to go into and the
    /// hosts of the group it is in.
    struct WorkspaceLevel: Equatable {
        var crumbs: [HostGroup] = []
        var folders: [HostGroup] = []
        var hosts: [Host] = []
    }

    /// The level at `group` (nil = the workspace's own: its top-level
    /// groups). A group that is gone, or that has moved to another
    /// workspace since, reads as the top — the tile never shows what its
    /// workspace no longer holds.
    static func workspaceLevel(_ workspace: UUID, at group: UUID?, plan: WorkspacePlan, groups: [HostGroup]) -> WorkspaceLevel {
        let roots = GroupTree.children(of: nil, in: groups).filter { plan.workspace(for: $0.id) == workspace }
        guard let group, let here = groups.first(where: { $0.id == group }),
              roots.contains(where: { $0.id == WorkspacePlan.root(of: group, in: groups) }) else {
            return WorkspaceLevel(folders: roots)
        }
        return WorkspaceLevel(crumbs: GroupTree.ancestors(of: group, in: groups) + [here],
                              folders: GroupTree.children(of: group, in: groups), hosts: here.hosts)
    }

    /// The hosts in a folder, its subgroups' included: the number on it.
    static func folderCount(_ group: UUID, groups: [HostGroup]) -> Int {
        hosts(for: .group(group), groups: groups, recents: []).count
    }

    /// A widget whose group or Jump Server is gone is dropped, not shown empty.
    /// `workspaces` (when given): a Workspace tile whose workspace was deleted goes too.
    static func live(_ widgets: [Widget], groups: [HostGroup], workspaces: Set<UUID>? = nil) -> [Widget] {
        widgets.filter { widget in
            switch widget.source {
            case .workspace(let id): return workspaces?.contains(id) ?? true
            case .recent, .type, .types: return true
            case .group(let id): return groups.contains { $0.id == id }
            case .jumpServer(let id): return groups.contains { $0.hosts.contains { $0.id == id } }
            case .clock, .sessions, .ping, .cables, .snippets, .logs, .fileServer, .note, .rackFill: return true
            }
        }
    }

    /// Drag and drop: `id` goes where `target` is (before it moving up,
    /// after it moving down) — the two swap places when they are neighbours.
    static func moved(_ widgets: [Widget], id: UUID, onto target: UUID) -> [Widget] {
        guard id != target, let from = widgets.firstIndex(where: { $0.id == id }),
              let to = widgets.firstIndex(where: { $0.id == target }) else { return widgets }
        var copy = widgets
        let widget = copy.remove(at: from)
        copy.insert(widget, at: to)
        return copy
    }

    /// The drag's text: "home-widget:<uuid>". Anything else is not ours.
    static let dragPrefix = "home-widget:"
    static func draggedID(_ text: String, in widgets: [Widget]) -> UUID? {
        guard text.hasPrefix(dragPrefix), let id = UUID(uuidString: String(text.dropFirst(dragPrefix.count))),
              widgets.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}
