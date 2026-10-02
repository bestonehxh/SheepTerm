// OpenSSH's own private key file format, "openssh-key-v1" (OpenSSH
// PROTOCOL.key) — what `ssh-keygen` has written by default since 7.8:
//
//   -----BEGIN OPENSSH PRIVATE KEY-----  base64 of:
//   "openssh-key-v1\0"
//   string ciphername      "none" | aes256-ctr | … | chacha20-poly1305@openssh.com
//   string kdfname         "none" | "bcrypt"
//   string kdfoptions      bcrypt: string salt, uint32 rounds
//   uint32 number of keys  (always 1 in practice; more is refused)
//   string public key blob
//   string private section (encrypted unless ciphername is "none")
//   [auth tag, for the AEAD ciphers, right after that string]
//
// The private section, once decrypted:
//   uint32 check, uint32 check (equal — a mismatch means a wrong passphrase)
//   string keytype, <type-specific fields>, string comment
//   padding 1, 2, 3 … up to the cipher block size
//
// The older PEM formats (-----BEGIN RSA/EC PRIVATE KEY-----, PKCS#8) are a
// separate parser, not this one.
import Foundation

public struct SSHPrivateKey: Sendable {
    public enum Kind: Sendable {
        /// 32-byte seed (what CryptoKit's Curve25519.Signing takes).
        case ed25519(seed: [UInt8])
        /// Private scalar, left-padded to the curve's coordinate size.
        case ecdsa(curve: ECDSACurve, scalar: [UInt8])
        case rsa(modulus: BigUInt, publicExponent: BigUInt, privateExponent: BigUInt,
                 iqmp: BigUInt, p: BigUInt, q: BigUInt)
    }

    public let kind: Kind
    public let publicKey: SSHPublicKey
    public let comment: String
}

public struct OpenSSHPrivateKeyFile: Sendable {
    public static let armorBegin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    public static let armorEnd = "-----END OPENSSH PRIVATE KEY-----"
    static let magic = Array("openssh-key-v1".utf8) + [0]

    public let cipherName: String
    public let kdfName: String
    let kdfSalt: [UInt8]
    let kdfRounds: Int
    /// The public half, readable without the passphrase.
    public let publicKey: SSHPublicKey
    let privateSection: [UInt8]
    /// The AEAD tag after the private section (empty for the other ciphers).
    let tag: [UInt8]

    public var isEncrypted: Bool { cipherName != "none" }

    /// True when `text` looks like this format (so a caller can route PEM
    /// files elsewhere without a parse error).
    public static func isOpenSSHFormat(_ text: String) -> Bool {
        text.contains(armorBegin)
    }

    public init(text: String) throws(SSHKeyError) {
        guard let begin = text.range(of: Self.armorBegin),
              let end = text.range(of: Self.armorEnd, range: begin.upperBound..<text.endIndex) else {
            throw .malformed("not an OpenSSH private key (no BEGIN/END OPENSSH PRIVATE KEY lines)")
        }
        let body = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else {
            throw .malformed("key body is not valid base64")
        }
        try self.init(binary: Array(data))
    }

    public init(binary: [UInt8]) throws(SSHKeyError) {
        guard binary.count > Self.magic.count, Array(binary[0..<Self.magic.count]) == Self.magic else {
            throw .malformed("missing openssh-key-v1 magic")
        }
        var r = SSHReader(binary, from: Self.magic.count)
        do {
            cipherName = try r.readUTF8()
            kdfName = try r.readUTF8()
            var options = SSHReader(try r.readString())
            switch kdfName {
            case "none":
                kdfSalt = []
                kdfRounds = 0
            case "bcrypt":
                kdfSalt = try options.readString()
                let rounds = try options.readUInt32()
                // OpenSSH's default is 16; ~10k already takes minutes. A
                // file demanding more is refused rather than hanging the app.
                guard rounds >= 1, rounds <= 100_000 else {
                    throw SSHKeyError.malformed("bcrypt rounds \(rounds) out of range")
                }
                kdfRounds = Int(rounds)
            default:
                throw SSHKeyError.unsupportedKDF(kdfName)
            }
            guard options.isAtEnd else { throw SSHKeyError.malformed("trailing bytes in kdf options") }
            if cipherName == "none", kdfName != "none" {
                throw SSHKeyError.malformed("unencrypted key with a KDF")
            }
            if cipherName != "none", kdfName == "none" {
                throw SSHKeyError.malformed("encrypted key without a KDF")
            }
            let count = try r.readUInt32()
            guard count == 1 else { throw SSHKeyError.malformed("file holds \(count) keys; exactly one is supported") }
            publicKey = try SSHPublicKey(blob: try r.readString())
            privateSection = try r.readString()
            let spec = try Self.cipherSpec(cipherName)
            tag = try r.readBytes(spec.tagSize)
            guard r.isAtEnd else { throw SSHKeyError.malformed("trailing bytes after the private section") }
            guard privateSection.count % spec.blockSize == 0 else {
                throw SSHKeyError.malformed("private section is not a whole number of cipher blocks")
            }
        } catch let error as SSHKeyError {
            throw error
        } catch {
            throw .malformed("truncated key file")
        }
    }

    struct CipherSpec {
        let keySize: Int
        let ivSize: Int
        let blockSize: Int
        let tagSize: Int
    }

    static func cipherSpec(_ name: String) throws(SSHKeyError) -> CipherSpec {
        switch name {
        case "none": return CipherSpec(keySize: 0, ivSize: 0, blockSize: 8, tagSize: 0)
        case "aes128-ctr", "aes128-cbc": return CipherSpec(keySize: 16, ivSize: 16, blockSize: 16, tagSize: 0)
        case "aes192-ctr", "aes192-cbc": return CipherSpec(keySize: 24, ivSize: 16, blockSize: 16, tagSize: 0)
        case "aes256-ctr", "aes256-cbc": return CipherSpec(keySize: 32, ivSize: 16, blockSize: 16, tagSize: 0)
        case "aes128-gcm@openssh.com": return CipherSpec(keySize: 16, ivSize: 12, blockSize: 16, tagSize: 16)
        case "aes256-gcm@openssh.com": return CipherSpec(keySize: 32, ivSize: 12, blockSize: 16, tagSize: 16)
        case "chacha20-poly1305@openssh.com": return CipherSpec(keySize: 64, ivSize: 0, blockSize: 8, tagSize: 16)
        default: throw .unsupportedCipher(name)
        }
    }

    /// Decrypts (when needed) and parses the private key. `passphrase` is
    /// ignored for an unencrypted file.
    public func decrypt(passphrase: [UInt8]?) throws(SSHKeyError) -> SSHPrivateKey {
        var plain: [UInt8]
        if isEncrypted {
            guard let passphrase, !passphrase.isEmpty else { throw .passphraseRequired }
            let spec = try Self.cipherSpec(cipherName)
            var material: [UInt8]
            do {
                material = try BcryptPBKDF.derive(password: passphrase, salt: kdfSalt, rounds: kdfRounds,
                                                  keyLength: spec.keySize + spec.ivSize)
            } catch {
                throw .malformed("bcrypt parameters rejected")
            }
            defer { for i in material.indices { material[i] = 0 } }
            let key = Array(material[0..<spec.keySize])
            let iv = Array(material[spec.keySize...])
            do {
                switch cipherName {
                case "chacha20-poly1305@openssh.com":
                    plain = try ChaChaPolyOpenSSH(key: key)
                        .open(sequenceNumber: 0, aadLength: 0, sealed: privateSection + tag)
                case "aes128-gcm@openssh.com", "aes256-gcm@openssh.com":
                    plain = try AESGCM.open(key: key, nonce: iv, ciphertext: privateSection, tag: tag)
                case let name where name.hasSuffix("-ctr"):
                    plain = try AESStream(mode: .ctr, key: key, iv: iv).process(privateSection)
                default:
                    plain = try AESStream(mode: .cbcDecrypt, key: key, iv: iv).process(privateSection)
                }
            } catch {
                // An AEAD tag failure is the AEAD ciphers' way of saying
                // "wrong passphrase"; CTR/CBC find out at the check words.
                throw .wrongPassphrase
            }
        } else {
            plain = privateSection
        }
        defer { for i in plain.indices { plain[i] = 0 } }
        return try Self.parsePrivateSection(plain, expectedPublic: publicKey,
                                            blockSize: try Self.cipherSpec(cipherName).blockSize)
    }

    static func parsePrivateSection(_ plain: [UInt8], expectedPublic: SSHPublicKey, blockSize: Int) throws(SSHKeyError) -> SSHPrivateKey {
        var r = SSHReader(plain)
        do {
            let check1 = try r.readUInt32()
            let check2 = try r.readUInt32()
            guard check1 == check2 else { throw SSHKeyError.wrongPassphrase }
            let type = try r.readUTF8()
            guard type == expectedPublic.keyType else {
                throw SSHKeyError.malformed("private key is \(type) but the public key is \(expectedPublic.keyType)")
            }
            let kind: SSHPrivateKey.Kind
            switch type {
            case "ssh-ed25519":
                let pk = try r.readString()
                let sk = try r.readString()
                // sk is seed ‖ public key (the NaCl layout).
                guard pk.count == 32, sk.count == 64, Array(sk[32...]) == pk,
                      case .ed25519(let expected) = expectedPublic.kind, expected == pk else {
                    throw SSHKeyError.malformed("ed25519 private key does not match its public key")
                }
                kind = .ed25519(seed: Array(sk[0..<32]))
            case "ssh-rsa":
                let n = try r.readMPInt(), e = try r.readMPInt(), d = try r.readMPInt()
                let iqmp = try r.readMPInt(), p = try r.readMPInt(), q = try r.readMPInt()
                guard case .rsa(let pe, let pn) = expectedPublic.kind, pe == e, pn == n,
                      p > BigUInt(1), q > BigUInt(1), p * q == n else {
                    throw SSHKeyError.malformed("RSA private key does not match its public key")
                }
                kind = .rsa(modulus: n, publicExponent: e, privateExponent: d, iqmp: iqmp, p: p, q: q)
            default:
                guard let curve = ECDSACurve.allCases.first(where: { $0.keyType == type }) else {
                    throw SSHKeyError.unsupportedKeyType(type)
                }
                let curveName = try r.readUTF8()
                let point = try r.readString()
                let d = try r.readMPIntBytes()
                guard curveName == curve.rawValue, d.count <= curve.coordinateSize,
                      case .ecdsa(_, let expected) = expectedPublic.kind, expected == point else {
                    throw SSHKeyError.malformed("\(type) private key does not match its public key")
                }
                kind = .ecdsa(curve: curve, scalar: [UInt8](repeating: 0, count: curve.coordinateSize - d.count) + d)
            }
            let comment = String(decoding: try r.readString(), as: UTF8.self)
            // Padding is 1, 2, 3, … and brings the section to a block multiple.
            var expectedPad: UInt8 = 1
            while !r.isAtEnd {
                guard try r.readByte() == expectedPad else { throw SSHKeyError.malformed("bad padding in the private section") }
                expectedPad &+= 1
            }
            guard Int(expectedPad) - 1 < blockSize else { throw SSHKeyError.malformed("padding longer than a block") }
            return SSHPrivateKey(kind: kind, publicKey: expectedPublic, comment: comment)
        } catch let error as SSHKeyError {
            throw error
        } catch {
            throw .malformed("truncated private section")
        }
    }
}
