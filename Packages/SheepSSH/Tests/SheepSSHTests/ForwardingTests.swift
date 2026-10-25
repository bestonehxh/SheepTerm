import XCTest
@testable import SheepSSH

/// Port forwarding's sans-I/O halves: a channel whose window reopens only
/// as its owner consumes (`manualWindow`), and the SOCKS5 server handshake.
/// Byte layouts from RFC 4254 §5.2/§7.2 and RFC 1928.
final class ForwardingTests: XCTestCase {
    private let helper = ConnectionTests()

    private func data(_ id: UInt32, count: Int) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(94); w.writeUInt32(id); w.writeString([UInt8](repeating: 0x61, count: count))
        return w.bytes
    }

    private func windowAdjusts(_ packets: [[UInt8]]) -> [UInt32] {
        packets.compactMap { p in
            guard p.first == 93 else { return nil }
            var r = SSHReader(p, from: 1)
            _ = try? r.readUInt32()
            return try? r.readUInt32()
        }
    }

    func testDirectTCPIPCarriesTheOriginatorItIsGiven() throws {
        let (c, t) = helper.connection()
        _ = try c.openDirectTCPIP(host: "db.lab", port: 5432, originatorHost: "127.0.0.1", originatorPort: 51515, manualWindow: true)
        var r = SSHReader(helper.sent(t)[0], from: 1)
        _ = try r.readString(); _ = try r.readUInt32(); _ = try r.readUInt32(); _ = try r.readUInt32()
        XCTAssertEqual(try r.readString(), Array("db.lab".utf8))
        XCTAssertEqual(try r.readUInt32(), 5432)
        XCTAssertEqual(try r.readString(), Array("127.0.0.1".utf8))
        XCTAssertEqual(try r.readUInt32(), 51515)
    }

    func testManualWindowReopensOnlyAsBytesAreConsumed() throws {
        let (c, t) = helper.connection()
        let id = try c.openDirectTCPIP(host: "x", port: 1, manualWindow: true)
        try c.handle(helper.confirmation(local: id, remote: 9))
        _ = helper.sent(t); _ = c.takeEvents()
        // A whole window arrives and nobody consumes it: no WINDOW_ADJUST.
        let half = Int(SSHConnection.windowSize / 2)
        try c.handle(data(id, count: half))
        try c.handle(data(id, count: half))
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [], "parsed is not consumed")
        // Consuming less than half reopens nothing yet; reaching half does.
        try c.consumed(id, half - 1)
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [])
        try c.consumed(id, 1)
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [UInt32(half)])
        // Consuming more than was ever received credits nothing extra.
        try c.consumed(id, 10 * half)
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [UInt32(half)], "only what arrived is credited")
        try c.consumed(id, 1)
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [])
    }

    func testSessionChannelCanUseTheManualWindow() throws {
        let (c, t) = helper.connection()
        let id = try c.openSession(manualWindow: true)
        try c.handle(helper.confirmation(local: id, remote: 9))
        _ = helper.sent(t); _ = c.takeEvents()
        let half = Int(SSHConnection.windowSize / 2)
        try c.handle(data(id, count: half))
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [], "an SFTP side channel waits for its owner")
        try c.consumed(id, half)
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [UInt32(half)])
        // The terminal's own session channel keeps the automatic top-up.
        let shell = try c.openSession()
        try c.handle(helper.confirmation(local: shell, remote: 10))
        _ = helper.sent(t)
        try c.handle(data(shell, count: half))
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [UInt32(half)])
    }

    func testAutomaticWindowIsUnchangedForOtherChannels() throws {
        let (c, t) = helper.connection()
        let id = try c.openDirectTCPIP(host: "x", port: 1)
        try c.handle(helper.confirmation(local: id, remote: 9))
        _ = helper.sent(t)
        try c.handle(data(id, count: Int(SSHConnection.windowSize / 2)))
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [UInt32(SSHConnection.windowSize / 2)], "the jump tunnel keeps its top-up")
        try c.consumed(id, 1000)   // a no-op here
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [])
    }

    // MARK: SOCKS5

    func testSOCKSGreetingAndDomainConnect() {
        var s = SOCKSHandshake()
        XCTAssertEqual(s.receive([5]), .pending)
        XCTAssertEqual(s.receive([1, 0]), .reply([5, 0]))
        let request: [UInt8] = [5, 1, 0, 3, 11] + Array("intranet.lb".utf8) + [0x01, 0xBB]
        XCTAssertEqual(s.receive(Array(request.prefix(7))), .pending)
        XCTAssertEqual(s.receive(Array(request.dropFirst(7)) + Array("GET".utf8)),
                       .connect(host: "intranet.lb", port: 443, leftover: Array("GET".utf8)))
        XCTAssertEqual(s.pendingReply, [])
        XCTAssertEqual(SOCKSHandshake.succeeded(), [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
    }

    func testSOCKSGreetingAndRequestInOneRead() {
        var s = SOCKSHandshake()
        XCTAssertEqual(s.receive([5, 2, 2, 0, 5, 1, 0, 1, 192, 0, 2, 7, 0, 80]),
                       .connect(host: "192.0.2.7", port: 80, leftover: []))
        XCTAssertEqual(s.pendingReply, [5, 0], "the greeting's answer goes before the connect reply")
    }

    func testSOCKSIPv6Target() {
        var s = SOCKSHandshake()
        _ = s.receive([5, 1, 0])
        let v6: [UInt8] = [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]
        XCTAssertEqual(s.receive([5, 1, 0, 4] + v6 + [0x1F, 0x90]),
                       .connect(host: "2001:db8:0:0:0:0:0:1", port: 8080, leftover: []))
    }

    func testSOCKSRefusals() {
        var noAuth = SOCKSHandshake()
        XCTAssertEqual(noAuth.receive([5, 1, 2]), .refuse([5, 0xFF]), "username/password only: no acceptable method")
        var http = SOCKSHandshake()
        XCTAssertEqual(http.receive(Array("GET / HTTP/1.1\r\n".utf8)), .refuse([]), "not SOCKS at all")
        var bind = SOCKSHandshake()
        _ = bind.receive([5, 1, 0])
        XCTAssertEqual(bind.receive([5, 2, 0, 1, 1, 2, 3, 4, 0, 80]), .refuse([5, 7, 0, 1, 0, 0, 0, 0, 0, 0]), "BIND: command not supported")
        var udp = SOCKSHandshake()
        _ = udp.receive([5, 1, 0])
        XCTAssertEqual(udp.receive([5, 3, 0, 1, 1, 2, 3, 4, 0, 80]), .refuse([5, 7, 0, 1, 0, 0, 0, 0, 0, 0]), "UDP ASSOCIATE: not supported")
        var badType = SOCKSHandshake()
        _ = badType.receive([5, 1, 0])
        XCTAssertEqual(badType.receive([5, 1, 0, 9, 0, 0]), .refuse([5, 8, 0, 1, 0, 0, 0, 0, 0, 0]))
        var portZero = SOCKSHandshake()
        _ = portZero.receive([5, 1, 0])
        XCTAssertEqual(portZero.receive([5, 1, 0, 1, 1, 2, 3, 4, 0, 0]), .refuse([5, 4, 0, 1, 0, 0, 0, 0, 0, 0]))
        var flood = SOCKSHandshake()
        XCTAssertEqual(flood.receive([5, 255] + [UInt8](repeating: 1, count: 2000)), .refuse([]), "bounded")
        var emptyName = SOCKSHandshake()
        _ = emptyName.receive([5, 1, 0])
        XCTAssertEqual(emptyName.receive([5, 1, 0, 3, 0, 0, 80]), .refuse([5, 4, 0, 1, 0, 0, 0, 0, 0, 0]))
    }

    func testSOCKSFailureCodes() {
        XCTAssertEqual(SOCKSHandshake.code(forOpenFailure: 1), 2)
        XCTAssertEqual(SOCKSHandshake.code(forOpenFailure: 2), 5)
        XCTAssertEqual(SOCKSHandshake.code(forOpenFailure: 4), 1)
        XCTAssertEqual(SOCKSHandshake.failed(5), [5, 5, 0, 1, 0, 0, 0, 0, 0, 0])
    }

    // MARK: -R (tcpip-forward / forwarded-tcpip)

    private func forwardedOpen(sender: UInt32, port: Int) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(90); w.writeString("forwarded-tcpip"); w.writeUInt32(sender)
        w.writeUInt32(1 << 20); w.writeUInt32(32 * 1024)
        w.writeString("127.0.0.1"); w.writeUInt32(UInt32(port)); w.writeString("192.0.2.9"); w.writeUInt32(40000)
        return w.bytes
    }

    func testRemoteForwardRequestAndRepliesInOrderWithKeepalives() throws {
        let (c, t) = helper.connection()
        try c.sendKeepalive()
        let token = try c.requestRemoteForward(address: "", port: 9000)
        let zero = try c.requestRemoteForward(address: "0.0.0.0", port: 0)
        let packets = helper.sent(t)
        XCTAssertEqual(packets.count, 3)
        var r = SSHReader(packets[1], from: 1)
        XCTAssertEqual(try r.readString(), Array("tcpip-forward".utf8))
        XCTAssertEqual(try r.readBool(), true)
        XCTAssertEqual(try r.readString(), [])
        XCTAssertEqual(try r.readUInt32(), 9000)
        // Answers in request order: keepalive (failure), 9000 ok, port 0 ok with the port chosen.
        try c.handle([82])
        try c.handle([81])
        var w = SSHWriter(); w.writeByte(81); w.writeUInt32(53123)
        try c.handle(w.bytes)
        XCTAssertEqual(c.takeEvents(), [.globalReply(success: false),
                                        .remoteForwardReply(token: token, success: true, port: 9000),
                                        .remoteForwardReply(token: zero, success: true, port: 53123)])
    }

    func testRefusedRemoteForwardReportsNoPort() throws {
        let (c, _) = helper.connection()
        let token = try c.requestRemoteForward(address: "", port: 22)
        try c.handle([82])
        XCTAssertEqual(c.takeEvents(), [.remoteForwardReply(token: token, success: false, port: nil)])
    }

    func testForwardedChannelOnlyOnAConfirmedPort() throws {
        let (c, t) = helper.connection()
        // Not asked for: refused (OPEN_FAILURE, administratively prohibited).
        try c.handle(forwardedOpen(sender: 5, port: 9000))
        XCTAssertEqual(c.takeEvents(), [])
        let refusal = helper.sent(t)
        XCTAssertEqual(refusal.first?.first, 92)
        // Asked and confirmed: accepted, with a manual window.
        _ = try c.requestRemoteForward(address: "", port: 9000)
        try c.handle([81])
        _ = c.takeEvents(); _ = helper.sent(t)
        try c.handle(forwardedOpen(sender: 6, port: 9000))
        guard case .forwardedChannelOpened(let id, "127.0.0.1", 9000, "192.0.2.9", 40000)? = c.takeEvents().first else {
            return XCTFail("not accepted")
        }
        XCTAssertEqual(helper.sent(t).first?.first, 91, "OPEN_CONFIRMATION")
        try c.handle(data(id, count: Int(SSHConnection.windowSize)))
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [], "manual window: nothing reopens until consumed")
        try c.consumed(id, Int(SSHConnection.windowSize / 2))
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [UInt32(SSHConnection.windowSize / 2)])
        // A port the server confirmed for a different request is still ours;
        // another port is not.
        try c.handle(forwardedOpen(sender: 7, port: 9001))
        XCTAssertEqual(helper.sent(t).first?.first, 92)
    }

    func testCancelRemoteForwardStopsItsChannels() throws {
        let (c, t) = helper.connection()
        _ = try c.requestRemoteForward(address: "", port: 9000)
        try c.handle([81])
        _ = c.takeEvents(); _ = helper.sent(t)
        try c.cancelRemoteForward(address: "", port: 9000)
        var r = SSHReader(helper.sent(t)[0], from: 1)
        XCTAssertEqual(try r.readString(), Array("cancel-tcpip-forward".utf8))
        XCTAssertEqual(try r.readBool(), false, "no reply asked: the reply queue stays in step")
        XCTAssertEqual(try r.readString(), [])
        XCTAssertEqual(try r.readUInt32(), 9000)
        try c.handle(forwardedOpen(sender: 8, port: 9000))
        XCTAssertEqual(helper.sent(t).first?.first, 92, "a channel for a cancelled port is refused")
        try c.sendKeepalive()
        try c.handle([82])
        XCTAssertEqual(c.takeEvents(), [.globalReply(success: false)], "keepalive replies still line up")
    }

    func testSOCKS4And4a() {
        var v4 = SOCKSHandshake()
        XCTAssertEqual(v4.receive([4, 1, 0, 80, 192, 0, 2, 7] + Array("user".utf8)), .pending, "user id not ended yet")
        XCTAssertEqual(v4.receive([0] + Array("GET".utf8)), .connect(host: "192.0.2.7", port: 80, leftover: Array("GET".utf8)))
        XCTAssertEqual(v4.successReply(), [0, 0x5A, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(v4.failureReply(5), [0, 0x5B, 0, 0, 0, 0, 0, 0])
        var v4a = SOCKSHandshake()
        XCTAssertEqual(v4a.receive([4, 1, 0x01, 0xBB, 0, 0, 0, 1, 0] + Array("intranet.lb".utf8) + [0]),
                       .connect(host: "intranet.lb", port: 443, leftover: []))
        var bind4 = SOCKSHandshake()
        XCTAssertEqual(bind4.receive([4, 2, 0, 80, 1, 2, 3, 4, 0]), .refuse([0, 0x5B, 0, 0, 0, 0, 0, 0]), "SOCKS4 BIND refused")
        var v5 = SOCKSHandshake()
        _ = v5.receive([5, 1, 0, 5, 1, 0, 1, 1, 2, 3, 4, 0, 80])
        XCTAssertEqual(v5.successReply(), [5, 0] + SOCKSHandshake.succeeded(), "v5 reply carries the greeting's answer")
    }

    func testRemoteRuleLabels() {
        XCTAssertEqual(ForwardRule.remote(bindAddress: "", bindPort: 9000, host: "127.0.0.1", port: 3000).label, "R 9000 → 127.0.0.1:3000")
        XCTAssertEqual(ForwardRule.remote(bindAddress: "0.0.0.0", bindPort: 9000, host: "h", port: 1).label, "R 0.0.0.0:9000 → h:1")
        XCTAssertEqual(ForwardRule.remoteDynamic(bindAddress: "", bindPort: 1080).label, "R 1080 SOCKS")
        XCTAssertTrue(ForwardRule.remoteDynamic(bindAddress: "", bindPort: 1080).isRemote)
        XCTAssertFalse(ForwardRule.dynamic(bindPort: 1080).isRemote)
    }

    func testRuleLabels() {
        XCTAssertEqual(ForwardRule.local(bindPort: 8443, host: "10.0.0.1", port: 443).label, "8443 → 10.0.0.1:443")
        XCTAssertEqual(ForwardRule.local(bindPort: 8443, host: "2001:db8::1", port: 443).label, "8443 → [2001:db8::1]:443")
        XCTAssertEqual(ForwardRule.dynamic(bindPort: 1080).label, "1080 SOCKS")
    }
}
