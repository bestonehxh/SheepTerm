// Arbitrary-precision unsigned integers, just enough for SSH: the finite-field
// Diffie-Hellman groups, DSA verification and mpint fields.
//
// TIMING: everything in this file is VARIABLE-TIME and must only ever see
// public values (moduli, peer public values, signatures, key blobs). The one
// operation that touches a secret — raising g to our private DH exponent — goes
// through `MontgomeryContext.pow(_:secretExponent:exponentBits:)`, which is
// written to be constant-time.

public struct BigUInt: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Little-endian 64-bit limbs, normalized: no zero limb at the top, and
    /// zero is the empty array.
    public private(set) var limbs: [UInt64]

    public init() { limbs = [] }

    public init(_ value: UInt64) {
        limbs = value == 0 ? [] : [value]
    }

    /// From limbs in little-endian order; trailing zero limbs are dropped.
    public init(limbs: [UInt64]) {
        self.limbs = limbs
        normalize()
    }

    /// From an unsigned big-endian magnitude (leading zeros allowed).
    public init<C: Collection>(bigEndian bytes: C) where C.Element == UInt8 {
        var out = [UInt64](repeating: 0, count: (bytes.count + 7) / 8)
        var shift: UInt64 = 0
        var index = 0
        for byte in bytes.reversed() {
            out[index] |= UInt64(byte) << shift
            shift += 8
            if shift == 64 { shift = 0; index += 1 }
        }
        limbs = out
        normalize()
    }

    /// From hexadecimal text; whitespace is ignored. Nil on any other character.
    public init?(hex: String) {
        var bytes: [UInt8] = []
        var nibbles: [UInt8] = []
        for c in hex.unicodeScalars {
            if c == " " || c == "\n" || c == "\t" || c == "\r" { continue }
            guard let v = c.hexNibble else { return nil }
            nibbles.append(v)
        }
        if nibbles.count % 2 == 1 { nibbles.insert(0, at: 0) }
        bytes.reserveCapacity(nibbles.count / 2)
        var i = 0
        while i < nibbles.count {
            bytes.append(nibbles[i] << 4 | nibbles[i + 1])
            i += 2
        }
        self.init(bigEndian: bytes)
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    public var isZero: Bool { limbs.isEmpty }
    public var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }

    /// Number of significant bits (0 for zero).
    public var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 64 - top.leadingZeroBitCount
    }

    public func bit(_ i: Int) -> Bool {
        let limb = i / 64
        guard i >= 0, limb < limbs.count else { return false }
        return (limbs[limb] >> UInt64(i % 64)) & 1 == 1
    }

    /// Minimal big-endian magnitude; zero is empty.
    public func bigEndianBytes() -> [UInt8] {
        bigEndianBytes(count: (bitWidth + 7) / 8)
    }

    /// Big-endian magnitude left-padded to exactly `count` bytes. Traps if the
    /// value does not fit — a caller that pads a shared secret to the field
    /// size has a bug if it ever does not.
    public func bigEndianBytes(count: Int) -> [UInt8] {
        precondition((bitWidth + 7) / 8 <= count, "BigUInt does not fit in \(count) bytes")
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let limb = i / 8
            guard limb < limbs.count else { break }
            out[count - 1 - i] = UInt8(truncatingIfNeeded: limbs[limb] >> UInt64((i % 8) * 8))
        }
        return out
    }

    public var description: String {
        if isZero { return "0" }
        let hex = bigEndianBytes().map { byte -> String in
            let s = String(byte, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
        return String(hex.drop(while: { $0 == "0" }))
    }

    // MARK: Comparison

    public static func < (a: BigUInt, b: BigUInt) -> Bool {
        compare(a.limbs, b.limbs) < 0
    }

    /// -1, 0, 1 for normalized limb arrays.
    static func compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        var i = a.count - 1
        while i >= 0 {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    // MARK: Arithmetic

    public static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        let n = max(a.limbs.count, b.limbs.count)
        var out = [UInt64](repeating: 0, count: n + 1)
        var carry: UInt64 = 0
        for i in 0..<n {
            let x = i < a.limbs.count ? a.limbs[i] : 0
            let y = i < b.limbs.count ? b.limbs[i] : 0
            let (s1, o1) = x.addingReportingOverflow(y)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        out[n] = carry
        return BigUInt(limbs: out)
    }

    /// Traps when b > a: SheepSSH never needs a negative result, so one is a bug.
    public static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        precondition(!(a < b), "BigUInt subtraction underflow")
        var out = a.limbs
        var borrow: UInt64 = 0
        for i in 0..<out.count {
            let y = i < b.limbs.count ? b.limbs[i] : 0
            let (d1, o1) = out[i].subtractingReportingOverflow(y)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return BigUInt(limbs: out)
    }

    public static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        if a.isZero || b.isZero { return BigUInt() }
        var out = [UInt64](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<b.limbs.count {
                let (hi, lo) = mulAdd(a.limbs[i], b.limbs[j], out[i + j], carry)
                out[i + j] = lo
                carry = hi
            }
            out[i + b.limbs.count] = carry
        }
        return BigUInt(limbs: out)
    }

    public static func << (a: BigUInt, shift: Int) -> BigUInt {
        precondition(shift >= 0)
        if a.isZero || shift == 0 { return a }
        let limbShift = shift / 64
        let bitShift = UInt64(shift % 64)
        var out = [UInt64](repeating: 0, count: a.limbs.count + limbShift + 1)
        for i in 0..<a.limbs.count {
            out[i + limbShift] |= a.limbs[i] << bitShift
            if bitShift != 0 {
                out[i + limbShift + 1] |= a.limbs[i] >> (64 - bitShift)
            }
        }
        return BigUInt(limbs: out)
    }

    public static func >> (a: BigUInt, shift: Int) -> BigUInt {
        precondition(shift >= 0)
        let limbShift = shift / 64
        guard limbShift < a.limbs.count else { return BigUInt() }
        let bitShift = UInt64(shift % 64)
        var out = [UInt64](repeating: 0, count: a.limbs.count - limbShift)
        for i in 0..<out.count {
            out[i] = a.limbs[i + limbShift] >> bitShift
            if bitShift != 0, i + limbShift + 1 < a.limbs.count {
                out[i] |= a.limbs[i + limbShift + 1] << (64 - bitShift)
            }
        }
        return BigUInt(limbs: out)
    }

    /// Quotient and remainder by binary long division. Slow (one pass per bit
    /// of the dividend) and variable-time; SheepSSH divides only public
    /// numbers a few times per connection, where simple beats fast.
    public func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "BigUInt division by zero")
        if self < divisor { return (BigUInt(), self) }
        let width = bitWidth
        var quotient = [UInt64](repeating: 0, count: limbs.count)
        var remainder = BigUInt()
        var i = width - 1
        while i >= 0 {
            remainder = remainder << 1
            if bit(i) {
                if remainder.limbs.isEmpty { remainder.limbs = [1] } else { remainder.limbs[0] |= 1 }
            }
            if !(remainder < divisor) {
                remainder = remainder - divisor
                quotient[i / 64] |= 1 << UInt64(i % 64)
            }
            i -= 1
        }
        return (BigUInt(limbs: quotient), remainder)
    }

    public static func % (a: BigUInt, m: BigUInt) -> BigUInt {
        a.quotientAndRemainder(dividingBy: m).remainder
    }

    public static func / (a: BigUInt, m: BigUInt) -> BigUInt {
        a.quotientAndRemainder(dividingBy: m).quotient
    }

    /// Multiplicative inverse modulo `m`, or nil when gcd(self, m) != 1.
    /// Extended Euclid, variable-time: public values only (DSA's s⁻¹ mod q).
    public func inverse(modulo m: BigUInt) -> BigUInt? {
        precondition(!m.isZero)
        // Track the Bézout coefficient of `self` as (magnitude, isNegative).
        var r0 = m, r1 = self % m
        var t0 = (BigUInt(), false), t1 = (BigUInt(1), false)
        while !r1.isZero {
            let (q, r2) = r0.quotientAndRemainder(dividingBy: r1)
            // t2 = t0 - q * t1, with signs.
            let qt1 = (q * t1.0, t1.1)
            let t2 = Self.signedSub(t0, qt1)
            r0 = r1; r1 = r2
            t0 = t1; t1 = t2
        }
        guard r0 == BigUInt(1) else { return nil }
        if t0.1 {
            return m - (t0.0 % m)
        }
        return t0.0 % m
    }

    private static func signedSub(_ a: (BigUInt, Bool), _ b: (BigUInt, Bool)) -> (BigUInt, Bool) {
        // a - b = a + (-b)
        let nb = (b.0, !b.1)
        if a.1 == nb.1 { return (a.0 + nb.0, a.1) }
        if a.0 < nb.0 { return (nb.0 - a.0, nb.1) }
        let d = a.0 - nb.0
        return (d, d.isZero ? false : a.1)
    }

    /// Modular exponentiation with a PUBLIC exponent (signature checks).
    /// Odd moduli go through Montgomery; even ones (never used by SSH) through
    /// square-and-multiply with division.
    public func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero)
        if let context = MontgomeryContext(modulus: modulus) {
            return context.pow(self, publicExponent: exponent)
        }
        var result = BigUInt(1) % modulus
        var base = self % modulus
        for i in 0..<exponent.bitWidth {
            if exponent.bit(i) { result = (result * base) % modulus }
            base = (base * base) % modulus
        }
        return result
    }
}

/// a*b + c + d as a 128-bit (hi, lo) pair. Cannot overflow:
/// (2⁶⁴−1)² + 2(2⁶⁴−1) = 2¹²⁸−1.
@inline(__always)
func mulAdd(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64) -> (hi: UInt64, lo: UInt64) {
    let (h, l) = a.multipliedFullWidth(by: b)
    let (l1, o1) = l.addingReportingOverflow(c)
    let (l2, o2) = l1.addingReportingOverflow(d)
    return (h &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0), l2)
}

extension Unicode.Scalar {
    var hexNibble: UInt8? {
        switch value {
        case 0x30...0x39: return UInt8(value - 0x30)
        case 0x41...0x46: return UInt8(value - 0x41 + 10)
        case 0x61...0x66: return UInt8(value - 0x61 + 10)
        default: return nil
        }
    }
}
