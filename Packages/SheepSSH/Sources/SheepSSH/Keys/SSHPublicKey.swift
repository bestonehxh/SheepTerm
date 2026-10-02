// SSH public keys in wire ("blob") form — what a server sends as its host key
// and what known_hosts / authorized_keys / *.pub store in base64.
// Parsing only checks shape; signature verification lives with the transport.
import Foundation

public enum SSHKeyError: Error, Equatable, Sendable {
    case malformed(String)
    case unsupportedKeyType(String)
    /// An OpenSSH key file encrypted with a cipher SheepSSH does not do.
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    /// The file is encrypted and no passphrase was given.
    case passphraseRequired
    /// The check words did not match after decryption — almost always a
    /// wrong passphrase.
    case wrongPassphrase
}

public enum ECDSACurve: String, Sendable, CaseIterable {
    case nistp256, nistp384, nistp521

    public var keyType: String { "ecdsa-sha2-" + rawValue }
    /// Bytes in one coordinate.
    public var coordinateSize: Int {
        switch self {
        case .nistp256: return 32
        case .nistp384: return 48
        case .nistp521: return 66
        }
    }
    /// Uncompressed SEC1 point: 0x04 ‖ X ‖ Y.
    public var pointSize: Int { 1 + 2 * coordinateSize }
    public var hash: SSHHash {
        switch self {
        case .nistp256: return .sha256
        case .nistp384: return .sha384
        case .nistp521: return .sha512
        }
    }
}

public struct SSHPublicKey: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case ed25519(publicKey: [UInt8])
        case ecdsa(curve: ECDSACurve, point: [UInt8])
        case rsa(exponent: BigUInt, modulus: BigUInt)
        case dsa(p: BigUInt, q: BigUInt, g: BigUInt, y: BigUInt)
    }

    /// The key type name inside the blob ("ssh-ed25519", "ssh-rsa", …).
    public let keyType: String
    /// The exact bytes as received. Comparisons (known_hosts, fingerprints)
    /// use these, never a re-encoding.
    public let blob: [UInt8]
    public let kind: Kind

    /// OpenSSH's SSH_RSA_MAXIMUM_MODULUS_SIZE. The bignum code is slow on
    /// purpose-built giant numbers, and a server chooses what it sends.
    public static let maximumModulusBits = 16384

    public init(blob: [UInt8]) throws(SSHKeyError) {
        var r = SSHReader(blob)
        do {
            let type = try r.readUTF8()
            let kind: Kind
            switch type {
            case "ssh-ed25519":
                let pk = try r.readString()
                guard pk.count == 32 else { throw SSHKeyError.malformed("ed25519 key is \(pk.count) bytes, not 32") }
                kind = .ed25519(publicKey: pk)
            case "ssh-rsa":
                let e = try r.readUnsignedMPInt()
                let n = try r.readUnsignedMPInt()
                guard !e.isZero, !n.isZero, n.isOdd else { throw SSHKeyError.malformed("RSA key with an impossible modulus or exponent") }
                guard n.bitWidth <= Self.maximumModulusBits, e.bitWidth <= n.bitWidth else {
                    throw SSHKeyError.malformed("RSA key larger than \(Self.maximumModulusBits) bits")
                }
                kind = .rsa(exponent: e, modulus: n)
            case "ssh-dss":
                let p = try r.readUnsignedMPInt(), q = try r.readUnsignedMPInt(), g = try r.readUnsignedMPInt(), y = try r.readUnsignedMPInt()
                guard !p.isZero, !q.isZero, !g.isZero, !y.isZero else { throw SSHKeyError.malformed("DSA key with a zero parameter") }
                guard p.bitWidth <= Self.maximumModulusBits, q.bitWidth <= p.bitWidth,
                      g.bitWidth <= p.bitWidth, y.bitWidth <= p.bitWidth else {
                    throw SSHKeyError.malformed("DSA key larger than \(Self.maximumModulusBits) bits")
                }
                kind = .dsa(p: p, q: q, g: g, y: y)
            default:
                guard let curve = ECDSACurve.allCases.first(where: { $0.keyType == type }) else {
                    throw SSHKeyError.unsupportedKeyType(type)
                }
                let curveName = try r.readUTF8()
                guard curveName == curve.rawValue else {
                    throw SSHKeyError.malformed("\(type) key names curve \(curveName)")
                }
                let point = try r.readString()
                guard point.count == curve.pointSize, point.first == 0x04 else {
                    throw SSHKeyError.malformed("\(type) point is not an uncompressed \(curve.pointSize)-byte point")
                }
                kind = .ecdsa(curve: curve, point: point)
            }
            guard r.isAtEnd else { throw SSHKeyError.malformed("trailing bytes after the \(type) key") }
            self.keyType = type
            self.blob = blob
            self.kind = kind
        } catch let error as SSHKeyError {
            throw error
        } catch {
            throw .malformed("truncated public key")
        }
    }

    /// "SHA256:<base64, no padding>" — what `ssh-keygen -l` and OpenSSH's
    /// host-key prompt print.
    public var fingerprintSHA256: String {
        let b64 = Data(SSHHash.sha256.hash(blob)).base64EncodedString()
        return "SHA256:" + b64.replacingOccurrences(of: "=", with: "")
    }

    /// Size in bits the way `ssh-keygen -l` reports it.
    public var bits: Int {
        switch kind {
        case .ed25519: return 256
        case .ecdsa(let curve, _):
            switch curve {
            case .nistp256: return 256
            case .nistp384: return 384
            case .nistp521: return 521
            }
        case .rsa(_, let n): return n.bitWidth
        case .dsa(let p, _, _, _): return p.bitWidth
        }
    }

    /// The base64 text of the blob, as stored in known_hosts.
    public var base64: String { Data(blob).base64EncodedString() }

    /// Parses "<type> <base64> [comment]" (a *.pub file, an authorized_keys
    /// or known_hosts key field). The type word must match the blob.
    public init(openSSHLine line: String) throws(SSHKeyError) {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2 else { throw .malformed("expected \"<type> <base64>\"") }
        guard let data = Data(base64Encoded: String(fields[1])) else {
            throw .malformed("key is not valid base64")
        }
        try self.init(blob: Array(data))
        guard keyType == fields[0] else {
            throw .malformed("line says \(fields[0]) but the key is \(keyType)")
        }
    }
}

extension SSHPublicKey {
    /// The same key, whatever the encoding (mpint padding, re-serialized).
    public func sameKey(as other: SSHPublicKey) -> Bool { kind == other.kind }
}
