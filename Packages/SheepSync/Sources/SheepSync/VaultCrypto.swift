import Foundation
#if canImport(CryptoKit)
import CommonCrypto
import CryptoKit
#else
import Crypto
#endif

/// Everything SheepSync encrypts goes through here. Apple primitives only:
/// PBKDF2-HMAC-SHA256 from CommonCrypto, HKDF / AES-256-GCM / HMAC-SHA256
/// from CryptoKit. Nothing here is our own cipher code.
///
/// Key hierarchy (the Termius shape):
///
///     passphrase ──PBKDF2──▶ wrapping key ──AES-GCM──▶ wrapped vault key  (cloud: key file)
///     vault key  ──HKDF────▶ data key  ──AES-GCM──▶ sealed records        (cloud: data file)
///                └─HKDF────▶ digest key (local change detection only)
///
/// The vault key is random and never changes for the life of a vault, so
/// changing the passphrase only re-wraps 32 bytes. Only the wrapped form
/// ever leaves the Mac; the unwrapped key lives in this Mac's Keychain.
public enum VaultCryptoError: Error, Equatable, Sendable {
    /// The passphrase did not open the key file (AES-GCM refused it).
    case wrongPassphrase
    /// Sealed bytes that are not ours, cut short, or altered.
    case damaged(String)
    /// A key file or sealed blob written by a newer SheepSync.
    case unsupportedFormat(Int)
    case keyDerivationFailed(Int32)
    case randomFailed(Int32)
}

public enum PassphraseKDF {
    /// OWASP's 2023 figure for PBKDF2-HMAC-SHA256. About half a second on an
    /// M-series Mac, paid once per device (the result is cached as the vault
    /// key in the Keychain, never re-derived per sync).
    public static let defaultIterations = 600_000
    public static let saltLength = 16

    /// The passphrase as bytes: NFC first, so the same passphrase typed on a
    /// keyboard that composes é differently still opens the vault.
    public static func passphraseBytes(_ passphrase: String) -> Data {
        Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
    }

#if !canImport(CommonCrypto)
    /// swift-crypto has no PBKDF2. A port (Windows) may install a faster one
    /// (the app owns a pre-keyed SHA-256 loop); the default below is the plain
    /// HMAC loop — the same function, only slow at 600 000 iterations.
    nonisolated(unsafe) public static var portableImplementation: (@Sendable (Data, Data, Int, Int) -> Data)?

    static func referencePBKDF2(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
        let base = HMAC<SHA256>(key: SymmetricKey(data: password))
        var out = [UInt8]()
        var block: UInt32 = 1
        while out.count < length {
            var m = base
            m.update(data: salt)
            m.update(data: [UInt8(block >> 24 & 0xFF), UInt8(block >> 16 & 0xFF), UInt8(block >> 8 & 0xFF), UInt8(block & 0xFF)])
            var u = Array(m.finalize())
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    var h = base
                    h.update(data: u)
                    u = Array(h.finalize())
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            out.append(contentsOf: t)
            block += 1
        }
        return Data(out.prefix(length))
    }

    public static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int) throws -> Data {
        if let portableImplementation { return portableImplementation(password, salt, iterations, length) }
        return referencePBKDF2(password: password, salt: salt, iterations: iterations, length: length)
    }
#else
    public static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int) throws -> Data {
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pw in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == kCCSuccess else { throw VaultCryptoError.keyDerivationFailed(status) }
        return derived
    }
#endif
}

enum SecureRandom {
    static func bytes(_ count: Int) throws -> Data {
#if !canImport(Security)
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
#else
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw VaultCryptoError.randomFailed(status) }
        return data
#endif
    }
}

/// The cloud copy of the vault key, wrapped under the passphrase. Not secret
/// by itself — it is useless without the passphrase — but it is the ONLY
/// copy that can bring the vault to a new Mac, so it is never rewritten
/// except by an explicit passphrase change or reset.
public struct VaultKeyFile: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    static let wrapContext = "sheepsync/vault-key/v1"

    public var format: Int
    public var kdf: String
    public var iterations: Int
    public var salt: Data
    /// AES-GCM combined (nonce ‖ ciphertext ‖ tag) of the 32-byte vault key.
    public var wrappedKey: Data
    /// Names the vault without revealing the key: a reset elsewhere gives a
    /// new id, and a Mac holding the old key can tell before it writes.
    public var keyID: String
    public var created: Date

    /// A brand-new vault: a fresh random key wrapped under `passphrase`.
    public static func create(passphrase: String,
                              iterations: Int = PassphraseKDF.defaultIterations,
                              now: Date = Date()) throws -> (file: VaultKeyFile, key: SymmetricKey) {
        let key = SymmetricKey(data: try SecureRandom.bytes(32))
        let file = try wrap(key, passphrase: passphrase, iterations: iterations, created: now)
        return (file, key)
    }

    static func wrap(_ key: SymmetricKey, passphrase: String, iterations: Int, created: Date) throws -> VaultKeyFile {
        let salt = try SecureRandom.bytes(PassphraseKDF.saltLength)
        let wrapping = try wrappingKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let raw = key.withUnsafeBytes { Data($0) }
        let box = try AES.GCM.seal(raw, using: wrapping, authenticating: Data(wrapContext.utf8))
        guard let combined = box.combined else { throw VaultCryptoError.damaged("no combined form") }
        return VaultKeyFile(format: currentFormat, kdf: "pbkdf2-sha256", iterations: iterations,
                            salt: salt, wrappedKey: combined, keyID: keyID(of: key), created: created)
    }

    /// The same vault key under a new passphrase (new salt as well).
    /// Never fewer iterations than the default: the count comes from the
    /// cloud file, and a lowered one must not be carried into the new wrap.
    public func rewrapped(_ key: SymmetricKey, newPassphrase: String,
                          iterations: Int = PassphraseKDF.defaultIterations) throws -> VaultKeyFile {
        try Self.wrap(key, passphrase: newPassphrase, iterations: max(iterations, self.iterations),
                      created: created)
    }

    public func unwrap(passphrase: String) throws -> SymmetricKey {
        guard format <= Self.currentFormat else { throw VaultCryptoError.unsupportedFormat(format) }
        guard kdf == "pbkdf2-sha256", (1...10_000_000).contains(iterations),
              salt.count >= 8 else { throw VaultCryptoError.damaged("key file parameters") }
        let wrapping = try Self.wrappingKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let box: AES.GCM.SealedBox
        do { box = try AES.GCM.SealedBox(combined: wrappedKey) } catch {
            throw VaultCryptoError.damaged("wrapped key")
        }
        let raw: Data
        do { raw = try AES.GCM.open(box, using: wrapping, authenticating: Data(Self.wrapContext.utf8)) } catch {
            throw VaultCryptoError.wrongPassphrase
        }
        guard raw.count == 32 else { throw VaultCryptoError.damaged("vault key length") }
        let key = SymmetricKey(data: raw)
        guard Self.keyID(of: key) == keyID else { throw VaultCryptoError.damaged("key id") }
        return key
    }

    static func wrappingKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        SymmetricKey(data: try PassphraseKDF.pbkdf2SHA256(
            password: PassphraseKDF.passphraseBytes(passphrase), salt: salt,
            iterations: iterations, length: 32))
    }

    public static func keyID(of key: SymmetricKey) -> String {
        let digest = key.withUnsafeBytes { SHA256.hash(data: Data("sheepsync/key-id".utf8) + Data($0)) }
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Sealing with the vault key. Every blob is bound to a context string (the
/// file it belongs to) as AES-GCM associated data, so a sealed blob moved to
/// another name — or another app's file — fails to open instead of being
/// read as something it is not.
public struct VaultSealer: Sendable {
    static let magic = Data("SSV1".utf8)

    private let dataKey: SymmetricKey
    private let digestKey: SymmetricKey

    public init(vaultKey: SymmetricKey) {
        dataKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, info: Data("sheepsync/data".utf8),
                                         outputByteCount: 32)
        digestKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, info: Data("sheepsync/digest".utf8),
                                           outputByteCount: 32)
    }

    public func seal(_ plaintext: Data, context: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: dataKey, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw VaultCryptoError.damaged("no combined form") }
        return Self.magic + combined
    }

    public func open(_ sealed: Data, context: String) throws -> Data {
        guard sealed.count > Self.magic.count + 28, sealed.prefix(Self.magic.count) == Self.magic else {
            throw VaultCryptoError.damaged("not a SheepSync blob")
        }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(Self.magic.count))
            return try AES.GCM.open(box, using: dataKey, authenticating: Data(context.utf8))
        } catch {
            throw VaultCryptoError.damaged("sealed data did not authenticate")
        }
    }

    /// Keyed digest of a record, for telling "changed since the last sync"
    /// on this Mac. Keyed so the local state file says nothing about the
    /// content (a bare SHA-256 of a short password is a lookup away).
    public func digest(id: String, payload: Data) -> String {
        var mac = HMAC<SHA256>(key: digestKey)
        mac.update(data: Data(id.utf8))
        mac.update(data: Data([0]))
        mac.update(data: payload)
        return Data(mac.finalize()).base64EncodedString()
    }
}
