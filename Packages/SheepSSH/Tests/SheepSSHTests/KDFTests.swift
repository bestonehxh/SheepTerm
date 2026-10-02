import XCTest
@testable import SheepSSH

final class KDFTests: XCTestCase {
    func testBlowfishTablesArePi() {
        XCTAssertEqual(BlowfishTables.p[0], 0x243F_6A88)
        XCTAssertEqual(BlowfishTables.p[17], 0x8979_FB1B)
        XCTAssertEqual(BlowfishTables.s0[0], 0xD131_0BA6)
        XCTAssertEqual(BlowfishTables.s3[255], 0x3AC3_72E6)
        XCTAssertEqual(BlowfishTables.p.count, 18)
        for s in [BlowfishTables.s0, BlowfishTables.s1, BlowfishTables.s2, BlowfishTables.s3] {
            XCTAssertEqual(s.count, 256)
        }
    }

    /// Blowfish itself, from Eric Young's test set (key = 8 zero bytes and
    /// all-ones), through the plain key schedule: expand0state on the initial
    /// state is Blowfish_key.
    func testBlowfishKnownAnswers() {
        let cases: [(key: [UInt8], plain: (UInt32, UInt32), cipher: (UInt32, UInt32))] = [
            ([UInt8](repeating: 0, count: 8), (0, 0), (0x4EF9_9745, 0x6198_DD78)),
            ([UInt8](repeating: 0xFF, count: 8), (0xFFFF_FFFF, 0xFFFF_FFFF), (0x5186_6FD5, 0xB85E_CB8A)),
            (hex("0123456789abcdef"), (0x1111_1111, 0x1111_1111), (0x61F9_C380, 0x2281_B096)),
        ]
        for c in cases {
            let state = BlowfishState()
            state.expand0(key: c.key)
            let (l, r) = state.encipher(c.plain.0, c.plain.1)
            XCTAssertEqual(l, c.cipher.0)
            XCTAssertEqual(r, c.cipher.1)
        }
    }

    func testBcryptPBKDFVectors() throws {
        for v in Vectors.bcryptPBKDF {
            let key = try BcryptPBKDF.derive(password: hex(v.password), salt: hex(v.salt),
                                             rounds: v.rounds, keyLength: v.key.count / 2)
            XCTAssertEqual(hex(key), v.key, "rounds \(v.rounds) len \(v.key.count / 2)")
        }
    }

    func testBcryptPBKDFRejectsBadParameters() {
        XCTAssertThrowsError(try BcryptPBKDF.derive(password: [], salt: [1], rounds: 1, keyLength: 16))
        XCTAssertThrowsError(try BcryptPBKDF.derive(password: [1], salt: [], rounds: 1, keyLength: 16))
        XCTAssertThrowsError(try BcryptPBKDF.derive(password: [1], salt: [1], rounds: 0, keyLength: 16))
        XCTAssertThrowsError(try BcryptPBKDF.derive(password: [1], salt: [1], rounds: 1, keyLength: 0))
        XCTAssertThrowsError(try BcryptPBKDF.derive(password: [1], salt: [1], rounds: 1, keyLength: 1025))
    }
}
