import XCTest
@testable import SheepSSH

/// Throughput and latency numbers, not assertions. Skipped unless
/// SHEEPSSH_BENCH=1:  SHEEPSSH_BENCH=1 swift test -c release --filter Bench
final class BenchTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["SHEEPSSH_BENCH"] == "1" else { throw XCTSkip("SHEEPSSH_BENCH not set") }
    }

    func measure(_ label: String, bytes: Int = 0, _ body: () throws -> Void) rethrows {
        let t0 = Date()
        try body()
        let dt = Date().timeIntervalSince(t0)
        if bytes > 0 {
            print(String(format: "BENCH %@ %.1f MB/s (%.3f s)", label, Double(bytes) / dt / 1e6, dt))
        } else {
            print(String(format: "BENCH %@ %.1f ms", label, dt * 1000))
        }
    }

    func testPacketThroughput() throws {
        let payload = [UInt8](repeating: 0x61, count: 32 * 1024)
        let packets = 640   // 20 MB
        let cases: [(CipherAlgorithm, MACAlgorithm?)] = [(.chacha20Poly1305, nil), (.aes256GCM, nil),
                                                         (.aes128CTR, .hmacSHA256ETM), (.aes256CBC, .hmacSHA1)]
        for (c, m) in cases {
            let k = PacketTests.keys(c, m)
            let out = try PacketProtection(keys: k, encrypting: true)
            let inp = try PacketProtection(keys: k, encrypting: false)
            var sealed: [[UInt8]] = []
            try measure("seal \(c.rawValue) \(m?.rawValue ?? "")", bytes: payload.count * packets) {
                for i in 0..<packets { sealed.append(try out.seal(payload: payload, sequence: UInt32(i))) }
            }
            try measure("open \(c.rawValue) \(m?.rawValue ?? "")", bytes: payload.count * packets) {
                for (i, p) in sealed.enumerated() {
                    let size = try XCTUnwrap(try inp.packetSize(in: p[...], sequence: UInt32(i)))
                    _ = try inp.open(p[0..<size], sequence: UInt32(i))
                }
            }
        }
    }

    func testKeyExchangeCost() throws {
        for (g, name) in [(DHGroup.group14, "group14"), (.group16, "group16"), (.group18, "group18")] {
            let x = randomExponent(bits: 1024)
            measure("DH \(name) g^x, 1024-bit exponent") { _ = g.publicValue(privateExponent: x, exponentBits: 1024) }
        }
        try measure("bcrypt_pbkdf 16 rounds") {
            _ = try BcryptPBKDF.derive(password: Array("pw".utf8), salt: [UInt8](repeating: 1, count: 16), rounds: 16, keyLength: 48)
        }
    }

    /// A whole session: 50 MB down through a real sshd.
    func testLiveDownload() throws {
        let s = try LiveSession()
        let id = try s.exec("head -c 50000000 /dev/zero")
        let t0 = Date()
        XCTAssertTrue(try s.pump(timeout: 120) { _ in s.isClosed(id) })
        let dt = Date().timeIntervalSince(t0)
        let n = s.output(id).count
        XCTAssertEqual(n, 50_000_000)
        print(String(format: "BENCH live download (%@) %.1f MB/s", s.driver.transport.negotiated?.cipherServerToClient.rawValue ?? "?",
                     Double(n) / dt / 1e6))
    }

    /// A 3 MB paste up through a real sshd.
    func testLiveUpload() throws {
        let s = try LiveSession()
        let id = try s.exec("wc -c")
        try s.pump { _ in s.replies(id)["exec"] != nil }
        let t0 = Date()
        try s.connection.write(id, [UInt8](repeating: 0x42, count: 3_000_000))
        try s.connection.sendEOF(id)
        XCTAssertTrue(try s.pump(timeout: 120) { _ in s.isClosed(id) })
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "BENCH live upload 3 MB %.1f MB/s", 3.0 / dt))
    }
}
