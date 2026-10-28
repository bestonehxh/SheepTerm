import Foundation

/// The rules of SheepTerm's Sync that decide what may be read as "deleted"
/// and what may be written — pure, so the harness checks them
/// (`Tests/tests/SyncPolicyTests.swift`). `SheepTermSync` only feeds them.
nonisolated enum SyncPolicy {
    static let passwordPrefix = "password:"

    struct PasswordRecords: Equatable {
        var records: [String: Data] = [:]
        var unavailable: Set<String> = []
        var unavailablePrefixes: [String] = []
    }

    /// One record per credential that has a password here. A credential with
    /// no password (another Mac's, not unlocked yet; a locked Keychain) is
    /// UNKNOWN, not deleted. And when the list that names the passwords is
    /// itself not trustworthy (failed to load, file unreadable), no password
    /// may be read as deleted at all — an empty list would otherwise wipe
    /// every password on every other Mac.
    static func passwordRecords(listTrusted: Bool, listFileReadable: Bool, credentialIDs: [UUID],
                                password: (UUID) -> String?) -> PasswordRecords {
        var out = PasswordRecords()
        guard listTrusted, listFileReadable else {
            out.unavailablePrefixes = [passwordPrefix]
            return out
        }
        for id in credentialIDs {
            let key = passwordPrefix + id.uuidString
            if let value = password(id) { out.records[key] = Data(value.utf8) } else { out.unavailable.insert(key) }
        }
        return out
    }

    /// A password from the cloud is written only for a credential the
    /// (trusted) list names — otherwise it is an orphan nothing can reach.
    static func mayWritePassword(_ id: UUID, listTrusted: Bool, known: Set<UUID>) -> Bool {
        listTrusted && known.contains(id)
    }

    enum PasswordAction: Equatable {
        case write, delete
        /// Done with nothing to do: an orphan (its credential is not in the
        /// list), or a deletion of a password whose credential this Mac's
        /// list still names — keep it; the next sync puts it back.
        case skip
        /// Not now: the list that decides it did not arrive or is not
        /// trustworthy. Counted as failed, so it is tried again.
        case retry
    }

    /// What to do with one cloud password change, AFTER the cloud's
    /// credentials.json (if any) has been applied.
    static func passwordAction(_ id: UUID, isDelete: Bool, listTrusted: Bool, known: Set<UUID>,
                               listFailedThisRound: Bool) -> PasswordAction {
        if listFailedThisRound || !listTrusted { return .retry }
        if isDelete { return known.contains(id) ? .skip : .delete }
        return known.contains(id) ? .write : .skip
    }

    /// The client id Sync may use: none when the build has no secret (a
    /// public clone without Secrets.xcconfig, or the unexpanded build
    /// variable) — a Desktop client cannot finish a sign-in without it.
    static func usableClientID(id: String, secret: String) -> String {
        let secret = secret.trimmingCharacters(in: .whitespaces)
        return secret.isEmpty || secret.hasPrefix("$(") ? "" : id
    }

    enum FamilyRead: Equatable {
        /// Split the file into records.
        case records
        /// Leave every record of the family alone (never read as deleted).
        case unavailable
        /// This Mac's copy is not the user's data: bring ALL of it down.
        case wantCloud
    }

    /// How one file enters a sync. A missing file is only "take the whole
    /// family from the cloud" when the store is empty too — a file that
    /// vanished under a store still holding entries is left alone.
    static func familyRead(quarantined: Bool, fileExists: Bool, storeEmpty: Bool,
                           readableAndSaved: Bool) -> FamilyRead {
        if quarantined { return .wantCloud }
        if !fileExists { return storeEmpty ? .wantCloud : .unavailable }
        return readableAndSaved ? .records : .unavailable
    }

    /// Whether cloud changes may be laid over an EMPTY base (no readable
    /// file). Only when the snapshot asked for the whole family — otherwise
    /// the file would end up holding just the latest changes and the next
    /// sync would read every other entry as deleted.
    static func mayApplyWithoutFile(quarantined: Bool, fileExists: Bool, storeEmpty: Bool) -> Bool {
        quarantined || (!fileExists && storeEmpty)
    }

    /// What the cloud's changes are laid over. Normally the file as it is.
    /// For a QUARANTINED family too, when a readable file exists: the corrupt
    /// original was set aside, so that file holds only what the user made
    /// since — it must survive the recovery (cloud wins per id; entries only
    /// here stay and are uploaded once the quarantine clears).
    static func applyBase(current: Data?, decompose: (Data) throws -> [String: Data]) throws -> [String: Data] {
        guard let current else { return [:] }
        return try decompose(current)
    }

    /// The store's in-memory value is what the file holds: compared after
    /// decoding both sides the same way, so a file from an older build
    /// (other formatting, fields added since) still matches, and a store
    /// holding a change it could not save does not.
    static func sameContent<T: Codable>(_ type: T.Type, disk: Data, memory: T,
                                        decode: (Data) throws -> T = { try JSONDecoder().decode(T.self, from: $0) }) -> Bool {
        guard let fromDisk = try? decode(disk) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let a = try? encoder.encode(fromDisk), let b = try? encoder.encode(memory) else { return false }
        return a == b
    }

    // MARK: Mixed builds — nested groups (6.0 (12)) beside a build with sections

    /// A group record written by a build before nested groups (Mac 6.0 (11),
    /// Windows 0.1 (21)) has NO `parentID` key: "I don't know", not "top
    /// level". Laid over this copy's hosts.json and re-encoded by the restore
    /// hygiene on the way to disk, the gap would land as `"parentID": null` —
    /// a deliberate top level — and the load pass could no longer tell the
    /// two apart: one rename on the older build flattened the subgroup here.
    /// So the parents this copy holds (`parents`: group id → parent id, as
    /// the records spell them) are put into the composed file BEFORE it is
    /// checked and written. Only a gap is filled, never a value or a null,
    /// and only with a parent that is in the file (`GroupTree.repair` would
    /// take any other out again).
    static func fillKnownParents(composed data: Data, parents: [String: String]) -> Data {
        guard !parents.isEmpty,
              var list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return data }
        let ids = Set(list.compactMap { $0["id"] as? String })
        var changed = false
        for index in list.indices where list[index]["parentID"] == nil {
            guard let id = list[index]["id"] as? String, let parent = parents[id],
                  parent != id, ids.contains(parent) else { continue }
            list[index]["parentID"] = parent
            changed = true
        }
        guard changed, let filled = try? SyncRecordCodec.canonical(list) else { return data }
        return filled
    }

    /// Whether a record this copy holds says the same as the cloud's copy,
    /// allowing for the two shapes one group has across builds: a build
    /// before nested groups always writes `"sections": []` and never
    /// `parentID`; this build omits an empty list and always writes the
    /// parent (`null` at the top level). A cloud record WITHOUT the key does
    /// not know the parent, so the parent this copy holds is not a
    /// difference either — as long as it is still the parent this copy gave
    /// the record when it applied that cloud copy (`parentAtApply`: the
    /// group id, nil = top level). A different parent is a MOVE made here
    /// since, and a move is a real change: taken for shape, it was never
    /// uploaded and the next old-build copy flattened it. Anything else that
    /// differs — a name, the host order, a section list with names in it —
    /// is a real change too.
    static func sameRecordAcrossBuilds(local: Data, cloud: Data, parentAtApply: String?) -> Bool {
        guard local != cloud else { return true }
        guard var mine = (try? JSONSerialization.jsonObject(with: local)) as? [String: Any],
              var theirs = (try? JSONSerialization.jsonObject(with: cloud)) as? [String: Any] else { return false }
        if (mine["sections"] as? [Any])?.isEmpty == true { mine["sections"] = nil }
        if (theirs["sections"] as? [Any])?.isEmpty == true { theirs["sections"] = nil }
        if theirs["parentID"] == nil {
            guard (mine["parentID"] as? String) == parentAtApply else { return false }
            mine["parentID"] = nil
        }
        guard let a = try? SyncRecordCodec.canonical(mine), let b = try? SyncRecordCodec.canonical(theirs) else { return false }
        return a == b
    }

    /// The snapshot's records with the CLOUD's bytes in place of this copy's
    /// for every record that says the same across builds (`lastApplied`: the
    /// cloud's bytes as `syncApply` last laid them over the file, by id).
    ///
    /// The engine uploads a record whose bytes differ from what it last
    /// synced. A record from an older build is re-encoded into this build's
    /// shape on the way to disk, so it always differed — and the older build,
    /// given this shape, re-encodes it back into its own and uploads THAT:
    /// two builds on one vault traded the same group back and forth on every
    /// sync, forever (one Drive write per round per machine). Handing the
    /// engine the cloud's own bytes for a record that only differs in shape
    /// ends it on this side; a real edit here — a move included: the parent
    /// is compared with `parentAtApply` (record id → the group id this copy
    /// gave it when that cloud copy was applied; absent = top level) —
    /// differs in content and is uploaded as before.
    static func presentAcrossBuilds(_ records: inout [String: Data], lastApplied: [String: Data],
                                    parentAtApply: [String: String]) {
        for (id, cloud) in lastApplied {
            guard let local = records[id], local != cloud,
                  sameRecordAcrossBuilds(local: local, cloud: cloud, parentAtApply: parentAtApply[id]) else { continue }
            records[id] = cloud
        }
    }

    /// The parent each group in a hosts.json file has, keyed by RECORD id
    /// (`group:<id>` → parent group id; a top-level group is absent): what
    /// `presentAcrossBuilds` compares a later local copy with. Read from the
    /// file as it is written after an apply, so a parent `fillKnownParents`
    /// could not keep (not in the file) counts as the top level it became.
    static func recordParents(inFile data: Data) -> [String: String] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        var parents: [String: String] = [:]
        for group in list {
            guard let id = group["id"] as? String, let parent = group["parentID"] as? String else { continue }
            parents["\(SyncRecordCodec.hosts.item)\(id)"] = parent
        }
        return parents
    }
}

/// Sync per RECORD, not per file (5.0 (7)): two Macs that change different
/// hosts, credentials or snippets before syncing keep both changes. Works on
/// the JSON of the three files, so every field — present or added later —
/// travels without this code knowing it, and the harness checks it without
/// the app's types.
///
///     hosts.json        hosts:order (group ids), group:<id> (the group minus
///                       its hosts, plus "hostOrder"), host:<id> (the host
///                       plus "groupID")
///     credentials.json  credentials:order, credential:<id>
///     snippets.json     snippets:order, snippet:<id>
///
/// Record ids are part of the vault format — never rename one.
nonisolated enum SyncRecordCodec {
    enum CodecError: Error, Equatable {
        case notAList
        case missingID
        /// Two entries share an id: splitting would lose one, so the file is
        /// not synced at all until it is fixed.
        case duplicateID(String)
    }

    struct Family: Equatable {
        let file: String
        let order: String
        let item: String
        /// hosts.json only: the second level.
        let child: String?

        var prefixes: [String] { [order] + [item, child].compactMap { $0 } }
        func owns(_ id: String) -> Bool { id == order || id.hasPrefix(item) || child.map { id.hasPrefix($0) } == true }
    }

    static let hosts = Family(file: "hosts.json", order: "hosts:order", item: "group:", child: "host:")
    static let credentials = Family(file: "credentials.json", order: "credentials:order", item: "credential:", child: nil)
    static let snippets = Family(file: "snippets.json", order: "snippets:order", item: "snippet:", child: nil)
    static let families = [hosts, credentials, snippets]

    /// Where hosts go whose group was deleted on another Mac while they were
    /// added: the same id on every Mac, so they meet in ONE group.
    static let recoveredGroupID = "5EEB5EEB-0000-4000-8000-5EEB5EEB0000"

    static func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func objects(_ data: Data) throws -> [[String: Any]] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CodecError.notAList
        }
        return list
    }

    private static func id(of object: [String: Any]) throws -> String {
        guard let id = object["id"] as? String, !id.isEmpty else { throw CodecError.missingID }
        return id
    }

    static func decompose(_ data: Data, as family: Family) throws -> [String: Data] {
        var out: [String: Data] = [:]
        var order: [String] = []
        for var object in try objects(data) {
            let itemID = try id(of: object)
            guard out[family.item + itemID] == nil else { throw CodecError.duplicateID(itemID) }
            order.append(itemID)
            if let child = family.child {
                let hosts = object["hosts"] as? [[String: Any]] ?? []
                var hostOrder: [String] = []
                for var host in hosts {
                    let hostID = try id(of: host)
                    guard out[child + hostID] == nil else { throw CodecError.duplicateID(hostID) }
                    hostOrder.append(hostID)
                    host["groupID"] = itemID
                    out[child + hostID] = try canonical(host)
                }
                object["hosts"] = nil
                object["hostOrder"] = hostOrder
            }
            out[family.item + itemID] = try canonical(object)
        }
        out[family.order] = try canonical(order)
        return out
    }

    /// The file's JSON from records. Order: the order record, then anything
    /// it does not name, by id — the same on every Mac.
    static func compose(_ records: [String: Data], as family: Family) throws -> Data {
        func load(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        func ordered(_ ids: [String], by hint: [String]) -> [String] {
            let present = Set(ids)
            var seen = Set<String>()
            let first = hint.filter { present.contains($0) && seen.insert($0).inserted }
            return first + ids.filter { !seen.contains($0) }.sorted()
        }
        var items: [String: [String: Any]] = [:]
        for (key, data) in records where key.hasPrefix(family.item) {
            if let object = load(data) { items[String(key.dropFirst(family.item.count))] = object }
        }
        var children: [String: [String: [String: Any]]] = [:]   // group id → host id → host
        if let child = family.child {
            for (key, data) in records where key.hasPrefix(child) {
                guard var host = load(data) else { continue }
                var group = host["groupID"] as? String ?? recoveredGroupID
                if items[group] == nil { group = recoveredGroupID }
                host["groupID"] = nil
                children[group, default: [:]][String(key.dropFirst(child.count))] = host
            }
            if children[recoveredGroupID] != nil, items[recoveredGroupID] == nil {
                items[recoveredGroupID] = ["id": recoveredGroupID, "name": "Recovered", "hostOrder": [String]()]
            }
        }
        let hint = records[family.order].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        var list: [[String: Any]] = []
        for itemID in ordered(Array(items.keys), by: hint) {
            var object = items[itemID]!
            if family.child != nil {
                let hostHint = object["hostOrder"] as? [String] ?? []
                let hosts = children[itemID] ?? [:]
                object["hosts"] = ordered(Array(hosts.keys), by: hostHint).map { hosts[$0]! }
                object["hostOrder"] = nil
            }
            list.append(object)
        }
        return try canonical(list)
    }
}

/// Ranges the app already enforces locally, applied to a value that arrived
/// from the cloud (or a restored backup) so a hand-edited or newer-version
/// record cannot park a setting outside what the UI can reach. Out of range
/// is CLAMPED, not rejected (same as the Windows port's SyncSettingsMap).
/// The literals mirror their owners: `Theme.fontSizeRange`,
/// `HostStore.maxRecents`, the sidebar drag clamp in ContentView, the
/// `scrollbackLines` clamp in SessionTerminalHost, `pasteDelayChoices`.
nonisolated enum SettingBounds {
    static let safePasteDelays = SafePastePlan.delayChoices

    /// The bounded number for `key`, or nil when the key has no numeric
    /// bound (use the value as it is) — a non-finite number gives nil too,
    /// reported through `isUsable`.
    static func clamp(key: String, _ value: Double) -> Double? {
        switch key {
        case "terminalFontSize": return min(max(value.rounded(), 9), 24)
        case "recentsShown": return min(max(value.rounded(), 1), 20)
        case "sidebarWidth": return min(max(value, 200), 320)
        case "scrollbackLines": return min(max(value.rounded(), 500), 200_000)
        case "safePasteDelayMilliseconds":
            return Double(safePasteDelays.min { abs(Double($0) - value) < abs(Double($1) - value) } ?? SafePastePlan.delayDefault)
        default: return nil
        }
    }

    /// False for NaN / infinity on a bounded key: nothing sensible to clamp to.
    static func isUsable(key: String, _ value: Double) -> Bool {
        value.isFinite || clamp(key: key, 0) == nil
    }
}
