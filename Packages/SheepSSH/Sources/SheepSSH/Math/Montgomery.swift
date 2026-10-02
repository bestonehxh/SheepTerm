// Montgomery arithmetic modulo an odd n, with a constant-time exponentiation
// for secret exponents (our Diffie-Hellman private value).
//
// What "constant-time" means here, precisely:
//  - `mul` runs the same loops and the same instructions whatever the limb
//    values are; the final conditional subtraction is a masked select.
//  - `pow(_:secretExponent:exponentBits:)` walks a fixed number of 4-bit
//    windows (from `exponentBits`, not from the exponent's value), always does
//    four squarings and one multiplication per window, and fetches the table
//    entry by scanning all 16 entries with a mask — so neither the branch
//    pattern nor the memory access pattern depends on exponent bits.
// Swift array bounds checks depend only on indices, which are public.

public struct MontgomeryContext: Sendable {
    public let modulus: BigUInt
    /// n as exactly `k` limbs.
    let n: [UInt64]
    let k: Int
    /// −n⁻¹ mod 2⁶⁴.
    let n0inv: UInt64
    /// R² mod n, R = 2^(64k).
    let r2: [UInt64]
    /// R mod n (Montgomery form of 1).
    let one: [UInt64]

    /// Nil unless the modulus is odd and greater than 1.
    public init?(modulus: BigUInt) {
        guard modulus.isOdd, modulus > BigUInt(1) else { return nil }
        self.modulus = modulus
        n = modulus.limbs
        k = n.count
        // Newton iteration for n⁻¹ mod 2⁶⁴: each step doubles the correct bits.
        var inv: UInt64 = 1
        for _ in 0..<6 { inv = inv &* (2 &- n[0] &* inv) }
        n0inv = 0 &- inv
        let r = BigUInt(1) << (64 * k)
        one = Self.padded((r % modulus).limbs, k)
        r2 = Self.padded(((r * r) % modulus).limbs, k)
    }

    static func padded(_ limbs: [UInt64], _ k: Int) -> [UInt64] {
        var out = limbs
        out.append(contentsOf: repeatElement(0, count: k - limbs.count))
        return out
    }

    /// Montgomery product a·b·R⁻¹ mod n for a, b < n given as `k` limbs.
    /// CIOS (Koç et al.), result fully reduced.
    func mul(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: k)
        a.withUnsafeBufferPointer { a in
        b.withUnsafeBufferPointer { b in
        n.withUnsafeBufferPointer { n in
        result.withUnsafeMutableBufferPointer { out in
            Self.montMul(a, b, n, n0inv, k, out)
        }}}}
        return result
    }

    static func montMul(_ a: UnsafeBufferPointer<UInt64>, _ b: UnsafeBufferPointer<UInt64>,
                        _ n: UnsafeBufferPointer<UInt64>, _ n0inv: UInt64, _ k: Int,
                        _ out: UnsafeMutableBufferPointer<UInt64>) {
        // t has k + 2 limbs.
        let t = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: k + 2)
        defer { t.deallocate() }
        t.initialize(repeating: 0)
        for i in 0..<k {
            var carry: UInt64 = 0
            let bi = b[i]
            for j in 0..<k {
                let (hi, lo) = mulAdd(a[j], bi, t[j], carry)
                t[j] = lo
                carry = hi
            }
            let (s, o) = t[k].addingReportingOverflow(carry)
            t[k] = s
            t[k + 1] = o ? 1 : 0

            let m = t[0] &* n0inv
            var (c, _) = mulAdd(m, n[0], t[0], 0)
            for j in 1..<k {
                let (hi, lo) = mulAdd(m, n[j], t[j], c)
                t[j - 1] = lo
                c = hi
            }
            let (s2, o2) = t[k].addingReportingOverflow(c)
            t[k - 1] = s2
            t[k] = t[k + 1] &+ (o2 ? 1 : 0)
        }
        // t < 2n here. Compute d = t − n and keep it unless that borrowed past
        // the top limb t[k].
        var borrow: UInt64 = 0
        for j in 0..<k {
            let (d1, b1) = t[j].subtractingReportingOverflow(n[j])
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            out[j] = d2
            borrow = (b1 ? 1 : 0) | (b2 ? 1 : 0)
        }
        // Keep d when t[k] == 1 or there was no borrow.
        let useD = t[k] | (borrow ^ 1)
        let mask = 0 &- useD
        for j in 0..<k {
            out[j] = (out[j] & mask) | (t[j] & ~mask)
        }
        t.update(repeating: 0)
    }

    /// Converts x (any size; reduced first, variable-time — x must be public)
    /// into Montgomery form.
    func toMontgomery(_ x: BigUInt) -> [UInt64] {
        let reduced = x < modulus ? x : x % modulus
        return mul(Self.padded(reduced.limbs, k), r2)
    }

    func fromMontgomery(_ x: [UInt64]) -> BigUInt {
        var unit = [UInt64](repeating: 0, count: k)
        unit[0] = 1
        return BigUInt(limbs: mul(x, unit))
    }

    /// base^e mod n for a SECRET exponent, constant-time in e (see file
    /// comment). `exponentBits` must be at least e's bit width and should be a
    /// fixed property of the key size, never derived from e itself.
    public func pow(_ base: BigUInt, secretExponent e: BigUInt, exponentBits: Int) -> BigUInt {
        precondition(exponentBits >= e.bitWidth, "exponentBits smaller than the exponent")
        let windows = (exponentBits + 3) / 4
        // Exponent as a fixed-size limb array so the window reads below index
        // it the same way whatever its value.
        let eLimbs = Self.padded(e.limbs, (windows * 4 + 63) / 64)

        var table = [[UInt64]](repeating: one, count: 16)
        table[1] = toMontgomery(base)
        for i in 2..<16 { table[i] = mul(table[i - 1], table[1]) }

        var acc = one
        var selected = [UInt64](repeating: 0, count: k)
        var w = windows - 1
        while w >= 0 {
            for _ in 0..<4 { acc = mul(acc, acc) }
            let bitIndex = w * 4
            let digit = (eLimbs[bitIndex / 64] >> UInt64(bitIndex % 64)) & 0xF
            for j in 0..<k { selected[j] = 0 }
            for i in 0..<16 {
                let x = UInt64(i) ^ digit
                // All ones when x == 0, else zero, without a branch.
                let mask = ((x | (0 &- x)) >> 63) &- 1
                for j in 0..<k { selected[j] |= table[i][j] & mask }
            }
            acc = mul(acc, selected)
            w -= 1
        }
        return fromMontgomery(acc)
    }

    /// base^e mod n for a PUBLIC exponent. Same code path, sized to e.
    public func pow(_ base: BigUInt, publicExponent e: BigUInt) -> BigUInt {
        if e.isZero { return fromMontgomery(one) }
        return pow(base, secretExponent: e, exponentBits: e.bitWidth)
    }
}
