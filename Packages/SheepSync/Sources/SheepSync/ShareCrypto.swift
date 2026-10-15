#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// What is inside a share once BOTH halves (link key and passphrase) have opened it. JSON, UTF-8, sorted keys when written.
/// `Data` fields are standard base64 (Swift's default).
public struct ShareEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public var v: Int
    /// "group" — the only kind today.
    public var kind: String
    /// Unix seconds.
    public var created: Int
    /// Unix seconds; absent = never expires.
    public var expires: Int?
    /// The sender's Google address, as the sender's app wrote it. Display only: it is not verified by anything.
    public var sender: String
    /// Who the sender meant this for (lowercase addresses). The importing app refuses an account that is not here.
    public var recipients: [String]
    public var name: String
    public var hostCount: Int
    /// The group document (SheepTerm: the `.sheepterm` JSON of one group), already stripped of credential references.
    public var group: Data
    public var credentials: ShareCredentials?

    public init(v: Int = ShareEnvelope.currentVersion, kind: String = "group", created: Int, expires: Int?, sender: String,
                recipients: [String], name: String, hostCount: Int, group: Data, credentials: ShareCredentials?) {
        self.v = v; self.kind = kind; self.created = created; self.expires = expires; self.sender = sender
        self.recipients = recipients; self.name = name; self.hostCount = hostCount; self.group = group; self.credentials = credentials
    }
}

/// The logins that ride along: one entry per distinct login, with the host ids (as written in the group document) that use it.
public struct ShareCredentials: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        public var username: String
        public var password: String
        public var hosts: [String]
        public init(name: String, username: String, password: String, hosts: [String]) {
            self.name = name; self.username = username; self.password = password; self.hosts = hosts
        }
    }
    public var entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }
    public var isEmpty: Bool { entries.isEmpty }
}

/// One AES-256-GCM layer whose key needs BOTH secrets:
///
///     blob = "SSL2" ‖ iterations (u32 BE) ‖ salt (16) ‖ nonce (12) ‖ ciphertext ‖ tag (16)
///     pk   = PBKDF2-HMAC-SHA256(NFC(passphrase) as UTF-8, salt, iterations, 32)
///     key  = HKDF-SHA256(ikm = linkKey, salt = pk, info = "SSL2", 32)
///     AAD  = the 24 header bytes ("SSL2" ‖ iterations ‖ salt)
///
/// The file is public ciphertext on Drive (anyone who has the file id can download it). The link key is in the URL fragment, the passphrase
/// travels another way: the link alone, or the passphrase alone, opens nothing.
public enum ShareCrypto {
    public static let magic = Data("SSL2".utf8)
    public static let oldMagic = Data("SSL1".utf8)
    public static let hkdfInfo = Data("SSL2".utf8)
    public static let saltLength = 16
    public static let headerLength = 4 + 4 + 16
    public static let defaultIterations = PassphraseKDF.defaultIterations
    /// An importer refuses fewer (a share made to be easy to brute-force) and more (a share made to hang the app).
    public static let iterationRange = 100_000...10_000_000
    public static let maximumBlobBytes = 8 * 1024 * 1024

    public static func newLinkKey() throws -> Data { try SecureRandom.bytes(32) }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func derive(linkKey: Data, passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let pk = try PassphraseKDF.pbkdf2SHA256(password: PassphraseKDF.passphraseBytes(passphrase), salt: salt,
                                                iterations: iterations, length: 32)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: linkKey), salt: pk, info: hkdfInfo, outputByteCount: 32)
    }

    /// `salt` / `nonce` only for the known-answer tests; production passes nil (fresh random ones).
    public static func seal(_ envelope: ShareEnvelope, linkKey: Data, passphrase: String, iterations: Int = defaultIterations,
                            salt: Data? = nil, nonce: Data? = nil) throws -> Data {
        guard linkKey.count == 32 else { throw ShareError.damaged("link key length") }
        guard iterationRange.contains(iterations) else { throw ShareError.damaged("iterations") }
        let salt = try salt ?? SecureRandom.bytes(saltLength)
        var header = magic
        let n = UInt32(iterations)
        header.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        header.append(salt)
        let key = try derive(linkKey: linkKey, passphrase: passphrase, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(try encoder().encode(envelope), using: key,
                                   nonce: try nonce.map { try AES.GCM.Nonce(data: $0) }, authenticating: header)
        guard let combined = box.combined else { throw ShareError.damaged("no combined form") }
        return header + combined
    }

    public static func open(_ blob: Data, linkKey: Data, passphrase: String) throws -> ShareEnvelope {
        guard linkKey.count == 32 else { throw ShareError.badLink }
        guard blob.count <= maximumBlobBytes else { throw ShareError.tooLarge }
        if blob.prefix(4) == oldMagic { throw ShareError.unsupported(1) }
        guard blob.count > headerLength + 28, blob.prefix(4) == magic else { throw ShareError.damaged("not a share") }
        let bytes = [UInt8](blob.prefix(headerLength))
        let iterations = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        guard iterationRange.contains(iterations) else { throw ShareError.damaged("iterations") }
        let salt = Data(bytes[8..<headerLength])
        let key = try derive(linkKey: linkKey, passphrase: passphrase, salt: salt, iterations: iterations)
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: blob.dropFirst(headerLength))
            plain = try AES.GCM.open(box, using: key, authenticating: Data(bytes))
        } catch {
            // A wrong passphrase, a wrong link key and altered bytes are the same thing to GCM.
            throw ShareError.wrongPassphrase
        }
        guard let envelope = try? JSONDecoder().decode(ShareEnvelope.self, from: plain) else { throw ShareError.damaged("envelope") }
        guard envelope.v <= ShareEnvelope.currentVersion else { throw ShareError.unsupported(envelope.v) }
        guard envelope.kind == "group", envelope.hostCount >= 0 else { throw ShareError.damaged("envelope fields") }
        return envelope
    }
}
