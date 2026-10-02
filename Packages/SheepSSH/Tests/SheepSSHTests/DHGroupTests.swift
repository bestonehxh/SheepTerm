import XCTest
@testable import SheepSSH

final class DHGroupTests: XCTestCase {
    func testPrimesArePinned() {
        for group in [DHGroup.group1, .group14, .group16, .group18] {
            XCTAssertEqual(hex(SSHHash.sha256.hash(group.prime.bigEndianBytes())), Vectors.dhPrimeSHA256[group.bits],
                           group.name)
            XCTAssertEqual(group.generator, BigUInt(2))
        }
        XCTAssertEqual(DHGroup.group1.bits, 1024)
        XCTAssertEqual(DHGroup.group14.bits, 2048)
        XCTAssertEqual(DHGroup.group16.bits, 4096)
        XCTAssertEqual(DHGroup.group18.bits, 8192)
    }

    func testExchangeAgainstPython() {
        let groups = [1024: DHGroup.group1, 2048: .group14, 4096: .group16]
        for v in Vectors.dh {
            let g = groups[v.bits]!
            XCTAssertEqual(g.publicValue(privateExponent: big(v.x), exponentBits: 512), big(v.publicX))
            XCTAssertEqual(g.sharedSecret(peerPublic: big(v.publicX), privateExponent: big(v.y), exponentBits: 512),
                           big(v.shared))
        }
    }

    func testPeerPublicRangeIsEnforced() {
        let g = DHGroup.group14
        let x = BigUInt(12345)
        for bad in [BigUInt(), BigUInt(1), g.prime - BigUInt(1), g.prime, g.prime + BigUInt(5)] {
            XCTAssertNil(g.sharedSecret(peerPublic: bad, privateExponent: x, exponentBits: 64))
        }
        XCTAssertNotNil(g.sharedSecret(peerPublic: BigUInt(2), privateExponent: x, exponentBits: 64))
    }

    func testGroupExchangeValidation() {
        let p = DHGroup.group14.prime
        XCTAssertNotNil(DHGroup(validatingPrime: p, generator: BigUInt(2), bitRange: 2048...8192))
        XCTAssertNil(DHGroup(validatingPrime: p, generator: BigUInt(2), bitRange: 3072...8192), "too small")
        XCTAssertNil(DHGroup(validatingPrime: p + BigUInt(1), generator: BigUInt(2), bitRange: 1024...8192), "even")
        XCTAssertNil(DHGroup(validatingPrime: p, generator: BigUInt(1), bitRange: 1024...8192))
        XCTAssertNil(DHGroup(validatingPrime: p, generator: p - BigUInt(1), bitRange: 1024...8192))
    }
}
