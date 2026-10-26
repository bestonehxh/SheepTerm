// Host keys for the server role (SheepTerm's File Server): an Ed25519 key
// (stored in the OpenSSH private-key container, unencrypted) and an RSA key
// (generated with Security.framework, stored as PKCS#1 PEM) — the formats
// ssh-keygen reads and writes, and that this package's own parsers load back.
//
// Both are needed: legacy network gear (ArubaOS `copy scp:`, old IOS,
// Comware) knows no ed25519 host key and dies at kex with "no match for
// method server host key algo" against an ed25519-only server (SheepDrop,
// proven on real Aruba gear).
//
// A file that is missing, empty, unreadable, of the wrong key type or does
// not parse is REPLACED by a fresh key — never a crash, never a server that
// cannot start. Files are created 0600 from the first byte (O_EXCL, no
// follow), the directory is kept 0700.
//
// Ported from SheepDrop's Server/HostKeyStore.swift; changes: RSA 3072
// (was 2048), the directory API, the type check on load, O_EXCL|O_NOFOLLOW.
import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum HostKeyStoreError: Error, Sendable {
    case generationFailed(String)
    case storageFailed(String)
}

extension SSHPrivateKey {
    /// Builds a key from its parts; the public half is derived from `kind`.
    /// Used by the server role's host-key generation.
    init(kind: Kind, comment: String = "") {
        var w = SSHWriter()
        switch kind {
        case .ed25519(let seed):
            let publicRaw = (try? Curve25519.Signing.PrivateKey(rawRepresentation: seed))
                .map { Array($0.publicKey.rawRepresentation) } ?? []
            w.writeString("ssh-ed25519")
            w.writeString(publicRaw)
        case .ecdsa(let curve, let scalar):
            w.writeString(curve.keyType)
            w.writeString(curve.rawValue)
            let point: [UInt8]
            switch curve {
            case .nistp256:
                point = (try? P256.Signing.PrivateKey(rawRepresentation: scalar)).map { Array($0.publicKey.x963Representation) } ?? []
            case .nistp384:
                point = (try? P384.Signing.PrivateKey(rawRepresentation: scalar)).map { Array($0.publicKey.x963Representation) } ?? []
            case .nistp521:
                point = (try? P521.Signing.PrivateKey(rawRepresentation: scalar)).map { Array($0.publicKey.x963Representation) } ?? []
            }
            w.writeString(point)
        case .rsa(let n, let e, _, _, _, _):
            w.writeString("ssh-rsa")
            w.writeMPInt(e)
            w.writeMPInt(n)
        }
        // The blob is built here from our own kind — it always parses.
        self.init(kind: kind, publicKey: try! SSHPublicKey(blob: w.bytes), comment: comment)
    }
}

public enum HostKeyStore {
    public static let ed25519FileName = "ssh_host_ed25519_key"
    public static let rsaFileName = "ssh_host_rsa_key"
    public static let rsaBits = 3072
    static let comment = "SheepTerm file server host key"

    /// Both host keys in `directory` (created 0700 if missing), generated on
    /// first use; ed25519 first, then RSA.
    public static func ensureAll(directory: URL) throws -> [SSHPrivateKey] {
        let path = directory.path
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw HostKeyStoreError.storageFailed("cannot create \(path): \(error.localizedDescription)")
        }
        restrict(path, 0o700)
        let ed = try ensureEd25519(path: directory.appendingPathComponent(ed25519FileName).path)
        let rsa = try ensureRSA(path: directory.appendingPathComponent(rsaFileName).path)
        return [ed, rsa]
    }

    /// Loads the key in `path` (any format PEMPrivateKey / the OpenSSH
    /// container reads), or nil when the file is missing, empty, encrypted
    /// or does not parse.
    public static func load(path: String) -> SSHPrivateKey? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size > 0, size < 64 * 1024,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        if OpenSSHPrivateKeyFile.isOpenSSHFormat(text) {
            guard let file = try? OpenSSHPrivateKeyFile(text: text), !file.isEncrypted else { return nil }
            return try? file.decrypt(passphrase: [])
        }
        return try? PEMPrivateKey.load(text, passphrase: nil)
    }

    /// Loads or generates an Ed25519 host key (OpenSSH container).
    public static func ensureEd25519(path: String) throws -> SSHPrivateKey {
        if let key = load(path: path), case .ed25519 = key.kind {
            restrict(path, 0o600)
            return key
        }
        let seed = Array(Curve25519.Signing.PrivateKey().rawRepresentation)
        let key = SSHPrivateKey(kind: .ed25519(seed: seed), comment: comment)
        try writeOpenSSHContainer(key: key, path: path)
        return key
    }

    /// Loads or generates an RSA host key (`rsaBits`), stored as PKCS#1 PEM.
    public static func ensureRSA(path: String) throws -> SSHPrivateKey {
        if let key = load(path: path), case .rsa = key.kind, key.publicKey.bits >= 2048 {
            restrict(path, 0o600)
            return key
        }
        #if canImport(Security)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: rsaBits,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw HostKeyStoreError.generationFailed("RSA generation failed: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        guard let der = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            throw HostKeyStoreError.generationFailed("RSA export failed: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        let key = try rsaPrivateKey(fromPKCS1: Array(der))
        let base64 = Data(der).base64EncodedString().chunks(ofCount: 64).joined(separator: "\n")
        try writePrivate("-----BEGIN RSA PRIVATE KEY-----\n" + base64 + "\n-----END RSA PRIVATE KEY-----\n", path: path)
        return key
        #else
        throw HostKeyStoreError.generationFailed("RSA key generation needs Security.framework")
        #endif
    }

    // MARK: - OpenSSH container writer (ed25519)

    private static func writeOpenSSHContainer(key: SSHPrivateKey, path: String) throws {
        guard case .ed25519(let seed) = key.kind else {
            throw HostKeyStoreError.storageFailed("only ed25519 keys go in the OpenSSH container")
        }
        // Derive the public half THROUGH the private key — Signing.PublicKey
        // (rawRepresentation:) would happily treat the seed AS the public key.
        let publicRaw = (try? Curve25519.Signing.PrivateKey(rawRepresentation: seed))
            .map { Array($0.publicKey.rawRepresentation) } ?? []
        guard publicRaw.count == 32 else {
            throw HostKeyStoreError.storageFailed("cannot derive the ed25519 public key")
        }
        var pubBlob = SSHWriter()
        pubBlob.writeString("ssh-ed25519")
        pubBlob.writeString(publicRaw)

        // Private section: checkints, key type, public, private (seed ‖ public), comment.
        var rng = SystemRandomNumberGenerator()
        let check = UInt32.random(in: 0...UInt32.max, using: &rng)
        var section = SSHWriter()
        section.writeUInt32(check)
        section.writeUInt32(check)
        section.writeString("ssh-ed25519")
        section.writeString(publicRaw)
        section.writeString(seed + publicRaw)
        section.writeString(key.comment)
        // Padded to the cipher's block size (8 for "none") with 1, 2, 3, …
        var pad: UInt8 = 1
        while section.bytes.count % 8 != 0 {
            section.writeByte(pad)
            pad &+= 1
        }

        var body = SSHWriter()
        body.writeBytes(OpenSSHPrivateKeyFile.magic)
        body.writeString("none")       // cipher
        body.writeString("none")       // kdf
        body.writeString([])           // kdf options
        body.writeUInt32(1)            // one key
        body.writeString(pubBlob.bytes)
        body.writeString(section.bytes)

        let text = OpenSSHPrivateKeyFile.armorBegin + "\n"
            + Data(body.bytes).base64EncodedString().chunks(ofCount: 64).joined(separator: "\n")
            + "\n" + OpenSSHPrivateKeyFile.armorEnd + "\n"
        try writePrivate(text, path: path)
    }

    /// Owner-only permissions. Not on Windows: there `chmod` is a deprecated
    /// alias that only toggles read-only — the profile folder's ACL is what
    /// keeps a key private (as in `writePrivate`).
    private static func restrict(_ path: String, _ mode: Int) {
        #if !os(Windows)
        chmod(path, mode_t(mode))
        #endif
    }

    /// Replaces whatever is at `path` (a corrupt key, a symlink — unlink
    /// removes the link, not its target) with a new 0600 file, created
    /// exclusively so nothing else can be holding it open.
    private static func writePrivate(_ text: String, path: String) throws {
        #if os(Windows)
        // The Windows port has no File Server; this only has to compile there (no O_NOFOLLOW / fchmod: the profile folder's ACL
        // is what keeps a key private on Windows).
        try? FileManager.default.removeItem(atPath: path)
        guard FileManager.default.createFile(atPath: path, contents: Data(text.utf8)) else {
            throw HostKeyStoreError.storageFailed("cannot write \(path)")
        }
        #else
        unlink(path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw HostKeyStoreError.storageFailed("cannot write \(path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else {
                unlink(path)
                throw HostKeyStoreError.storageFailed("cannot write \(path): \(String(cString: strerror(errno)))")
            }
            written += n
        }
        fchmod(fd, 0o600)
        #endif
    }

    // MARK: - PKCS#1 DER reader (RSA)

    /// Minimal DER parse of a PKCS#1 RSAPrivateKey:
    /// SEQUENCE { INTEGER version, n, e, d, p, q, dp, dq, qinv }.
    static func rsaPrivateKey(fromPKCS1 der: [UInt8]) throws -> SSHPrivateKey {
        var reader = HostKeyDERReader(der)
        guard reader.readTag() == 0x30, let content = reader.readLengthPrefixed() else {
            throw HostKeyStoreError.generationFailed("malformed PKCS#1 DER")
        }
        var r = HostKeyDERReader(content)
        guard r.readTag() == 0x02, r.readLengthPrefixed() != nil else {   // version
            throw HostKeyStoreError.generationFailed("malformed PKCS#1 DER")
        }
        func integer() throws -> BigUInt {
            guard r.readTag() == 0x02, let bytes = r.readLengthPrefixed() else {
                throw HostKeyStoreError.generationFailed("malformed PKCS#1 DER")
            }
            var trimmed = bytes
            while trimmed.count > 1, trimmed[0] == 0 { trimmed.removeFirst() }
            return BigUInt(bigEndian: trimmed)
        }
        let n = try integer()
        let e = try integer()
        let d = try integer()
        let p = try integer()
        let q = try integer()
        _ = try integer()       // dp
        _ = try integer()       // dq
        let qinv = try integer()
        return SSHPrivateKey(kind: .rsa(modulus: n, publicExponent: e, privateExponent: d,
                                        iqmp: qinv, p: p, q: q), comment: comment)
    }
}

/// The smallest DER reader that walks PKCS#1: tag + length prefixes.
struct HostKeyDERReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func readTag() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// The bytes after a DER length prefix (short or long form).
    mutating func readLengthPrefixed() -> [UInt8]? {
        guard offset < bytes.count else { return nil }
        let first = bytes[offset]
        offset += 1
        let length: Int
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, offset + count <= bytes.count else { return nil }
            length = bytes[offset..<(offset + count)].reduce(0) { $0 << 8 | Int($1) }
            offset += count
        }
        guard length >= 0, offset + length <= bytes.count else { return nil }
        let out = Array(bytes[offset..<(offset + length)])
        offset += length
        return out
    }
}

private extension String {
    func chunks(ofCount count: Int) -> [String] {
        stride(from: 0, to: self.count, by: count).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: Swift.min(count, self.count - offset))
            return String(self[start..<end])
        }
    }
}
