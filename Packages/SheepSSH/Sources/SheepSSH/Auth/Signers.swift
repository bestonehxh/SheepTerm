// Producing SSH signatures for user authentication.
//
// A signer holds one public key and signs with the matching private key,
// wherever that lives: in this process (`PrivateKeySigner`, from a key file)
// or in ssh-agent (`SSHAgent.Identity`). The result is the SSH signature blob
// (string algorithm, string signature) that goes into USERAUTH_REQUEST.
//
// Private-key operations go to the platform: CryptoKit for Ed25519/ECDSA,
// Security.framework for RSA on macOS (swift-crypto's _RSA stands in on
// Linux). Nothing secret passes through BigUInt except building the RSA key's
// DER form (d mod (p−1), d mod (q−1)) once when a key file is loaded — a
// local, one-off computation no remote party can time.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
import _CryptoExtras
#endif
#if canImport(Security)
import Security
#endif

public enum SignerError: Error, Equatable, Sendable {
    case unsupportedAlgorithm(String)
    case keyRejected(String)
    case signingFailed(String)
    case agent(String)
}

public protocol SSHSigner: AnyObject {
    var publicKey: SSHPublicKey { get }
    /// "file ~/.ssh/id_ed25519", "agent: user@host" — for messages.
    var label: String { get }
    /// Returns the signature blob for `data` under `algorithm`
    /// ("ssh-ed25519", "rsa-sha2-512", …).
    func sign(_ data: [UInt8], algorithm: String) throws(SignerError) -> [UInt8]
}

/// The public-key algorithm name to use for `key`, given what we accept and
/// what the server said it accepts (server-sig-algs, RFC 8308). For RSA:
/// the strongest SHA-2 variant the server lists; with no server-sig-algs at
/// all (older servers) plain ssh-rsa if allowed — what OpenSSH's client does.
public func publicKeyAlgorithm(for key: SSHPublicKey, accepted: [HostKeyAlgorithm],
                               serverSignatureAlgorithms: [String]?) -> String? {
    guard key.keyType == "ssh-rsa" else {
        return accepted.contains(where: { $0.rawValue == key.keyType }) ? key.keyType : nil
    }
    let rsa = accepted.filter { $0.keyType == "ssh-rsa" }
    guard let serverList = serverSignatureAlgorithms else {
        if rsa.contains(.rsaSHA1) { return "ssh-rsa" }
        return rsa.first?.rawValue
    }
    return rsa.first(where: { serverList.contains($0.rawValue) })?.rawValue
}

func signatureBlob(_ algorithm: String, _ signature: [UInt8]) -> [UInt8] {
    var w = SSHWriter()
    w.writeString(algorithm)
    w.writeString(signature)
    return w.bytes
}

public final class PrivateKeySigner: SSHSigner {
    public let key: SSHPrivateKey
    public let label: String
    public var publicKey: SSHPublicKey { key.publicKey }
    /// RSA only: the platform DER, built here and nowhere else, so the
    /// variable-time d mod (p−1) runs once at load — not on every sign(),
    /// which a server can trigger and time with each PK_OK.
    private let rsaDER: [UInt8]?

    public init(_ key: SSHPrivateKey, label: String) {
        self.key = key
        self.label = label
        rsaDER = RSASigning.pkcs1DER(key)
    }

    public func sign(_ data: [UInt8], algorithm: String) throws(SignerError) -> [UInt8] {
        switch key.kind {
        case .ed25519(let seed):
            guard algorithm == "ssh-ed25519" else { throw .unsupportedAlgorithm(algorithm) }
            guard let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
                  let sig = try? k.signature(for: data) else { throw .signingFailed("ed25519") }
            return signatureBlob(algorithm, Array(sig))
        case .ecdsa(let curve, let scalar):
            guard algorithm == curve.keyType else { throw .unsupportedAlgorithm(algorithm) }
            let raw: [UInt8]
            switch curve {
            case .nistp256:
                guard let k = try? P256.Signing.PrivateKey(rawRepresentation: scalar),
                      let s = try? k.signature(for: data) else { throw .signingFailed(algorithm) }
                raw = Array(s.rawRepresentation)
            case .nistp384:
                guard let k = try? P384.Signing.PrivateKey(rawRepresentation: scalar),
                      let s = try? k.signature(for: data) else { throw .signingFailed(algorithm) }
                raw = Array(s.rawRepresentation)
            case .nistp521:
                guard let k = try? P521.Signing.PrivateKey(rawRepresentation: scalar),
                      let s = try? k.signature(for: data) else { throw .signingFailed(algorithm) }
                raw = Array(s.rawRepresentation)
            }
            // SSH wants r and s as two mpints inside the signature string.
            var inner = SSHWriter()
            inner.writeMPInt(unsigned: raw[0..<raw.count / 2])
            inner.writeMPInt(unsigned: raw[(raw.count / 2)...])
            return signatureBlob(algorithm, inner.bytes)
        case .rsa:
            guard let rsaDER else { throw .unsupportedAlgorithm(algorithm) }
            return signatureBlob(algorithm, try RSASigning.sign(der: rsaDER, data: data, algorithm: algorithm))
        }
    }
}

enum RSASigning {
    /// PKCS#1 RSAPrivateKey DER for the platform key APIs.
    static func pkcs1DER(_ key: SSHPrivateKey) -> [UInt8]? {
        guard case .rsa(let n, let e, let d, let iqmp, let p, let q) = key.kind else { return nil }
        let one = BigUInt(1)
        // The parsers refuse p or q ≤ 1; this guards the division regardless.
        guard p > one, q > one else { return nil }
        let fields = [BigUInt(), n, e, d, p, q, d % (p - one), d % (q - one), iqmp]
        return DERWriter.sequence(fields.map(DERWriter.integer).reduce([], +))
    }

    static func sign(der: [UInt8], data: [UInt8], algorithm: String) throws(SignerError) -> [UInt8] {
#if canImport(Security)
        let secAlgorithm: SecKeyAlgorithm
        switch algorithm {
        case "rsa-sha2-512": secAlgorithm = .rsaSignatureMessagePKCS1v15SHA512
        case "rsa-sha2-256": secAlgorithm = .rsaSignatureMessagePKCS1v15SHA256
        case "ssh-rsa": secAlgorithm = .rsaSignatureMessagePKCS1v15SHA1
        default: throw .unsupportedAlgorithm(algorithm)
        }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error) else {
            throw .keyRejected(error?.takeRetainedValue().localizedDescription ?? "RSA key rejected")
        }
        guard let signature = SecKeyCreateSignature(secKey, secAlgorithm, Data(data) as CFData, &error) else {
            throw .signingFailed(error?.takeRetainedValue().localizedDescription ?? "RSA signing failed")
        }
        return Array(signature as Data)
#else
        let digest: _RSA.Signing.RSASignature
        do {
            let k = try _RSA.Signing.PrivateKey(unsafeDERRepresentation: Data(der))
            switch algorithm {
            case "rsa-sha2-512": digest = try k.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
            case "rsa-sha2-256": digest = try k.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
            case "ssh-rsa": digest = try k.signature(for: Insecure.SHA1.hash(data: data), padding: .insecurePKCS1v1_5)
            default: throw SignerError.unsupportedAlgorithm(algorithm)
            }
        } catch let error as SignerError {
            throw error
        } catch {
            throw .signingFailed("\(error)")
        }
        return Array(digest.rawRepresentation)
#endif
    }
}

enum DERWriter {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func integer(_ v: BigUInt) -> [UInt8] {
        var content = v.bigEndianBytes()
        if content.isEmpty || content[0] & 0x80 != 0 { content.insert(0, at: 0) }
        return [0x02] + length(content.count) + content
    }

    static func sequence(_ content: [UInt8]) -> [UInt8] {
        [0x30] + length(content.count) + content
    }
}
