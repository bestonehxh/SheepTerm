import Foundation

/// When a record was last changed and on which device. Ordered: later wins,
/// and the device name breaks an exact tie so every Mac picks the same one.
public struct SyncStamp: Codable, Equatable, Hashable, Comparable, Sendable {
    /// Milliseconds since 1970.
    public var modified: Int64
    public var device: String

    public init(modified: Int64, device: String) {
        self.modified = modified
        self.device = device
    }

    public static func < (a: SyncStamp, b: SyncStamp) -> Bool {
        a.modified != b.modified ? a.modified < b.modified : a.device < b.device
    }
}

/// One unit of sync. Opaque to SheepSync: the app decides what a record is
/// (a whole file, one password, one setting) and what its bytes mean.
public struct SyncRecord: Codable, Equatable, Sendable {
    public var id: String
    public var stamp: SyncStamp
    /// A tombstone: the record was deleted at `stamp`. Kept so a Mac that
    /// still has the record deletes it instead of uploading it again.
    public var deleted: Bool
    public var payload: Data?

    public init(id: String, stamp: SyncStamp, deleted: Bool = false, payload: Data?) {
        self.id = id
        self.stamp = stamp
        self.deleted = deleted
        self.payload = deleted ? nil : payload
    }
}

/// The plaintext of the cloud data file (sealed before it leaves the Mac).
public struct SyncDocument: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    public var format: Int
    public var records: [SyncRecord]

    public init(records: [SyncRecord]) {
        format = Self.currentFormat
        self.records = records.sorted { $0.id < $1.id }
    }

    public var byID: [String: SyncRecord] {
        Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, b in max(a.stamp, b.stamp) == a.stamp ? a : b })
    }
}

/// What this Mac remembers about a record as of the last sync: enough to
/// tell "the user changed it since" without keeping the content.
public struct ShadowEntry: Codable, Equatable, Sendable {
    public var stamp: SyncStamp
    public var deleted: Bool
    /// `VaultSealer.digest` of the payload; nil for a tombstone.
    public var digest: String?

    public init(stamp: SyncStamp, deleted: Bool, digest: String?) {
        self.stamp = stamp
        self.deleted = deleted
        self.digest = digest
    }
}

/// The app's records as they are right now.
public struct SyncSnapshot: Sendable {
    public var records: [String: Data]
    /// Records that exist but whose value could not be read this time (a
    /// locked Keychain item, a file that failed to load). Absence from
    /// `records` would otherwise read as "the user deleted it" and that
    /// deletion would be pushed to every other Mac. An unavailable record is
    /// never tombstoned and never uploaded; the cloud's copy may still be
    /// applied over it.
    public var unavailable: Set<String>
    /// Every id starting with one of these counts as unavailable — for a
    /// family of records the app cannot enumerate right now (passwords,
    /// while the list that names them failed to load).
    public var unavailablePrefixes: [String]
    /// Unavailable records whose local copy is known to be BAD (a file the
    /// app quarantined at launch): the cloud's copy is applied even when it
    /// is not newer than the last sync — it is how such a Mac recovers.
    public var wantCloudCopy: Set<String>
    /// The same for whole families of records (every record of a file the
    /// app quarantined).
    public var wantCloudPrefixes: [String]

    public init(records: [String: Data], unavailable: Set<String> = [], unavailablePrefixes: [String] = [],
                wantCloudCopy: Set<String> = [], wantCloudPrefixes: [String] = []) {
        self.records = records
        self.unavailable = unavailable.union(wantCloudCopy)
        self.unavailablePrefixes = unavailablePrefixes + wantCloudPrefixes
        self.wantCloudCopy = wantCloudCopy
        self.wantCloudPrefixes = wantCloudPrefixes
    }

    public func isUnavailable(_ id: String) -> Bool {
        unavailable.contains(id) || unavailablePrefixes.contains { id.hasPrefix($0) }
    }

    public func wantsCloudCopy(_ id: String) -> Bool {
        wantCloudCopy.contains(id) || wantCloudPrefixes.contains { id.hasPrefix($0) }
    }
}

/// The result of one three-way merge (this Mac now, this Mac at the last
/// sync, the cloud). Pure data: the engine uploads, applies and saves.
public struct SyncPlan: Equatable, Sendable {
    /// What the cloud should hold after this sync.
    public var merged: [String: SyncRecord]
    /// True when `merged` differs from what the cloud holds now.
    public var needsUpload: Bool
    /// Changes the app must make locally: a value to write, or nil = delete.
    public var apply: [String: Data?]
    /// The shadow to save once the upload (if any) and every apply landed.
    public var shadow: [String: ShadowEntry]
}

public enum SyncMerge {
    /// How long a deletion is remembered. A Mac that has not synced for
    /// longer than this can bring a deleted record back — the price of not
    /// keeping every deletion forever.
    public static let tombstoneLifetimeMs: Int64 = 180 * 24 * 3600 * 1000

    /// - Parameters:
    ///   - shadow: nil on a device's FIRST sync with this vault. Then every
    ///     record the cloud already has is taken from the cloud (the new Mac
    ///     joins the vault, it does not overwrite it with its defaults), and
    ///     only records the cloud lacks are uploaded.
    ///   - digest: `VaultSealer.digest`, injected so this stays pure.
    public static func plan(snapshot: SyncSnapshot,
                            shadow: [String: ShadowEntry]?,
                            remote: [String: SyncRecord],
                            now: Int64,
                            device: String,
                            joining: Set<String> = [],
                            digest: (String, Data) -> String) -> SyncPlan {
        let firstJoin = shadow == nil
        let shadow = shadow ?? [:]
        // A local change always sorts after what this Mac last synced for
        // that record — even an edit made in the same millisecond as the
        // sync, which would otherwise tie with the cloud's copy and lose.
        func changed(_ id: String) -> SyncStamp {
            SyncStamp(modified: max(now, (shadow[id]?.stamp.modified ?? 0) + 1), device: device)
        }

        // This Mac's view of every record, stamped.
        var local: [String: SyncRecord] = [:]
        // Records we know exist locally but could not read: their last
        // synced stamp, so a newer cloud copy can still come down.
        var unknown: [String: SyncStamp] = [:]

        for (id, data) in snapshot.records {
            if let entry = shadow[id], !entry.deleted, entry.digest == digest(id, data) {
                local[id] = SyncRecord(id: id, stamp: entry.stamp, payload: data)
            } else if firstJoin || joining.contains(id), remote[id] != nil {
                // Loses to any cloud stamp: joining takes the vault's copy.
                local[id] = SyncRecord(id: id, stamp: SyncStamp(modified: 0, device: device), payload: data)
            } else {
                local[id] = SyncRecord(id: id, stamp: changed(id), payload: data)
            }
        }
        for (id, entry) in shadow where snapshot.records[id] == nil {
            if entry.deleted {
                local[id] = SyncRecord(id: id, stamp: entry.stamp, deleted: true, payload: nil)
            } else if snapshot.isUnavailable(id) {
                unknown[id] = entry.stamp
            } else {
                local[id] = SyncRecord(id: id, stamp: changed(id), deleted: true, payload: nil)
            }
        }

        var merged: [String: SyncRecord] = [:]
        var apply: [String: Data?] = [:]
        var newShadow: [String: ShadowEntry] = [:]
        let oldestTombstone = now - tombstoneLifetimeMs

        for id in Set(local.keys).union(remote.keys).union(unknown.keys) {
            let mine = local[id]
            let theirs = remote[id]
            let winner: SyncRecord
            switch (mine, theirs) {
            case let (m?, t?): winner = t.stamp < m.stamp ? m : t
            case let (m?, nil): winner = m
            case let (nil, t?): winner = t
            case (nil, nil):
                // Unreadable here and not in the cloud: nothing to do, keep
                // what we remembered.
                if let entry = shadow[id] { newShadow[id] = entry }
                continue
            }

            if winner.deleted, winner.stamp.modified < oldestTombstone {
                // Expired: forget the deletion everywhere. A live local copy
                // (cannot normally exist next to an old tombstone) is left be.
                continue
            }
            merged[id] = winner

            // Unreadable here and the cloud has nothing newer than what this
            // Mac last synced: there is nothing to bring down (re-applying it
            // every sync would only overwrite whatever is really there).
            if mine == nil, let known = unknown[id], let t = theirs, t.stamp == known,
               !snapshot.wantsCloudCopy(id) {
                newShadow[id] = ShadowEntry(stamp: t.stamp, deleted: t.deleted,
                                            digest: t.payload.map { digest(id, $0) })
                continue
            }
            if winner != mine {
                // The cloud's version wins (or the record is unknown here):
                // make this Mac match it.
                let current = snapshot.records[id]
                if winner.deleted {
                    // Also when unreadable here: the app must get the chance
                    // to delete it. (If it cannot, the engine keeps the old
                    // shadow, so the record is not later taken for a fresh
                    // re-creation and uploaded back.)
                    if current != nil || snapshot.isUnavailable(id) { apply[id] = .some(nil) }
                } else if let payload = winner.payload, current != payload {
                    apply[id] = .some(payload)
                }
            }
            newShadow[id] = ShadowEntry(
                stamp: winner.stamp, deleted: winner.deleted,
                digest: winner.payload.map { digest(id, $0) })
        }

        return SyncPlan(merged: merged, needsUpload: merged != remote, apply: apply, shadow: newShadow)
    }
}
