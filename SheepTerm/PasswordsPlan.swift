import Foundation

// The Passwords page (5.0 (24), Safari's): what the list shows for a search,
// how the web sites field reads, and how long one Touch ID answer lasts —
// pure, so the harness covers it. The page is `CredentialsSheet`.

nonisolated enum PasswordsPlan {
    /// Rows for `query`: every word must appear in the name, the user or a
    /// web site (case-insensitive); sorted by name, then user. An empty
    /// query lists everything.
    static func rows(_ credentials: [Credential], query: String) -> [Credential] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = credentials.filter { credential in
            let haystack = ([credential.name, credential.username] + (credential.websites ?? [])).joined(separator: "\n").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return matching.sorted { ($0.name.localizedLowercase, $0.username) < ($1.name.localizedLowercase, $1.username) }
    }

    /// A site as the list shows it: "192.168.225.39" for https on 443,
    /// "http://10.0.0.1" for plain http, the port only when it is not the
    /// scheme's own.
    static func display(_ site: String) -> String {
        guard let origin = WebAddress.origin(of: site) else { return site }
        let host = origin.host.contains(":") ? "[\(origin.host)]" : origin.host
        let defaultPort = origin.scheme == "https" ? 443 : 80
        let port = origin.port == defaultPort ? "" : ":\(origin.port)"
        return (origin.scheme == "https" ? "" : "\(origin.scheme)://") + host + port
    }

    /// The edit form's web sites field (one per line, or comma-separated):
    /// what is stored. A bare host or IP means https, as typed in Safari.
    static func sites(fromField text: String) -> [String] {
        let parts = text.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
        return WebLoginKey.cleanedSites(parts.filter { !$0.isEmpty }.map { part in
            if part.contains("://") { return part }
            // A bare IPv6 address (two or more colons, no brackets) needs them in a URL.
            let bare = part.filter { $0 == ":" }.count >= 2 && !part.hasPrefix("[")
            return "https://" + (bare ? "[\(part)]" : part)
        })
    }

    /// The field's text for a stored list.
    static func field(for sites: [String]?) -> String {
        (sites ?? []).map(display).joined(separator: "\n")
    }

    /// One Touch ID / login password answer opens the passwords for this long.
    static let unlockSeconds: TimeInterval = 300

    static func isUnlocked(until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    /// The rows still showing their password: none once the window closes
    /// (a shown password does not outlive the Touch ID answer that showed it).
    static func revealed(_ ids: Set<UUID>, until: Date?, now: Date) -> Set<UUID> {
        isUnlocked(until: until, now: now) ? ids : []
    }

    enum KeyEditOutcome: Equatable {
        case saved
        /// The credential is not there any more (deleted here or by Sync):
        /// nothing was written.
        case gone
        /// The vault refused the key, or the old key could not be read to
        /// undo with (a read the user denied, or a vault that could not
        /// answer): nothing was changed.
        case keyRefused
        /// credentials.json refused the change; the vault was put back as it
        /// was (`restored` false only if the vault then refused that too).
        case updateFailed(restored: Bool)
    }

    /// Edit credential ▸ Save with a key change (`change`: nil = none,
    /// `.some(nil)` = remove the key, else the new key). The key goes into
    /// the vault BEFORE the credential names it, so a credential never points
    /// at a missing key — and when the credential's own write then fails, the
    /// old key is put back, so the vault and credentials.json never disagree
    /// (review 6.1 (62): the new key stayed, or the old one stayed deleted).
    /// `hadKey` = the credential names a key now; `current` reads it;
    /// `absent` = the vault positively says there is no such entry (asked
    /// only after `current` came back empty). A credential whose key is not
    /// in the vault at all — a Backup restored from another Mac — has nothing
    /// to put back, so it is repaired like a credential without a key rather
    /// than refused forever (review 6.1 (62)).
    static func applyKeyEdit<Key>(_ change: Key??, exists: Bool, hadKey: Bool, current: () -> Key?,
                                  absent: () -> Bool,
                                  set: (Key) -> Bool, remove: () -> Bool, update: () -> Bool) -> KeyEditOutcome {
        guard exists else { return .gone }
        guard let change else { return update() ? .saved : .updateFailed(restored: true) }
        var previous: Key?
        if hadKey {
            if let old = current() {
                previous = old
            } else if !absent() {
                // A key we cannot read is a key we cannot put back.
                return .keyRefused
            }
        }
        let wrote: Bool
        // Nothing stored = nothing to delete: a removal only updates the metadata.
        if let new = change { wrote = set(new) } else { wrote = previous != nil ? remove() : true }
        guard wrote else { return .keyRefused }
        guard update() else {
            let restored = previous.map(set) ?? (change == nil ? true : remove())
            return .updateFailed(restored: restored)
        }
        return .saved
    }
}
