// OpenSSH user certificates (PROTOCOL.certkeys): a public key signed by a CA,
// offered in USERAUTH_REQUEST in place of the bare key. The client only needs
// to read one (the `-cert.pub` file ssh-keygen -s writes) and offer it; the
// SERVER checks the CA signature, principals and validity — so nothing here
// verifies the CA's signature, it is carried as bytes.
//
// A certificate is an `SSHPublicKey` whose `keyType` and `blob` are the
// certificate's ("ssh-ed25519-cert-v01@openssh.com", the whole cert) and whose
// `kind` is the key inside it — so the PK_OK blob check, `sameKey` against the
// private key and the fingerprints all work unchanged. Built ONLY by
// `SSHPublicKey(certificateBlob:)` / `(certificateLine:)`: `init(blob:)` (host
// keys, known_hosts) still refuses certificate types.
import Foundation

public struct SSHCertificateInfo: Sendable, Hashable {
    /// 1 = user certificate, 2 = host certificate.
    public let type: UInt32
    public let serial: UInt64
    public let keyID: String
    /// Empty = valid for any principal.
    public let principals: [String]
    /// Seconds since 1970; validBefore == UInt64.max means "forever".
    public let validAfter: UInt64
    public let validBefore: UInt64
    /// The CA key that signed it.
    public let signatureKey: SSHPublicKey
    /// The bare key's own blob ("ssh-ed25519" ‖ key), re-encoded from the
    /// certificate's fields.
    public let plainBlob: [UInt8]

    public var isUserCertificate: Bool { type == 1 }

    /// Whether `date` falls inside the validity window.
    public func isValid(at date: Date) -> Bool {
        let now = UInt64(max(0, date.timeIntervalSince1970))
        return now >= validAfter && now < validBefore
    }
}

public enum SSHCertificate {
    public static let suffix = "-cert-v01@openssh.com"

    /// "ssh-ed25519-cert-v01@openssh.com" → "ssh-ed25519"; nil for a non-certificate type.
    public static func baseKeyType(of certType: String) -> String? {
        guard certType.hasSuffix(suffix) else { return nil }
        let base = String(certType.dropLast(suffix.count))
        return ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"]
            .contains(base) ? base : nil
    }

    /// The USERAUTH algorithm name for a certificate whose bare key would
    /// sign as `baseAlgorithm`: "rsa-sha2-512" → "rsa-sha2-512-cert-v01@openssh.com".
    public static func algorithm(forBase baseAlgorithm: String) -> String { baseAlgorithm + suffix }

    /// The signature algorithm behind a certificate algorithm name; the name
    /// itself when it is not one.
    public static func baseAlgorithm(of algorithm: String) -> String {
        algorithm.hasSuffix(suffix) ? String(algorithm.dropLast(suffix.count)) : algorithm
    }
}

extension SSHPublicKey {
    /// The certificate's details; nil for a bare key.
    public var certificate: SSHCertificateInfo? { certificateInfo }

    public init(certificateBlob blob: [UInt8]) throws(SSHKeyError) {
        var r = SSHReader(blob)
        do {
            let certType = try r.readUTF8()
            guard let base = SSHCertificate.baseKeyType(of: certType) else {
                throw SSHKeyError.unsupportedKeyType(certType)
            }
            _ = try r.readString()                         // nonce
            var plain = SSHWriter()
            plain.writeString(base)
            switch base {
            case "ssh-ed25519":
                plain.writeString(try r.readString())
            case "ssh-rsa":
                plain.writeString(try r.readString())      // e (mpint, kept as sent)
                plain.writeString(try r.readString())      // n
            default:
                plain.writeString(try r.readString())      // curve name
                plain.writeString(try r.readString())      // point
            }
            let bare = try SSHPublicKey(blob: plain.bytes)  // checks the key's shape
            let serial = try r.readUInt64()
            let type = try r.readUInt32()
            let keyID = try r.readUTF8()
            var principalReader = SSHReader(try r.readString())
            var principals: [String] = []
            while !principalReader.isAtEnd { principals.append(try principalReader.readUTF8()) }
            let validAfter = try r.readUInt64()
            let validBefore = try r.readUInt64()
            _ = try r.readString()                         // critical options
            _ = try r.readString()                         // extensions
            _ = try r.readString()                         // reserved
            let caKey = try SSHPublicKey(blob: try r.readString())
            _ = try r.readString()                         // CA signature
            guard r.isAtEnd else { throw SSHKeyError.malformed("trailing bytes after the certificate") }
            guard type == 1 || type == 2 else { throw SSHKeyError.malformed("certificate type \(type)") }
            self.init(keyType: certType, blob: blob, kind: bare.kind,
                      certificate: SSHCertificateInfo(type: type, serial: serial, keyID: keyID, principals: principals,
                                                      validAfter: validAfter, validBefore: validBefore,
                                                      signatureKey: caKey, plainBlob: plain.bytes))
        } catch let error as SSHKeyError {
            throw error
        } catch {
            throw .malformed("truncated certificate")
        }
    }

    /// Parses a `-cert.pub` line: "<cert type> <base64> [comment]".
    public init(certificateLine line: String) throws(SSHKeyError) {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2 else { throw .malformed("expected \"<type> <base64>\"") }
        guard let data = Data(base64Encoded: String(fields[1])) else { throw .malformed("certificate is not valid base64") }
        try self.init(certificateBlob: Array(data))
        guard keyType == fields[0] else { throw .malformed("line says \(fields[0]) but the certificate is \(keyType)") }
    }
}

/// Offers a certificate and signs with the private key behind it. The
/// algorithm the server is asked for is the certificate one
/// ("ssh-ed25519-cert-v01@openssh.com"); the signature inside is the bare
/// key's ("ssh-ed25519"), as OpenSSH writes it.
public final class CertificateSigner: SSHSigner {
    public let publicKey: SSHPublicKey
    public let label: String
    private let inner: SSHSigner

    /// Fails when the certificate is not for `inner`'s key.
    public init(certificate: SSHPublicKey, signer inner: SSHSigner, label: String) throws(SignerError) {
        guard certificate.certificate != nil else { throw .keyRejected("not a certificate") }
        guard certificate.sameKey(as: inner.publicKey) else {
            throw .keyRejected("the certificate is for a different key")
        }
        self.publicKey = certificate
        self.inner = inner
        self.label = label
    }

    public func sign(_ data: [UInt8], algorithm: String) throws(SignerError) -> [UInt8] {
        try inner.sign(data, algorithm: SSHCertificate.baseAlgorithm(of: algorithm))
    }
}
