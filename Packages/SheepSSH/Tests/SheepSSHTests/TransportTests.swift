import XCTest
@testable import SheepSSH

/// The transport against a scripted peer — hostile orderings no real server
/// sends on purpose.
final class TransportTests: XCTestCase {
    func transport(strict: Bool = true) -> SSHTransport {
        let t = SSHTransport(configuration: .init(strictKex: strict, hostKeyValidator: { _ in true }))
        t.start()
        _ = t.takeOutgoing()
        return t
    }

    func packet(_ payload: [UInt8]) -> [UInt8] {
        try! PacketProtection().seal(payload: payload, sequence: 0)
    }

    func serverKexInit(strict: Bool = true, follows: Bool = false, kex: [String] = ["curve25519-sha256"]) -> [UInt8] {
        let k = KexInit(cookie: [UInt8](repeating: 1, count: 16),
                        kexAlgorithms: kex + (strict ? ["kex-strict-s-v00@openssh.com"] : []),
                        hostKeyAlgorithms: ["ssh-ed25519"], ciphers: ["aes128-ctr"], macs: ["hmac-sha2-256"])
        var p = k.payload
        if follows { p[p.count - 5] = 1 }
        return p
    }

    let version = Array("SSH-2.0-Scripted\r\n".utf8)

    func testKexInitRoundTrip() throws {
        let k = KexInit(cookie: Array(0..<16), kexAlgorithms: ["a", "b"], hostKeyAlgorithms: ["h"], ciphers: ["c"], macs: ["m"])
        let parsed = try KexInit(payload: k.payload)
        XCTAssertEqual(parsed.kexAlgorithms, ["a", "b"])
        XCTAssertEqual(parsed.ciphersServerToClient, ["c"])
        XCTAssertEqual(parsed.compressionClientToServer, ["none"])
        XCTAssertFalse(parsed.firstKexPacketFollows)
        XCTAssertEqual(parsed.payload, k.payload)
        for cut in 0..<k.payload.count { XCTAssertThrowsError(try KexInit(payload: Array(k.payload[0..<cut]))) }
    }

    func testNegotiationFollowsClientOrder() throws {
        let server = KexInit(cookie: Array(0..<16), kexAlgorithms: ["diffie-hellman-group14-sha256", "curve25519-sha256"],
                             hostKeyAlgorithms: ["rsa-sha2-256", "ssh-ed25519"],
                             ciphers: ["aes128-ctr", "chacha20-poly1305@openssh.com"], macs: ["hmac-sha1", "hmac-sha2-256"])
        let n = try Negotiation.negotiate(client: .modern, server: server)
        XCTAssertEqual(n.kex, .curve25519)
        XCTAssertEqual(n.hostKey, .ed25519)
        XCTAssertEqual(n.cipherClientToServer, .chacha20Poly1305)
        XCTAssertNil(n.macClientToServer, "AEAD needs no MAC")
        let ctrOnly = KexInit(cookie: Array(0..<16), kexAlgorithms: ["curve25519-sha256"], hostKeyAlgorithms: ["ssh-ed25519"],
                              ciphers: ["aes128-ctr"], macs: ["hmac-sha1", "hmac-sha2-256"])
        XCTAssertEqual(try Negotiation.negotiate(client: .modern, server: ctrOnly).macClientToServer, .hmacSHA256)
        let noMac = KexInit(cookie: Array(0..<16), kexAlgorithms: ["curve25519-sha256"], hostKeyAlgorithms: ["ssh-ed25519"],
                            ciphers: ["aes128-ctr"], macs: ["umac-64@openssh.com"])
        XCTAssertThrowsError(try Negotiation.negotiate(client: .modern, server: noMac))
        let oldBox = KexInit(cookie: Array(0..<16),
                             kexAlgorithms: ["diffie-hellman-group1-sha1", "ext-info-s", "kex-strict-s-v00@openssh.com"],
                             hostKeyAlgorithms: ["ssh-dss"], ciphers: ["3des-cbc", "aes128-cbc"], macs: ["hmac-md5"])
        XCTAssertThrowsError(try Negotiation.negotiate(client: .modern, server: oldBox)) {
            XCTAssertEqual($0 as? NegotiationError,
                           .noCommonAlgorithm(category: "key exchange", serverOffers: ["diffie-hellman-group1-sha1"]),
                           "the device's offer is reported without the protocol markers")
        }
        XCTAssertEqual(try Negotiation.negotiate(client: .legacy.available, server: oldBox).kex, .dhGroup1)
    }

    func testPinnedHostKeyTypesGoFirst() {
        let p = AlgorithmPreferences.legacy.preferringHostKeyTypes(["ssh-rsa", "ecdsa-sha2-nistp256"])
        XCTAssertEqual(p.hostKeys, [.rsaSHA512, .rsaSHA256, .rsaSHA1, .ecdsaP256, .ed25519, .ecdsaP521, .ecdsaP384, .dss])
        XCTAssertEqual(AlgorithmPreferences.modern.preferringHostKeyTypes([]).hostKeys, AlgorithmPreferences.modern.hostKeys)
        XCTAssertEqual(AlgorithmPreferences.modern.preferringHostKeyTypes(["ssh-dss"]).hostKeys, AlgorithmPreferences.modern.hostKeys,
                       "a type the list does not offer adds nothing")
    }

    func testClientKexInitCarriesTheMarkers() throws {
        let t = SSHTransport(configuration: .init(hostKeyValidator: { _ in true }))
        t.start()
        let out = t.takeOutgoing()
        let line = Array("SSH-2.0-SheepSSH_1.0\r\n".utf8)
        XCTAssertEqual(Array(out.prefix(line.count)), line)
        let rest = Array(out[line.count...])
        let size = try XCTUnwrap(try PacketProtection().packetSize(in: rest[...], sequence: 0))
        let kexInit = try KexInit(payload: try PacketProtection().open(rest[0..<size], sequence: 0))
        XCTAssertTrue(kexInit.kexAlgorithms.contains("kex-strict-c-v00@openssh.com"))
        XCTAssertTrue(kexInit.kexAlgorithms.contains("ext-info-c"))
        XCTAssertEqual(kexInit.compressionClientToServer, ["none"])
        XCTAssertFalse(kexInit.ciphersClientToServer.contains("aes256-cbc"), "modern offers no CBC")
    }

    func testBannerLinesBeforeTheVersionAreSkipped() throws {
        let t = transport()
        try t.receive(Array("Welcome\r\nto the switch\n".utf8))
        XCTAssertNil(t.serverVersion)
        try t.receive(Array("SSH-2.0-Cisco-1.25\r".utf8))
        XCTAssertNil(t.serverVersion, "no newline yet")
        try t.receive([0x0A])
        XCTAssertEqual(t.serverVersion, "SSH-2.0-Cisco-1.25")
        let t2 = transport()
        try t2.receive(Array("SSH-1.99-OldBox\n".utf8))
        XCTAssertEqual(t2.serverVersion, "SSH-1.99-OldBox")
    }

    func testSSH1AndEndlessPreamblesAreRefused() {
        XCTAssertThrowsError(try transport().receive(Array("SSH-1.5-Ancient\r\n".utf8)))
        let t = transport()
        XCTAssertThrowsError(try {
            for _ in 0..<2000 { try t.receive(Array(String(repeating: "x", count: 60).appending("\n").utf8)) }
        }())
        XCTAssertThrowsError(try transport().receive([UInt8](repeating: 0x41, count: 9000)), "one line without a newline")
    }

    /// Terrapin (CVE-2023-48795): an attacker who slips a packet in before
    /// the server's KEXINIT shifts the sequence numbers. With strict kex
    /// negotiated, that must be fatal.
    func testTerrapinPrefixIsFatalUnderStrictKex() {
        let t = transport()
        var w = SSHWriter()
        w.writeByte(SSHMessage.ignore)
        w.writeString("")
        XCTAssertThrowsError(try t.receive(version + packet(w.bytes) + packet(serverKexInit()))) {
            guard case .protocolError(let m) = $0 as? SSHTransportError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("first packet"), m)
        }
    }

    func testIgnoreBeforeKexInitIsFineWithoutStrictKex() throws {
        let t = transport()
        var w = SSHWriter()
        w.writeByte(SSHMessage.ignore)
        w.writeString("")
        try t.receive(version + packet(w.bytes) + packet(serverKexInit(strict: false)))
        XCTAssertFalse(t.isStrictKex)
    }

    func testCleartextExtInfoIsIgnored() throws {
        // Without strict kex an attacker could inject EXT_INFO before the
        // first NEWKEYS and pin server-sig-algs to ssh-rsa (SHA-1).
        let t = transport(strict: false)
        var w = SSHWriter()
        w.writeByte(SSHMessage.extInfo)
        w.writeUInt32(1)
        w.writeString("server-sig-algs")
        w.writeString("ssh-rsa")
        try t.receive(version + packet(serverKexInit(strict: false)) + packet(w.bytes))
        XCTAssertNil(t.serverSignatureAlgorithms)
    }

    func testServerVersionIsHashedAsReceived() throws {
        // A Latin-1 byte in the comment must reach H unchanged — a lossy
        // UTF-8 round trip turns it into U+FFFD and every signature fails.
        let t = transport()
        let line = Array("SSH-2.0-Foo_1.0 ".utf8) + [0xA9] + Array("Vendor".utf8)
        try t.receive(line + [0x0D, 0x0A])
        XCTAssertEqual(t.serverVersionBytes, line)
        var w = SSHWriter()
        ExchangeHashPrefix(clientVersion: "c", serverVersion: t.serverVersionBytes, clientKexInit: [], serverKexInit: []).write(into: &w)
        XCTAssertTrue(w.bytes.starts(with: [0, 0, 0, 1, 0x63, 0, 0, 0, UInt8(line.count)] + line))
    }

    func testNonKexMessageDuringStrictInitialKexIsFatal() {
        let t = transport()
        XCTAssertThrowsError(try t.receive(version + packet(serverKexInit()) + packet([SSHMessage.debug, 0, 0, 0, 0, 0, 0, 0, 0, 0])))
    }

    func testApplicationMessageBeforeKeysIsFatal() {
        let t = transport(strict: false)
        XCTAssertThrowsError(try t.receive(version + packet(serverKexInit(strict: false)) + packet([94, 0, 0, 0, 0])))
    }

    func testNewKeysBeforeKexIsFatal() {
        let t = transport()
        XCTAssertThrowsError(try t.receive(version + packet(serverKexInit()) + packet([SSHMessage.newKeys])))
    }

    func testWrongKexGuessIsIgnored() throws {
        // The server guesses diffie-hellman-group14-sha256 first; we choose
        // curve25519, so its guessed packet must be dropped silently.
        let t = transport()
        let kexInit = serverKexInit(follows: true, kex: ["diffie-hellman-group14-sha256", "curve25519-sha256"])
        try t.receive(version + packet(kexInit) + packet([SSHMessage.kexDHInit, 0, 0, 0, 1, 5]))
        // The next kex packet would be parsed; a garbage reply is now an error.
        XCTAssertThrowsError(try t.receive(packet([SSHMessage.kexDHReply, 0, 0, 0, 1, 5])))
    }

    func testDisconnectIsReported() {
        let t = transport()
        var w = SSHWriter()
        w.writeByte(SSHMessage.disconnect)
        w.writeUInt32(DisconnectReason.tooManyConnections.rawValue)
        w.writeString("go away")
        w.writeString("")
        XCTAssertThrowsError(try t.receive(version + packet(w.bytes))) {
            XCTAssertEqual($0 as? SSHTransportError, .disconnectedByServer(reason: 12, description: "go away"))
        }
        XCTAssertThrowsError(try t.receive([0])) { XCTAssertEqual($0 as? SSHTransportError, .closed) }
    }

    func testSendBeforeKeysIsRefused() {
        XCTAssertThrowsError(try transport().send([94]))
    }

    func testSmallGroupExchangePrimeIsItsOwnError() throws {
        let prefix = ExchangeHashPrefix(clientVersion: "a", serverVersion: Array("b".utf8), clientKexInit: [], serverKexInit: [])
        let gex = GroupExchangeDH(prefix: prefix, hash: .sha256, bits: 2048...8192, preferred: 4096, exponentBits: 512)
        _ = try gex.start()
        var w = SSHWriter()
        w.writeByte(SSHMessage.kexDHReply)
        w.writeMPInt(DHGroup.group1.prime)        // 1024-bit
        w.writeMPInt(BigUInt(2))
        XCTAssertThrowsError(try gex.handle(w.bytes)) { XCTAssertEqual($0 as? KexError, .groupTooSmall(bits: 1024)) }
        let legacy = GroupExchangeDH(prefix: prefix, hash: .sha256, bits: 1024...8192, preferred: 4096, exponentBits: 512)
        _ = try legacy.start()
        XCTAssertNoThrow(try legacy.handle(w.bytes), "legacy's range takes it")
    }

    func testDHExponentSizing() {
        let n = NegotiatedAlgorithms(kex: .dhGroup14SHA256, hostKey: .ed25519, cipherClientToServer: .chacha20Poly1305,
                                     cipherServerToClient: .aes128CTR, macClientToServer: nil, macServerToClient: .hmacSHA512)
        XCTAssertEqual(KeyDerivation.dhExponentBits(for: n), 1024, "chacha's 64-byte key → 2 × 512 bits")
        let small = NegotiatedAlgorithms(kex: .dhGroup1, hostKey: .ed25519, cipherClientToServer: .aes128CTR,
                                         cipherServerToClient: .aes128CTR, macClientToServer: .hmacSHA1, macServerToClient: .hmacSHA1)
        XCTAssertEqual(KeyDerivation.dhExponentBits(for: small), 320)
    }
}
