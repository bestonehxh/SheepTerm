// Verifying a host key's signature over the exchange hash.
//
// ed25519 and ECDSA go to CryptoKit. RSA (PKCS#1 v1.5) and DSA are checked
// here with BigUInt: verification uses only public values, so variable-time
// arithmetic is fine, and doing it ourselves keeps one code path on every
// platform. The RSA check never parses the decrypted block — it builds the
// one correct encoding and compares all of it (the standard defence against
// Bleichenbacher-style signature forgeries).
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum SignatureError: Error, Equatable, Sendable {
    case malformed(String)
    /// The signature names an algorithm other than the negotiated one.
    case algorithmMismatch(expected: String, got: String)
    case keyTypeMismatch(expected: String, got: String)
    case keyTooSmall(bits: Int)
    case invalid
}

public enum SignatureVerifier {
    /// OpenSSH's SSH_RSA_MINIMUM_MODULUS_SIZE — plenty of network gear still
    /// ships 1024-bit RSA host keys.
    public static let minimumRSABits = 1024

    /// Verifies `signatureBlob` (string algorithm, string signature) by `key`
    /// over `data`, requiring the signature algorithm to be `algorithm`.
    public static func verify(signatureBlob: [UInt8], data: [UInt8], key: SSHPublicKey,
                              algorithm: HostKeyAlgorithm) throws(SignatureError) {
        guard key.keyType == algorithm.keyType else {
            throw .keyTypeMismatch(expected: algorithm.keyType, got: key.keyType)
        }
        var r = SSHReader(signatureBlob)
        let name: String
        let signature: [UInt8]
        do {
            name = try r.readUTF8()
            signature = try r.readString()
        } catch {
            throw .malformed("truncated signature")
        }
        guard r.isAtEnd else { throw .malformed("trailing bytes after the signature") }
        guard name == algorithm.rawValue else { throw .algorithmMismatch(expected: algorithm.rawValue, got: name) }

        switch key.kind {
        case .ed25519(let publicKey):
            guard signature.count == 64,
                  let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
                  pk.isValidSignature(signature, for: data) else { throw .invalid }
        case .ecdsa(let curve, let point):
            try verifyECDSA(curve: curve, point: point, signature: signature, data: data)
        case .rsa(let e, let n):
            let hash: SSHHash
            switch algorithm {
            case .rsaSHA512: hash = .sha512
            case .rsaSHA256: hash = .sha256
            default: hash = .sha1
            }
            try verifyRSA(e: e, n: n, hash: hash, signature: signature, data: data)
        case .dsa(let p, let q, let g, let y):
            try verifyDSA(p: p, q: q, g: g, y: y, signature: signature, data: data)
        }
    }

    static func verifyECDSA(curve: ECDSACurve, point: [UInt8], signature: [UInt8], data: [UInt8]) throws(SignatureError) {
        var r = SSHReader(signature)
        let rBytes: [UInt8], sBytes: [UInt8]
        do {
            rBytes = try r.readMPIntBytes(allowingSignBit: true)
            sBytes = try r.readMPIntBytes(allowingSignBit: true)
        } catch {
            throw .malformed("ECDSA signature is not two mpints")
        }
        guard r.isAtEnd else { throw .malformed("trailing bytes in the ECDSA signature") }
        let size = curve.coordinateSize
        guard !rBytes.isEmpty, !sBytes.isEmpty, rBytes.count <= size, sBytes.count <= size else { throw .invalid }
        let raw = [UInt8](repeating: 0, count: size - rBytes.count) + rBytes
            + [UInt8](repeating: 0, count: size - sBytes.count) + sBytes
        // CryptoKit hashes `data` with the curve's hash (SHA-256/384/512),
        // which is exactly what ecdsa-sha2-nistp* specifies.
        let valid: Bool
        switch curve {
        case .nistp256:
            guard let pk = try? P256.Signing.PublicKey(x963Representation: point),
                  let sig = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { throw .invalid }
            valid = pk.isValidSignature(sig, for: data)
        case .nistp384:
            guard let pk = try? P384.Signing.PublicKey(x963Representation: point),
                  let sig = try? P384.Signing.ECDSASignature(rawRepresentation: raw) else { throw .invalid }
            valid = pk.isValidSignature(sig, for: data)
        case .nistp521:
            guard let pk = try? P521.Signing.PublicKey(x963Representation: point),
                  let sig = try? P521.Signing.ECDSASignature(rawRepresentation: raw) else { throw .invalid }
            valid = pk.isValidSignature(sig, for: data)
        }
        guard valid else { throw .invalid }
    }

    /// DER DigestInfo prefixes (RFC 8017 §9.2 note 1).
    static func digestInfo(_ hash: SSHHash) -> [UInt8] {
        switch hash {
        case .sha1: return hex("3021300906052b0e03021a05000414")
        case .sha256: return hex("3031300d060960864801650304020105000420")
        case .sha512: return hex("3051300d060960864801650304020305000440")
        default: return []
        }
    }

    /// OpenSSL's cap for large moduli. Without it a server could send a
    /// 16384-bit key whose exponent is as long as the modulus and make one
    /// verification cost seconds of CPU, inside `receive`, where neither the
    /// connect deadline nor a tab close can interrupt it.
    static let maximumRSAExponentBits = 64

    static func verifyRSA(e: BigUInt, n: BigUInt, hash: SSHHash, signature: [UInt8], data: [UInt8]) throws(SignatureError) {
        guard n.bitWidth >= minimumRSABits else { throw .keyTooSmall(bits: n.bitWidth) }
        guard e.bitWidth <= maximumRSAExponentBits, e > BigUInt(1), e.isOdd else { throw .invalid }
        let k = (n.bitWidth + 7) / 8
        // OpenSSH accepts a signature shorter than the modulus (some servers
        // drop leading zero bytes) by left-padding it; longer is refused.
        guard !signature.isEmpty, signature.count <= k else { throw .invalid }
        let s = BigUInt(bigEndian: signature)
        guard s < n else { throw .invalid }
        let m = s.power(e, modulus: n).bigEndianBytes(count: k)
        let t = digestInfo(hash) + hash.hash(data)
        guard k >= t.count + 11 else { throw .invalid }
        let expected: [UInt8] = [0x00, 0x01] + [UInt8](repeating: 0xFF, count: k - t.count - 3) + [0x00] + t
        guard constantTimeEqual(m, expected) else { throw .invalid }
    }

    /// FIPS 186 DSA with SHA-1 and the SSH signature layout: r ‖ s, 20 bytes each.
    static func verifyDSA(p: BigUInt, q: BigUInt, g: BigUInt, y: BigUInt, signature: [UInt8], data: [UInt8]) throws(SignatureError) {
        guard signature.count == 40, q.bitWidth == 160, p.bitWidth >= 1024, p.isOdd,
              g > BigUInt(1), g < p, y > BigUInt(1), y < p else { throw .invalid }
        let r = BigUInt(bigEndian: signature[0..<20]), s = BigUInt(bigEndian: signature[20..<40])
        guard !r.isZero, r < q, !s.isZero, s < q, let w = s.inverse(modulo: q) else { throw .invalid }
        let z = BigUInt(bigEndian: SSHHash.sha1.hash(data))
        let u1 = (z * w) % q
        let u2 = (r * w) % q
        let v = ((g.power(u1, modulus: p) * y.power(u2, modulus: p)) % p) % q
        guard v == r else { throw .invalid }
    }

    static func hex(_ s: String) -> [UInt8] {
        BigUInt(hex: s)!.bigEndianBytes(count: s.count / 2)
    }
}
