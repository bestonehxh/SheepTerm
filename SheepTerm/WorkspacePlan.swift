import Foundation

/// Workspaces (Design/workspaces/PLAN.md): which top-level groups the sidebar
/// shows — Lab, a customer, "General" for everything else. A way to sort, not
/// a boundary: credentials and snippets stay shared.
///
/// Round 1 (6.1 (14)) only KEEPS the data: one synced, backed-up setting
/// (`storageKey`) that this build reads, writes back unchanged and carries
/// through Sync and Backup. No screen uses it yet. It ships a release ahead
/// of the picker because a build that does not list the key forgets it — the
/// sync engine reads a record it applied but cannot see again as deleted —
/// so every build that may share a vault must list it before anyone makes a
/// workspace.
///
/// Membership is kept HERE, by top-level group id, not on `HostGroup`: a
/// build without the field would drop it on its next save and upload every
/// group without it. Subgroups follow their top-level group.
nonisolated struct HostWorkspace: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// The abbreviation the user typed for the search field's chip (6.1 (26),
    /// the owner: "ตัวย่อเดี๋ยวลูกค้าใส่เอง"), at most `WorkspacePlan.shortLength`
    /// characters; nil = made from the name (`WorkspacePlan.short`).
    var code: String?
    /// Keys a NEWER build wrote on this workspace that this one does not
    /// know, as JSON object bytes: put back by `WorkspacePlan.save`, so an
    /// edit here does not drop them and sync the loss (`UnknownFields` does
    /// the same for hosts). Never encoded as a key of its own.
    var unknown: Data?
    init(id: UUID = UUID(), name: String, code: String? = nil) { self.id = id; self.name = name; self.code = code }

    /// CaseIterable: `WorkspacePlan.load` keeps every key NOT on this list.
    enum CodingKeys: String, CodingKey, CaseIterable { case id, name, code }
}

nonisolated struct WorkspacePlan: Codable, Equatable, Sendable {
    /// The `BackupManager.settingKeys` entry: bytes of this struct as JSON.
    static let storageKey = "hostWorkspaces"
    /// Where every top-level group is until the user moves it (the owner).
    static let defaultName = "General"
    /// The default workspace's id, the same on every Mac, so two Macs that
    /// each made the plan on their own agree on where unassigned groups are.
    static let defaultID = UUID(uuidString: "00000000-0000-4000-8000-0000000000D1")!

    var workspaces: [HostWorkspace]
    /// Top-level group id → workspace id, both as UUID strings: a String key
    /// encodes as a JSON object (sorted below, so the bytes are stable); a
    /// UUID key would encode as an array in dictionary order — different
    /// bytes each launch, a sync upload each time. A group that is not in
    /// here, or names a workspace that is gone, is in the default one.
    var rootMembership: [String: String]
    /// The plan's own keys a newer build wrote and this one does not know
    /// (JSON object bytes), put back by `save` — see `HostWorkspace.unknown`.
    var unknown: Data?

    /// CaseIterable: `load` keeps every key NOT on this list.
    enum CodingKeys: String, CodingKey, CaseIterable { case workspaces, rootMembership }

    init(workspaces: [HostWorkspace] = [HostWorkspace(id: WorkspacePlan.defaultID, name: WorkspacePlan.defaultName)],
         rootMembership: [String: String] = [:]) {
        self.workspaces = workspaces
        self.rootMembership = rootMembership
    }

    /// The short form the sidebar shows in the search field (6.1 (25), the
    /// owner: at most 4 letters, one fixed width, the full name on hover):
    /// a name of up to 4 characters as it is; several words → their
    /// initials; one long word → its first 3 characters (the owner: "GEN
    /// พอมั้ง General น่ะ"). Upper case.
    /// Derived, never stored — two Macs show the same letters.
    static let shortLength = 4
    static func short(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= shortLength { return String(trimmed.uppercased().prefix(shortLength)) }
        // Spaces and punctuation part words — not "is not a letter": a Thai
        // vowel or tone mark is none, and stays with its consonant.
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation || $0.isSymbol })
        // Upper-casing can lengthen ("ß" → "SS"): cut again after it.
        if words.count > 1 { return String(String(words.prefix(shortLength).compactMap(\.first)).uppercased().prefix(shortLength)) }
        return String(String(trimmed.prefix(3)).uppercased().prefix(shortLength))
    }

    /// A typed abbreviation as it is kept: trimmed, one line, at most
    /// `shortLength` characters; nothing left = nil (made from the name).
    static func cleanCode(_ raw: String?) -> String? {
        let text = (raw ?? "").components(separatedBy: .whitespacesAndNewlines).joined()
        return text.isEmpty ? nil : String(text.prefix(shortLength))
    }

    /// What the chip shows for a workspace: its own abbreviation, else one
    /// made from its name.
    static func label(_ workspace: HostWorkspace) -> String {
        cleanCode(workspace.code) ?? short(workspace.name)
    }

    /// The workspace a top-level group is in.
    func workspace(for root: UUID) -> UUID {
        guard let chosen = rootMembership[root.uuidString].flatMap(UUID.init(uuidString:)),
              workspaces.contains(where: { $0.id == chosen }) else {
            return Self.defaultID
        }
        return chosen
    }

    /// Moves a top-level group to `workspace`; false (nothing changed) when
    /// there is no such workspace. The default one is stored as no entry.
    @discardableResult mutating func assign(root: UUID, to workspace: UUID) -> Bool {
        guard workspaces.contains(where: { $0.id == workspace }) else { return false }
        rootMembership[root.uuidString] = workspace == Self.defaultID ? nil : workspace.uuidString
        return true
    }

    // MARK: Reading and writing the setting

    /// The plan the setting holds. Missing or unreadable → the default plan
    /// (one "General"); a plan without the default workspace gets it back,
    /// first — the place every unassigned group goes must always exist.
    /// Entries naming a group or workspace that is gone are KEPT: the group
    /// may only be missing on this Mac for now (a sync still on its way).
    /// False when there IS a stored plan and this build cannot read it (a
    /// newer build's shape, a damaged value). `load` then shows the default
    /// plan, and nothing may be written over the stored one
    /// (`WorkspaceDefaults.update`) — unreadable is never "empty".
    static func isReadable(_ data: Data?) -> Bool {
        guard let data else { return true }
        return (try? JSONDecoder().decode(WorkspacePlan.self, from: data)) != nil
    }

    static func load(_ data: Data?) -> WorkspacePlan {
        guard let data, var plan = try? JSONDecoder().decode(WorkspacePlan.self, from: data) else { return WorkspacePlan() }
        // What a newer build wrote that this one does not know, kept to be
        // written back (`save`): the plan's own keys, and each workspace's —
        // by position, which is the decoded list's order.
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            plan.unknown = unknownKeys(object, known: Set(CodingKeys.allCases.map(\.stringValue)))
            if let list = object[CodingKeys.workspaces.stringValue] as? [[String: Any]], list.count == plan.workspaces.count {
                let known = Set(HostWorkspace.CodingKeys.allCases.map(\.stringValue))
                for index in list.indices { plan.workspaces[index].unknown = unknownKeys(list[index], known: known) }
            }
        }
        if !plan.workspaces.contains(where: { $0.id == defaultID }) {
            plan.workspaces.insert(HostWorkspace(id: defaultID, name: defaultName), at: 0)
        }
        return plan
    }

    /// Sorted keys, so the same plan is the same bytes on every Mac (the
    /// sync engine compares bytes).
    static func save(_ plan: WorkspacePlan) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(plan) else { return nil }
        // Nothing kept from a newer build: the encoder's bytes as they are.
        guard plan.unknown != nil || plan.workspaces.contains(where: { $0.unknown != nil }),
              var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else { return encoded }
        // A key this build wrote itself always wins.
        for (key, value) in keptObject(plan.unknown) where object[key] == nil { object[key] = value }
        if var list = object[CodingKeys.workspaces.stringValue] as? [[String: Any]], list.count == plan.workspaces.count {
            for index in list.indices {
                for (key, value) in keptObject(plan.workspaces[index].unknown) where list[index][key] == nil { list[index][key] = value }
            }
            object[CodingKeys.workspaces.stringValue] = list
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? encoded
    }

    private static func unknownKeys(_ object: [String: Any], known: Set<String>) -> Data? {
        let extra = object.filter { !known.contains($0.key) }
        guard !extra.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys])
    }

    private static func keptObject(_ data: Data?) -> [String: Any] {
        data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    }
}

/// Editing and what the sidebar shows (round 3): on the main actor, like
/// the `GroupTree` / `HostStore` helpers they use.
@MainActor extension WorkspacePlan {
    // MARK: Editing (round 3)

    /// The cleaned name, or nil when it is empty or another workspace has it
    /// already (case and spacing folded, like group names).
    func usableName(_ raw: String, renaming id: UUID? = nil) -> String? {
        let name = HostStore.cleanGroupName(raw)
        guard !name.isEmpty else { return nil }
        let key = name.lowercased()
        guard !workspaces.contains(where: { $0.id != id && HostStore.cleanGroupName($0.name).lowercased() == key }) else { return nil }
        return name
    }

    /// A new workspace at the end; its id, or nil when the name is unusable.
    @discardableResult mutating func add(named raw: String, code: String? = nil) -> UUID? {
        guard let name = usableName(raw) else { return nil }
        let workspace = HostWorkspace(name: name, code: WorkspacePlan.cleanCode(code))
        workspaces.append(workspace)
        return workspace.id
    }

    /// `code`: the abbreviation typed with it ("" or nil = made from the name).
    @discardableResult mutating func rename(_ id: UUID, to raw: String, code: String? = nil) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), let name = usableName(raw, renaming: id) else { return false }
        workspaces[index].name = name
        workspaces[index].code = WorkspacePlan.cleanCode(code)
        return true
    }

    /// One row of Manage Workspaces… (6.1 (27)): a workspace as the sheet
    /// edits it — its name and the abbreviation, both the user's to type.
    struct Draft: Identifiable, Equatable {
        var id: UUID
        var name: String
        var code: String
    }

    var drafts: [Draft] { workspaces.map { Draft(id: $0.id, name: $0.name, code: $0.code ?? "") } }

    /// `rows` with the row `id` put where `target` is (a drag in Manage
    /// Workspaces…): dragged down it lands after the target, dragged up
    /// before it — the two swap places when they are neighbours.
    static func moved(_ rows: [Draft], _ id: UUID, onto target: UUID) -> [Draft] {
        guard let from = rows.firstIndex(where: { $0.id == id }), let to = rows.firstIndex(where: { $0.id == target }), from != to else { return rows }
        var out = rows
        let row = out.remove(at: from)
        out.insert(row, at: to)
        return out
    }

    /// The plan after Manage Workspaces… is saved: the rows in their order,
    /// names cleaned; a workspace that is no longer a row is gone and its
    /// groups are back in General (no host or group is touched). nil — the
    /// sheet cannot be saved — when a name is empty or there twice, or
    /// General is not a row.
    ///
    /// `opened`: the workspaces the sheet started with. One that is here
    /// now and was NOT among them arrived while the sheet was open (Sync,
    /// another window): the sheet never showed it, so it cannot have removed
    /// it — it stays, after the rows (6.1 (52); it was deleted with its
    /// memberships). nil = the rows are all there is.
    func applying(_ drafts: [Draft], opened: Set<UUID>? = nil) -> WorkspacePlan? {
        var seen = Set<String>()
        var list: [HostWorkspace] = []
        for draft in drafts {
            let name = HostStore.cleanGroupName(draft.name)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            var workspace = HostWorkspace(id: draft.id, name: name, code: WorkspacePlan.cleanCode(draft.code))
            // A newer build's keys on it stay with it (`HostWorkspace.unknown`).
            workspace.unknown = workspaces.first { $0.id == draft.id }?.unknown
            list.append(workspace)
        }
        if let opened {
            let rows = Set(drafts.map(\.id))
            for late in workspaces where !opened.contains(late.id) && !rows.contains(late.id) {
                // Its name may now be a row's: it keeps a free one.
                var name = late.name, number = 2
                while !seen.insert(name.lowercased()).inserted { name = "\(late.name) \(number)"; number += 1 }
                var kept = HostWorkspace(id: late.id, name: name, code: late.code)
                kept.unknown = late.unknown
                list.append(kept)
            }
        }
        guard list.contains(where: { $0.id == Self.defaultID }) else { return nil }
        let kept = Set(list.map(\.id.uuidString))
        var out = WorkspacePlan(workspaces: list, rootMembership: rootMembership.filter { kept.contains($0.value) })
        out.unknown = unknown
        return out
    }

    /// Deletes a workspace: its groups go back to General (no host or group
    /// is touched). General itself cannot go.
    @discardableResult mutating func remove(_ id: UUID) -> Bool {
        guard id != Self.defaultID, workspaces.contains(where: { $0.id == id }) else { return false }
        workspaces.removeAll { $0.id == id }
        rootMembership = rootMembership.filter { $0.value != id.uuidString }
        return true
    }

    // MARK: What the sidebar shows

    /// `selected` as stored per Mac (`selectionKey`): a workspace id, or
    /// `allValue`; anything else (missing, a workspace deleted since) is
    /// General.
    static let selectionKey = "selectedWorkspace"
    static let allValue = "all"

    /// The selection a stored value stands for: nil = All Workspaces.
    func selection(_ stored: String?) -> UUID? {
        if stored == Self.allValue { return nil }
        guard let id = stored.flatMap(UUID.init(uuidString:)), workspaces.contains(where: { $0.id == id }) else { return Self.defaultID }
        return id
    }

    /// The top-level groups the sidebar shows for `selection` (nil = all of
    /// them, no filter). A group whose parent is missing counts as top level,
    /// as everywhere else.
    func visibleRoots(_ selection: UUID?, groups: [HostGroup]) -> Set<UUID>? {
        guard let selection else { return nil }
        return Set(GroupTree.children(of: nil, in: groups).map(\.id).filter { workspace(for: $0) == selection })
    }

    func visibleRoots(_ selection: UUID?, index: GroupTree.Index) -> Set<UUID>? {
        guard let selection else { return nil }
        return Set(index.children(of: nil).map(\.id).filter { workspace(for: $0) == selection })
    }

    /// How deep the tree shown goes (nil = every workspace), the top-level
    /// group counted: 1 = no subgroup anywhere, 0 = no group. `SidebarWidth` reads it.
    func levels(shown: Set<UUID>?, groups: [HostGroup]) -> Int {
        levels(shown: shown, index: GroupTree.Index(groups))
    }

    func levels(shown: Set<UUID>?, index: GroupTree.Index) -> Int {
        let roots = index.children(of: nil).map(\.id).filter { shown?.contains($0) ?? true }
        return roots.map { GroupTree.height(of: $0, in: index) }.max() ?? 0
    }

    /// Every saved host's top-level group, built once (Home filters each
    /// widget's hosts by it — `shows` per host scanned every group's hosts,
    /// which is hosts × hosts on every body pass).
    static func rootsByHost(_ groups: [HostGroup]) -> [UUID: UUID] {
        rootsByHost(GroupTree.Index(groups))
    }

    static func rootsByHost(_ index: GroupTree.Index) -> [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        for group in index.groups {
            let root = index.root(of: group.id)
            for host in group.hosts where out[host.id] == nil { out[host.id] = root }
        }
        return out
    }

    /// Where a drop between the top-level groups SHOWN lands among ALL of
    /// them: the sidebar counts the slot among the groups it shows, the
    /// store among every top-level group. Slot n = before the n-th shown
    /// group; past the last = right after the last shown one (never among
    /// another workspace's groups at the end of the list).
    static func topLevelIndex(shownSlot slot: Int, shown: Set<UUID>?, groups: [HostGroup]) -> Int {
        let tops = GroupTree.children(of: nil, in: groups).map(\.id)
        guard let shown else { return slot }
        let visible = tops.filter(shown.contains)
        if slot < visible.count, slot >= 0, let index = tops.firstIndex(of: visible[slot]) { return index }
        guard let last = visible.last, let index = tops.firstIndex(of: last) else { return tops.count }
        return index + 1
    }

    /// The top-level group a group is under (itself when top level).
    static func root(of id: UUID, in groups: [HostGroup]) -> UUID {
        GroupTree.ancestors(of: id, in: groups).first?.id ?? id
    }

    static func root(of id: UUID, in index: GroupTree.Index) -> UUID { index.root(of: id) }

    /// Whether a Recent entry shows under `visible` roots: one of a saved
    /// host (the same id, or the same connection as `RecentSave.isSaved`
    /// reads it) when any group holding it is under a visible top-level
    /// group; one saved nowhere (a typed connection) always.
    static func shows(_ host: Host, visible: Set<UUID>?, groups: [HostGroup]) -> Bool {
        shows(host, visible: visible, groups: groups) { root(of: $0, in: groups) }
    }

    static func shows(_ host: Host, visible: Set<UUID>?, index: GroupTree.Index) -> Bool {
        shows(host, visible: visible, groups: index.groups, root: index.root(of:))
    }

    private static func shows(_ host: Host, visible: Set<UUID>?, groups: [HostGroup], root: (UUID) -> UUID) -> Bool {
        guard let visible else { return true }
        // A SAVED host is where it is saved: two customers may both have a
        // 192.168.1.1, and the other one's must not show here.
        if let holder = groups.first(where: { $0.hosts.contains { $0.id == host.id } }) {
            return visible.contains(root(holder.id))
        }
        func same(_ saved: Host) -> Bool {
            saved.id == host.id || (saved.kind == host.kind && saved.address == host.address && saved.port == host.port
                && (saved.username.isEmpty || host.username.isEmpty || saved.username == host.username))
        }
        let holders = groups.filter { $0.hosts.contains(where: same) }
        guard !holders.isEmpty else { return true }
        return holders.contains { visible.contains(root($0.id)) }
    }
}

/// The plan as this Mac stores it: `WorkspacePlan.storageKey` in the user
/// defaults (synced and backed up), read and written whole.
@MainActor enum WorkspaceDefaults {
    /// Top-level groups made since `before` go in the workspace being shown
    /// (6.1 (29)): a group made by Add Hosts or Quick Connect while "Lab" is
    /// chosen used to land in General and vanish from the sidebar the moment
    /// it was made.
    static func adoptNewRoots(since before: Set<UUID>, groups: [HostGroup], _ defaults: UserDefaults = .standard) {
        let made = GroupTree.children(of: nil, in: groups).map(\.id).filter { !before.contains($0) }
        guard !made.isEmpty else { return }
        let current = plan(defaults)
        // All Workspaces: every group shows, nothing to file. General: a
        // group with no entry is General's — but one that was a root before
        // may still have its old entry (entries are kept), and would jump
        // back to that workspace; assigning General clears it.
        guard let shown = current.selection(defaults.string(forKey: WorkspacePlan.selectionKey)) else { return }
        update(defaults) { plan in
            let was = plan
            for id in made { plan.assign(root: id, to: shown) }
            return plan != was
        }
    }

    static func plan(_ defaults: UserDefaults = .standard) -> WorkspacePlan {
        WorkspacePlan.load(defaults.data(forKey: WorkspacePlan.storageKey))
    }

    /// Applies `change` and stores the result when it says something changed.
    /// (Refused — false, nothing stored — while the stored plan is one this
    /// build cannot read: `WorkspacePlan.isReadable`.)
    @discardableResult
    static func update(_ defaults: UserDefaults = .standard, _ change: (inout WorkspacePlan) -> Bool) -> Bool {
        guard WorkspacePlan.isReadable(defaults.data(forKey: WorkspacePlan.storageKey)) else { return false }
        var plan = plan(defaults)
        guard change(&plan), let data = WorkspacePlan.save(plan) else { return false }
        defaults.set(data, forKey: WorkspacePlan.storageKey)
        return true
    }
}
