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
