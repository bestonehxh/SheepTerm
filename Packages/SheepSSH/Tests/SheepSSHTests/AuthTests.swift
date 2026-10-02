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
}
