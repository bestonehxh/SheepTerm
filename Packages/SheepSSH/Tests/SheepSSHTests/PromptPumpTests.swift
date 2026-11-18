import XCTest
@testable import SheepSSH

/// 6.1 (62) review: the app's I/O loop now sleeps until its next keepalive
/// when it looks idle, and asks `wantsPromptPump` whether a forwarder has
/// work that nothing will wake it for. Every such state must say so for as
/// long as it lasts — and nothing else may (an idle forwarder must let the
/// loop sleep).
final class PromptPumpTests: XCTestCase {
    private let helper = ConnectionTests()

    private func waitFor(_ seconds: TimeInterval = 5, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { usleep(5_000) }
        return done()
    }

    private func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: a.sin_port))
    }

    private func dial(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var to = sockaddr_in(); to.sin_family = sa_family_t(AF_INET); to.sin_port = in_port_t(UInt16(port).bigEndian)
        to.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    private func readNow(_ fd: Int32) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 256)
        let n = Darwin.read(fd, &b, b.count)
        return n > 0 ? Array(b[0..<n]) : []
    }

    /// A SOCKS5 client that waits for the method reply before its request
    /// (curl, browsers): the reply is made while READING the client, after
    /// this pass's write — the client then says nothing until it gets it.
    func testSOCKSReplyMadeWhileReadingAsksForAPromptPump() throws {
        let (c, _) = helper.connection()
        let port = freePort()
        let forwarder = PortForwarder(rules: [.dynamic(bindPort: port)])
        defer { forwarder.closeAll() }
        XCTAssertEqual(forwarder.start(), [.dynamic(bindPort: port)])
        XCTAssertFalse(forwarder.wantsPromptPump, "a listener alone lets the loop sleep (quiet)")
        let client = dial(port)
        defer { close(client) }
        XCTAssertTrue(waitFor { try? forwarder.pump(connection: c); return forwarder.activeTunnels == 1 })
        XCTAssertFalse(forwarder.wantsPromptPump, "an accepted client saying nothing yet: quiet")
        let greeting: [UInt8] = [5, 1, 0]
        XCTAssertEqual(Darwin.write(client, greeting, 3), 3)
        usleep(50_000)
        try forwarder.pump(connection: c)
        XCTAssertEqual(readNow(client), [], "the reply is queued, not yet written")
        XCTAssertTrue(forwarder.wantsPromptPump, "…so the loop must come back for it")
        try forwarder.pump(connection: c)
        var got: [UInt8] = []
        XCTAssertTrue(waitFor { got += readNow(client); return !got.isEmpty })
        XCTAssertEqual(got, [5, 0], "the method reply")
        XCTAssertFalse(forwarder.wantsPromptPump, "written: quiet again")
    }

    /// The reply really is delivered by the next pass (and only then).
    func testSOCKSReplyArrivesOnTheNextPass() throws {
        let (c, _) = helper.connection()
        let port = freePort()
        let forwarder = PortForwarder(rules: [.dynamic(bindPort: port)])
        defer { forwarder.closeAll() }
        _ = forwarder.start()
        let client = dial(port)
        defer { close(client) }
        XCTAssertTrue(waitFor { try? forwarder.pump(connection: c); return forwarder.activeTunnels == 1 })
        let greeting: [UInt8] = [5, 1, 0]
        _ = Darwin.write(client, greeting, 3)
        usleep(50_000)
        try forwarder.pump(connection: c)
        XCTAssertEqual(readNow(client), [])
        try forwarder.pump(connection: c)
        var got: [UInt8] = []
        XCTAssertTrue(waitFor { got += readNow(client); return !got.isEmpty })
        XCTAssertEqual(got, [5, 0])
    }

    /// A -R connect: the lookup finishes on its own thread, which wakes
    /// nobody — the tunnel asks for prompt pumps for the WHOLE time it is
    /// pending (lookup, connect, up to the 15 s timeout), and stops once it
    /// is over.
    func testConnectingTunnelAsksUntilItEnds() throws {
        XCTAssertTrue(waitFor { TCPConnector.lookupsRunning == 0 })
        let gate = DispatchSemaphore(value: 0)
        let saved = TCPConnector.resolve
        TCPConnector.resolve = { _, _ in gate.wait(); return .failure(ForwardSocket.Failure("no such host")) }
        defer { TCPConnector.resolve = saved }
        let (c, _) = helper.connection()
        let forwarder = PortForwarder(rules: [.remote(bindAddress: "", bindPort: 9000, host: "slow.example", port: 80)])
        try forwarder.requestRemote(connection: c)
        try c.handle([81])
        for case .remoteForwardReply(let token, let success, let port) in c.takeEvents() {
            forwarder.remoteForwardReply(token: token, success: success, port: port)
        }
        XCTAssertFalse(forwarder.wantsPromptPump, "a confirmed -R with no connection: quiet")
        var w = SSHWriter()
        w.writeByte(90); w.writeString("forwarded-tcpip"); w.writeUInt32(6)
        w.writeUInt32(1 << 20); w.writeUInt32(32 * 1024)
        w.writeString("127.0.0.1"); w.writeUInt32(9000); w.writeString("192.0.2.9"); w.writeUInt32(40000)
        try c.handle(w.bytes)
        guard case .forwardedChannelOpened(let id, _, _, _, _)? = c.takeEvents().first else { return XCTFail("not accepted") }
        try forwarder.forwardedChannelOpened(id, port: 9000, connection: c)
        for _ in 0..<5 {
            try forwarder.pump(connection: c)
            XCTAssertTrue(forwarder.wantsPromptPump, "the lookup is still running")
        }
        gate.signal()
        XCTAssertTrue(waitFor { TCPConnector.lookupsRunning == 0 })
        XCTAssertTrue(forwarder.wantsPromptPump, "finished on its thread, not yet seen: still prompt")
        try forwarder.pump(connection: c)
        XCTAssertTrue(forwarder.takeNotices().contains("forward R 9000 → slow.example:80: no such host"))
        XCTAssertFalse(forwarder.wantsPromptPump, "over: quiet")
    }

    /// An agent request bigger than the agent socket takes at once: the
    /// rest waits for the next pass, and the far end sends nothing more
    /// until it is answered.
    func testPartlyWrittenAgentRequestAsksForAPromptPump() throws {
        let path = NSTemporaryDirectory() + "pp-agent-\(getpid()).sock"
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() where i < raw.count - 1 { raw[i] = b }
        }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(listener, 4)
        defer { close(listener); unlink(path) }

        let (c, _) = helper.connection()
        let forwarder = AgentForwarder(socketPath: path)
        XCTAssertFalse(forwarder.wantsPromptPump)
        try forwarder.channelOpened(7, connection: c)
        let agent = Darwin.accept(listener, nil, nil)
        defer { close(agent) }
        XCTAssertGreaterThanOrEqual(agent, 0)
        try forwarder.pump(connection: c)
        XCTAssertFalse(forwarder.wantsPromptPump, "an open tunnel with nothing to write: quiet")
        let request = [UInt8](repeating: 0x41, count: 200 * 1024)
        forwarder.received(7, request, connection: c)
        try forwarder.pump(connection: c)
        XCTAssertTrue(forwarder.wantsPromptPump, "part of the request still waits for the agent's socket")
        // The agent reads; the next passes deliver the rest.
        var got = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        _ = fcntl(agent, F_SETFL, fcntl(agent, F_GETFL) | O_NONBLOCK)
        XCTAssertTrue(waitFor(10) {
            try? forwarder.pump(connection: c)
            let n = Darwin.read(agent, &buffer, buffer.count)
            if n > 0 { got += n }
            return got == request.count && !forwarder.wantsPromptPump
        })
        XCTAssertEqual(got, request.count)
        XCTAssertFalse(forwarder.wantsPromptPump, "all written: quiet")
        forwarder.closeAll()
    }
}
