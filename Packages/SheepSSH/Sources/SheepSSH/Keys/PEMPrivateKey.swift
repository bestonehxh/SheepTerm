// The older private key files libssh read through OpenSSL:
//
//   -----BEGIN RSA PRIVATE KEY-----   PKCS#1 RSAPrivateKey
//   -----BEGIN EC PRIVATE KEY-----    SEC1 ECPrivateKey
//   -----BEGIN PRIVATE KEY-----       PKCS#8 (RSA, EC P-256/384/521, Ed25519)
//
// The first two may carry OpenSSL's legacy encryption
// ("Proc-Type: 4,ENCRYPTED" + "DEK-Info: AES-128-CBC,<iv>"; key =
// EVP_BytesToKey(MD5, salt = first 8 IV bytes, 1 iteration)). Encrypted
// PKCS#8 ("ENCRYPTED PRIVATE KEY", PBES2) and DSA keys are refused with a
// message saying so; `ssh-keygen -p -f <file>` converts them to the OpenSSH
// format, which is read by `OpenSSHPrivateKeyFile`.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum PEMPrivateKey {
    /// Any private key file SheepSSH reads, in either format.
    public static func isEncrypted(_ text: String) -> Bool {
        if OpenSSHPrivateKeyFile.isOpenSSHFormat(text) {
            return (try? OpenSSHPrivateKeyFile(text: text))?.isEncrypted ?? false
        }
        return text.contains("Proc-Type: 4,ENCRYPTED") || text.contains("BEGIN ENCRYPTED PRIVATE KEY")
    }

    /// Parses (and decrypts) a private key file of either format.
    public static func load(_ text: String, passphrase: [UInt8]?) throws(SSHKeyError) -> SSHPrivateKey {
        if OpenSSHPrivateKeyFile.isOpenSSHFormat(text) {
            return try OpenSSHPrivateKeyFile(text: text).decrypt(passphrase: passphrase)
        }
        guard let begin = text.range(of: "-----BEGIN "),
              let labelEnd = text.range(of: "-----", range: begin.upperBound..<text.endIndex) else {
            throw .malformed("not a private key file")
        }
        let label = String(text[begin.upperBound..<labelEnd.lowerBound])
        guard let end = text.range(of: "-----END \(label)-----", range: labelEnd.upperBound..<text.endIndex) else {
            throw .malformed("no END line for \(label)")
        }
        var headers: [String: String] = [:]
        var bodyLines: [Substring] = []
        for line in text[labelEnd.upperBound..<end.lowerBound].split(whereSeparator: \.isNewline) {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].trimmingCharacters(in: .whitespaces)] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                bodyLines.append(line)
            }
        }
        guard let data = Data(base64Encoded: bodyLines.joined().filter { !$0.isWhitespace }) else {
            throw .malformed("key body is not valid base64")
        }
        var der = Array(data)
        if headers["Proc-Type"]?.contains("ENCRYPTED") == true {
            guard let passphrase, !passphrase.isEmpty else { throw .passphraseRequired }
            der = try decryptLegacy(der, dekInfo: headers["DEK-Info"] ?? "", passphrase: passphrase)
        }
        switch label {
        case "RSA PRIVATE KEY": return try parsePKCS1(der)
        case "EC PRIVATE KEY": return try parseSEC1(der, curveFromAlgorithm: nil)
        case "PRIVATE KEY": return try parsePKCS8(der)
        case "ENCRYPTED PRIVATE KEY":
            throw .unsupportedCipher("encrypted PKCS#8 — convert with: ssh-keygen -p -f <file>")
        case "DSA PRIVATE KEY": throw .unsupportedKeyType("ssh-dss (DSA user keys)")
        default: throw .malformed("unknown key file type \"\(label)\"")
        }
    }

    // MARK: Legacy OpenSSL encryption

    static func decryptLegacy(_ der: [UInt8], dekInfo: String, passphrase: [UInt8]) throws(SSHKeyError) -> [UInt8] {
        let parts = dekInfo.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // Even length checked first: bigEndianBytes(count:) traps on a value
        // that needs more bytes than asked ("ABC" is 0x0ABC, two bytes).
        guard parts.count == 2, parts[1].count % 2 == 0, parts[1].count >= 16,
              let iv = BigUInt(hex: parts[1]).map({ $0.bigEndianBytes(count: parts[1].count / 2) }) else {
            throw .malformed("bad DEK-Info header")
        }
        let (keySize, algorithm): (Int, BlockCipherStream.Algorithm)
        switch parts[0].uppercased() {
        case "AES-128-CBC": (keySize, algorithm) = (16, .aes)
        case "AES-192-CBC": (keySize, algorithm) = (24, .aes)
        case "AES-256-CBC": (keySize, algorithm) = (32, .aes)
        case "DES-EDE3-CBC": (keySize, algorithm) = (24, .tripleDES)
        default: throw .unsupportedCipher(parts[0])
        }
        guard iv.count == (algorithm == .aes ? 16 : 8) else { throw .malformed("bad DEK-Info header") }
        // EVP_BytesToKey with MD5 and one iteration.
        let salt = Array(iv[0..<8])
        var material: [UInt8] = []
        var previous: [UInt8] = []
        while material.count < keySize {
            previous = SSHHash.md5.hash(previous + passphrase + salt)
            material += previous
        }
        let key = Array(material[0..<keySize])
        var plain: [UInt8]
        do {
            plain = try BlockCipherStream(mode: .cbcDecrypt, algorithm: algorithm, key: key, iv: iv).process(der)
        } catch {
            throw .unsupportedCipher(parts[0])
        }
        // PKCS#7 padding: a wrong passphrase almost never produces a valid one.
        guard let pad = plain.last, pad >= 1, Int(pad) <= iv.count, Int(pad) <= plain.count,
              plain.suffix(Int(pad)).allSatisfy({ $0 == pad }) else {
            throw .wrongPassphrase
        }
        plain.removeLast(Int(pad))
        return plain
    }

    // MARK: Formats

    static func parsePKCS1(_ der: [UInt8]) throws(SSHKeyError) -> SSHPrivateKey {
        do {
            var outer = DERReader(der)
            var seq = try outer.readSequence()
            guard try seq.readInteger() == BigUInt() else { throw SSHKeyError.malformed("multi-prime RSA key") }
            let n = try seq.readInteger(), e = try seq.readInteger(), d = try seq.readInteger()
            let p = try seq.readInteger(), q = try seq.readInteger()
            _ = try seq.readInteger(); _ = try seq.readInteger()        // dP, dQ (recomputed when needed)
            let iqmp = try seq.readInteger()
            // p, q > 1: p = 1, q = n multiplies fine and would divide by
            // zero (d mod (p − 1)) when the signer is built.
            guard p > BigUInt(1), q > BigUInt(1), p * q == n else {
                throw SSHKeyError.malformed("RSA key whose primes do not multiply to n")
            }
            var w = SSHWriter()
            w.writeString("ssh-rsa")
            w.writeMPInt(e)
            w.writeMPInt(n)
            let pub = try SSHPublicKey(blob: w.bytes)
            return SSHPrivateKey(kind: .rsa(modulus: n, publicExponent: e, privateExponent: d, iqmp: iqmp, p: p, q: q),
                                 publicKey: pub, comment: "")
        } catch let error as SSHKeyError {
            throw error
        } catch {
            throw .malformed("RSA key is not valid PKCS#1 DER")
        }
    }

    static let oidRSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    static let oidEC: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    static let oidEd25519: [UInt8] = [0x2B, 0x65, 0x70]
    static let curveOIDs: [[UInt8]: ECDSACurve] = [
        [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]: .nistp256,
        [0x2B, 0x81, 0x04, 0x00, 0x22]: .nistp384,
        [0x2B, 0x81, 0x04, 0x00, 0x23]: .nistp521,
    ]

    static func parseSEC1(_ der: [UInt8], curveFromAlgorithm: ECDSACurve?) throws(SSHKeyError) -> SSHPrivateKey {
        do {
            var outer = DERReader(der)
            var seq = try outer.readSequence()
            guard try seq.readInteger() == BigUInt(1) else { throw SSHKeyError.malformed("unknown EC key version") }
            let scalar = try seq.readOctetString()
            var curve = curveFromAlgorithm
            while !seq.isAtEnd {
                let (tag, content) = try seq.readAny()
                if tag == 0xA0 {
                    var params = DERReader(content)
                    let oid = try params.readOID()
                    guard let named = curveOIDs[oid] else { throw SSHKeyError.unsupportedKeyType("EC curve \(oid)") }
                    curve = named
                }
            }
            guard let curve else { throw SSHKeyError.malformed("EC key without a named curve") }
            return try ecdsaKey(curve: curve, scalar: scalar)
        } catch let error as SSHKeyError {
            throw error
        } catch {
            throw .malformed("EC key is not valid SEC1 DER")
        }
    }

    static func parsePKCS8(_ der: [UInt8]) throws(SSHKeyError) -> SSHPrivateKey {
        do {
            var outer = DERReader(der)
            var seq = try outer.readSequence()
            _ = try seq.readInteger()
            var algorithm = try seq.readSequence()
            let oid = try algorithm.readOID()
            let inner = try seq.readOctetString()
            switch oid {
            case oidRSA:
                return try parsePKCS1(inner)
            case oidEC:
                let curveOID = try algorithm.readOID()
                guard let curve = curveOIDs[curveOID] else { throw SSHKeyError.unsupportedKeyType("EC curve") }
                return try parseSEC1(inner, curveFromAlgorithm: curve)
            case oidEd25519:
                var octets = DERReader(inner)
                let seed = try octets.readOctetString()
                guard seed.count == 32,
                      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
                    throw SSHKeyError.malformed("Ed25519 key is not 32 bytes")
                }
                var w = SSHWriter()
                w.writeString("ssh-ed25519")
                w.writeString(Array(key.publicKey.rawRepresentation))
                return SSHPrivateKey(kind: .ed25519(seed: seed), publicKey: try SSHPublicKey(blob: w.bytes), comment: "")
            default:
                throw SSHKeyError.unsupportedKeyType("PKCS#8 algorithm \(oid)")
            }
        } catch let error as SSHKeyError {
            throw error
        } catch {
            throw .malformed("key is not valid PKCS#8 DER")
        }
    }

    /// Derives the public point from the scalar (SEC1 may omit it).
    static func ecdsaKey(curve: ECDSACurve, scalar raw: [UInt8]) throws(SSHKeyError) -> SSHPrivateKey {
        let trimmed = Array(raw.drop(while: { $0 == 0 }))
        guard trimmed.count <= curve.coordinateSize else { throw .malformed("EC scalar too long") }
        let scalar = [UInt8](repeating: 0, count: curve.coordinateSize - trimmed.count) + trimmed
        let point: [UInt8]
        switch curve {
        case .nistp256:
            guard let k = try? P256.Signing.PrivateKey(rawRepresentation: scalar) else { throw .malformed("bad P-256 scalar") }
            point = Array(k.publicKey.x963Representation)
        case .nistp384:
            guard let k = try? P384.Signing.PrivateKey(rawRepresentation: scalar) else { throw .malformed("bad P-384 scalar") }
            point = Array(k.publicKey.x963Representation)
        case .nistp521:
            guard let k = try? P521.Signing.PrivateKey(rawRepresentation: scalar) else { throw .malformed("bad P-521 scalar") }
            point = Array(k.publicKey.x963Representation)
        }
        var w = SSHWriter()
        w.writeString(curve.keyType)
        w.writeString(curve.rawValue)
        w.writeString(point)
        return SSHPrivateKey(kind: .ecdsa(curve: curve, scalar: scalar), publicKey: try SSHPublicKey(blob: w.bytes), comment: "")
    }
}

/// Just enough DER for private key files: definite lengths only.
struct DERReader {
    enum Failure: Error { case malformed }

    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readAny() throws -> (tag: UInt8, content: [UInt8]) {
        guard offset + 2 <= bytes.count else { throw Failure.malformed }
        let tag = bytes[offset]
        var length = Int(bytes[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 4, offset + count <= bytes.count else { throw Failure.malformed }
            length = 0
            for _ in 0..<count { length = length << 8 | Int(bytes[offset]); offset += 1 }
        }
        guard length >= 0, offset + length <= bytes.count else { throw Failure.malformed }
        defer { offset += length }
        return (tag, Array(bytes[offset..<offset + length]))
    }

    mutating func read(tag expected: UInt8) throws -> [UInt8] {
        let (tag, content) = try readAny()
        guard tag == expected else { throw Failure.malformed }
        return content
    }

    mutating func readSequence() throws -> DERReader { DERReader(try read(tag: 0x30)) }
    mutating func readOctetString() throws -> [UInt8] { try read(tag: 0x04) }
    mutating func readOID() throws -> [UInt8] { try read(tag: 0x06) }

    /// A non-negative INTEGER.
    mutating func readInteger() throws -> BigUInt {
        let content = try read(tag: 0x02)
        guard let first = content.first, first & 0x80 == 0 else { throw Failure.malformed }
        return BigUInt(bigEndian: content)
    }
}
