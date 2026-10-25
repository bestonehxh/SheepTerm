// Server-role key exchange methods — the mirror of the client KexMethods in
// Transport/KeyExchange.swift: the client's KEXDH_INIT arrives, the server
// computes the shared secret and answers KEXDH_REPLY with its host key and a
// SIGNATURE over H (the client verifies it; the server never verifies).
//
//   H = HASH(V_C ‖ V_S ‖ I_C ‖ I_S ‖ K_S ‖ e ‖ f ‖ K)
//
// Same exchange-hash layout as the client side, with e (client) before
// f (server). Ported from SheepDrop (proven against real Aruba gear);
// changes: V_C goes into H as the exact bytes received, the DH exponent is
// sized from the negotiated algorithms like the client's (OpenSSH's rule,
// not a fixed 2048 bits), no debug output.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// V_C ‖ V_S ‖ I_C ‖ I_S, all as bytes (the client's version line exactly
/// as it arrived).
struct ServerExchangePrefix {
    let clientVersion: [UInt8]
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

protocol ServerKexMethod: AnyObject {
    /// Handles the client's KEXDH_INIT; returns the outcome and the
    /// KEXDH_REPLY to send.
    func handle(_ payload: [UInt8]) throws(KexError) -> (outcome: KexOutcome, reply: [UInt8])
}

enum ServerKexFactory {
    /// What the server role can run: no group exchange (it would need a
    /// moduli source), no ML-KEM hybrid (encapsulation side not written), no
    /// group16/18 (pre-auth CPU per handshake that no switch needs).
    static let supported: [KexAlgorithm] = [.curve25519, .curve25519LibSSH, .ecdhP256, .ecdhP384, .ecdhP521,
                                            .dhGroup14SHA256, .dhGroup14SHA1, .dhGroup1]

    static func make(_ algorithm: KexAlgorithm, prefix: ServerExchangePrefix, hostKeyBlob: [UInt8],
                     signer: SSHSigner, signatureAlgorithm: String, exponentBits: Int) throws(KexError) -> ServerKexMethod {
        let common = ServerKexCommon(prefix: prefix, hostKeyBlob: hostKeyBlob, signer: signer,
                                     signatureAlgorithm: signatureAlgorithm)
        switch algorithm {
        case .curve25519, .curve25519LibSSH:
            return ServerCurve25519Kex(common)
        case .ecdhP256:
            return ServerECDHKex<P256.KeyAgreement.PrivateKey>(common, hash: .sha256)
        case .ecdhP384:
            return ServerECDHKex<P384.KeyAgreement.PrivateKey>(common, hash: .sha384)
        case .ecdhP521:
            return ServerECDHKex<P521.KeyAgreement.PrivateKey>(common, hash: .sha512)
        case .dhGroup1:
            return ServerFixedGroupDH(common, group: .group1, hash: .sha1, exponentBits: exponentBits)
        case .dhGroup14SHA1:
            return ServerFixedGroupDH(common, group: .group14, hash: .sha1, exponentBits: exponentBits)
        case .dhGroup14SHA256:
            return ServerFixedGroupDH(common, group: .group14, hash: .sha256, exponentBits: exponentBits)
        case .dhGroup16, .dhGroup18, .dhGexSHA1, .dhGexSHA256, .mlkem768x25519:
            throw KexError.groupRejected("\(algorithm.rawValue) is not offered by the server")
        }
    }
}

struct ServerKexCommon {
    let prefix: ServerExchangePrefix
    let hostKeyBlob: [UInt8]
    let signer: SSHSigner
    let signatureAlgorithm: String

    /// H over the prefix, K_S, e, f, K — `values` writes e and f.
    func exchangeHash(_ hash: SSHHash, values: (inout SSHWriter) -> Void, encodedSecret: [UInt8]) -> [UInt8] {
        var h = SSHWriter(capacity: 2048)
        prefix.write(into: &h)
        h.writeString(hostKeyBlob)
        values(&h)
        h.writeBytes(encodedSecret)
        return hash.hash(h.bytes)
    }

    /// KEXDH_REPLY: string K_S, f, string signature-of-H.
    func reply(exchangeHash: [UInt8], f: (inout SSHWriter) -> Void) throws(KexError) -> [UInt8] {
        // signer.sign returns the COMPLETE SSH signature string (algorithm
        // name prefixed) — exactly what KEXDH_REPLY's signature field carries.
        let blob: [UInt8]
        do {
            blob = try signer.sign(exchangeHash, algorithm: signatureAlgorithm)
        } catch {
            throw KexError.malformed("host key signing failed: \(error)")
        }
        var w = SSHWriter(capacity: 1024)
        w.writeByte(SSHMessage.kexDHReply)
        w.writeString(hostKeyBlob)
        f(&w)
        w.writeString(blob)
        return w.bytes
    }

    func outcome(secret: [UInt8], hash: [UInt8]) -> KexOutcome {
        KexOutcome(encodedSecret: secret, exchangeHash: hash, hostKeyBlob: hostKeyBlob, signatureBlob: [])
    }
}

/// Reads the KEXDH_INIT header; a truncated packet is `.malformed`.
private func readInit<T>(_ payload: [UInt8], _ body: (inout SSHReader) throws -> T) throws(KexError) -> T {
    var r = SSHReader(payload)
    do {
        guard try r.readByte() == SSHMessage.kexDHInit else { throw KexError.unexpectedMessage(payload.first ?? 0) }
        return try body(&r)
    } catch let error as KexError {
        throw error
    } catch {
        throw .malformed("truncated key exchange init")
    }
}

// MARK: - X25519 (RFC 8731)

final class ServerCurve25519Kex: ServerKexMethod {
    let common: ServerKexCommon
    let privateKey = Curve25519.KeyAgreement.PrivateKey()

    init(_ common: ServerKexCommon) { self.common = common }

    func handle(_ payload: [UInt8]) throws(KexError) -> (outcome: KexOutcome, reply: [UInt8]) {
        let e = try readInit(payload) { try $0.readString() }
        guard e.count == 32,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: e),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else {
            throw KexError.invalidPeerPublicValue
        }
        let secret = shared.withUnsafeBytes { Array($0) }
        guard !isAllZero(secret) else { throw KexError.invalidPeerPublicValue }
        let f = Array(privateKey.publicKey.rawRepresentation)
        var k = SSHWriter()
        k.writeMPInt(unsigned: secret)
        let hash = common.exchangeHash(.sha256, values: { $0.writeString(e); $0.writeString(f) }, encodedSecret: k.bytes)
        let reply = try common.reply(exchangeHash: hash) { $0.writeString(f) }
        return (common.outcome(secret: k.bytes, hash: hash), reply)
    }
}

// MARK: - ECDH over NIST curves (RFC 5656)

final class ServerECDHKex<Key: NISTKeyAgreementKey>: ServerKexMethod {
    let common: ServerKexCommon
    let hash: SSHHash
    let privateKey = Key.generate()

    init(_ common: ServerKexCommon, hash: SSHHash) {
        self.common = common
        self.hash = hash
    }

    func handle(_ payload: [UInt8]) throws(KexError) -> (outcome: KexOutcome, reply: [UInt8]) {
        let e = try readInit(payload) { try $0.readString() }
        // CryptoKit refuses points that are not on the curve.
        guard let secret = privateKey.sharedX(withX963: e) else { throw KexError.invalidPeerPublicValue }
        let f = privateKey.x963PublicKey
        var k = SSHWriter()
        k.writeMPInt(unsigned: secret)
        let exchangeHash = common.exchangeHash(hash, values: { $0.writeString(e); $0.writeString(f) }, encodedSecret: k.bytes)
        let reply = try common.reply(exchangeHash: exchangeHash) { $0.writeString(f) }
        return (common.outcome(secret: k.bytes, hash: exchangeHash), reply)
    }
}

// MARK: - Finite-field DH, fixed groups (RFC 4253 §8, RFC 8268)

final class ServerFixedGroupDH: ServerKexMethod {
    let common: ServerKexCommon
    let group: DHGroup
    let hash: SSHHash
    let exponentBits: Int
    let y: BigUInt

    init(_ common: ServerKexCommon, group: DHGroup, hash: SSHHash, exponentBits: Int) {
        self.common = common
        self.group = group
        self.hash = hash
        self.exponentBits = min(max(exponentBits, 256), group.bits - 1)
        self.y = randomExponent(bits: self.exponentBits)
    }

    func handle(_ payload: [UInt8]) throws(KexError) -> (outcome: KexOutcome, reply: [UInt8]) {
        let e = BigUInt(bigEndian: try readInit(payload) { try $0.readMPIntBytes() })
        // sharedSecret enforces 1 < e < p−1 for the client's value, the same
        // check the client applies to our f.
        guard let secret = group.sharedSecret(peerPublic: e, privateExponent: y, exponentBits: exponentBits) else {
            throw KexError.invalidPeerPublicValue
        }
        let f = group.publicValue(privateExponent: y, exponentBits: exponentBits)
        var k = SSHWriter()
        k.writeMPInt(secret)
        let exchangeHash = common.exchangeHash(hash, values: { $0.writeMPInt(e); $0.writeMPInt(f) }, encodedSecret: k.bytes)
        let reply = try common.reply(exchangeHash: exchangeHash) { $0.writeMPInt(f) }
        return (common.outcome(secret: k.bytes, hash: exchangeHash), reply)
    }
}
