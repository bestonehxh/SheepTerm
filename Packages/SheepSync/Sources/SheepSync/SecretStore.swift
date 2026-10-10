import Foundation
#if canImport(Security)
import Security
#endif

/// The few secrets SheepSync keeps on a Mac — the Google refresh token and
/// the unwrapped vault key — in the login Keychain under the app's own
/// service, never in a file. Accounts are prefixed `sheepsync.` so they can
/// never collide with what the app itself stores under the same service.
public struct SecretStore: Sendable {
    public let service: String

    public init(service: String) { self.service = service }

#if !canImport(Security)
    /// Without a Keychain (Windows) the app supplies the store — its own
    /// encrypted vault file — before the engine is created. With none set,
    /// nothing can be kept, so nothing can be signed in.
    nonisolated(unsafe) public static var portableStore: SecretStoring?

    public func read(_ account: String) -> Data? { Self.portableStore?.read("sheepsync.\(account)") }
    @discardableResult
    public func write(_ account: String, _ value: Data) -> Bool { Self.portableStore?.write("sheepsync.\(account)", value) ?? false }
    @discardableResult
    public func delete(_ account: String) -> Bool { Self.portableStore?.delete("sheepsync.\(account)") ?? true }
#else

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "sheepsync.\(account)"]
    }

    public func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Update in place, add only when there is nothing to update — the same
    /// rule as the app's own Keychain wrapper: never delete a working value
    /// before the new one is known to have landed.
    @discardableResult
    public func write(_ account: String, _ value: Data) -> Bool {
        let q = query(account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = q
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
#endif
}
