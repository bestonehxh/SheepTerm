import XCTest
@testable import SheepSSH
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// End-to-end: SheepSSH's transport against a real OpenSSH sshd, one
/// algorithm at a time. Each case completes key exchange, verifies the host
/// key, asks for the ssh-userauth service, gets a USERAUTH_FAILURE for
/// method "none", rekeys, and does it once more under the new keys.
final class TransportLiveTests: XCTestCase {
    struct Case {
        var name: String
        var hostKey: String = "ed25519"
        var server: [String] = []
        var client: AlgorithmPreferences = .legacy
        var strict = true
    }

    func runCase(_ c: Case, file: StaticString = #filePath, line: UInt = #line) throws {
        let sshd = try LiveSSHD(hostKeys: [c.hostKey], options: c.server)
        var seenKey: SSHPublicKey?
        let config = SSHTransport.Configuration(preferences: c.client, strictKex: c.strict,
                                                groupExchangeBits: 1024...8192,
                                                hostKeyValidator: { _ in true })
        var driver = try TransportDriver(port: sshd.port, configuration: config)
        defer { driver.close() }
        do {
            let ok = try driver.run { $0.contains(.ready) }
            XCTAssertTrue(ok, "\(c.name): no ready\n\(sshd.log())", file: file, line: line)
            seenKey = driver.transport.hostKey
            // ssh-userauth service.
            var w = SSHWriter()
            w.writeByte(SSHMessage.serviceRequest)
            w.writeString("ssh-userauth")
            try driver.transport.send(w.bytes)
            XCTAssertTrue(try driver.run { $0.contains(where: { if case .message(let m) = $0 { return m.first == SSHMessage.serviceAccept }; return false }) },
                          "\(c.name): no SERVICE_ACCEPT\n\(sshd.log())", file: file, line: line)
            try authNone(&driver, c, file: file, line: line)
            try authPublicKey(&driver, c, file: file, line: line)
            try keepalive(&driver, c, file: file, line: line)
            // Rekey (OpenSSH allows it only after authentication), then prove
            // the new keys work in both directions.
            let before = driver.events.filter { if case .keysChanged = $0 { return true }; return false }.count
            driver.transport.requestRekey()
            XCTAssertTrue(try driver.run { $0.filter { if case .keysChanged = $0 { return true }; return false }.count == before + 1 },
                          "\(c.name): rekey did not finish\n\(sshd.log())", file: file, line: line)
            try keepalive(&driver, c, file: file, line: line)
        } catch {
            XCTFail("\(c.name): \(error)\n--- sshd log ---\n\(sshd.log())", file: file, line: line)
        }
        let expected = try SSHPublicKey(openSSHLine: String(contentsOfFile: LiveSSHD.hostKeyDirectory().appendingPathComponent(c.hostKey + ".pub").path, encoding: .utf8))
        XCTAssertEqual(seenKey?.blob, expected.blob, "\(c.name): host key", file: file, line: line)
    }

    private func authNone(_ driver: inout TransportDriver, _ c: Case, file: StaticString, line: UInt) throws {
        driver.events.removeAll { if case .message = $0 { return true }; return false }
        var w = SSHWriter()
        w.writeByte(50)                 // USERAUTH_REQUEST
        w.writeString(LiveSSHD.userName)
        w.writeString("ssh-connection")
        w.writeString("none")
        try driver.transport.send(w.bytes)
        XCTAssertTrue(try driver.run { $0.contains(where: { if case .message(let m) = $0 { return m.first == 51 }; return false }) },
                      "\(c.name): no USERAUTH_FAILURE", file: file, line: line)
    }

    /// publickey with the fixture's ed25519 key → USERAUTH_SUCCESS.
    func authPublicKey(_ driver: inout TransportDriver, _ c: Case, file: StaticString, line: UInt) throws {
        driver.events.removeAll { if case .message = $0 { return true }; return false }
        var body = SSHWriter()
        body.writeByte(50)
        body.writeString(LiveSSHD.userName)
        body.writeString("ssh-connection")
        body.writeString("publickey")
        body.writeBool(true)
        body.writeString("ssh-ed25519")
        body.writeString(LiveSSHD.clientKeyBlob)
        var signed = SSHWriter()
        signed.writeString(driver.transport.sessionID!)
        signed.writeBytes(body.bytes)
        var sig = SSHWriter()
        sig.writeString("ssh-ed25519")
        sig.writeString(Array(try LiveSSHD.clientKey.signature(for: signed.bytes)))
        var request = body
        request.writeString(sig.bytes)
        try driver.transport.send(request.bytes)
        XCTAssertTrue(try driver.run { $0.contains(where: { if case .message(let m) = $0 { return m.first == 52 }; return false }) },
                      "\(c.name): no USERAUTH_SUCCESS", file: file, line: line)
    }

    /// keepalive@openssh.com with want-reply → REQUEST_FAILURE, what SheepTerm uses.
    func keepalive(_ driver: inout TransportDriver, _ c: Case, file: StaticString, line: UInt) throws {
        driver.events.removeAll { if case .message = $0 { return true }; return false }
        var w = SSHWriter()
        w.writeByte(80)
        w.writeString("keepalive@openssh.com")
        w.writeBool(true)
        try driver.transport.send(w.bytes)
        XCTAssertTrue(try driver.run { $0.contains(where: { if case .message(let m) = $0 { return m.first == 82 }; return false }) },
                      "\(c.name): no REQUEST_FAILURE to keepalive", file: file, line: line)
    }

    static func only(kex: [KexAlgorithm]? = nil, hostKeys: [HostKeyAlgorithm]? = nil,
                     ciphers: [CipherAlgorithm]? = nil, macs: [MACAlgorithm]? = nil) -> AlgorithmPreferences {
        let l = AlgorithmPreferences.legacy
        return AlgorithmPreferences(kex: kex ?? l.kex.filter { $0 != .mlkem768x25519 }, hostKeys: hostKeys ?? l.hostKeys,
                                    ciphers: ciphers ?? l.ciphers, macs: macs ?? l.macs)
    }

    func testDefaultsAgainstDefaultServer() throws {
        try runCase(Case(name: "modern defaults", client: .modern))
        try runCase(Case(name: "legacy defaults", client: .legacy))
    }

    func testEveryKeyExchange() throws {
        let local = LiveSSHD.supported("kex")
        let testable = KexAlgorithm.allCases.filter { $0.isAvailable && local.contains($0.rawValue) }
        let serverAll = "KexAlgorithms " + testable.map(\.rawValue).joined(separator: ",")
        for kex in testable {
            try runCase(Case(name: kex.rawValue, server: [serverAll], client: Self.only(kex: [kex])))
        }
    }

    func testEveryHostKeyAlgorithm() throws {
        let local = LiveSSHD.supported("key")
        let testable = HostKeyAlgorithm.allCases.filter { local.contains($0.keyType) }
        let all = "HostKeyAlgorithms " + testable.map(\.rawValue).joined(separator: ",")
        let files: [HostKeyAlgorithm: String] = [.ed25519: "ed25519", .ecdsaP256: "ecdsa256", .ecdsaP384: "ecdsa384",
                                                 .ecdsaP521: "ecdsa521", .rsaSHA512: "rsa", .rsaSHA256: "rsa",
                                                 .rsaSHA1: "rsa", .dss: "dsa"]
        for alg in testable {
            try runCase(Case(name: alg.rawValue, hostKey: files[alg]!, server: [all], client: Self.only(hostKeys: [alg])))
        }
        try runCase(Case(name: "rsa-1024 via ssh-rsa", hostKey: "rsa1024", server: [all], client: Self.only(hostKeys: [.rsaSHA1])))
    }

    func testEveryCipher() throws {
        let local = LiveSSHD.supported("cipher")
        let testable = CipherAlgorithm.allCases.filter { $0.isAvailable && local.contains($0.rawValue) }
        let all = "Ciphers " + testable.map(\.rawValue).joined(separator: ",")
        for cipher in testable {
            try runCase(Case(name: cipher.rawValue, server: [all], client: Self.only(ciphers: [cipher])))
        }
    }

    func testEveryMACWithCTRAndCBC() throws {
        let local = LiveSSHD.supported("mac")
        let testable = MACAlgorithm.allCases.filter { local.contains($0.rawValue) }
        let macs = "MACs " + testable.map(\.rawValue).joined(separator: ",")
        let ciphers = "Ciphers aes128-ctr,aes256-cbc"
        for mac in testable {
            for cipher in [CipherAlgorithm.aes128CTR, .aes256CBC] {
                try runCase(Case(name: "\(cipher.rawValue)+\(mac.rawValue)", server: [macs, ciphers],
                                 client: Self.only(ciphers: [cipher], macs: [mac])))
            }
        }
    }

    func testMLKEMHybridWhereAvailable() throws {
        guard KexAlgorithm.mlkem768x25519.isAvailable else { throw XCTSkip("no ML-KEM in this build") }
        guard LiveSSHD.supported("kex").contains("mlkem768x25519-sha256") else { throw XCTSkip("local sshd lacks ML-KEM") }
        try runCase(Case(name: "mlkem768x25519-sha256", server: ["KexAlgorithms mlkem768x25519-sha256"],
                         client: AlgorithmPreferences(kex: [.mlkem768x25519], hostKeys: [.ed25519], ciphers: [.chacha20Poly1305], macs: [])))
    }

    func testWithoutStrictKex() throws {
        try runCase(Case(name: "no strict kex", client: Self.only(ciphers: [.chacha20Poly1305]), strict: false))
        try runCase(Case(name: "no strict kex, cbc", server: ["Ciphers aes128-cbc", "MACs hmac-sha1"], client: Self.only(ciphers: [.aes128CBC], macs: [.hmacSHA1]), strict: false))
    }

    func testStrictKexIsNegotiated() throws {
        let sshd = try LiveSSHD(hostKeys: ["ed25519"], options: [])
        var driver = try TransportDriver(port: sshd.port, configuration: .init(hostKeyValidator: { _ in true }))
        defer { driver.close() }
        try driver.run { $0.contains(.ready) }
        XCTAssertTrue(driver.transport.isStrictKex)
        XCTAssertNotNil(driver.transport.serverSignatureAlgorithms, "ext-info-c should bring server-sig-algs")
    }

    func testRejectedHostKeyStopsBeforeNewKeys() throws {
        let sshd = try LiveSSHD(hostKeys: ["ed25519"], options: [])
        var driver = try TransportDriver(port: sshd.port, configuration: .init(hostKeyValidator: { _ in false }))
        defer { driver.close() }
        XCTAssertThrowsError(try driver.run { $0.contains(.ready) }) {
            XCTAssertEqual($0 as? SSHTransportError, .hostKeyRejected)
        }
    }

    func testNoCommonCipherIsReportedWithTheServerOffer() throws {
        let sshd = try LiveSSHD(hostKeys: ["ed25519"], options: ["Ciphers aes128-cbc"])
        var driver = try TransportDriver(port: sshd.port, configuration: .init(preferences: .modern, hostKeyValidator: { _ in true }))
        defer { driver.close() }
        XCTAssertThrowsError(try driver.run { $0.contains(.ready) }) {
            guard case .negotiation(.noCommonAlgorithm(let category, let offer)) = $0 as? SSHTransportError else {
                return XCTFail("\($0)")
            }
            XCTAssertTrue(category.hasPrefix("cipher"))
            XCTAssertEqual(offer, ["aes128-cbc"])
        }
    }

    /// Bulk traffic crosses the byte-count rekey threshold; the transport
    /// must rekey on its own and keep going.
    func testAutomaticRekeyByVolume() throws {
        let sshd = try LiveSSHD(hostKeys: ["ed25519"], options: [])
        var config = SSHTransport.Configuration(hostKeyValidator: { _ in true })
        config.rekeyAfterBytes = 64 * 1024
        var driver = try TransportDriver(port: sshd.port, configuration: config)
        defer { driver.close() }
        try driver.run { $0.contains(.ready) }
        var sr = SSHWriter()
        sr.writeByte(SSHMessage.serviceRequest)
        sr.writeString("ssh-userauth")
        try driver.transport.send(sr.bytes)
        try authPublicKey(&driver, Case(name: "volume"), file: #filePath, line: #line)
        var w = SSHWriter()
        w.writeByte(SSHMessage.ignore)
        w.writeString([UInt8](repeating: 0x41, count: 8000))
        for _ in 0..<40 { try driver.transport.send(w.bytes) }
        let rekeys = { (e: [SSHTransport.Event]) in e.filter { if case .keysChanged = $0 { return true }; return false }.count }
        XCTAssertTrue(try driver.run { rekeys($0) >= 2 }, sshd.log())
        try keepalive(&driver, Case(name: "after volume rekey"), file: #filePath, line: #line)
    }
}
