import XCTest
@testable import SheepSSH

/// Userauth end to end against OpenSSH: every key type and file format,
/// query-then-sign, ssh-agent, banners, partial success, and (where the
/// environment provides a test account) password and keyboard-interactive.
final class AuthLiveTests: XCTestCase {
    struct Session {
        var driver: TransportDriver
        let auth: SSHUserAuth
        let sshd: LiveSSHD
    }

    func connect(options: [String] = [], authorizedKeys: [String] = [], user: String = LiveSSHD.userName,
                 preferences: AlgorithmPreferences = .legacy) throws -> Session {
        let sshd = try LiveSSHD(hostKeys: ["ed25519"], options: options, authorizedKeys: authorizedKeys)
        var driver = try TransportDriver(port: sshd.port, configuration: .init(preferences: preferences, hostKeyValidator: { _ in true }))
        try driver.run { $0.contains(.ready) }
        let auth = SSHUserAuth(transport: driver.transport, username: user)
        try auth.requestService()
        var session = Session(driver: driver, auth: auth, sshd: sshd)
        _ = try next(&session)
        XCTAssertTrue(auth.serviceAccepted)
        return session
    }

    /// Pumps until the userauth layer produces events; returns them.
    func next(_ s: inout Session) throws -> [SSHUserAuth.Event] {
        var out: [SSHUserAuth.Event] = []
        var processed = 0
        var failure: Error?
        let auth = s.auth
        let ok = try s.driver.run { events in
            while processed < events.count {
                if case .message(let m) = events[processed] {
                    do { out += try auth.handle(m) } catch { failure = error }
                }
                processed += 1
            }
            return !out.isEmpty || failure != nil
        }
        s.driver.events.removeAll()
        if let failure { throw failure }
        XCTAssertTrue(ok, "no userauth reply\n\(s.sshd.log())")
        return out
    }

    func signIn(_ signer: SSHSigner, algorithm: String, query: Bool = true, _ s: inout Session) throws -> [SSHUserAuth.Event] {
        if query {
            try s.auth.queryPublicKey(signer.publicKey, algorithm: algorithm)
            let reply = try next(&s)
            guard reply == [.publicKeyAcceptable(signer.publicKey)] else { return reply }
        }
        try s.auth.tryPublicKey(signer, algorithm: algorithm)
        return try next(&s)
    }

    func testNoneListsTheMethods() throws {
        var s = try connect()
        try s.auth.tryNone()
        let events = try next(&s)
        guard case .failure(.none, let methods, false) = events.first else { return XCTFail("\(events)") }
        XCTAssertTrue(methods.contains("publickey"))
    }

    func testEveryOpenSSHKeyFile() throws {
        for v in Vectors.keyFiles {
            let key = try OpenSSHPrivateKeyFile(text: v.privateText).decrypt(passphrase: v.passphrase.map { Array($0.utf8) })
            let signer = PrivateKeySigner(key, label: v.name)
            var s = try connect(authorizedKeys: [v.publicLine])
            let algorithm = publicKeyAlgorithm(for: key.publicKey, accepted: AlgorithmPreferences.legacy.hostKeys,
                                               serverSignatureAlgorithms: s.driver.transport.serverSignatureAlgorithms)!
            XCTAssertEqual(try signIn(signer, algorithm: algorithm, &s), [.success], "\(v.name) \(algorithm)\n\(s.sshd.log())")
        }
    }

    func testEveryPEMKeyFile() throws {
        for v in Vectors.pemKeys {
            if v.name.contains("3des"), !BlockCipherStream.tripleDESAvailable { continue }
            let key = try PEMPrivateKey.load(v.text, passphrase: v.passphrase.map { Array($0.utf8) })
            var s = try connect(authorizedKeys: [v.publicLine])
            let algorithm = publicKeyAlgorithm(for: key.publicKey, accepted: AlgorithmPreferences.legacy.hostKeys,
                                               serverSignatureAlgorithms: s.driver.transport.serverSignatureAlgorithms)!
            XCTAssertEqual(try signIn(PrivateKeySigner(key, label: v.name), algorithm: algorithm, &s), [.success], v.name)
        }
    }

    func testEveryRSASignatureAlgorithm() throws {
        let v = Vectors.keyFiles.first { $0.name == "rsa2048" }!
        let signer = PrivateKeySigner(try OpenSSHPrivateKeyFile(text: v.privateText).decrypt(passphrase: nil), label: "rsa")
        for algorithm in ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"] {
            var s = try connect(options: ["PubkeyAcceptedAlgorithms +ssh-rsa"], authorizedKeys: [v.publicLine])
            XCTAssertEqual(try signIn(signer, algorithm: algorithm, query: false, &s), [.success], algorithm)
        }
    }

    func testUnknownKeyIsRefusedAtTheQuery() throws {
        let v = Vectors.keyFiles.first { $0.name == "ecdsa256" }!
        let signer = PrivateKeySigner(try OpenSSHPrivateKeyFile(text: v.privateText).decrypt(passphrase: nil), label: "x")
        var s = try connect()       // not authorized
        let events = try signIn(signer, algorithm: "ecdsa-sha2-nistp256", &s)
        guard case .failure(.publicKeyQuery, _, false) = events.first else { return XCTFail("\(events)") }
    }

    func testAgentIdentities() throws {
        let agent = try LiveAgent()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sheepssh-agentkeys-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var lines: [String] = []
        for v in Vectors.keyFiles where v.passphrase == nil {
            let path = dir.appendingPathComponent(v.name).path
            try v.privateText.write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o600)
            try agent.add(path)
            lines.append(v.publicLine)
        }
        let identities = try SSHAgent.identities(socketPath: agent.socketPath)
        XCTAssertEqual(identities.count, lines.count)
        for identity in identities {
            var s = try connect(authorizedKeys: lines)
            let algorithm = publicKeyAlgorithm(for: identity.publicKey, accepted: AlgorithmPreferences.legacy.hostKeys,
                                               serverSignatureAlgorithms: s.driver.transport.serverSignatureAlgorithms)!
            XCTAssertEqual(try signIn(identity, algorithm: algorithm, &s), [.success], "\(identity.label) \(algorithm)")
        }
        XCTAssertThrowsError(try SSHAgent.identities(socketPath: "/tmp/definitely-no-agent-here"))
    }

    func testBannerArrives() throws {
        let banner = FileManager.default.temporaryDirectory.appendingPathComponent("sheepssh-banner-\(getpid())")
        try "Authorized access only\n".write(to: banner, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: banner) }
        var s = try connect(options: ["Banner \(banner.path)"])
        try s.auth.tryNone()
        var events = try next(&s)
        if events.count == 1, case .banner = events[0] { events += try next(&s) }
        XCTAssertEqual(events.first, .banner("Authorized access only\n"))
    }

    func testPartialSuccessNeedsASecondKey() throws {
        let a = Vectors.keyFiles.first { $0.name == "ed25519" }!, b = Vectors.keyFiles.first { $0.name == "ecdsa384" }!
        var s = try connect(options: ["AuthenticationMethods publickey,publickey"], authorizedKeys: [a.publicLine, b.publicLine])
        let first = PrivateKeySigner(try OpenSSHPrivateKeyFile(text: a.privateText).decrypt(passphrase: nil), label: "a")
        let second = PrivateKeySigner(try OpenSSHPrivateKeyFile(text: b.privateText).decrypt(passphrase: nil), label: "b")
        let one = try signIn(first, algorithm: "ssh-ed25519", query: false, &s)
        guard case .failure(.publicKey, _, true) = one.first else { return XCTFail("\(one)") }
        XCTAssertEqual(try signIn(second, algorithm: "ecdsa-sha2-nistp384", query: false, &s), [.success])
    }

    /// Needs an account with a known password: SHEEPSSH_PASSWORD_USER=user:password
    /// (the Linux container creates one; skipped elsewhere).
    func passwordAccount() throws -> (String, String) {
        guard let spec = ProcessInfo.processInfo.environment["SHEEPSSH_PASSWORD_USER"],
              let colon = spec.firstIndex(of: ":") else { throw XCTSkip("SHEEPSSH_PASSWORD_USER not set") }
        return (String(spec[..<colon]), String(spec[spec.index(after: colon)...]))
    }

    func testPassword() throws {
        let (user, password) = try passwordAccount()
        var s = try connect(options: ["PasswordAuthentication yes"], user: user)
        try s.auth.tryPassword("wrong-\(password)")
        guard case .failure(.password, _, false) = try next(&s).first else { return XCTFail() }
        try s.auth.tryPassword(password)
        XCTAssertEqual(try next(&s), [.success], s.sshd.log())
    }

    func testKeyboardInteractiveThroughPAM() throws {
        let (user, password) = try passwordAccount()
        var s = try connect(options: ["UsePAM yes", "KbdInteractiveAuthentication yes", "PasswordAuthentication no"], user: user)
        try s.auth.startKeyboardInteractive()
        var events = try next(&s)
        guard case .infoRequest(let request) = events.first else { return XCTFail("\(events)\n\(s.sshd.log())") }
        XCTAssertEqual(request.prompts.count, 1)
        XCTAssertFalse(request.prompts[0].echo, "a password prompt must not echo")
        try s.auth.respond([password])
        events = try next(&s)
        // PAM may send a zero-prompt round before the verdict.
        while case .infoRequest(let r) = events.first, r.prompts.isEmpty {
            try s.auth.respond([])
            events = try next(&s)
        }
        XCTAssertEqual(events, [.success], s.sshd.log())
    }
}

import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
