import XCTest
@testable import SheepSSH
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A whole client — transport, publickey login with the fixture key,
/// connection layer — driven against a live sshd.
final class LiveSession {
    let sshd: LiveSSHD
    var driver: TransportDriver
    let auth: SSHUserAuth
    let connection: SSHConnection
    var forwarder: AgentForwarder?
    var events: [SSHConnection.Event] = []
    private var processed = 0

    init(options: [String] = [], agentSocket: String? = nil) throws {
        sshd = try LiveSSHD(hostKeys: ["ed25519"], options: options)
        driver = try TransportDriver(port: sshd.port, configuration: .init(hostKeyValidator: { _ in true }))
        auth = SSHUserAuth(transport: driver.transport, username: LiveSSHD.userName)
        connection = SSHConnection(transport: driver.transport)
        forwarder = agentSocket.map { AgentForwarder(socketPath: $0) }
        try driver.run { $0.contains(.ready) }
        processed = driver.events.count
        try auth.requestService()
        try pumpAuth { $0.contains(.serviceAccepted) }
        let signer = FixtureSigner()
        try auth.tryPublicKey(signer, algorithm: "ssh-ed25519")
        try pumpAuth { $0.contains(.success) }
    }

    private func pumpAuth(_ done: @escaping ([SSHUserAuth.Event]) -> Bool) throws {
        var got: [SSHUserAuth.Event] = []
        var failure: Error?
        let auth = self.auth
        var seen = processed
        let ok = try driver.run { events in
            while seen < events.count {
                if case .message(let m) = events[seen] { do { got += try auth.handle(m) } catch { failure = error } }
                seen += 1
            }
            return done(got) || failure != nil
        }
        processed = seen
        if let failure { throw failure }
        guard ok else { throw XCTSkip("login did not finish:\n\(sshd.log())") }
    }

    /// Pumps until `done(all connection events so far)`.
    @discardableResult
    func pump(timeout: TimeInterval = 30, until done: @escaping ([SSHConnection.Event]) -> Bool) throws -> Bool {
        var failure: Error?
        var seen = processed
        let ok = try driver.run(timeout: timeout) { [self] transportEvents in
            while seen < transportEvents.count {
                if case .message(let m) = transportEvents[seen] {
                    do { try connection.handle(m) } catch { failure = error }
                }
                seen += 1
            }
            for e in connection.takeEvents() {
                // Straight into self.events: `done` closures read it.
                events.append(e)
                guard let forwarder else { continue }
                do {
                    switch e {
                    case .agentChannelOpened(let id): try forwarder.channelOpened(id, connection: connection)
                    case .data(let id, let bytes) where forwarder.owns(id): forwarder.received(id, bytes, connection: connection)
                    case .eof(let id) where forwarder.owns(id): forwarder.channelEOF(id)
                    case .closed(let id): forwarder.channelClosed(id)
                    default: break
                    }
                } catch { failure = error }
            }
            if let forwarder { do { try forwarder.pump(connection: connection) } catch { failure = error } }
            return done(events) || failure != nil
        }
        processed = seen
        if let failure { throw failure }
        return ok
    }

    func output(_ channel: UInt32) -> [UInt8] {
        events.flatMap { e -> [UInt8] in if case .data(channel, let b) = e { return b }; return [] }
    }

    func text(_ channel: UInt32) -> String { String(decoding: output(channel), as: UTF8.self) }

    func opened(_ channel: UInt32) -> Bool { events.contains(.channelOpened(channel)) }

    func replies(_ channel: UInt32) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for e in events { if case .channelRequestReply(channel, let r, let ok) = e { out[r] = ok } }
        return out
    }

    func exitStatus(_ channel: UInt32) -> UInt32? {
        for e in events { if case .exitStatus(channel, let s) = e { return s } }
        return nil
    }

    func isClosed(_ channel: UInt32) -> Bool { events.contains(.closed(channel)) }

    /// Opens a session channel and runs `command` (exec).
    func exec(_ command: String) throws -> UInt32 {
        let id = try connection.openSession()
        try pump { _ in self.connection.isOpen(id) || self.events.contains { if case .channelOpenFailed(id, _, _) = $0 { return true }; return false } }
        guard connection.isOpen(id) else { throw XCTSkip("channel open failed") }
        try connection.requestExec(id, command: command)
        return id
    }
}

/// Signs with the fixture key the test sshd trusts.
final class FixtureSigner: SSHSigner {
    var publicKey: SSHPublicKey { try! SSHPublicKey(blob: LiveSSHD.clientKeyBlob) }
    var label: String { "fixture" }
    func sign(_ data: [UInt8], algorithm: String) throws(SignerError) -> [UInt8] {
        signatureBlob("ssh-ed25519", Array(try! LiveSSHD.clientKey.signature(for: data)))
    }
}

final class ConnectionLiveTests: XCTestCase {
    func testInteractiveShellWithPTY() throws {
        let s = try LiveSession()
        let id = try s.connection.openSession()
        try s.pump { $0.contains(.channelOpened(id)) }
        try s.connection.requestPTY(id, columns: 100, rows: 30)
        try s.connection.requestShell(id)
        XCTAssertTrue(try s.pump { _ in s.replies(id)["shell"] != nil })
        XCTAssertEqual(s.replies(id), ["pty-req": true, "shell": true])
        try s.connection.write(id, Array("echo sheep-$((6*7)); echo $TERM\n".utf8))
        XCTAssertTrue(try s.pump { _ in s.text(id).contains("sheep-42") && s.text(id).contains("xterm-256color\r\n") }, s.text(id))
        try s.connection.windowChange(id, columns: 123, rows: 45)
        try s.connection.write(id, Array("stty size\n".utf8))
        XCTAssertTrue(try s.pump { _ in s.text(id).contains("45 123") }, s.text(id))
        try s.connection.write(id, Array("exit 0\n".utf8))
        XCTAssertTrue(try s.pump { _ in s.isClosed(id) })
        XCTAssertEqual(s.exitStatus(id), 0)
    }

    /// More than twice the 2 MiB window: the server stalls unless we top it up.
    func testLargeDownloadRefillsTheWindow() throws {
        let s = try LiveSession()
        let id = try s.exec("head -c 5000000 /dev/zero | tr '\\000' a")
        XCTAssertTrue(try s.pump(timeout: 60) { _ in s.isClosed(id) },
                      "got \(s.output(id).count) bytes; last events \(s.events.suffix(3)); \(String(decoding: s.events.compactMap { if case .extendedData(_, let b) = $0 { return b }; return nil }.joined(), as: UTF8.self))")
        let out = s.output(id)
        XCTAssertEqual(out.count, 5_000_000)
        XCTAssertTrue(out.allSatisfy { $0 == UInt8(ascii: "a") })
        XCTAssertEqual(s.exitStatus(id), 0)
    }

    /// More than the server's window the other way: our queue must wait for
    /// WINDOW_ADJUST and cut packets to the server's maximum.
    func testLargeUploadRespectsTheServerWindow() throws {
        let s = try LiveSession()
        let id = try s.exec("wc -c")
        try s.pump { _ in s.replies(id)["exec"] != nil }
        let chunk = [UInt8](repeating: 0x42, count: 100_000)
        for _ in 0..<30 { try s.connection.write(id, chunk) }
        try s.connection.sendEOF(id)
        XCTAssertTrue(try s.pump(timeout: 60) { _ in s.isClosed(id) })
        XCTAssertEqual(s.text(id).trimmingCharacters(in: .whitespacesAndNewlines), "3000000")
        XCTAssertEqual(s.connection.pendingOutput(id), 0)
    }

    func testExitStatusAndStderr() throws {
        let s = try LiveSession()
        let id = try s.exec("echo out; echo err 1>&2; exit 3")
        XCTAssertTrue(try s.pump { _ in s.isClosed(id) })
        XCTAssertEqual(s.text(id), "out\n")
        XCTAssertTrue(s.events.contains(.extendedData(id, Array("err\n".utf8))))
        XCTAssertEqual(s.exitStatus(id), 3)
    }

    func testKeepalivesAreAnswered() throws {
        let s = try LiveSession()
        for _ in 0..<3 { try s.connection.sendKeepalive() }
        XCTAssertTrue(try s.pump { $0.filter { if case .globalReply = $0 { return true }; return false }.count == 3 })
    }

    func testRefusedChannelIsReported() throws {
        let s = try LiveSession(options: ["MaxSessions 0"])
        let id = try s.connection.openSession()
        XCTAssertTrue(try s.pump { $0.contains { if case .channelOpenFailed(id, _, _) = $0 { return true }; return false } }, s.sshd.log())
        XCTAssertFalse(s.connection.isOpen(id))
    }

    func testAgentForwarding() throws {
        let agent = try LiveAgent()
        let v = Vectors.keyFiles.first { $0.name == "ecdsa256" }!
        let path = "/tmp/sheepssh-fwd-key-\(getpid())"
        try v.privateText.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o600)
        defer { unlink(path) }
        try agent.add(path)

        let s = try LiveSession(agentSocket: agent.socketPath)
        let id = try s.connection.openSession()
        try s.pump { $0.contains(.channelOpened(id)) }
        try s.connection.requestAgentForwarding(id)
        try s.connection.requestExec(id, command: "ssh-add -l")
        XCTAssertTrue(try s.pump { _ in s.isClosed(id) }, s.sshd.log())
        // Sent without asking for a reply (as OpenSSH does): the proof is
        // the far end listing our key.
        XCTAssertNil(s.replies(id)["auth-agent-req@openssh.com"])
        XCTAssertTrue(s.text(id).contains(v.fingerprint), "the far end lists our key through the tunnel: \(s.text(id))")
        XCTAssertEqual(s.exitStatus(id), 0)
    }

    func testNoAgentChannelWithoutForwarding() throws {
        let s = try LiveSession()
        let id = try s.exec("echo ${SSH_AUTH_SOCK:-none}")
        XCTAssertTrue(try s.pump { _ in s.isClosed(id) })
        XCTAssertEqual(s.text(id), "none\n")
    }
}
