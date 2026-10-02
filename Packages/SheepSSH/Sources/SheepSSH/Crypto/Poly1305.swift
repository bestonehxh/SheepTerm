// Poly1305 one-time authenticator (RFC 8439 §2.5), 26-bit limb arithmetic in
// the style of poly1305-donna-32: every product fits in UInt64, the final
// reduction mod 2¹³⁰ − 5 is a masked select. No data-dependent branches.

public enum Poly1305 {
    public static let tagSize = 16

    /// Tag of `message` under the 32-byte one-time `key` (r ‖ s).
    public static func tag<C: RandomAccessCollection>(message: C, key: [UInt8]) -> [UInt8]
    where C.Element == UInt8, C.Index == Int {
        if let tag = message.withContiguousStorageIfAvailable({ tag(pointer: $0, key: key) }) { return tag }
        return Array(message).withUnsafeBufferPointer { tag(pointer: $0, key: key) }
    }

    /// Full blocks are read in place; only a short final block is copied.
    static func tag(pointer m: UnsafeBufferPointer<UInt8>, key: [UInt8]) -> [UInt8] {
        precondition(key.count == 32, "Poly1305 key must be 32 bytes")
        // r, clamped, in five 26-bit limbs.
        let r0 = UInt64(loadLE32(key, 0)) & 0x3ff_ffff
        let r1 = UInt64(loadLE32(key, 3) >> 2) & 0x3ff_ff03
        let r2 = UInt64(loadLE32(key, 6) >> 4) & 0x3ff_c0ff
        let r3 = UInt64(loadLE32(key, 9) >> 6) & 0x3f0_3fff
        let r4 = UInt64(loadLE32(key, 12) >> 8) & 0x00f_ffff
        let s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5

        var h0: UInt64 = 0, h1: UInt64 = 0, h2: UInt64 = 0, h3: UInt64 = 0, h4: UInt64 = 0
        var last = [UInt8](repeating: 0, count: 17)
        var offset = 0
        let count = m.count
        while offset < count {
            let n = min(16, count - offset)
            let hibit: UInt64
            let t0, t1, t2, t3, t4: UInt64
            if n == 16 {
                // The high bit: 2¹²⁸ for a full block.
                let b = m.baseAddress! + offset
                t0 = UInt64(le32(b, 0)); t1 = UInt64(le32(b, 3)); t2 = UInt64(le32(b, 6))
                t3 = UInt64(le32(b, 9)); t4 = UInt64(le32(b, 12))
                hibit = 1 << 24
            } else {
                // A short final block: the data, a 0x01, zeros; no 2¹²⁸.
                for i in 0..<17 { last[i] = 0 }
                for i in 0..<n { last[i] = m[offset + i] }
                last[n] = 1
                t0 = UInt64(loadLE32(last, 0)); t1 = UInt64(loadLE32(last, 3)); t2 = UInt64(loadLE32(last, 6))
                t3 = UInt64(loadLE32(last, 9)); t4 = UInt64(loadLE32(last, 12))
                hibit = 0
            }
            h0 += t0 & 0x3ff_ffff
            h1 += (t1 >> 2) & 0x3ff_ffff
            h2 += (t2 >> 4) & 0x3ff_ffff
            h3 += (t3 >> 6) & 0x3ff_ffff
            h4 += (t4 >> 8) | hibit

            let d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1
            var d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2
            var d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3
            var d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4
            var d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0

            var c = d0 >> 26; h0 = d0 & 0x3ff_ffff
            d1 += c; c = d1 >> 26; h1 = d1 & 0x3ff_ffff
            d2 += c; c = d2 >> 26; h2 = d2 & 0x3ff_ffff
            d3 += c; c = d3 >> 26; h3 = d3 & 0x3ff_ffff
            d4 += c; c = d4 >> 26; h4 = d4 & 0x3ff_ffff
            h0 += c * 5; c = h0 >> 26; h0 &= 0x3ff_ffff
            h1 += c
            offset += n
        }

        // Full carry.
        var c = h1 >> 26; h1 &= 0x3ff_ffff
        h2 += c; c = h2 >> 26; h2 &= 0x3ff_ffff
        h3 += c; c = h3 >> 26; h3 &= 0x3ff_ffff
        h4 += c; c = h4 >> 26; h4 &= 0x3ff_ffff
        h0 += c * 5; c = h0 >> 26; h0 &= 0x3ff_ffff
        h1 += c

        // g = h + 5 − 2¹³⁰; keep g when it did not go negative.
        var g0 = h0 &+ 5; c = g0 >> 26; g0 &= 0x3ff_ffff
        var g1 = h1 &+ c; c = g1 >> 26; g1 &= 0x3ff_ffff
        var g2 = h2 &+ c; c = g2 >> 26; g2 &= 0x3ff_ffff
        var g3 = h3 &+ c; c = g3 >> 26; g3 &= 0x3ff_ffff
        let g4 = h4 &+ c &- (1 << 26)
        // Top bit of g4 set → g negative → keep h.
        let keepH = 0 &- (g4 >> 63)            // all ones when negative
        let keepG = ~keepH
        h0 = (h0 & keepH) | (g0 & keepG)
        h1 = (h1 & keepH) | (g1 & keepG)
        h2 = (h2 & keepH) | (g2 & keepG)
        h3 = (h3 & keepH) | (g3 & keepG)
        h4 = (h4 & keepH) | (g4 & keepG & 0x3ff_ffff)

        // h mod 2¹²⁸ as four 32-bit words, then + s.
        let w0 = (h0 | h1 << 26) & 0xffff_ffff
        let w1 = (h1 >> 6 | h2 << 20) & 0xffff_ffff
        let w2 = (h2 >> 12 | h3 << 14) & 0xffff_ffff
        let w3 = (h3 >> 18 | h4 << 8) & 0xffff_ffff
        var f = w0 + UInt64(loadLE32(key, 16))
        var out = [UInt8](repeating: 0, count: 16)
        storeLE32(&out, 0, UInt32(truncatingIfNeeded: f))
        f = w1 + UInt64(loadLE32(key, 20)) + (f >> 32)
        storeLE32(&out, 4, UInt32(truncatingIfNeeded: f))
        f = w2 + UInt64(loadLE32(key, 24)) + (f >> 32)
        storeLE32(&out, 8, UInt32(truncatingIfNeeded: f))
        f = w3 + UInt64(loadLE32(key, 28)) + (f >> 32)
        storeLE32(&out, 12, UInt32(truncatingIfNeeded: f))
        return out
    }

    /// Recomputes the tag and compares it in constant time.
    public static func verify<C: RandomAccessCollection>(tag expected: [UInt8], message: C, key: [UInt8]) -> Bool
    where C.Element == UInt8, C.Index == Int {
        constantTimeEqual(tag(message: message, key: key), expected)
    }
}

@inline(__always)
private func le32(_ p: UnsafePointer<UInt8>, _ i: Int) -> UInt32 {
    UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
}

@inline(__always)
func storeLE32(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
    b[i] = UInt8(truncatingIfNeeded: v)
    b[i + 1] = UInt8(truncatingIfNeeded: v >> 8)
    b[i + 2] = UInt8(truncatingIfNeeded: v >> 16)
    b[i + 3] = UInt8(truncatingIfNeeded: v >> 24)
}

/// Equality whose running time depends only on the lengths. Use it for every
/// MAC, tag or check value compared against attacker-supplied bytes.
public func constantTimeEqual<A: Collection, B: Collection>(_ a: A, _ b: B) -> Bool
where A.Element == UInt8, B.Element == UInt8 {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}
