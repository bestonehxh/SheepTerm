// ChaCha20 in its ORIGINAL (Bernstein) layout: 64-bit block counter in state
// words 12–13 and a 64-bit nonce in words 14–15. That is the variant
// chacha20-poly1305@openssh.com uses; CryptoKit's ChaChaPoly is the IETF
// variant (32-bit counter, 96-bit nonce) and cannot stand in for it.
// With the counter below 2³² and the first four nonce bytes zero the two
// layouts coincide, which is how the RFC 8439 vectors test this one.
//
// No table lookups and no data-dependent branches: constant-time by shape.

public struct ChaCha20: Sendable {
    /// Key as eight little-endian words.
    private let key: [UInt32]

    /// `key` must be 32 bytes.
    public init(key: [UInt8]) {
        precondition(key.count == 32, "ChaCha20 key must be 32 bytes")
        var words = [UInt32](repeating: 0, count: 8)
        for i in 0..<8 { words[i] = loadLE32(key, 4 * i) }
        self.key = words
    }

    /// XORs the keystream for (`nonce`, starting at block `counter`) into
    /// `data` in place. `nonce` must be 8 bytes.
    public func apply(nonce: [UInt8], counter: UInt64, to data: inout [UInt8]) {
        apply(nonce: nonce, counter: counter, to: &data, range: 0..<data.count)
    }

    /// XORs the keystream into `data[range]` only, in place.
    public func apply(nonce: [UInt8], counter: UInt64, to data: inout [UInt8], range: Range<Int>) {
        precondition(nonce.count == 8, "ChaCha20 (original) nonce must be 8 bytes")
        precondition(range.lowerBound >= 0 && range.upperBound <= data.count)
        guard !range.isEmpty else { return }
        let n0 = loadLE32(nonce, 0), n1 = loadLE32(nonce, 4)
        data.withUnsafeMutableBufferPointer { whole in
            let part = UnsafeMutableBufferPointer(rebasing: whole[range])
            key.withUnsafeBufferPointer { k in
                Self.xorKeystream(part, key: k, nonce0: n0, nonce1: n1, counter: counter)
            }
        }
    }

    /// The first `count` keystream bytes (used for the Poly1305 one-time key).
    public func keystream(nonce: [UInt8], counter: UInt64, count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        apply(nonce: nonce, counter: counter, to: &out)
        return out
    }

    /// The whole cipher on 16 locals: no arrays, no bounds checks, no
    /// allocation per block (the array version ran at ~140 MB/s).
    static func xorKeystream(_ buf: UnsafeMutableBufferPointer<UInt8>, key k: UnsafeBufferPointer<UInt32>,
                             nonce0: UInt32, nonce1: UInt32, counter: UInt64) {
        guard let base = buf.baseAddress else { return }
        var blockCounter = counter
        var offset = 0
        let total = buf.count
        while offset < total {
            let c0 = UInt32(truncatingIfNeeded: blockCounter), c1 = UInt32(truncatingIfNeeded: blockCounter >> 32)
            var x0: UInt32 = 0x6170_7865, x1: UInt32 = 0x3320_646e, x2: UInt32 = 0x7962_2d32, x3: UInt32 = 0x6b20_6574
            var x4 = k[0], x5 = k[1], x6 = k[2], x7 = k[3], x8 = k[4], x9 = k[5], x10 = k[6], x11 = k[7]
            var x12 = c0, x13 = c1, x14 = nonce0, x15 = nonce1
            for _ in 0..<10 {
                quarter(&x0, &x4, &x8, &x12); quarter(&x1, &x5, &x9, &x13)
                quarter(&x2, &x6, &x10, &x14); quarter(&x3, &x7, &x11, &x15)
                quarter(&x0, &x5, &x10, &x15); quarter(&x1, &x6, &x11, &x12)
                quarter(&x2, &x7, &x8, &x13); quarter(&x3, &x4, &x9, &x14)
            }
            let words: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                         UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (
                x0 &+ 0x6170_7865, x1 &+ 0x3320_646e, x2 &+ 0x7962_2d32, x3 &+ 0x6b20_6574,
                x4 &+ k[0], x5 &+ k[1], x6 &+ k[2], x7 &+ k[3],
                x8 &+ k[4], x9 &+ k[5], x10 &+ k[6], x11 &+ k[7],
                x12 &+ c0, x13 &+ c1, x14 &+ nonce0, x15 &+ nonce1)
            let n = min(64, total - offset)
            withUnsafeBytes(of: words) { raw in
                // Keystream bytes are the words little-endian, which is the
                // in-memory order on every platform SheepSSH runs on.
                let ks = raw.bindMemory(to: UInt8.self)
                let p = base + offset
                for i in 0..<n { p[i] ^= ks[i] }
            }
            offset += n
            blockCounter &+= 1
        }
    }

    @inline(__always)
    static func quarter(_ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32, _ d: inout UInt32) {
        a = a &+ b; d = rotl(d ^ a, 16)
        c = c &+ d; b = rotl(b ^ c, 12)
        a = a &+ b; d = rotl(d ^ a, 8)
        c = c &+ d; b = rotl(b ^ c, 7)
    }

    @inline(__always)
    static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }
}

@inline(__always)
func loadLE32<C: RandomAccessCollection>(_ b: C, _ i: Int) -> UInt32 where C.Element == UInt8, C.Index == Int {
    let s = b.startIndex + i
    return UInt32(b[s]) | UInt32(b[s + 1]) << 8 | UInt32(b[s + 2]) << 16 | UInt32(b[s + 3]) << 24
}
