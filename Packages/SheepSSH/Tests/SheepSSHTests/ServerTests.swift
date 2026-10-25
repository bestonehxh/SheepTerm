import XCTest
@testable import SheepSSH

/// The server role (SheepTerm's File Server) against SheepSSH's own client,
/// in process and sans-I/O: two state machines with the bytes moved between
/// them by hand. Every key exchange, cipher, MAC and host-key algorithm the
/// server offers is negotiated for real and carries data both ways.
final class ServerTests: XCTestCase {

    /// One ed25519 + one RSA 3072 key for the whole class (RSA generation
    /// costs a moment), made through the real HostKeyStore.
    nonisolated(unsafe) static var keys: [SSHPrivateKey] = []
    nonisolated(unsafe) static var keyDirectory: URL?

    override class func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sheepssh-server-\(UUID().uuidString)")
        keyDirectory = dir
        keys = (try? HostKeyStore.ensureAll(directory: dir)) ?? []
    }

    override class func tearDown() {
        if let dir = keyDirectory { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    var signers: [SSHSigner] {
        Self.keys.map { PrivateKeySigner($0, label: "host key") }
    }

    // MARK: Harness

    final class Pair {
        let client: SSHTransport
        let server: SSHServerTransport
        let auth: SSHUserAuth
        let serverConnection: SSHServerConnection
        var clientConnection: SSHConnection?
        var authEvents: [SSHUserAuth.Event] = []
        var clientEvents: [SSHConnection.Event] = []
        var serverEvents: [SSHServerConnection.Event] = []
        var clientError: Error?
        var serverError: Error?
        var presentedKey: SSHPublicKey?
        var negotiated: NegotiatedAlgorithms?
        var serverNegotiated: NegotiatedAlgorithms?
        /// Bytes moved on the wire, both directions.
        var wireBytes = 0

        init(client prefs: AlgorithmPreferences, server serverPrefs: AlgorithmPreferences = .server,
             signers: [SSHSigner], username: String = "sheepterm", password: String = "s3cret",
             strict: Bool = true, rekeyAfterBytes: UInt64 = 1 << 30) {
            let box = KeyBox()
            client = SSHTransport(configuration: .init(preferences: prefs, strictKex: strict,
                                                       rekeyAfterBytes: rekeyAfterBytes,
                                                       hostKeyValidator: { key in box.key = key; return true }))
            server = SSHServerTransport(configuration: .init(preferences: serverPrefs, strictKex: strict,
                                                             rekeyAfterBytes: rekeyAfterBytes, hostKeys: signers))
            auth = SSHUserAuth(transport: client, username: username)
            serverConnection = SSHServerConnection(transport: server,
                                                   configuration: .init(username: "sheepterm", password: password))
            self.keyBox = box
            client.start()
            server.start()
        }
        private let keyBox: KeyBox
        final class KeyBox: @unchecked Sendable { var key: SSHPublicKey? }

        /// Moves bytes until neither side has anything left to say.
        func pump(limit: Int = 10_000) {
            for _ in 0..<limit {
                let toServer = client.takeOutgoing()
                let toClient = server.takeOutgoing()
                if toServer.isEmpty && toClient.isEmpty { return }
                wireBytes += toServer.count + toClient.count
                if !toServer.isEmpty, serverError == nil {
                    do {
                        try server.receive(toServer)
                        for event in server.takeEvents() {
                            switch event {
                            case .message(let payload):
                                try serverConnection.handle(payload)
                                serverEvents += serverConnection.takeEvents()
                            case .keysChanged(let n): serverNegotiated = n
                            case .ready: break
                            }
                        }
                    } catch { serverError = error }
                }
                if !toClient.isEmpty, clientError == nil {
                    do {
                        try client.receive(toClient)
                        for event in client.takeEvents() {
                            switch event {
                            case .ready:
                                presentedKey = keyBox.key
                                try auth.requestService()
                            case .keysChanged(let n): negotiated = n
                            case .message(let payload):
                                if let connection = clientConnection {
                                    try connection.handle(payload)
                                    clientEvents += connection.takeEvents()
                                } else {
                                    authEvents += try auth.handle(payload)
                                }
                            }
                        }
                    } catch { clientError = error }
                }
            }
            XCTFail("pump did not settle")
        }

        /// Handshake + password; true when the server let us in.
        func login(_ password: String = "s3cret") throws -> Bool {
            pump()
            guard authEvents.contains(.serviceAccepted) else { return false }
            authEvents.removeAll()
            try auth.tryPassword(password)
            pump()
            if authEvents.contains(.success) {
                clientConnection = SSHConnection(transport: client)
                return true
            }
            return false
        }

        /// Opens a session and runs `exec`, returns the client channel and
        /// the server channel.
        func openExec(_ command: String) throws -> (UInt32, UInt32) {
            let connection = try XCTUnwrap(clientConnection)
            let id = try connection.openSession()
            pump()
            var serverID: UInt32?
            for case .channelOpened(let s) in serverEvents { serverID = s }
            try connection.requestExec(id, command: command)
            pump()
            let s = try XCTUnwrap(serverID)
            XCTAssertTrue(serverEvents.contains(.channelRequest(s, .exec(command))))
            serverConnection.replyRequest(s, success: true)
            pump()
            XCTAssertTrue(clientEvents.contains(.channelRequestReply(id, request: "exec", success: true)))
            return (id, s)
        }

        func clientData(_ id: UInt32) -> [UInt8] {
            clientEvents.reduce(into: []) { if case .data(id, let b) = $1 { $0 += b } }
        }

        func serverData(_ id: UInt32) -> [UInt8] {
            serverEvents.reduce(into: []) { if case .data(id, let b) = $1 { $0 += b } }
        }
    }

    func only(kex: KexAlgorithm = .curve25519, hostKey: HostKeyAlgorithm = .ed25519,
              cipher: CipherAlgorithm = .aes128CTR, mac: MACAlgorithm = .hmacSHA256) -> AlgorithmPreferences {
        AlgorithmPreferences(kex: [kex], hostKeys: [hostKey], ciphers: [cipher], macs: [mac])
    }

    /// Full round: negotiate exactly `prefs`, log in, exec, data both ways.
    func roundTrip(_ prefs: AlgorithmPreferences, file: StaticString = #filePath, line: UInt = #line) throws {
        let pair = Pair(client: prefs, signers: signers)
        XCTAssertTrue(try pair.login(), "login with \(prefs)", file: file, line: line)
        XCTAssertNil(pair.clientError, file: file, line: line)
        XCTAssertNil(pair.serverError, file: file, line: line)
        let n = try XCTUnwrap(pair.negotiated, file: file, line: line)
        XCTAssertEqual(n.kex, prefs.kex[0], file: file, line: line)
        XCTAssertEqual(n.hostKey, prefs.hostKeys[0], file: file, line: line)
        XCTAssertEqual(n.cipherClientToServer, prefs.ciphers[0], file: file, line: line)
        XCTAssertEqual(pair.serverNegotiated, n, "both ends agree", file: file, line: line)
        if !prefs.ciphers[0].isAEAD { XCTAssertEqual(n.macServerToClient, prefs.macs[0], file: file, line: line) }
        let expectedType = prefs.hostKeys[0].keyType
        XCTAssertEqual(pair.presentedKey?.keyType, expectedType, file: file, line: line)
        let (c, s) = try pair.openExec("scp -f /x")
        let up = Array((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try pair.clientConnection!.write(c, up)
        pair.pump()
        XCTAssertEqual(pair.serverData(s), up, file: file, line: line)
        let down = Array((0..<90_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try pair.serverConnection.write(s, down)
        pair.pump()
        XCTAssertEqual(pair.clientData(c), down, file: file, line: line)
    }

    // MARK: Algorithms

    func testEveryOfferedKeyExchange() throws {
        XCTAssertEqual(Self.keys.count, 2)
        let offered = SSHServerTransport(configuration: .init(hostKeys: signers)).offer.kex
        XCTAssertEqual(Set(offered), Set(ServerKexFactory.supported))
        for kex in offered { try roundTrip(only(kex: kex)) }
    }

    func testEveryOfferedHostKeyAlgorithm() throws {
        let offered = SSHServerTransport(configuration: .init(hostKeys: signers)).offer.hostKeys
        XCTAssertEqual(offered, [.ed25519, .rsaSHA512, .rsaSHA256, .rsaSHA1],
                       "ssh-rsa stays on offer: ArubaOS copy scp: knows nothing newer")
        for hostKey in offered { try roundTrip(only(hostKey: hostKey)) }
    }

    func testEveryOfferedCipher() throws {
        let offered = SSHServerTransport(configuration: .init(hostKeys: signers)).offer.ciphers
        XCTAssertTrue(offered.contains(.aes128CBC) && offered.contains(.chacha20Poly1305))
        for cipher in offered { try roundTrip(only(cipher: cipher)) }
    }

    func testEveryOfferedMAC() throws {
        let offered = SSHServerTransport(configuration: .init(hostKeys: signers)).offer.macs
        XCTAssertTrue(offered.contains(.hmacSHA1) && offered.contains(.hmacMD5))
        for mac in offered { try roundTrip(only(mac: mac)) }
    }

    /// The legacy-switch shape end to end: group1, 3DES/CBC, hmac-sha1, ssh-rsa.
    func testOldSwitchShape() throws {
        try roundTrip(only(kex: .dhGroup14SHA1, hostKey: .rsaSHA1, cipher: .aes128CBC, mac: .hmacSHA1))
        try roundTrip(only(kex: .dhGroup1, hostKey: .rsaSHA1, cipher: .aes256CBC, mac: .hmacMD5))
    }

    /// The client's order picks (RFC 4253 §7.1), not the server's.
    func testClientOrderWins() throws {
        let prefs = AlgorithmPreferences(kex: [.ecdhP384, .curve25519], hostKeys: [.rsaSHA256, .ed25519],
                                         ciphers: [.aes192CTR, .chacha20Poly1305], macs: [.hmacSHA512, .hmacSHA256])
        let pair = Pair(client: prefs, signers: signers)
        XCTAssertTrue(try pair.login())
        XCTAssertEqual(pair.negotiated?.kex, .ecdhP384)
        XCTAssertEqual(pair.negotiated?.hostKey, .rsaSHA256)
        XCTAssertEqual(pair.negotiated?.cipherServerToClient, .aes192CTR)
        XCTAssertEqual(pair.negotiated?.macClientToServer, .hmacSHA512)
    }

    /// What the server cannot run is never offered: an offer it could not
    /// honour used to fail after negotiation.
    func testOfferHoldsOnlyWhatTheServerCanRun() throws {
        let edOnly = [signers[0]]
        let t = SSHServerTransport(configuration: .init(preferences: .legacy, hostKeys: edOnly))
        XCTAssertEqual(t.offer.hostKeys, [.ed25519], "no RSA key → no rsa algorithms; no ECDSA/DSS signer")
        for kex in [KexAlgorithm.dhGexSHA1, .dhGexSHA256, .mlkem768x25519, .dhGroup16, .dhGroup18] {
            XCTAssertFalse(t.offer.kex.contains(kex), "\(kex)")
        }
        let pair = Pair(client: only(hostKey: .ecdsaP256), signers: signers)
        pair.pump()
        guard case .negotiation(.noCommonAlgorithm(category: "host key", _))? = pair.serverError as? SSHTransportError else {
            return XCTFail("expected a host-key negotiation failure, got \(String(describing: pair.serverError))")
        }
        let gexOnly = Pair(client: only(kex: .dhGexSHA256), signers: signers)
        gexOnly.pump()
        XCTAssertNotNil(gexOnly.serverError)
    }

    func testWithoutStrictKex() throws {
        let pair = Pair(client: .modern, signers: signers, strict: false)
        XCTAssertTrue(try pair.login())
        XCTAssertFalse(pair.server.isStrictKex)
        let strict = Pair(client: .modern, signers: signers)
        XCTAssertTrue(try strict.login())
        XCTAssertTrue(strict.server.isStrictKex)
    }

    // MARK: Rekey

    func testRekeyFromEitherSideKeepsTheSessionAndTheKey() throws {
        let pair = Pair(client: .modern, signers: signers)
        XCTAssertTrue(try pair.login())
        let firstKey = pair.presentedKey
        let session = pair.server.sessionID
        let (c, s) = try pair.openExec("scp -t /x")
        let before = pair.server.packetsReceived

        pair.client.requestRekey()
        try pair.clientConnection!.write(c, Array(repeating: 1, count: 1000))   // held through the kex
        pair.pump()
        XCTAssertNil(pair.serverError); XCTAssertNil(pair.clientError)
        XCTAssertEqual(pair.serverData(s).count, 1000)

        pair.server.requestRekey()
        try pair.serverConnection.write(s, Array(repeating: 2, count: 2000))
        pair.pump()
        XCTAssertNil(pair.serverError); XCTAssertNil(pair.clientError)
        XCTAssertEqual(pair.clientData(c), Array(repeating: 2, count: 2000))
        XCTAssertEqual(pair.server.sessionID, session, "a rekey keeps the session id")
        XCTAssertEqual(pair.presentedKey, firstKey)
        XCTAssertGreaterThan(pair.server.packetsReceived, before + 4)
    }

    func testRekeyAfterBytes() throws {
        let pair = Pair(client: only(cipher: .aes128GCM), signers: signers, rekeyAfterBytes: 256 * 1024)
        XCTAssertTrue(try pair.login())
        let (c, s) = try pair.openExec("scp -f /x")
        var sent: [UInt8] = []
        for round in 0..<8 {
            let chunk = [UInt8](repeating: UInt8(round), count: 100_000)
            sent += chunk
            try pair.serverConnection.write(s, chunk)
            pair.pump()
        }
        XCTAssertNil(pair.clientError); XCTAssertNil(pair.serverError)
        XCTAssertEqual(pair.clientData(c), sent, "800 KB across three automatic rekeys")
    }

    // MARK: Authentication

    func testWrongPasswordIsRefusedAndTheThirdEndsTheConnection() throws {
        let pair = Pair(client: .modern, signers: signers)
        XCTAssertFalse(try pair.login("wrong"))
        XCTAssertTrue(pair.authEvents.contains { if case .failure(.password, ["password"], false) = $0 { return true }; return false })
        XCTAssertFalse(pair.serverConnection.isAuthenticated)
        pair.authEvents.removeAll()
        try pair.auth.tryPassword("s3cre")                  // a prefix
        pair.pump()
        XCTAssertFalse(pair.authEvents.contains(.success))
        XCTAssertEqual(pair.serverConnection.passwordFailures, 2)
        try pair.auth.tryPassword("s3cret ")                // the right one plus a byte
        pair.pump()
        XCTAssertFalse(pair.authEvents.contains(.success))
        XCTAssertEqual(pair.serverError as? ConnectionError, .protocolError("too many authentication failures"))
        guard case .disconnectedByServer(reason: 14, _)? = pair.clientError as? SSHTransportError else {
            return XCTFail("the client is told: \(String(describing: pair.clientError))")
        }
    }

    func testWrongUserIsRefused() throws {
        let pair = Pair(client: .modern, signers: signers, username: "admin")
        XCTAssertFalse(try pair.login())
        XCTAssertFalse(pair.serverConnection.isAuthenticated)
    }

    func testEmptyConfiguredPasswordLetsNobodyIn() throws {
        let pair = Pair(client: .modern, signers: signers, password: "")
        XCTAssertFalse(try pair.login(""))
    }

    func testNoneProbeIsNotAFailure() throws {
        let pair = Pair(client: .modern, signers: signers)
        pair.pump()
        try pair.auth.tryNone()
        pair.pump()
        XCTAssertEqual(pair.serverConnection.passwordFailures, 0)
        pair.authEvents.removeAll()
        try pair.auth.tryPassword("s3cret")
        pair.pump()
        XCTAssertTrue(pair.authEvents.contains(.success))
    }

    func testAuthRequestFloodEndsTheConnection() throws {
        let pair = Pair(client: .modern, signers: signers)
        pair.pump()
        for _ in 0..<20 where pair.serverError == nil {
            try? pair.auth.tryNone()
            pair.pump()
        }
        XCTAssertEqual(pair.serverError as? ConnectionError, .protocolError("too many authentication requests"))
    }

    /// The comparison: equal only for equal strings, whatever the lengths,
    /// through fixed-size digests (no early exit on a length mismatch —
    /// `constantTimeEqual` alone has one).
    func testSecretsCompareInConstantTime() {
        XCTAssertTrue(ServerAuth.secretsEqual("s3cret", "s3cret"))
        XCTAssertTrue(ServerAuth.secretsEqual("", ""))
        XCTAssertFalse(ServerAuth.secretsEqual("s3cre", "s3cret"))
        XCTAssertFalse(ServerAuth.secretsEqual("s3cret!", "s3cret"))
        XCTAssertFalse(ServerAuth.secretsEqual("S3cret", "s3cret"))
        XCTAssertFalse(ServerAuth.secretsEqual("", "s3cret"))
        XCTAssertFalse(ServerAuth.secretsEqual(String(repeating: "a", count: 10_000), "a"))
        // Coarse timing check: a mismatch in the first byte and one in the
        // last byte of a long secret cost the same work (both hash the whole
        // input and compare 32 bytes). Generous bound — a loaded CI box.
        let secret = String(repeating: "x", count: 4096)
        let early = "y" + String(repeating: "x", count: 4095)
        let late = String(repeating: "x", count: 4095) + "y"
        func time(_ s: String) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<300 { _ = ServerAuth.secretsEqual(s, secret) }
            return Double(DispatchTime.now().uptimeNanoseconds - start)
        }
        _ = time(early); _ = time(late)
        let a = min(time(early), time(early)), b = min(time(late), time(late))
        XCTAssertLessThan(max(a, b) / min(a, b), 3.0, "early \(a) ns vs late \(b) ns")
    }

    // MARK: Connection gate

    func testNoChannelBeforeAuthentication() throws {
        let pair = Pair(client: .modern, signers: signers)
        pair.pump()
        var w = SSHWriter()
        w.writeByte(90); w.writeString("session"); w.writeUInt32(0); w.writeUInt32(1 << 20); w.writeUInt32(32768)
        XCTAssertThrowsError(try pair.serverConnection.handle(w.bytes)) {
            XCTAssertEqual($0 as? ConnectionError, .protocolError("message 90 before authentication"))
        }
    }

    func testOnlySessionChannelsAndSubsystemOrExecReachTheOwner() throws {
        let pair = Pair(client: .modern, signers: signers)
        XCTAssertTrue(try pair.login())
        let connection = pair.clientConnection!
        _ = try connection.openDirectTCPIP(host: "10.0.0.1", port: 22)
        pair.pump()
        XCTAssertTrue(pair.clientEvents.contains { if case .channelOpenFailed = $0 { return true }; return false },
                      "no port forwarding through the file server")
        let id = try connection.openSession()
        pair.pump()
        try connection.requestPTY(id, columns: 80, rows: 24)
        try connection.requestShell(id)
        pair.pump()
        XCTAssertTrue(pair.clientEvents.contains(.channelRequestReply(id, request: "pty-req", success: false)))
        XCTAssertTrue(pair.clientEvents.contains(.channelRequestReply(id, request: "shell", success: false)))
        try connection.sendKeepalive()
        pair.pump()
        XCTAssertTrue(pair.clientEvents.contains(.globalReply(success: false)), "a global request is answered, not dropped")
        XCTAssertNil(pair.serverError)
    }

    func testDataPastTheWindowIsRefused() throws {
        let pair = Pair(client: .modern, signers: signers)
        XCTAssertTrue(try pair.login())
        let (_, s) = try pair.openExec("scp -t x")
        // A hand-made CHANNEL_DATA bigger than the whole window.
        var w = SSHWriter()
        w.writeByte(94); w.writeUInt32(s); w.writeString([UInt8](repeating: 0, count: Int(SSHServerConnection.windowSize) + 1))
        XCTAssertThrowsError(try pair.serverConnection.handle(w.bytes))
    }

    func testFinishSendsEverythingThenEOFAndClose() throws {
        let pair = Pair(client: .modern, signers: signers)
        XCTAssertTrue(try pair.login())
        let (c, s) = try pair.openExec("scp -f x")
        let big = [UInt8](repeating: 9, count: 3 * 1024 * 1024)       // more than the client's window
        try pair.serverConnection.write(s, big)
        XCTAssertGreaterThan(pair.serverConnection.pendingOutput(s), 0, "held for the client's window")
        pair.serverConnection.sendExitStatus(channel: s, code: 0)
        try pair.serverConnection.finish(s)
        pair.pump()
        XCTAssertEqual(pair.clientData(c).count, big.count)
        XCTAssertTrue(pair.clientEvents.contains(.eof(c)))
        XCTAssertTrue(pair.clientEvents.contains(.exitStatus(c, 0)))
        // The client answers our CLOSE with its own; the channel is gone on
        // both ends.
        XCTAssertTrue(pair.clientEvents.contains(.closed(c)))
        XCTAssertTrue(pair.serverEvents.contains(.closed(s)))
    }

    // MARK: Host keys

    func testHostKeyStoreFilesAndReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sheepssh-hk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        // ed25519 only here (RSA generation is covered by the class setUp).
        let edPath = dir.appendingPathComponent(HostKeyStore.ed25519FileName).path
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = try HostKeyStore.ensureEd25519(path: edPath)
        let again = try HostKeyStore.ensureEd25519(path: edPath)
        XCTAssertEqual(first.publicKey, again.publicKey, "loaded, not regenerated")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: edPath)[.posixPermissions] as? Int, 0o600)
        // Corrupt → replaced with a new key, no throw.
        try Data("-----BEGIN OPENSSH PRIVATE KEY-----\ngarbage\n".utf8).write(to: URL(fileURLWithPath: edPath))
        let replaced = try HostKeyStore.ensureEd25519(path: edPath)
        XCTAssertNotEqual(replaced.publicKey, first.publicKey)
        XCTAssertEqual(try HostKeyStore.ensureEd25519(path: edPath).publicKey, replaced.publicKey)
        // A key of the wrong type in the file is replaced too.
        try FileManager.default.removeItem(atPath: edPath)
        try FileManager.default.copyItem(atPath: Self.keyDirectory!.appendingPathComponent(HostKeyStore.rsaFileName).path,
                                         toPath: edPath)
        guard case .ed25519 = try HostKeyStore.ensureEd25519(path: edPath).kind else { return XCTFail("not ed25519") }
        // An empty file, a directory in the way of nothing: still a key.
        try Data().write(to: URL(fileURLWithPath: edPath))
        XCTAssertNoThrow(try HostKeyStore.ensureEd25519(path: edPath))
    }

    func testEnsureAllLayoutAndRSASize() throws {
        let dir = try XCTUnwrap(Self.keyDirectory)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o700)
        for name in [HostKeyStore.ed25519FileName, HostKeyStore.rsaFileName] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.posixPermissions] as? Int,
                           0o600, name)
        }
        XCTAssertEqual(Self.keys.map(\.publicKey.keyType), ["ssh-ed25519", "ssh-rsa"])
        XCTAssertEqual(Self.keys[1].publicKey.bits, 3072)
        let reloaded = try HostKeyStore.ensureAll(directory: dir)
        XCTAssertEqual(reloaded.map(\.publicKey), Self.keys.map(\.publicKey), "kept across restarts")
        // OpenSSH reads both files (the format a user would check them with).
        let keygen = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        guard FileManager.default.isExecutableFile(atPath: keygen.path) else { return }
        for (name, key) in zip([HostKeyStore.ed25519FileName, HostKeyStore.rsaFileName], Self.keys) {
            let process = Process()
            process.executableURL = keygen
            process.arguments = ["-y", "-f", dir.appendingPathComponent(name).path]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, name)
            XCTAssertEqual(try SSHPublicKey(openSSHLine: line.trimmingCharacters(in: .whitespacesAndNewlines)), key.publicKey, name)
        }
    }
}
