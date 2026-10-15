import XCTest
@testable import SheepSSH

final class AuthTests: XCTestCase {
    func testEveryPEMKeyLoads() throws {
        for v in Vectors.pemKeys {
            if v.name.contains("3des"), !BlockCipherStream.tripleDESAvailable { continue }
            let key = try PEMPrivateKey.load(v.text, passphrase: v.passphrase.map { Array($0.utf8) })
            XCTAssertEqual(key.publicKey.blob, try SSHPublicKey(openSSHLine: v.publicLine).blob, v.name)
            XCTAssertEqual(PEMPrivateKey.isEncrypted(v.text), v.passphrase != nil, v.name)
        }
    }

    func testPEMWrongOrMissingPassphrase() throws {
        for v in Vectors.pemKeys where v.passphrase != nil {
            if v.name.contains("3des"), !BlockCipherStream.tripleDESAvailable { continue }
            XCTAssertThrowsError(try PEMPrivateKey.load(v.text, passphrase: nil)) {
                XCTAssertEqual($0 as? SSHKeyError, .passphraseRequired)
            }
            // A wrong passphrase yields garbage that fails the padding or the
            // DER parse — never a key.
            XCTAssertThrowsError(try PEMPrivateKey.load(v.text, passphrase: Array("nope".utf8)), v.name)
        }
    }

    func testRefusedFormatsSayWhy() {
        XCTAssertThrowsError(try PEMPrivateKey.load(Vectors.encryptedPKCS8, passphrase: Array("pw".utf8))) {
            guard case .unsupportedCipher(let why) = $0 as? SSHKeyError else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("ssh-keygen -p"))
        }
        XCTAssertThrowsError(try PEMPrivateKey.load(Vectors.unmask("-----BEGIN DSA PRIV#ATE KEY-----\nAAAA\n-----END DSA PRIV#ATE KEY-----\n"), passphrase: nil))
        XCTAssertThrowsError(try PEMPrivateKey.load("hello", passphrase: nil))
    }

    func testTruncatedPEMBodiesThrow() throws {
        for v in Vectors.pemKeys where v.passphrase == nil {
            let lines = v.text.split(separator: "\n")
            let body = Array(Data(base64Encoded: lines.dropFirst().dropLast().joined())!)
            for cut in stride(from: 0, to: body.count, by: 5) {
                let text = "\(lines.first!)\n\(Data(body[0..<cut]).base64EncodedString())\n\(lines.last!)\n"
                XCTAssertThrowsError(try PEMPrivateKey.load(text, passphrase: nil), "\(v.name) cut \(cut)")
            }
        }
    }

    /// Our signer signs, our (independent) verifier checks — every key type,
    /// every RSA hash.
    func testSignersProduceVerifiableSignatures() throws {
        var keys: [(SSHPrivateKey, [HostKeyAlgorithm])] = []
        for v in Vectors.keyFiles where v.passphrase == nil {
            let k = try OpenSSHPrivateKeyFile(text: v.privateText).decrypt(passphrase: nil)
            keys.append((k, k.publicKey.keyType == "ssh-rsa" ? [.rsaSHA512, .rsaSHA256, .rsaSHA1]
                                                              : [HostKeyAlgorithm(rawValue: k.publicKey.keyType)!]))
        }
        for v in Vectors.pemKeys where v.passphrase == nil {
            let k = try PEMPrivateKey.load(v.text, passphrase: nil)
            keys.append((k, k.publicKey.keyType == "ssh-rsa" ? [.rsaSHA256] : [HostKeyAlgorithm(rawValue: k.publicKey.keyType)!]))
        }
        for (key, algorithms) in keys {
            let signer = PrivateKeySigner(key, label: "test")
            for algorithm in algorithms {
                let data = Array("sign me \(algorithm)".utf8)
                let blob = try signer.sign(data, algorithm: algorithm.rawValue)
                XCTAssertNoThrow(try SignatureVerifier.verify(signatureBlob: blob, data: data, key: key.publicKey, algorithm: algorithm),
                                 algorithm.rawValue)
                XCTAssertThrowsError(try SignatureVerifier.verify(signatureBlob: blob, data: data + [0], key: key.publicKey,
                                                                  algorithm: algorithm))
            }
            XCTAssertThrowsError(try signer.sign([1], algorithm: "ssh-dss"))
        }
    }

    func testPublicKeyAlgorithmChoice() throws {
        let rsa = try SSHPublicKey(openSSHLine: Vectors.keyFiles.first { $0.name == "rsa2048" }!.publicLine)
        let ed = try SSHPublicKey(openSSHLine: Vectors.keyFiles.first { $0.name == "ed25519" }!.publicLine)
        let modern = AlgorithmPreferences.modern.hostKeys, legacy = AlgorithmPreferences.legacy.hostKeys
        XCTAssertEqual(publicKeyAlgorithm(for: rsa, accepted: modern, serverSignatureAlgorithms: ["rsa-sha2-256", "rsa-sha2-512"]), "rsa-sha2-512")
        XCTAssertEqual(publicKeyAlgorithm(for: rsa, accepted: modern, serverSignatureAlgorithms: ["rsa-sha2-256"]), "rsa-sha2-256")
        XCTAssertNil(publicKeyAlgorithm(for: rsa, accepted: modern, serverSignatureAlgorithms: ["ssh-rsa"]))
        XCTAssertEqual(publicKeyAlgorithm(for: rsa, accepted: legacy, serverSignatureAlgorithms: nil), "ssh-rsa",
                       "no server-sig-algs: an old server, which knows ssh-rsa")
        XCTAssertEqual(publicKeyAlgorithm(for: rsa, accepted: modern, serverSignatureAlgorithms: nil), "rsa-sha2-512")
        XCTAssertEqual(publicKeyAlgorithm(for: ed, accepted: modern, serverSignatureAlgorithms: nil), "ssh-ed25519")
        XCTAssertNil(publicKeyAlgorithm(for: ed, accepted: [.rsaSHA256], serverSignatureAlgorithms: nil))
    }

    // MARK: Userauth message handling against scripted replies

    func ready() throws -> (SSHUserAuth, SSHTransport) {
        let t = SSHTransport(configuration: .init(hostKeyValidator: { _ in true }))
        let auth = SSHUserAuth(transport: t, username: "admin")
        var w = SSHWriter()
        w.writeByte(SSHMessage.serviceAccept)
        w.writeString("ssh-userauth")
        XCTAssertEqual(try auth.handle(w.bytes), [.serviceAccepted])
        return (auth, t)
    }

    func testGlobalRequestDuringAuthIsAnsweredNotFatal() throws {
        // A server keepalive while a password prompt is up (libssh answers it).
        let (auth, _) = try ready()
        var w = SSHWriter()
        w.writeByte(80)
        w.writeString("keepalive@openssh.com")
        w.writeBool(false)
        XCTAssertEqual(try auth.handle(w.bytes), [])
    }

    func testBareServiceAcceptIsAccepted() throws {
        // OpenSSH takes one without the service name ("buggy server").
        let auth = SSHUserAuth(transport: SSHTransport(configuration: .init(hostKeyValidator: { _ in true })), username: "admin")
        XCTAssertEqual(try auth.handle([SSHMessage.serviceAccept]), [.serviceAccepted])
        var w = SSHWriter()
        w.writeByte(SSHMessage.serviceAccept)
        w.writeString("ssh-connection")
        XCTAssertThrowsError(try SSHUserAuth(transport: SSHTransport(configuration: .init(hostKeyValidator: { _ in true })),
                                             username: "admin").handle(w.bytes))
    }

    func testRepliesWithNothingInFlightAreProtocolErrors() throws {
        let (auth, _) = try ready()
        XCTAssertThrowsError(try auth.handle([52]))
        XCTAssertThrowsError(try auth.handle([51, 0, 0, 0, 0, 0]))
        XCTAssertThrowsError(try auth.handle([60, 0, 0, 0, 0]))
        XCTAssertThrowsError(try auth.handle([94, 0, 0, 0, 0]), "channel data before authentication")
        XCTAssertThrowsError(try auth.handle([]))
    }

    func testBannerIsDeliveredAnytime() throws {
        let (auth, _) = try ready()
        var w = SSHWriter()
        w.writeByte(53)
        w.writeString("Authorized access only\r\n")
        w.writeString("")
        XCTAssertEqual(try auth.handle(w.bytes), [.banner("Authorized access only\r\n")])
    }

    func testMethodsNeedTheServiceFirst() {
        let t = SSHTransport(configuration: .init(hostKeyValidator: { _ in true }))
        let auth = SSHUserAuth(transport: t, username: "admin")
        XCTAssertThrowsError(try auth.tryNone()) { XCTAssertEqual($0 as? UserAuthError, .notReady) }
    }

    // MARK: Trying again on the same transport (SheepTerm 5.0 (19))

    /// A transport past its key exchange, in the clear, with the userauth
    /// service accepted: what SSHWorker holds when it asks for a password.
    func clearSession() throws -> (SSHUserAuth, SSHTransport) {
        let t = SSHTransport(configuration: .init(hostKeyValidator: { _ in true }))
        t._testEnterRunningInTheClear()
        let auth = SSHUserAuth(transport: t, username: "admin")
        var w = SSHWriter()
        w.writeByte(SSHMessage.serviceAccept)
        w.writeString("ssh-userauth")
        XCTAssertEqual(try auth.handle(w.bytes), [.serviceAccepted])
        return (auth, t)
    }

    /// The USERAUTH_REQUEST payloads queued on the wire (cleartext packets).
    func requests(_ t: SSHTransport) -> [[UInt8]] {
        let bytes = t.takeOutgoing()
        var out: [[UInt8]] = []
        var i = 0
        while i + 5 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let padding = Int(bytes[i + 4])
            out.append(Array(bytes[(i + 5)..<(i + 4 + length - padding)]))
            i += 4 + length
        }
        return out
    }

    func failure(_ methods: [String], partial: Bool = false) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(51)
        w.writeNameList(methods)
        w.writeBool(partial)
        return w.bytes
    }

    func passwordSent(_ payload: [UInt8]) throws -> String {
        var r = SSHReader(payload)
        XCTAssertEqual(try r.readByte(), 50)
        XCTAssertEqual(try r.readUTF8(), "admin")
        XCTAssertEqual(try r.readUTF8(), "ssh-connection")
        XCTAssertEqual(try r.readUTF8(), "password")
        XCTAssertFalse(try r.readBool())
        return try r.readUTF8()
    }

    /// A refused password leaves nothing in flight: the next attempt goes
    /// out on the SAME transport (no new connection), and it can succeed.
    func testPasswordRejectedThenRetriedOnTheSameTransport() throws {
        let (auth, t) = try clearSession()
        try auth.tryPassword("wrong-1")
        XCTAssertEqual(try requests(t).map(passwordSent), ["wrong-1"])
        XCTAssertEqual(try auth.handle(failure(["publickey", "password"])),
                       [.failure(method: .password, methods: ["publickey", "password"], partialSuccess: false)])
        XCTAssertFalse(auth.isAuthenticated)
        try auth.tryPassword("wrong-2")
        XCTAssertEqual(try auth.handle(failure(["password"])),
                       [.failure(method: .password, methods: ["password"], partialSuccess: false)])
        try auth.tryPassword("right")
        XCTAssertEqual(try requests(t).map(passwordSent), ["wrong-2", "right"], "each retry is one request on the same wire")
        XCTAssertEqual(try auth.handle([52]), [.success])
        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertThrowsError(try auth.tryPassword("again")) { XCTAssertEqual($0 as? UserAuthError, .notReady) }
    }

    /// While an attempt waits for its answer, a second one is refused — the
    /// retry is only allowed once the server has said no.
    func testRetryWaitsForTheServersAnswer() throws {
        let (auth, _) = try clearSession()
        try auth.tryPassword("one")
        XCTAssertThrowsError(try auth.tryPassword("two")) { XCTAssertEqual($0 as? UserAuthError, .methodInProgress) }
        _ = try auth.handle(failure(["password"]))
        XCTAssertNoThrow(try auth.tryPassword("two"))
    }

    /// keyboard-interactive (Aruba / FortiGate style "Password:" prompt):
    /// refused, started again on the same transport, answered, accepted.
    func testKeyboardInteractiveRejectedThenRetried() throws {
        let (auth, t) = try clearSession()
        func infoRequest() -> [UInt8] {
            var w = SSHWriter()
            w.writeByte(60)
            w.writeString(""); w.writeString(""); w.writeString("")
            w.writeUInt32(1)
            w.writeString("Password:"); w.writeBool(false)
            return w.bytes
        }
        for (answer, accepted) in [("wrong", false), ("right", true)] {
            try auth.startKeyboardInteractive()
            guard case .infoRequest(let request)? = try auth.handle(infoRequest()).first else { return XCTFail("no info request") }
            XCTAssertEqual(request.prompts.count, 1)
            try auth.respond([answer])
            if accepted {
                XCTAssertEqual(try auth.handle([52]), [.success])
            } else {
                XCTAssertEqual(try auth.handle(failure(["keyboard-interactive"])),
                               [.failure(method: .keyboardInteractive, methods: ["keyboard-interactive"], partialSuccess: false)])
            }
        }
        let sent = requests(t)
        XCTAssertEqual(sent.map(\.first), [50, 61, 50, 61], "start, answer, start again, answer — one transport")
        XCTAssertTrue(auth.isAuthenticated)
    }

    /// N refusals, then the server hangs up (sshd at MaxAuthTries): the
    /// transport reports the disconnect and refuses anything after it — the
    /// terminal failure SSHWorker turns into "authentication failed".
    func testServerHangsUpAfterRepeatedRefusals() throws {
        let (auth, t) = try clearSession()
        for attempt in 1...2 {
            try auth.tryPassword("wrong-\(attempt)")
            _ = try auth.handle(failure(["password"]))
        }
        try auth.tryPassword("wrong-3")
        var w = SSHWriter()
        w.writeByte(SSHMessage.disconnect)
        w.writeUInt32(2)
        w.writeString("Too many authentication failures")
        w.writeString("")
        let packet = try PacketProtection().seal(payload: w.bytes, sequence: 0)
        XCTAssertThrowsError(try t.receive(packet)) {
            XCTAssertEqual($0 as? SSHTransportError, .disconnectedByServer(reason: 2, description: "Too many authentication failures"))
        }
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertThrowsError(try t.send([50])) { XCTAssertEqual($0 as? SSHTransportError, .closed) }
    }
}
