// Hashes and HMACs come from Apple's CryptoKit. On Linux (test runs only) the
// API-identical `Crypto` module of swift-crypto stands in.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum SSHHash: Sendable, Equatable {
    case sha1, sha256, sha384, sha512
    /// Only for hmac-md5 on legacy devices.
    case md5

    public var outputSize: Int {
        switch self {
        case .md5: return 16
        case .sha1: return 20
        case .sha256: return 32
        case .sha384: return 48
        case .sha512: return 64
        }
    }

    public func hash(_ data: [UInt8]) -> [UInt8] {
        switch self {
        case .md5: return Array(Insecure.MD5.hash(data: data))
        case .sha1: return Array(Insecure.SHA1.hash(data: data))
        case .sha256: return Array(SHA256.hash(data: data))
        case .sha384: return Array(SHA384.hash(data: data))
        case .sha512: return Array(SHA512.hash(data: data))
        }
    }

    public func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let k = SymmetricKey(data: key)
        switch self {
        case .md5: return Array(HMAC<Insecure.MD5>.authenticationCode(for: message, using: k))
        case .sha1: return Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: k))
        case .sha256: return Array(HMAC<SHA256>.authenticationCode(for: message, using: k))
        case .sha384: return Array(HMAC<SHA384>.authenticationCode(for: message, using: k))
        case .sha512: return Array(HMAC<SHA512>.authenticationCode(for: message, using: k))
        }
    }
}

/// The MAC of one SSH packet: HMAC(key, uint32 sequence ‖ data). The key is
/// wrapped once per direction, not per packet.
struct PacketMAC: Sendable {
    let algorithm: MACAlgorithm
    private let key: SymmetricKey

    init(algorithm: MACAlgorithm, key: [UInt8]) {
        self.algorithm = algorithm
        self.key = SymmetricKey(data: key)
    }

    var size: Int { algorithm.hash.outputSize }

    func compute(sequence: UInt32, _ data: ArraySlice<UInt8>) -> [UInt8] {
        switch algorithm.hash {
        case .md5: return Self.run(Insecure.MD5.self, key, sequence, data)
        case .sha1: return Self.run(Insecure.SHA1.self, key, sequence, data)
        case .sha256: return Self.run(SHA256.self, key, sequence, data)
        case .sha384: return Self.run(SHA384.self, key, sequence, data)
        case .sha512: return Self.run(SHA512.self, key, sequence, data)
        }
    }

    private static func run<H: HashFunction>(_: H.Type, _ key: SymmetricKey, _ sequence: UInt32,
                                             _ data: ArraySlice<UInt8>) -> [UInt8] {
        var h = HMAC<H>(key: key)
        let seq: [UInt8] = [UInt8(truncatingIfNeeded: sequence >> 24), UInt8(truncatingIfNeeded: sequence >> 16),
                            UInt8(truncatingIfNeeded: sequence >> 8), UInt8(truncatingIfNeeded: sequence)]
        h.update(data: seq)
        data.withUnsafeBytes { h.update(data: $0) }
        return Array(h.finalize())
    }
}
