// Key exchange methods. Each one produces the shared secret K (in the wire
// encoding the exchange hash and key derivation use) and the exchange hash H;
// the transport then checks the host key's signature over H.
//
//   H = HASH(V_C ‖ V_S ‖ I_C ‖ I_S ‖ K_S ‖ <method fields> ‖ K)
//
// with V = version strings, I = KEXINIT payloads, K_S = host key blob, all as
// SSH strings. K is an mpint for DH/ECDH/X25519 and a string for the hybrid
// post-quantum method.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum KexError: Error, Equatable, Sendable {
    case unexpectedMessage(UInt8)
    case malformed(String)
    case invalidPeerPublicValue
    case groupRejected(String)
    /// A group-exchange prime below the range asked for (legacy mode, which
    /// accepts 1024-bit groups, is the fix).
    case groupTooSmall(bits: Int)
}

/// The fields every exchange hash starts with.
struct ExchangeHashPrefix {
    let clientVersion: String
    let serverVersion: [UInt8]
    let clientKexInit: [UInt8]
    let serverKexInit: [UInt8]

    func write(into w: inout SSHWriter) {
        w.writeString(clientVersion)
        w.writeString(serverVersion)
        w.writeString(clientKexInit)
        w.writeString(serverKexInit)
    }
}

struct KexOutcome {
    /// K in its wire encoding (length prefix included).
    let encodedSecret: [UInt8]
    let exchangeHash: [UInt8]
    let hostKeyBlob: [UInt8]
    let signatureBlob: [UInt8]
}

enum KexStep {
    case send([UInt8])
    case done(KexOutcome)
}

protocol KexMethod: AnyObject {
    /// The first message(s) the client sends once the method is chosen.
    func start() throws(KexError) -> [UInt8]
    func handle(_ payload: [UInt8]) throws(KexError) -> KexStep
}

enum KexFactory {
    static func make(_ algorithm: KexAlgorithm, prefix: ExchangeHashPrefix, exponentBits: Int,
                     gexBits: ClosedRange<Int>, gexPreferred: Int) -> KexMethod {
        switch algorithm {
        case .mlkem768x25519:
            return HybridMLKEM(prefix: prefix)
        case .curve25519, .curve25519LibSSH:
            return Curve25519Kex(prefix: prefix)
        case .ecdhP256: return ECDHKex<P256.KeyAgreement.PrivateKey>(prefix: prefix, hash: .sha256)
        case .ecdhP384: return ECDHKex<P384.KeyAgreement.PrivateKey>(prefix: prefix, hash: .sha384)
        case .ecdhP521: return ECDHKex<P521.KeyAgreement.PrivateKey>(prefix: prefix, hash: .sha512)
        case .dhGroup1: return FixedGroupDH(prefix: prefix, group: .group1, hash: .sha1, exponentBits: exponentBits)
        case .dhGroup14SHA1: return FixedGroupDH(prefix: prefix, group: .group14, hash: .sha1, exponentBits: exponentBits)
        case .dhGroup14SHA256: return FixedGroupDH(prefix: prefix, group: .group14, hash: .sha256, exponentBits: exponentBits)
        case .dhGroup16: return FixedGroupDH(prefix: prefix, group: .group16, hash: .sha512, exponentBits: exponentBits)
        case .dhGroup18: return FixedGroupDH(prefix: prefix, group: .group18, hash: .sha512, exponentBits: exponentBits)
        case .dhGexSHA1:
            return GroupExchangeDH(prefix: prefix, hash: .sha1, bits: gexBits, preferred: gexPreferred, exponentBits: exponentBits)
        case .dhGexSHA256:
            return GroupExchangeDH(prefix: prefix, hash: .sha256, bits: gexBits, preferred: gexPreferred, exponentBits: exponentBits)
        }
    }
}

/// Reads KEXDH_REPLY-shaped messages: string K_S, <value>, string signature.
private func readReply(_ payload: [UInt8], expect: UInt8, value: (inout SSHReader) throws -> [UInt8]) throws(KexError)
-> (hostKey: [UInt8], value: [UInt8], signature: [UInt8]) {
    var r = SSHReader(payload)
    do {
        let type = try r.readByte()
        guard type == expect else { throw KexError.unexpectedMessage(type) }
        let hostKey = try r.readString()
        let v = try value(&r)
        let signature = try r.readString()
        guard r.isAtEnd else { throw KexError.malformed("trailing bytes in the key exchange reply") }
        return (hostKey, v, signature)
    } catch let error as KexError {
        throw error
    } catch {
        throw .malformed("truncated key exchange reply")
    }
}

// MARK: - X25519 (RFC 8731)

final class Curve25519Kex: KexMethod {
    let prefix: ExchangeHashPrefix
    let privateKey = Curve25519.KeyAgreement.PrivateKey()

    init(prefix: ExchangeHashPrefix) { self.prefix = prefix }

    func start() throws(KexError) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(SSHMessage.kexDHInit)
        w.writeString(Array(privateKey.publicKey.rawRepresentation))
        return w.bytes
    }

    func handle(_ payload: [UInt8]) throws(KexError) -> KexStep {
        let reply = try readReply(payload, expect: SSHMessage.kexDHReply) { try $0.readString() }
        guard reply.value.count == 32,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: reply.value),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else {
            throw .invalidPeerPublicValue
        }
        let secret = shared.withUnsafeBytes { Array($0) }
        // An all-zero result means a low-order point (RFC 7748 §6.1).
        guard !isAllZero(secret) else { throw .invalidPeerPublicValue }
        var k = SSHWriter()
        k.writeMPInt(unsigned: secret)
        var h = SSHWriter(capacity: 1024)
        prefix.write(into: &h)
        h.writeString(reply.hostKey)
        h.writeString(Array(privateKey.publicKey.rawRepresentation))
        h.writeString(reply.value)
        h.writeBytes(k.bytes)
        return .done(KexOutcome(encodedSecret: k.bytes, exchangeHash: SSHHash.sha256.hash(h.bytes),
                                hostKeyBlob: reply.hostKey, signatureBlob: reply.signature))
    }
}

// MARK: - ECDH over NIST curves (RFC 5656)

protocol NISTKeyAgreementKey {
    static func generate() -> Self
    var x963PublicKey: [UInt8] { get }
    func sharedX(withX963 peer: [UInt8]) -> [UInt8]?
}

extension P256.KeyAgreement.PrivateKey: NISTKeyAgreementKey {
    static func generate() -> Self { Self() }
    var x963PublicKey: [UInt8] { Array(publicKey.x963Representation) }
    func sharedX(withX963 peer: [UInt8]) -> [UInt8]? {
        guard let key = try? P256.KeyAgreement.PublicKey(x963Representation: peer),
              let s = try? sharedSecretFromKeyAgreement(with: key) else { return nil }
        return s.withUnsafeBytes { Array($0) }
    }
}

extension P384.KeyAgreement.PrivateKey: NISTKeyAgreementKey {
    static func generate() -> Self { Self() }
    var x963PublicKey: [UInt8] { Array(publicKey.x963Representation) }
    func sharedX(withX963 peer: [UInt8]) -> [UInt8]? {
        guard let key = try? P384.KeyAgreement.PublicKey(x963Representation: peer),
              let s = try? sharedSecretFromKeyAgreement(with: key) else { return nil }
        return s.withUnsafeBytes { Array($0) }
    }
}

extension P521.KeyAgreement.PrivateKey: NISTKeyAgreementKey {
    static func generate() -> Self { Self() }
    var x963PublicKey: [UInt8] { Array(publicKey.x963Representation) }
    func sharedX(withX963 peer: [UInt8]) -> [UInt8]? {
        guard let key = try? P521.KeyAgreement.PublicKey(x963Representation: peer),
              let s = try? sharedSecretFromKeyAgreement(with: key) else { return nil }
        return s.withUnsafeBytes { Array($0) }
    }
}

final class ECDHKex<Key: NISTKeyAgreementKey>: KexMethod {
    let prefix: ExchangeHashPrefix
    let hash: SSHHash
    let privateKey = Key.generate()

    init(prefix: ExchangeHashPrefix, hash: SSHHash) {
        self.prefix = prefix
        self.hash = hash
    }

    func start() throws(KexError) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(SSHMessage.kexDHInit)
        w.writeString(privateKey.x963PublicKey)
        return w.bytes
    }

    func handle(_ payload: [UInt8]) throws(KexError) -> KexStep {
        let reply = try readReply(payload, expect: SSHMessage.kexDHReply) { try $0.readString() }
        // CryptoKit refuses points that are not on the curve.
        guard let secret = privateKey.sharedX(withX963: reply.value) else { throw .invalidPeerPublicValue }
        var k = SSHWriter()
        k.writeMPInt(unsigned: secret)
        var h = SSHWriter(capacity: 1024)
        prefix.write(into: &h)
        h.writeString(reply.hostKey)
        h.writeString(privateKey.x963PublicKey)
        h.writeString(reply.value)
        h.writeBytes(k.bytes)
        return .done(KexOutcome(encodedSecret: k.bytes, exchangeHash: hash.hash(h.bytes),
                                hostKeyBlob: reply.hostKey, signatureBlob: reply.signature))
    }
}

// MARK: - Finite-field DH, fixed groups (RFC 4253 §8, RFC 8268)

/// A random private exponent of exactly `bits` bits or fewer, at least 2.
func randomExponent(bits: Int) -> BigUInt {
    var rng = SystemRandomNumberGenerator()
    while true {
        var limbs = (0..<((bits + 63) / 64)).map { _ in rng.next() as UInt64 }
        let extra = limbs.count * 64 - bits
        if extra > 0 { limbs[limbs.count - 1] &= UInt64.max >> UInt64(extra) }
        let x = BigUInt(limbs: limbs)
        if x > BigUInt(1) { return x }
    }
}

final class FixedGroupDH: KexMethod {
    let prefix: ExchangeHashPrefix
    let group: DHGroup
    let hash: SSHHash
    let exponentBits: Int
    let x: BigUInt
    let e: BigUInt

    init(prefix: ExchangeHashPrefix, group: DHGroup, hash: SSHHash, exponentBits: Int) {
        self.prefix = prefix
        self.group = group
        self.hash = hash
        self.exponentBits = min(exponentBits, group.bits - 1)
        x = randomExponent(bits: self.exponentBits)
        e = group.publicValue(privateExponent: x, exponentBits: self.exponentBits)
    }

    func start() throws(KexError) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(SSHMessage.kexDHInit)
        w.writeMPInt(e)
        return w.bytes
    }

    func handle(_ payload: [UInt8]) throws(KexError) -> KexStep {
        let reply = try readReply(payload, expect: SSHMessage.kexDHReply) { try $0.readMPIntBytes() }
        let f = BigUInt(bigEndian: reply.value)
        guard let secret = group.sharedSecret(peerPublic: f, privateExponent: x, exponentBits: exponentBits) else {
            throw .invalidPeerPublicValue
        }
        var k = SSHWriter()
        k.writeMPInt(secret)
        var h = SSHWriter(capacity: 2048)
        prefix.write(into: &h)
        h.writeString(reply.hostKey)
        h.writeMPInt(e)
        h.writeMPInt(f)
        h.writeBytes(k.bytes)
        return .done(KexOutcome(encodedSecret: k.bytes, exchangeHash: hash.hash(h.bytes),
                                hostKeyBlob: reply.hostKey, signatureBlob: reply.signature))
    }
}

// MARK: - DH group exchange (RFC 4419)

final class GroupExchangeDH: KexMethod {
    let prefix: ExchangeHashPrefix
    let hash: SSHHash
    let bits: ClosedRange<Int>
    let preferred: Int
    let requestedExponentBits: Int
    private var group: DHGroup?
    private var x = BigUInt()
    private var e = BigUInt()
    private var exponentBits = 0

    init(prefix: ExchangeHashPrefix, hash: SSHHash, bits: ClosedRange<Int>, preferred: Int, exponentBits: Int) {
        self.prefix = prefix
        self.hash = hash
        self.bits = bits
        self.preferred = min(max(preferred, bits.lowerBound), bits.upperBound)
        self.requestedExponentBits = exponentBits
    }

    func start() throws(KexError) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(SSHMessage.kexDHGexRequest)
        w.writeUInt32(UInt32(bits.lowerBound))
        w.writeUInt32(UInt32(preferred))
        w.writeUInt32(UInt32(bits.upperBound))
        return w.bytes
    }

    func handle(_ payload: [UInt8]) throws(KexError) -> KexStep {
        guard let group else {
            // SSH_MSG_KEX_DH_GEX_GROUP shares number 31 with KEXDH_REPLY.
            var r = SSHReader(payload)
            let p: BigUInt, g: BigUInt
            do {
                let type = try r.readByte()
                guard type == SSHMessage.kexDHReply else { throw KexError.unexpectedMessage(type) }
                p = try r.readMPInt()
                g = try r.readMPInt()
                guard r.isAtEnd else { throw KexError.malformed("trailing bytes in DH_GEX_GROUP") }
            } catch let error as KexError {
                throw error
            } catch {
                throw .malformed("truncated DH_GEX_GROUP")
            }
            if p.bitWidth < bits.lowerBound, p.isOdd { throw .groupTooSmall(bits: p.bitWidth) }
            guard let offered = DHGroup(validatingPrime: p, generator: g, bitRange: bits) else {
                throw .groupRejected("server offered a \(p.bitWidth)-bit group outside \(bits.lowerBound)…\(bits.upperBound) or a bad generator")
            }
            self.group = offered
            exponentBits = min(requestedExponentBits, offered.bits - 1)
            x = randomExponent(bits: exponentBits)
            e = offered.publicValue(privateExponent: x, exponentBits: exponentBits)
            var w = SSHWriter()
            w.writeByte(SSHMessage.kexDHGexInit)
            w.writeMPInt(e)
            return .send(w.bytes)
        }
        let reply = try readReply(payload, expect: SSHMessage.kexDHGexReply) { try $0.readMPIntBytes() }
        let f = BigUInt(bigEndian: reply.value)
        guard let secret = group.sharedSecret(peerPublic: f, privateExponent: x, exponentBits: exponentBits) else {
            throw .invalidPeerPublicValue
        }
        var k = SSHWriter()
        k.writeMPInt(secret)
        var h = SSHWriter(capacity: 4096)
        prefix.write(into: &h)
        h.writeString(reply.hostKey)
        h.writeUInt32(UInt32(bits.lowerBound))
        h.writeUInt32(UInt32(preferred))
        h.writeUInt32(UInt32(bits.upperBound))
        h.writeMPInt(group.prime)
        h.writeMPInt(group.generator)
        h.writeMPInt(e)
        h.writeMPInt(f)
        h.writeBytes(k.bytes)
        return .done(KexOutcome(encodedSecret: k.bytes, exchangeHash: hash.hash(h.bytes),
                                hostKeyBlob: reply.hostKey, signatureBlob: reply.signature))
    }
}

// MARK: - mlkem768x25519-sha256 (draft-ietf-sshm-mlkem-hybrid-kex)

/// ML-KEM-768 + X25519. Client sends C_INIT = ML-KEM public key (1184) ‖
/// X25519 public key (32); server answers S_REPLY = ML-KEM ciphertext (1088)
/// ‖ X25519 public key (32). K = SHA-256(mlkem secret ‖ x25519 secret),
/// encoded as a STRING (not an mpint) in both H and the key derivation.
/// Needs CryptoKit's MLKEM768 (macOS 26+); on Linux it is never offered.
final class HybridMLKEM: KexMethod {
    static let publicKeySize = 1184
    static let ciphertextSize = 1088

    /// Always on macOS (the package requires 26+); never on the Linux test
    /// stand-in, whose swift-crypto predates ML-KEM.
    static var isAvailable: Bool {
#if canImport(CryptoKit)
        return true
#else
        return false
#endif
    }

    let prefix: ExchangeHashPrefix
    private let x25519 = Curve25519.KeyAgreement.PrivateKey()
    private var clientInit: [UInt8] = []
    /// Type-erased so the class compiles where MLKEM768 does not exist.
    private var decapsulate: (([UInt8]) -> [UInt8]?)?

    init(prefix: ExchangeHashPrefix) { self.prefix = prefix }

    func start() throws(KexError) -> [UInt8] {
#if canImport(CryptoKit)
        guard let key = try? MLKEM768.PrivateKey() else { throw .malformed("ML-KEM key generation failed") }
        clientInit = Array(key.publicKey.rawRepresentation) + Array(x25519.publicKey.rawRepresentation)
        decapsulate = { ciphertext in
            guard let s = try? key.decapsulate(ciphertext) else { return nil }
            return s.withUnsafeBytes { Array($0) }
        }
#endif
        guard decapsulate != nil else { throw .malformed("ML-KEM is not available on this system") }
        var w = SSHWriter(capacity: 1300)
        w.writeByte(SSHMessage.kexDHInit)
        w.writeString(clientInit)
        return w.bytes
    }

    func handle(_ payload: [UInt8]) throws(KexError) -> KexStep {
        let reply = try readReply(payload, expect: SSHMessage.kexDHReply) { try $0.readString() }
        guard reply.value.count == Self.ciphertextSize + 32, let decapsulate else { throw .invalidPeerPublicValue }
        guard let kemSecret = decapsulate(Array(reply.value[0..<Self.ciphertextSize])),
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: reply.value[Self.ciphertextSize...]),
              let ecdh = try? x25519.sharedSecretFromKeyAgreement(with: peer) else {
            throw .invalidPeerPublicValue
        }
        let ecdhSecret = ecdh.withUnsafeBytes { Array($0) }
        guard !isAllZero(ecdhSecret) else { throw .invalidPeerPublicValue }
        var k = SSHWriter()
        k.writeString(SSHHash.sha256.hash(kemSecret + ecdhSecret))
        var h = SSHWriter(capacity: 4096)
        prefix.write(into: &h)
        h.writeString(reply.hostKey)
        h.writeString(clientInit)
        h.writeString(reply.value)
        h.writeBytes(k.bytes)
        return .done(KexOutcome(encodedSecret: k.bytes, exchangeHash: SSHHash.sha256.hash(h.bytes),
                                hostKeyBlob: reply.hostKey, signatureBlob: reply.signature))
    }
}

// MARK: - Key derivation (RFC 4253 §7.2)

enum KeyDerivation {
    /// HASH(K ‖ H ‖ letter ‖ session_id), extended with HASH(K ‖ H ‖ K1 ‖ …)
    /// until `count` bytes.
    static func derive(hash: SSHHash, encodedSecret: [UInt8], exchangeHash: [UInt8], letter: Character,
                       sessionID: [UInt8], count: Int) -> [UInt8] {
        if count == 0 { return [] }
        var input = encodedSecret + exchangeHash
        input.append(letter.asciiValue!)
        input += sessionID
        var out = hash.hash(input)
        while out.count < count {
            out += hash.hash(encodedSecret + exchangeHash + out)
        }
        return Array(out.prefix(count))
    }

    static func keys(for negotiated: NegotiatedAlgorithms, hash: SSHHash, encodedSecret: [UInt8],
                     exchangeHash: [UInt8], sessionID: [UInt8]) -> (clientToServer: DirectionKeys, serverToClient: DirectionKeys) {
        func d(_ letter: Character, _ n: Int) -> [UInt8] {
            derive(hash: hash, encodedSecret: encodedSecret, exchangeHash: exchangeHash, letter: letter,
                   sessionID: sessionID, count: n)
        }
        let c = negotiated.cipherClientToServer, s = negotiated.cipherServerToClient
        let c2s = DirectionKeys(cipher: c, mac: negotiated.macClientToServer, key: d("C", c.keySize),
                                iv: d("A", c.ivSize), macKey: d("E", negotiated.macClientToServer?.keySize ?? 0))
        let s2c = DirectionKeys(cipher: s, mac: negotiated.macServerToClient, key: d("D", s.keySize),
                                iv: d("B", s.ivSize), macKey: d("F", negotiated.macServerToClient?.keySize ?? 0))
        return (c2s, s2c)
    }

    /// OpenSSH's `we_need`: the largest key, block, IV or MAC key in bytes
    /// across both directions, or the hash length if larger. The DH private
    /// exponent gets twice that many bits (capped below the group size).
    static func dhExponentBits(for negotiated: NegotiatedAlgorithms) -> Int {
        var need = negotiated.kex.hash.outputSize
        for c in [negotiated.cipherClientToServer, negotiated.cipherServerToClient] {
            need = max(need, c.keySize, c.blockSize, c.ivSize)
        }
        for m in [negotiated.macClientToServer, negotiated.macServerToClient] {
            need = max(need, m?.keySize ?? 0)
        }
        return need * 8 * 2
    }
}

/// Constant-time all-zero test for a shared secret (OpenSSH uses
/// timingsafe_bcmp): no early exit at the first non-zero byte.
func isAllZero<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
    var acc: UInt8 = 0
    for b in bytes { acc |= b }
    return acc == 0
}
