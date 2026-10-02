// AES in CTR and CBC mode, stateful across calls (an SSH connection is one
// long CTR/CBC stream split into packets). On macOS this is CommonCrypto's
// streaming cryptor (hardware AES); on Linux, test runs only, the modes are
// composed here from swift-crypto's single-block AES permutation.
// AES-GCM is one-shot and comes from CryptoKit directly.
import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
import _CryptoExtras
#endif

public enum AESError: Error, Equatable, Sendable {
    case invalidKeySize
    case invalidIVSize
    /// CBC input that is not a whole number of 16-byte blocks.
    case notBlockAligned
    case authenticationFailed
    case platformFailure(Int32)
}

/// The AES name predates 3DES support; kept for the key-file code and tests.
public typealias AESStream = BlockCipherStream

public final class BlockCipherStream: @unchecked Sendable {
    public enum Mode: Sendable { case ctr, cbcEncrypt, cbcDecrypt }
    public enum Algorithm: Sendable { case aes, tripleDES }

    /// 3des-cbc exists only through CommonCrypto; the Linux test stand-in has
    /// no DES, so there it is left out of the offered cipher list.
#if canImport(CommonCrypto)
    public static let tripleDESAvailable = true
#else
    public static let tripleDESAvailable = false
#endif

    public let mode: Mode
    public let algorithm: Algorithm
    public var blockSize: Int { algorithm == .aes ? 16 : 8 }

    /// CTR: the next counter block (both platforms; see `ctr`).
    /// CBC on Linux: the previous ciphertext block.
    private var chain: [UInt8]
    /// CTR: keystream generated but not yet used (from `keystreamStart`).
    private var keystream: [UInt8] = []
    private var keystreamStart = 0
#if canImport(CommonCrypto)
    /// CBC: the streaming CBC cryptor. CTR: an ECB cryptor that only ever
    /// encrypts counter blocks.
    private var cryptor: CCCryptorRef?
#else
    private let key: SymmetricKey
#endif

    /// AES: `key` is 16, 24 or 32 bytes and `iv` 16 (the initial counter block
    /// for CTR, big-endian increment). 3DES: 24-byte key, 8-byte IV, CBC only.
    public init(mode: Mode, algorithm: Algorithm = .aes, key: [UInt8], iv: [UInt8]) throws(AESError) {
        switch algorithm {
        case .aes:
            guard [16, 24, 32].contains(key.count) else { throw .invalidKeySize }
            guard iv.count == 16 else { throw .invalidIVSize }
        case .tripleDES:
            guard Self.tripleDESAvailable, mode != .ctr else { throw .platformFailure(-4305) }
            guard key.count == 24 else { throw .invalidKeySize }
            guard iv.count == 8 else { throw .invalidIVSize }
        }
        self.mode = mode
        self.algorithm = algorithm
        self.chain = iv
#if canImport(CommonCrypto)
        // NOT kCCModeCTR: CommonCrypto's CTR increments only the low 64 bits
        // of the counter and wraps there (measured on macOS 27 against
        // OpenSSL), while SSH (RFC 4344 §4) counts all 128. So CTR is built
        // here from ECB-encrypted counter blocks, like on Linux.
        let operation = mode == .cbcDecrypt ? CCOperation(kCCDecrypt) : CCOperation(kCCEncrypt)
        let ccMode = mode == .ctr ? CCMode(kCCModeECB) : CCMode(kCCModeCBC)
        var ref: CCCryptorRef?
        let ccAlgorithm = algorithm == .aes ? CCAlgorithm(kCCAlgorithmAES) : CCAlgorithm(kCCAlgorithm3DES)
        let status = CCCryptorCreateWithMode(operation, ccMode, ccAlgorithm,
                                             CCPadding(ccNoPadding), mode == .ctr ? nil : iv, key, key.count,
                                             nil, 0, 0, CCModeOptions(0), &ref)
        guard status == CCCryptorStatus(kCCSuccess), let ref else { throw .platformFailure(status) }
        cryptor = ref
#else
        self.key = SymmetricKey(data: key)
#endif
    }

    deinit {
#if canImport(CommonCrypto)
        if let cryptor { CCCryptorRelease(cryptor) }
#endif
    }

    /// Encrypts or decrypts `data` (per `mode`), continuing the stream.
    public func process(_ data: [UInt8]) throws(AESError) -> [UInt8] {
        if mode != .ctr, data.count % blockSize != 0 { throw .notBlockAligned }
        if data.isEmpty { return [] }
        if mode == .ctr { return try ctr(data) }
#if canImport(CommonCrypto)
        return try cryptorUpdate(data)
#else
        do {
            switch mode {
            case .ctr: return try ctr(data)
            case .cbcEncrypt: return try cbcEncrypt(data)
            case .cbcDecrypt: return try cbcDecrypt(data)
            }
        } catch let error as AESError {
            throw error
        } catch {
            throw .platformFailure(-1)
        }
#endif
    }

    /// CTR with a full 128-bit big-endian counter: the counter blocks a call
    /// needs are laid out in one buffer and encrypted in one go. The counter
    /// is kept as two UInt64 halves (a carry out of the low half goes into the
    /// high one — exactly what CommonCrypto's own CTR mode got wrong), and
    /// leftover keystream is consumed by offset, not by shifting an array.
    private func ctr(_ data: [UInt8]) throws(AESError) -> [UInt8] {
        let available = keystream.count - keystreamStart
        if available < data.count {
            let blocks = (data.count - available + 15) / 16
            var hi = UInt64(bigEndian: chain.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self) })
            var lo = UInt64(bigEndian: chain.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) })
            var counters = [UInt8](repeating: 0, count: blocks * 16)
            counters.withUnsafeMutableBytes { raw in
                for b in 0..<blocks {
                    raw.storeBytes(of: hi.bigEndian, toByteOffset: b * 16, as: UInt64.self)
                    raw.storeBytes(of: lo.bigEndian, toByteOffset: b * 16 + 8, as: UInt64.self)
                    lo &+= 1
                    if lo == 0 { hi &+= 1 }
                }
            }
            chain.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: hi.bigEndian, toByteOffset: 0, as: UInt64.self)
                raw.storeBytes(of: lo.bigEndian, toByteOffset: 8, as: UInt64.self)
            }
            let fresh = try encryptBlocks(counters)
            if keystreamStart > 0 {
                keystream.removeFirst(keystreamStart)
                keystreamStart = 0
            }
            keystream += fresh
        }
        var out = data
        out.withUnsafeMutableBufferPointer { o in
            keystream.withUnsafeBufferPointer { k in
                let start = keystreamStart
                for i in 0..<o.count { o[i] ^= k[start + i] }
            }
        }
        keystreamStart += data.count
        return out
    }

#if canImport(CommonCrypto)
    private func encryptBlocks(_ blocks: [UInt8]) throws(AESError) -> [UInt8] {
        try cryptorUpdate(blocks)
    }

    private func cryptorUpdate(_ data: [UInt8]) throws(AESError) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCryptorUpdate(cryptor, data, data.count, &out, out.count, &moved)
        guard status == CCCryptorStatus(kCCSuccess), moved == data.count else {
            throw .platformFailure(status)
        }
        return out
    }
#else
    private func encryptBlocks(_ blocks: [UInt8]) throws(AESError) -> [UInt8] {
        var out = blocks
        var i = 0
        while i < out.count {
            do {
                try AES.permute(&out[i..<i + 16], key: key)
            } catch {
                throw .platformFailure(-1)
            }
            i += 16
        }
        return out
    }

    private func cbcEncrypt(_ data: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            var block = (0..<16).map { data[i + $0] ^ chain[$0] }
            try AES.permute(&block, key: key)
            out.append(contentsOf: block)
            chain = block
            i += 16
        }
        return out
    }

    private func cbcDecrypt(_ data: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            let cipherBlock = Array(data[i..<i + 16])
            var block = cipherBlock
            try AES.inversePermute(&block, key: key)
            out.append(contentsOf: (0..<16).map { block[$0] ^ chain[$0] })
            chain = cipherBlock
            i += 16
        }
        return out
    }
#endif
}

public enum AESGCM {
    public static let tagSize = 16
    public static let nonceSize = 12

    public static func seal(key: [UInt8], nonce: [UInt8], aad: [UInt8] = [], plaintext: [UInt8]) throws(AESError) -> (ciphertext: [UInt8], tag: [UInt8]) {
        do {
            let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                       nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
            return (Array(box.ciphertext), Array(box.tag))
        } catch {
            throw .platformFailure(-1)
        }
    }

    public static func open(key: [UInt8], nonce: [UInt8], aad: [UInt8] = [], ciphertext: [UInt8], tag: [UInt8]) throws(AESError) -> [UInt8] {
        guard [16, 24, 32].contains(key.count) else { throw .invalidKeySize }
        guard nonce.count == nonceSize else { throw .invalidIVSize }
        guard tag.count == tagSize else { throw .authenticationFailed }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        } catch {
            throw .platformFailure(-1)
        }
        do {
            return Array(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad))
        } catch {
            throw .authenticationFailed
        }
    }
}
