import Foundation

/// Fields a NEWER build wrote that this build does not know (6.1 (14), the
/// owner: an older version must never break a newer one's data).
///
/// `Host` and `HostGroup` decode only their own `CodingKeys`, so a save used
/// to drop any field added later — and sync then uploaded every group
/// without it, from every older Mac. Now the store keeps, per group id and
/// per host id, the keys of the file it read that are NOT on this build's
/// list, and lays them back over what it writes. Only unknown keys are
/// kept: a known optional field this build cleared (written as no key) is
/// never brought back. Pure JSON in, JSON out — the harness checks it
/// without the app's types.
nonisolated enum UnknownFields {
    /// Unknown keys as JSON object bytes, by group id and by host id.
    struct Extras: Equatable, Sendable {
        var groups: [String: Data] = [:]
        var hosts: [String: Data] = [:]
        var isEmpty: Bool { groups.isEmpty && hosts.isEmpty }

        /// `other` laid over this one (a newer read of the same file wins).
        func merging(_ other: Extras) -> Extras {
            Extras(groups: groups.merging(other.groups) { $1 }, hosts: hosts.merging(other.hosts) { $1 })
        }
    }

    static var groupKeys: Set<String> { Set(HostGroup.CodingKeys.allCases.map(\.stringValue)) }
    static var hostKeys: Set<String> { Set(Host.CodingKeys.allCases.map(\.stringValue)) }

    /// The unknown keys of a hosts.json (`[HostGroup]` as JSON). Anything
    /// unreadable → nothing kept (the decoder decides what loads).
    static func capture(_ data: Data, groupKeys: Set<String> = groupKeys, hostKeys: Set<String> = hostKeys) -> Extras {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return Extras() }
        var extras = Extras()
        for group in list {
            guard let id = group["id"] as? String else { continue }
            if let bytes = unknown(in: group, known: groupKeys) { extras.groups[id] = bytes }
            for host in group["hosts"] as? [[String: Any]] ?? [] {
                guard let hostID = host["id"] as? String, let bytes = unknown(in: host, known: hostKeys) else { continue }
                extras.hosts[hostID] = bytes
            }
        }
        return extras
    }

    /// `encoded` (this build's hosts.json) with the kept keys put back on
    /// the group / host of the same id. A key this build wrote itself always
    /// wins. Unchanged bytes when there is nothing to put back.
    static func restore(into encoded: Data, _ extras: Extras, pretty: Bool = true) -> Data {
        guard !extras.isEmpty,
              var list = (try? JSONSerialization.jsonObject(with: encoded)) as? [[String: Any]] else { return encoded }
        var touched = false
        for index in list.indices {
            if let id = list[index]["id"] as? String, let keep = object(extras.groups[id]) {
                for (key, value) in keep where list[index][key] == nil { list[index][key] = value; touched = true }
            }
            guard var hosts = list[index]["hosts"] as? [[String: Any]] else { continue }
            var hostsTouched = false
            for h in hosts.indices {
                guard let id = hosts[h]["id"] as? String, let keep = object(extras.hosts[id]) else { continue }
                for (key, value) in keep where hosts[h][key] == nil { hosts[h][key] = value; hostsTouched = true }
            }
            if hostsTouched { list[index]["hosts"] = hosts; touched = true }
        }
        guard touched else { return encoded }
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: list, options: options)) ?? encoded
    }

    // MARK: Flat lists (credentials.json, snippets.json)

    /// The unknown keys of each entry of a JSON list, by its `id`.
    static func captureList(_ data: Data, known: Set<String>) -> [String: Data] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        var kept: [String: Data] = [:]
        for entry in list {
            guard let id = entry["id"] as? String, let bytes = unknown(in: entry, known: known) else { continue }
            kept[id] = bytes
        }
        return kept
    }

    /// `encoded` with the kept keys back on the entry of the same id (this
    /// build's own keys win); unchanged bytes when nothing is put back.
    static func restoreList(into encoded: Data, _ kept: [String: Data], pretty: Bool = true) -> Data {
        guard !kept.isEmpty, var list = (try? JSONSerialization.jsonObject(with: encoded)) as? [[String: Any]] else { return encoded }
        var touched = false
        for index in list.indices {
            guard let id = list[index]["id"] as? String, let keep = object(kept[id]) else { continue }
            for (key, value) in keep where list[index][key] == nil { list[index][key] = value; touched = true }
        }
        guard touched else { return encoded }
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: list, options: options)) ?? encoded
    }

    static var credentialKeys: Set<String> { Set(Credential.CodingKeys.allCases.map(\.stringValue)) }
    static var snippetKeys: Set<String> { Set(Snippet.CodingKeys.allCases.map(\.stringValue)) }

    private static func unknown(in record: [String: Any], known: Set<String>) -> Data? {
        // Never a key that reads like a secret: hosts.json is synced and in
        // backups, and before this file a hand-made "password" field was
        // dropped by the decode — it must not be carried now.
        let extra = record.filter { !known.contains($0.key) && !looksSecret($0.key) }
        guard !extra.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys])
    }

    static func looksSecret(_ key: String) -> Bool {
        let name = key.lowercased()
        return ["password", "passwd", "passphrase", "secret", "token", "privatekey", "private_key", "apikey", "api_key"].contains { name.contains($0) }
    }

    private static func object(_ data: Data?) -> [String: Any]? {
        data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
}
