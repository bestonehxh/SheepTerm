// The binary packet protocol (RFC 4253 §6) for one direction:
//
//   uint32 packet_length, byte padding_length, payload, random padding, MAC
//
// Four shapes, by what protects the packet:
//   none                     — nothing; total length a multiple of 8.
//   block cipher + MAC       — whole packet encrypted; MAC(seq ‖ plaintext).
//   block cipher + ETM MAC   — length in clear, rest encrypted; MAC(seq ‖ length ‖ ciphertext).
//   AEAD (aes-gcm, chacha)   — length is associated data (gcm: in clear;
//                              chacha: encrypted under its own key); tag appended.
// Padding is at least 4 bytes and aligns what is encrypted to the block size.
// Sequence numbers are uint32 and wrap; strict kex resets them at NEWKEYS.

public enum PacketError: Error, Equatable, Sendable {
    /// Integrity check failed — the connection must be dropped.
    case macMismatch
    case badLength(UInt32)
    case badPadding
    case cryptoFailure
}

/// Keys for one direction, as derived after a key exchange.
struct DirectionKeys: Sendable {
    let cipher: CipherAlgorithm
    let mac: MACAlgorithm?
    let key: [UInt8]
    let iv: [UInt8]
    let macKey: [UInt8]
}

/// Mutable protection state for one direction (the cipher streams and the
/// GCM invocation counter advance with every packet).
final class PacketProtection {
    enum Kind {
        case none
        case chacha(ChaChaPolyOpenSSH)
        case gcm(key: [UInt8], nonce: [UInt8])
        case block(BlockCipherStream, mac: PacketMAC)
    }

    private(set) var kind: Kind
    let blockSize: Int

    static let maximumPacketLength: UInt32 = 256 * 1024

    init() {
        kind = .none
        blockSize = 8
    }

    init(keys: DirectionKeys, encrypting: Bool) throws(PacketError) {
        blockSize = keys.cipher.blockSize
        switch keys.cipher {
        case .chacha20Poly1305:
            kind = .chacha(ChaChaPolyOpenSSH(key: keys.key))
        case .aes128GCM, .aes256GCM:
            kind = .gcm(key: keys.key, nonce: keys.iv)
        default:
            guard let mac = keys.mac else { throw .cryptoFailure }
            let isCBC = keys.cipher.rawValue.hasSuffix("-cbc")
            let mode: BlockCipherStream.Mode = isCBC ? (encrypting ? .cbcEncrypt : .cbcDecrypt) : .ctr
            let algorithm: BlockCipherStream.Algorithm = keys.cipher == .tripleDESCBC ? .tripleDES : .aes
            do {
                kind = .block(try BlockCipherStream(mode: mode, algorithm: algorithm, key: keys.key, iv: keys.iv),
                              mac: PacketMAC(algorithm: mac, key: keys.macKey))
            } catch {
                throw .cryptoFailure
            }
        }
    }

    /// Whether the length field travels outside the encrypted/MAC'd body
    /// (and so is excluded from the block alignment).
    var lengthIsSeparate: Bool {
        switch kind {
        case .none: return false
        case .chacha, .gcm: return true
        case .block(_, let mac): return mac.algorithm.isEncryptThenMAC
        }
    }

    var trailerSize: Int {
        switch kind {
        case .none: return 0
        case .chacha, .gcm: return 16
        case .block(_, let mac): return mac.size
        }
    }

    // MARK: Sealing

    func seal(payload: [UInt8], sequence: UInt32) throws(PacketError) -> [UInt8] {
        let align = max(blockSize, 8)
        let aligned = (lengthIsSeparate ? 1 : 5) + payload.count
        var padding = align - aligned % align
        if padding < 4 { padding += align }
        let packetLength = 1 + payload.count + padding
        var plain = [UInt8]()
        plain.reserveCapacity(4 + packetLength + trailerSize)
        var w = SSHWriter(capacity: 5)
        w.writeUInt32(UInt32(packetLength))
        w.writeByte(UInt8(padding))
        plain.append(contentsOf: w.bytes)
        plain.append(contentsOf: payload)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<padding { plain.append(UInt8.random(in: 0...255, using: &rng)) }

        switch kind {
        case .none:
            return plain
        case .chacha(let cipher):
            return cipher.seal(sequenceNumber: sequence, aadLength: 4, plaintext: plain)
        case .gcm(let key, let nonce):
            let sealed: (ciphertext: [UInt8], tag: [UInt8])
            do {
                sealed = try AESGCM.seal(key: key, nonce: nonce, aad: Array(plain[0..<4]), plaintext: Array(plain[4...]))
            } catch {
                throw .cryptoFailure
            }
            kind = .gcm(key: key, nonce: Self.incrementInvocation(nonce))
            return Array(plain[0..<4]) + sealed.ciphertext + sealed.tag
        case .block(let stream, let mac):
            do {
                if mac.algorithm.isEncryptThenMAC {
                    var out = Array(plain[0..<4])
                    out.append(contentsOf: try stream.process(Array(plain[4...])))
                    out.append(contentsOf: mac.compute(sequence: sequence, out[...]))
                    return out
                }
                let tag = mac.compute(sequence: sequence, plain[...])
                return try stream.process(plain) + tag
            } catch {
                throw .cryptoFailure
            }
        }
    }

    /// RFC 5647 §7.1: the last 8 bytes of the GCM nonce are a big-endian
    /// invocation counter, +1 per packet; the first 4 stay fixed.
    static func incrementInvocation(_ nonce: [UInt8]) -> [UInt8] {
        var n = nonce
        var i = 11
        while i >= 4 {
            n[i] &+= 1
            if n[i] != 0 { break }
            i -= 1
        }
        return n
    }

    // MARK: Opening

    /// Decrypts the length of the packet at the head of `buffer` and returns
    /// how many bytes the whole packet (including MAC/tag) occupies, or nil
    /// if more bytes are needed to tell. For a non-ETM block cipher this
    /// consumes the first block of the stream — it is kept in `pendingHead`.
    private var pendingHead: [UInt8]?
    private var pendingLength: Int?
    /// Set when a non-ETM block cipher decrypted an impossible length: the
    /// packet is then "read" to the maximum size and failed as a MAC error.
    private(set) var discarding = false

    func packetSize(in buffer: ArraySlice<UInt8>, sequence: UInt32) throws(PacketError) -> Int? {
        if let pendingLength { return pendingLength }
        let first: Int
        switch kind {
        case .none, .gcm, .block:
            let headSize: Int
            if case .block(_, let mac) = kind, !mac.algorithm.isEncryptThenMAC {
                headSize = blockSize
            } else {
                headSize = 4
            }
            guard buffer.count >= headSize else { return nil }
            var head = Array(buffer.prefix(headSize))
            if case .block(let stream, let mac) = kind, !mac.algorithm.isEncryptThenMAC {
                do { head = try stream.process(head) } catch { throw .cryptoFailure }
                pendingHead = head
            }
            first = Int(UInt32(head[0]) << 24 | UInt32(head[1]) << 16 | UInt32(head[2]) << 8 | UInt32(head[3]))
        case .chacha(let cipher):
            guard buffer.count >= 4 else { return nil }
            first = Int(cipher.decryptLength(sequenceNumber: sequence, encrypted: buffer.prefix(4)))
        }
        let length = UInt32(truncatingIfNeeded: first)
        // Alignment: what is encrypted must be whole blocks. Before any
        // cipher there is nothing to align, and old embedded stacks frame
        // their cleartext KEXINIT loosely — libssh never checked it there.
        let alignedPart = lengthIsSeparate ? first : first + 4
        let aligned: Bool
        if case .none = kind { aligned = true } else { aligned = alignedPart % max(blockSize, 8) == 0 }
        guard first >= 5, length <= Self.maximumPacketLength, aligned else {
            if case .block(_, let mac) = kind, !mac.algorithm.isEncryptThenMAC {
                // CVE-2008-5161: with an encrypted, unauthenticated length,
                // failing AT ONCE on a bad one tells an attacker who injected
                // a block something about its plaintext (how soon the drop
                // came). Like OpenSSH's ssh_packet_start_discard, wait for a
                // maximum-size packet and fail it as a MAC error instead.
                discarding = true
                let total = 4 + Int(Self.maximumPacketLength) + trailerSize
                pendingLength = total
                return total
            }
            throw .badLength(length)
        }
        let total = 4 + first + trailerSize
        pendingLength = total
        return total
    }

    /// Verifies and decrypts one whole packet (exactly `packetSize` bytes)
    /// and returns its payload.
    func open(_ packet: ArraySlice<UInt8>, sequence: UInt32) throws(PacketError) -> [UInt8] {
        defer { pendingHead = nil; pendingLength = nil }
        if discarding { throw .macMismatch }
        let plain: [UInt8]
        switch kind {
        case .none:
            plain = Array(packet)
        case .chacha(let cipher):
            do {
                plain = try cipher.open(sequenceNumber: sequence, aadLength: 4, sealed: packet)
            } catch {
                throw .macMismatch
            }
        case .gcm(let key, let nonce):
            let body = packet.dropFirst(4).dropLast(16)
            do {
                plain = Array(packet.prefix(4)) + (try AESGCM.open(key: key, nonce: nonce, aad: Array(packet.prefix(4)),
                                                                   ciphertext: Array(body), tag: Array(packet.suffix(16))))
            } catch {
                throw .macMismatch
            }
            kind = .gcm(key: key, nonce: Self.incrementInvocation(nonce))
        case .block(let stream, let mac):
            let macStart = packet.endIndex - mac.size
            let received = packet[macStart...]
            if mac.algorithm.isEncryptThenMAC {
                // MAC first, and decrypt nothing that fails it.
                guard constantTimeEqual(mac.compute(sequence: sequence, packet[..<macStart]), received) else {
                    throw .macMismatch
                }
                do {
                    plain = Array(packet.prefix(4)) + (try stream.process(Array(packet[(packet.startIndex + 4)..<macStart])))
                } catch {
                    throw .cryptoFailure
                }
            } else {
                guard let head = pendingHead else { throw .cryptoFailure }
                let rest: [UInt8]
                do {
                    rest = try stream.process(Array(packet[(packet.startIndex + head.count)..<macStart]))
                } catch {
                    throw .cryptoFailure
                }
                let whole = head + rest
                guard constantTimeEqual(mac.compute(sequence: sequence, whole[...]), received) else {
                    throw .macMismatch
                }
                plain = whole
            }
        }
        let packetLength = plain.count - 4
        let padding = Int(plain[4])
        // At least 4 bytes of padding — enforced once encrypted; in the
        // cleartext kex (see packetSize) only that it fits, like libssh.
        let minimumPadding: Int
        if case .none = kind { minimumPadding = 0 } else { minimumPadding = 4 }
        guard padding >= minimumPadding, padding + 1 <= packetLength else { throw .badPadding }
        return Array(plain[5..<(4 + packetLength - padding)])
    }
}
