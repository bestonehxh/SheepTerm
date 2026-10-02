import XCTest
@testable import SheepSSH

final class BigUIntTests: XCTestCase {
    func testArithmeticAgainstPython() {
        for v in Vectors.bigArith {
            let a = big(v.a), b = big(v.b)
            XCTAssertEqual(a + b, big(v.sum))
            XCTAssertEqual(a * b, big(v.product))
            let (q, r) = a.quotientAndRemainder(dividingBy: b)
            XCTAssertEqual(q, big(v.quotient), "\(v.a) / \(v.b)")
            XCTAssertEqual(r, big(v.remainder))
            XCTAssertEqual((a + b) - b, a)
            XCTAssertEqual(q * b + r, a)
        }
    }

    func testModPowAgainstPython() {
        for v in Vectors.modPow {
            XCTAssertEqual(big(v.base).power(big(v.exponent), modulus: big(v.modulus)), big(v.result),
                           "bits \(big(v.modulus).bitWidth)")
        }
    }

    func testSecretExponentPathMatchesWhateverTheWindowCount() {
        let v = Vectors.modPow[9]
        let ctx = MontgomeryContext(modulus: big(v.modulus))!
        let e = big(v.exponent)
        for extra in [0, 1, 3, 4, 64, 200] {
            XCTAssertEqual(ctx.pow(big(v.base), secretExponent: e, exponentBits: e.bitWidth + extra), big(v.result))
        }
        XCTAssertEqual(ctx.pow(big(v.base), secretExponent: BigUInt(), exponentBits: 256), BigUInt(1))
    }

    func testModInverse() {
        for v in Vectors.modInverse {
            let inv = big(v.a).inverse(modulo: big(v.modulus))
            XCTAssertEqual(inv, v.inverse.map(big))
            if let inv { XCTAssertEqual((big(v.a) * inv) % big(v.modulus), BigUInt(1)) }
        }
    }

    func testBytesRoundTripAndShifts() {
        let x = big("0102030405060708090a0b0c0d0e0f10111213")
        XCTAssertEqual(hex(x.bigEndianBytes()), "0102030405060708090a0b0c0d0e0f10111213")
        XCTAssertEqual(hex(x.bigEndianBytes(count: 21)), "00000102030405060708090a0b0c0d0e0f10111213")
        XCTAssertEqual(BigUInt(bigEndian: [0, 0, 0, 5]), BigUInt(5))
        XCTAssertEqual(BigUInt(bigEndian: [UInt8]()), BigUInt())
        XCTAssertEqual(BigUInt().bigEndianBytes(), [])
        XCTAssertEqual((x << 77) >> 77, x)
        XCTAssertEqual(x >> 1000, BigUInt())
        XCTAssertEqual(BigUInt(1) << 64, big("10000000000000000"))
        XCTAssertEqual(big("ff").bitWidth, 8)
        XCTAssertEqual(BigUInt().bitWidth, 0)
        XCTAssertEqual(big("abc").description, "abc")
        XCTAssertNil(BigUInt(hex: "xyz"))
    }

    func testMontgomeryRefusesEvenOrTrivialModuli() {
        XCTAssertNil(MontgomeryContext(modulus: BigUInt(10)))
        XCTAssertNil(MontgomeryContext(modulus: BigUInt(1)))
        XCTAssertNotNil(MontgomeryContext(modulus: BigUInt(3)))
        // Single-limb modulus exercises the k == 1 path of the CIOS loop.
        XCTAssertEqual(BigUInt(3).power(BigUInt(200), modulus: BigUInt(1_000_000_007)), BigUInt(136_318_165))
    }
}
