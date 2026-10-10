import Foundation
import LocalAuthentication
import Security

/// Every secret SheepTerm keeps — each credential's password and Sync's
/// session — in ONE login-keychain item (`Bestchaan.SheepTerm` / `vault`).
///
/// Why one: the login keychain ties each item to the build that may read it
/// (its partition list). An app signed by Apple's Developer ID is named by
/// its Team ID there; ours ("Sheep Apps Signing", self-signed) can only be
/// named by its code hash, which every build changes. So after each update
/// macOS asks for the login password once per ITEM — one item per host meant
/// a hundred prompts for a hundred hosts. One item is one prompt.
///
/// The decoded contents are kept in memory until quit (never on disk), so
/// Sync's background reads, which must never prompt, are served from there
/// once anything has opened the vault.
///
/// Rules that must not be "simplified":
/// - a vault that cannot be read (denied, locked, garbage) is UNAVAILABLE,
///   never empty: nothing is written over it, and a missing password reads as
///   unknown (nil), never as "deleted".
/// - every write re-reads the item first (another copy of the app, a debug
///   build, may have written since), then updates it in place.
/// - a password still in its pre-5.0 (14) per-credential item is moved in at
///   launch (`migrate`, one write for all) or the first time it is asked for;
///   the old item is deleted only after the vault holds it, and never by a
///   plain `set` (Sync's session is read-modify-write: a write made while the
///   old item could not be read must not delete the half it never saw).
/// - a write of a vault that read as MISSING only adds: it can never update
///   (replace) an item that a wrong "not found" failed to show.
nonisolated final class PasswordVault: @unchecked Sendable {
    nonisolated enum ReadResult: Equatable, Sendable {
        case found(Data)
        case missing
        case unavailable
    }

    /// The Keychain, or a fake in the harness.
    nonisolated protocol Backend: Sendable {
        func read(_ account: String, interactive: Bool) -> ReadResult
        /// `exists`: what the read just before said. true = update in place
        /// only; false = add only (an item that is there after all fails).
        func write(_ account: String, _ value: Data, exists: Bool, interactive: Bool) -> Bool
        /// True when the item is gone (also when there was none).
        func delete(_ account: String, interactive: Bool) -> Bool
    }

    static let account = "vault"
    static let shared = PasswordVault(backend: KeychainBackend(service: "Bestchaan.SheepTerm"))

    private let backend: Backend
    private let lock = NSLock()
    /// nil = not read yet, or the last read was refused.
    private var cache: [String: Data]?

    init(backend: Backend) { self.backend = backend }

    private struct Contents: Codable {
        var version = 1
        var secrets: [String: Data]
    }

    /// The secret under `key`; nil when there is none OR it cannot be known
    /// right now (callers treat nil as "unknown", never as "deleted").
    func value(for key: String, interactive: Bool) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let all = load(interactive: interactive) else {
            // The vault cannot be read: a password still in its old item is
            // served from there (not moved — nothing may be written now).
            if case .found(let legacy) = backend.read(key, interactive: interactive) { return legacy }
            return nil
        }
        if let value = all[key] { return value }
        // Not moved in yet: its own pre-vault item.
        guard case .found(let legacy) = backend.read(key, interactive: interactive) else { return nil }
        if mutate(interactive: interactive, { $0[key] = legacy }) {
            _ = backend.delete(key, interactive: interactive)
        }
        return legacy
    }

    @discardableResult
    func set(_ value: Data, for key: String, interactive: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return mutate(interactive: interactive, { $0[key] = value })
    }

    /// Launch: moves every pre-5.0 (14) item named in `keys` into the vault
    /// in ONE write, so Sync sees them all at once instead of host by host.
    /// Each old item costs its own prompt this one time; after that, none.
    func migrate(_ keys: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard let all = load(interactive: true) else { return }
        var moved: [String: Data] = [:]
        for key in keys where all[key] == nil {
            if case .found(let legacy) = backend.read(key, interactive: true) { moved[key] = legacy }
        }
        guard !moved.isEmpty,
              mutate(interactive: true, { vault in for (key, data) in moved where vault[key] == nil { vault[key] = data } })
        else { return }
        for key in moved.keys { _ = backend.delete(key, interactive: true) }
    }

    /// True when the secret is gone from both the vault and its old item.
    @discardableResult
    func remove(_ key: String, interactive: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard mutate(interactive: interactive, { $0.removeValue(forKey: key) }) else { return false }
        return backend.delete(key, interactive: interactive)
    }

    // MARK: - under the lock

    private func decode(_ result: ReadResult) -> [String: Data]? {
        switch result {
        case .found(let data):
            guard let contents = try? JSONDecoder().decode(Contents.self, from: data) else {
                NSLog("SheepTerm: the Keychain vault is unreadable — left untouched")
                return nil
            }
            return contents.secrets
        case .missing: return [:]
        case .unavailable: return nil
        }
    }

    private func load(interactive: Bool) -> [String: Data]? {
        if let cache { return cache }
        cache = decode(backend.read(Self.account, interactive: interactive))
        return cache
    }

    private func mutate(interactive: Bool, _ change: (inout [String: Data]) -> Void) -> Bool {
        let read = backend.read(Self.account, interactive: interactive)
        guard var fresh = decode(read) else { return false }
        let exists = read != .missing
        change(&fresh)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Contents(secrets: fresh)),
              backend.write(Self.account, data, exists: exists, interactive: interactive) else { return false }
        cache = fresh
        return true
    }
}

/// The login keychain, generic-password items of one service.
nonisolated struct KeychainBackend: PasswordVault.Backend {
    let service: String

    private func query(_ account: String, interactive: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            // The login (file) keychain's access prompt is not covered by
            // the context above; this older flag is what refuses it there.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }

    func read(_ account: String, interactive: Bool) -> PasswordVault.ReadResult {
        var query = query(account, interactive: interactive)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data else { return .unavailable }
        return .found(data)
    }

    func write(_ account: String, _ value: Data, exists: Bool, interactive: Bool) -> Bool {
        if exists {
            let status = SecItemUpdate(query(account, interactive: interactive) as CFDictionary,
                                       [kSecValueData as String: value] as CFDictionary)
            if status != errSecSuccess { NSLog("SheepTerm: Keychain write failed (status %d) for %@", status, account) }
            return status == errSecSuccess
        }
        var add = query(account, interactive: true)
        add[kSecValueData as String] = value
        let added = SecItemAdd(add as CFDictionary, nil)
        if added != errSecSuccess { NSLog("SheepTerm: Keychain add failed (status %d) for %@", added, account) }
        return added == errSecSuccess
    }

    func delete(_ account: String, interactive: Bool) -> Bool {
        let status = SecItemDelete(query(account, interactive: interactive) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
