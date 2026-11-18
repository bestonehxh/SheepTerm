import Foundation

/// Recently Deleted (6.1 (28), the owner: "ให้มีถังขยะในกรณีที่ลบอะไร 30 วัน"):
/// a host or a group the user deletes is kept for 30 days and can be put
/// back. Pure — entries in, entries / groups out; `HostStore` owns the file
/// (`trash.json` beside hosts.json) and calls in here.
///
/// THIS Mac's only: never synced, not in a backup. On every other Mac the
/// delete is a delete, as before. A password is never in here (a host only
/// names its credential), and nothing here is read by an older build.
///
/// Putting back makes NEW ids: the old ids are tombstoned for the merge-on-
/// save and for Sync (so another Mac's stale copy cannot resurrect a deleted
/// host), and a restored record must not be mistaken for that stale copy.
/// What pointed at the old ids from outside (Recent, a Home tile, another
/// group's Jump Server) is not brought back; what points INSIDE a restored
/// group is remapped.
@MainActor enum HostTrash {
    static let days = 30
    static let fileName = "trash.json"

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var deletedAt: Date
        /// The group a host was in, or the parent of a deleted group (nil = top level).
        var origin: UUID?
        /// `origin` as the sidebar showed it ("Bangkok › DC 1"); "" = top level.
        var originPath: String
        /// A deleted host, or nil for a group.
        var host: Host?
        /// A deleted group and its whole subtree, the group itself first.
        var groups: [HostGroup] = []
        /// The workspace it was in (its top-level group's), so a top-level
        /// group put back — it gets a new id, and membership is by id —
        /// returns THERE, not wherever the user happens to be looking.
        /// nil = not recorded (the workspace shown is used).
        var workspace: UUID?
        /// Keys a NEWER build wrote on the deleted host, groups and their
        /// hosts that this build does not know (`UnknownFields`), by their
        /// OLD ids, put back on the new ids when restored — the record came
        /// back without them and synced the loss. nil = none (and every
        /// entry written before 6.1 (61), and by one: optional keys only,
        /// so an older build still reads the file).
        var unknownGroups: [String: Data]?
        var unknownHosts: [String: Data]?

        var name: String { host?.name ?? groups.first?.name ?? "" }
        var isGroup: Bool { host == nil }
        var hostCount: Int { host == nil ? groups.reduce(0) { $0 + $1.hosts.count } : 1 }
    }

    // MARK: Into the trash

    /// One entry per host about to be removed.
    static func entries(forHosts ids: Set<UUID>, in groups: [HostGroup], now: Date) -> [Entry] {
        groups.flatMap { group in
            group.hosts.filter { ids.contains($0.id) }.map {
                Entry(deletedAt: now, origin: group.id, originPath: GroupTree.shownPath(of: group.id, in: groups), host: $0)
            }
        }
    }

    /// One entry per group about to be deleted, with its subtree. A picked
    /// group that is inside another picked group goes with that one.
    static func entries(forGroups ids: Set<UUID>, in groups: [HostGroup], now: Date) -> [Entry] {
        var covered = Set<UUID>()
        var out: [Entry] = []
        // Tree order: a parent is met before anything under it.
        for entry in GroupTree.preorder(groups) where ids.contains(entry.group.id) && !covered.contains(entry.group.id) {
            let subtree = GroupTree.subtreeIDs(of: entry.group.id, in: groups)
            covered.formUnion(subtree)
            let members = subtree.compactMap { id in groups.first { $0.id == id } }
            let parent = entry.group.parentID.flatMap { id in groups.contains { $0.id == id } ? id : nil }
            out.append(Entry(deletedAt: now, origin: parent,
                             originPath: parent.map { GroupTree.shownPath(of: $0, in: groups) } ?? "", groups: members))
        }
        return out
    }

    /// `entry` with what `extras` keeps for its host, groups and their hosts.
    static func keepingUnknown(_ entry: Entry, _ extras: UnknownFields.Extras) -> Entry {
        var copy = entry
        let hostIDs = (entry.host.map { [$0] } ?? entry.groups.flatMap(\.hosts)).map(\.id.uuidString)
        let groups = extras.groups.filter { id, _ in entry.groups.contains { $0.id.uuidString == id } }
        let hosts = extras.hosts.filter { id, _ in hostIDs.contains(id) }
        copy.unknownGroups = groups.isEmpty ? nil : groups
        copy.unknownHosts = hosts.isEmpty ? nil : hosts
        return copy
    }

    // MARK: Thirty days

    /// The entries still inside their 30 days (an entry dated in the future —
    /// a clock set back — is kept, never thrown away early).
    static func kept(_ entries: [Entry], now: Date) -> [Entry] {
        entries.filter { now.timeIntervalSince($0.deletedAt) < Double(days) * 86_400 }
    }

    /// Whole days until an entry goes: 30 the moment it is deleted, 1 on its last day.
    static func daysLeft(_ entry: Entry, now: Date) -> Int {
        let left = Double(days) * 86_400 - now.timeIntervalSince(entry.deletedAt)
        return min(days, max(1, Int((left / 86_400).rounded(.up))))
    }

    // MARK: Putting back

    /// `groups` with `entry` back in it, under new ids.
    ///
    /// A host returns to its group (by id, else the group now at its old
    /// path); when there is none, to a new top-
    /// level group named after it. A group returns under its old parent when
    /// that is still there and the subtree still fits the depth cap,
    /// otherwise to the top level. A name taken among its new siblings gets
    /// " 2", " 3" … — two groups of one name in one place cannot be told apart.
    static func restored(_ entry: Entry, into groups: [HostGroup]) -> [HostGroup] {
        restoring(entry, into: groups).groups
    }

    /// `restored`, plus the entry's kept unknown keys (`Entry.unknownGroups`
    /// / `unknownHosts`) under the NEW ids, for the store to write back.
    static func restoring(_ entry: Entry, into groups: [HostGroup]) -> (groups: [HostGroup], unknown: UnknownFields.Extras) {
        var out = groups
        func unknown(groups groupIDs: [UUID: UUID], hosts hostIDs: [UUID: UUID]) -> UnknownFields.Extras {
            var extras = UnknownFields.Extras()
            for (old, new) in groupIDs { if let keep = entry.unknownGroups?[old.uuidString] { extras.groups[new.uuidString] = keep } }
            for (old, new) in hostIDs { if let keep = entry.unknownHosts?[old.uuidString] { extras.hosts[new.uuidString] = keep } }
            return extras
        }
        if var host = entry.host {
            let old = host.id
            host.id = UUID()
            if let jump = host.jumpHostID, !holdsHost(jump, in: out) { host.jumpHostID = nil }
            // Its group by id; or — the group was deleted and put back, so
            // it has a new id — the group now at the same path.
            let home = entry.origin.flatMap { id in out.firstIndex { $0.id == id } }
                ?? (entry.originPath.isEmpty ? nil : out.firstIndex { GroupTree.shownPath(of: $0.id, in: out) == entry.originPath })
            if let index = home {
                out[index].hosts.append(host)
            } else {
                let wanted = entry.originPath.components(separatedBy: GroupTree.shownSeparator).last ?? ""
                let name = freeName(wanted.isEmpty ? host.name : wanted, under: nil, in: out)
                out.append(HostGroup(name: name, hosts: [host]))
            }
            return (out, unknown(groups: [:], hosts: [old: host.id]))
        }
        guard let root = entry.groups.first else { return (out, UnknownFields.Extras()) }
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: a damaged file with one id twice must not trap.
        let groupIDs = Dictionary(entry.groups.map { ($0.id, UUID()) }, uniquingKeysWith: { first, _ in first })
        let hostIDs = Dictionary(entry.groups.flatMap(\.hosts).map { ($0.id, UUID()) }, uniquingKeysWith: { first, _ in first })
        func jump(_ old: UUID?) -> UUID? {
            guard let old else { return nil }
            return hostIDs[old] ?? (holdsHost(old, in: out) ? old : nil)
        }
        var parent = entry.origin.flatMap { id in out.contains { $0.id == id } ? id : nil }
        if let known = parent, GroupTree.depth(of: known, in: out) + GroupTree.height(of: root.id, in: entry.groups) > GroupTree.maxDepth {
            parent = nil
        }
        for var group in entry.groups {
            let isRoot = group.id == root.id
            group.parentID = isRoot ? parent : group.parentID.flatMap { groupIDs[$0] }
            if isRoot { group.name = freeName(group.name, under: parent, in: out) }
            group.id = groupIDs[group.id] ?? UUID()
            group.jumpHostID = jump(group.jumpHostID)
            group.hosts = group.hosts.map { host in
                var copy = host
                copy.id = hostIDs[host.id] ?? UUID()
                copy.jumpHostID = jump(host.jumpHostID)
                // A saved split's panes name hosts by id: those that came
                // back with it have new ones (6.1 (52) — the panes opened
                // as typed targets, their credential and jump path gone).
                if let split = host.split { copy.split = SavedSplit(root: Self.remapped(split.root, hostIDs)) }
                return copy
            }
            out.append(group)
        }
        return (out, unknown(groups: groupIDs, hosts: hostIDs))
    }

    private static func holdsHost(_ id: UUID, in groups: [HostGroup]) -> Bool {
        groups.contains { $0.hosts.contains { $0.id == id } }
    }

    /// `name`, or `name 2`, `name 3` … — the first no sibling under `parent` has.
    static func freeName(_ name: String, under parent: UUID?, in groups: [HostGroup]) -> String {
        let taken = Set(GroupTree.children(of: parent, in: groups).map { HostStore.cleanGroupName($0.name).lowercased() })
        let base = HostStore.cleanGroupName(name)
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    private static func remapped(_ node: SavedSplit.Node, _ hostIDs: [UUID: UUID]) -> SavedSplit.Node {
        switch node {
        case .pane(var pane):
            if let old = pane.hostID, let new = hostIDs[old] { pane.hostID = new }
            return .pane(pane)
        case .split(let vertical, let children, let fractions):
            return .split(vertical: vertical, children: children.map { remapped($0, hostIDs) }, fractions: fractions)
        }
    }

    // MARK: The file

    /// Missing → empty. Unreadable → nil: the store then moves the file
    /// aside before it writes a new one (it may hold things the user still
    /// wants back), and a delete is never stopped by it.
    /// `load`, told whether the file is THERE: a file that exists and gave
    /// no bytes (an I/O error, permissions) is unreadable, not missing — as
    /// "missing" it read as an empty trash and the next delete wrote over
    /// up to 30 days of things to put back.
    static func readable(_ data: Data?, fileExists: Bool) -> [Entry]? {
        data == nil && fileExists ? nil : load(data)
    }

    static func load(_ data: Data?) -> [Entry]? {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([Entry].self, from: data)
    }

    static func save(_ entries: [Entry]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(entries)
    }
}
