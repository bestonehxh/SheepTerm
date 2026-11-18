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

    private func delivered(_ events: [SSHConnection.Event], _ id: UInt32) -> Int {
        events.reduce(0) { if case .data(id, let b) = $1 { return $0 + b.count }; return $0 }
    }

    private func closes(_ packets: [[UInt8]], remote: UInt32) -> Int {
        packets.filter { $0 == [97] + [UInt8(remote >> 24), UInt8(remote >> 16 & 0xFF), UInt8(remote >> 8 & 0xFF), UInt8(remote & 0xFF)] }.count
    }

    /// A server that ignores the window of a port-forward channel whose
    /// socket stops reading (review 6.1 (59)): the owner is handed at most
    /// the window plus one packet, then THAT channel is closed and the rest
    /// dropped — the shell channel beside it, and the session, carry on.
    func testManualWindowOverrunClosesOnlyThatChannel() throws {
        let (c, t) = helper.connection()
        let id = try c.openDirectTCPIP(host: "x", port: 1, manualWindow: true)
        try c.handle(helper.confirmation(local: id, remote: 9))
        let shell = try c.openSession()
        try c.handle(helper.confirmation(local: shell, remote: 10))
        _ = helper.sent(t); _ = c.takeEvents()
        let packet = SSHConnection.maxPacket
        // The whole window, then one packet more (a server counting wrong):
        // still delivered, nothing closed.
        for _ in 0..<(Int(SSHConnection.windowSize) / packet + 1) { try c.handle(data(id, count: packet)) }
        XCTAssertEqual(delivered(c.takeEvents(), id), Int(SSHConnection.maximumOwed))
        XCTAssertEqual(closes(helper.sent(t), remote: 9), 0)
        // One byte past that: CLOSE for this channel, the byte dropped, and
        // every later packet too.
        try c.handle(data(id, count: 1))
        for _ in 0..<100 { try c.handle(data(id, count: packet)) }
        XCTAssertEqual(delivered(c.takeEvents(), id), 0, "nothing past the bound reaches the owner")
        XCTAssertEqual(closes(helper.sent(t), remote: 9), 1, "one CLOSE, for that channel only")
        try c.consumed(id, Int(SSHConnection.maximumOwed))
        XCTAssertEqual(windowAdjusts(helper.sent(t)), [], "a channel we closed is not reopened")
        // The shell beside it keeps the old tolerance: a packet bigger than
        // its whole window is delivered, the session goes on.
        try c.handle(data(shell, count: Int(SSHConnection.windowSize) + 100_000))
        try c.handle(data(shell, count: Int(SSHConnection.windowSize) + 100_000))
        XCTAssertEqual(delivered(c.takeEvents(), shell), 2 * (Int(SSHConnection.windowSize) + 100_000))
        XCTAssertEqual(closes(helper.sent(t), remote: 10), 0)
        // The server's CLOSE ends the forward channel as usual.
        try c.handle([97, 0, 0, 0, UInt8(id)])
        XCTAssertTrue(c.takeEvents().contains(.closed(id)))
        XCTAssertTrue(c.isOpen(shell))
    }

    /// Must stay quiet: an owner that passes the bytes on keeps a channel
    /// open through 16 MB — including a server that overshoots each window
    /// by most of a packet, and a lent SFTP channel's stderr.
    func testManualWindowOwnerThatKeepsUpIsNeverCut() throws {
        let (c, t) = helper.connection()
        let id = try c.openSession(manualWindow: true)
        try c.handle(helper.confirmation(local: id, remote: 9))
        _ = helper.sent(t); _ = c.takeEvents()
        var total = 0
        for _ in 0..<8 {
            for _ in 0..<(Int(SSHConnection.windowSize) / 65_536) { try c.handle(data(id, count: 65_536)) }
            try c.handle(data(id, count: SSHConnection.maxPacket - 100))   // overshoot, stderr fills the packet
            var w = SSHWriter()
            w.writeByte(95); w.writeUInt32(id); w.writeUInt32(1); w.writeString([UInt8](repeating: 0x65, count: 100))
            try c.handle(w.bytes)
            let events = c.takeEvents()
            let got = delivered(events, id) + events.reduce(0) { if case .extendedData(id, let b) = $1 { return $0 + b.count }; return $0 }
            XCTAssertEqual(got, Int(SSHConnection.maximumOwed))
            try c.consumed(id, got)
            total += got
        }
        XCTAssertGreaterThan(total, 16 * 1024 * 1024)
        XCTAssertEqual(closes(helper.sent(t), remote: 9), 0)
        XCTAssertTrue(c.isOpen(id))
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

    // MARK: Name lookups (TCPConnector)

    /// A resolver that blocks until released, counting the calls it saw.
    private final class SlowResolver: @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls = 0
        var resolve: @Sendable (String, Int) -> Result<[ForwardSocket.Address], ForwardSocket.Failure> {
            { [self] _, _ in
                lock.withLock { calls += 1 }
                gate.wait()
                return .failure(ForwardSocket.Failure("no such host"))
            }
        }
    }

    private func waitFor(_ seconds: TimeInterval = 5, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { usleep(5_000) }
        return done()
    }

    /// Review 6.1 (59): each connect ran getaddrinfo on a detached thread
    /// that nothing can stop; dropping the connector (a released tunnel —
    /// a remote SOCKS client can open and close channels as fast as it
    /// likes) left the thread blocked in a slow lookup and freed the
    /// tunnel slot. Lookups in flight are now capped over every connector;
    /// past the cap a connect fails at once, without a thread.
    func testNameLookupsInFlightAreCapped() throws {
        XCTAssertTrue(waitFor { TCPConnector.lookupsRunning == 0 })
        let slow = SlowResolver()
        let saved = TCPConnector.resolve
        TCPConnector.resolve = slow.resolve
        defer { TCPConnector.resolve = saved }
        var busy = 0
        for i in 0..<300 {
            let connector = TCPConnector(host: "slow-\(i).example", port: 80)
            if connector.step() == .failed(TCPConnector.busyMessage) { busy += 1 }
            // dropped here, like a released tunnel
        }
        XCTAssertTrue(waitFor { slow.lock.withLock { slow.calls } == min(300, TCPConnector.maximumLookups) })
        XCTAssertEqual(TCPConnector.lookupsRunning, TCPConnector.maximumLookups, "lookups in flight stop at the cap")
        XCTAssertEqual(busy, 300 - TCPConnector.maximumLookups, "the rest fail at once")
        for _ in 0..<300 { slow.gate.signal() }
        XCTAssertTrue(waitFor { TCPConnector.lookupsRunning == 0 }, "every lookup returned")
        XCTAssertEqual(slow.calls, TCPConnector.maximumLookups, "no thread for a refused connect")
        // Must stay quiet: with the slots free a connect looks up again.
        TCPConnector.resolve = saved
        let again = TCPConnector(host: "127.0.0.1", port: 9)
        var step = again.step()
        XCTAssertTrue(waitFor { step = again.step(); return step != .pending })
        XCTAssertNotEqual(step, .failed(TCPConnector.busyMessage))
    }

    /// Review 6.1 (62): the app-wide cap alone let ONE session's remote SOCKS
    /// client hold all 64 slots, and every other tab's forward then failed at
    /// once. An owner's `LookupBudget` is taken first: one owner stops at its
    /// share and another owner still gets a lookup.
    func testOneOwnerCannotTakeEveryLookup() throws {
        XCTAssertTrue(waitFor { TCPConnector.lookupsRunning == 0 })
        let slow = SlowResolver()
        let saved = TCPConnector.resolve
        TCPConnector.resolve = slow.resolve
        defer { TCPConnector.resolve = saved }
        let greedy = TCPConnector.LookupBudget()
        var busy = 0
        for i in 0..<200 {
            let connector = TCPConnector(host: "greedy-\(i).example", port: 80, budget: greedy)
            if connector.step() == .failed(TCPConnector.busyMessage) { busy += 1 }
        }
        XCTAssertLessThan(TCPConnector.LookupBudget.perOwner, TCPConnector.maximumLookups, "one owner's share is less than the whole")
        XCTAssertEqual(greedy.running, TCPConnector.LookupBudget.perOwner, "one owner stops at its share")
        XCTAssertEqual(TCPConnector.lookupsRunning, TCPConnector.LookupBudget.perOwner, "…and holds no more of the app-wide slots")
        XCTAssertEqual(busy, 200 - TCPConnector.LookupBudget.perOwner, "its other connects fail at once")
        // Another session's forward is looked up as usual.
        let other = TCPConnector.LookupBudget()
        let fair = TCPConnector(host: "other.example", port: 80, budget: other)
        XCTAssertEqual(fair.step(), .pending, "another owner still gets a lookup")
        XCTAssertEqual(other.running, 1)
        XCTAssertTrue(waitFor { slow.lock.withLock { slow.calls } == TCPConnector.LookupBudget.perOwner + 1 })
        // The app-wide cap still holds over many owners.
        let owners = (0..<8).map { _ in TCPConnector.LookupBudget() }
        var refused = 0
        for owner in owners {
            for i in 0..<TCPConnector.LookupBudget.perOwner {
                if TCPConnector(host: "many-\(i).example", port: 80, budget: owner).step() == .failed(TCPConnector.busyMessage) { refused += 1 }
            }
        }
        XCTAssertEqual(TCPConnector.lookupsRunning, TCPConnector.maximumLookups, "the app-wide cap still holds")
        XCTAssertEqual(refused, 8 * TCPConnector.LookupBudget.perOwner - (TCPConnector.maximumLookups - TCPConnector.LookupBudget.perOwner - 1))
        // A refusal by the app-wide cap gives the owner's slot back.
        XCTAssertEqual(owners.map(\.running).reduce(0, +), TCPConnector.maximumLookups - TCPConnector.LookupBudget.perOwner - 1,
                       "owners hold only the slots whose lookups run")
        for _ in 0..<(TCPConnector.maximumLookups + 8) { slow.gate.signal() }
        XCTAssertTrue(waitFor { TCPConnector.lookupsRunning == 0 }, "every lookup returned")
        XCTAssertTrue(waitFor { greedy.running == 0 && other.running == 0 && owners.allSatisfy { $0.running == 0 } },
                      "each owner's slots come back as its lookups return")
        // Must stay quiet: once its lookups returned the owner looks up again.
        TCPConnector.resolve = saved
        let again = TCPConnector(host: "127.0.0.1", port: 9, budget: greedy)
        var step = again.step()
        XCTAssertTrue(waitFor { step = again.step(); return step != .pending })
        XCTAssertNotEqual(step, .failed(TCPConnector.busyMessage))
    }

    /// The wiring: each PortForwarder (one per session) has its own share, so
    /// -R connects on one session past its share do not touch another's.
    func testEachForwarderHasItsOwnLookupShare() throws {
        XCTAssertTrue(waitFor { TCPConnector.lookupsRunning == 0 })
        let slow = SlowResolver()
        let saved = TCPConnector.resolve
        TCPConnector.resolve = slow.resolve
        defer { TCPConnector.resolve = saved }
        func remoteForwarder() throws -> (PortForwarder, SSHConnection) {
            let (c, _) = helper.connection()
            let forwarder = PortForwarder(rules: [.remote(bindAddress: "", bindPort: 9000, host: "slow.target", port: 80)])
            try forwarder.requestRemote(connection: c)
            try c.handle([81])
            for case .remoteForwardReply(let token, let success, let port) in c.takeEvents() {
                forwarder.remoteForwardReply(token: token, success: success, port: port)
            }
            return (forwarder, c)
        }
        let (a, ca) = try remoteForwarder()
        for sender in 0..<UInt32(TCPConnector.LookupBudget.perOwner + 10) {
            try ca.handle(forwardedOpen(sender: sender, port: 9000))
            for case .forwardedChannelOpened(let id, _, _, _, _) in ca.takeEvents() { try a.forwardedChannelOpened(id, port: 9000, connection: ca) }
        }
        XCTAssertEqual(a.lookups.running, TCPConnector.LookupBudget.perOwner, "one session's -R lookups stop at its share")
        let (b, cb) = try remoteForwarder()
        try cb.handle(forwardedOpen(sender: 1, port: 9000))
        for case .forwardedChannelOpened(let id, _, _, _, _) in cb.takeEvents() { try b.forwardedChannelOpened(id, port: 9000, connection: cb) }
        XCTAssertEqual(b.lookups.running, 1, "another session's -R connect is still looked up")
        XCTAssertEqual(TCPConnector.lookupsRunning, TCPConnector.LookupBudget.perOwner + 1)
        for _ in 0..<(TCPConnector.LookupBudget.perOwner + 1) { slow.gate.signal() }
        XCTAssertTrue(waitFor { TCPConnector.lookupsRunning == 0 })
    }

    /// The same cap seen by a remote SOCKS client (`R1080`): its CONNECT
    /// past the cap gets SOCKS "general failure" and its channel ends; a
    /// connect once a slot is free is looked up as usual.
    func testRemoteSOCKSConnectPastTheLookupCapIsAGeneralFailure() throws {
        XCTAssertTrue(waitFor { TCPConnector.lookupsRunning == 0 })
        let slow = SlowResolver()
        let saved = TCPConnector.resolve
        TCPConnector.resolve = slow.resolve
        defer { TCPConnector.resolve = saved }
        let fillers = (0..<TCPConnector.maximumLookups).map { TCPConnector(host: "filler-\($0).example", port: 80) }
        XCTAssertEqual(TCPConnector.lookupsRunning, TCPConnector.maximumLookups)

        let (c, t) = helper.connection()
        let forwarder = PortForwarder(rules: [.remoteDynamic(bindAddress: "", bindPort: 1080)])
        try forwarder.requestRemote(connection: c)
        try c.handle([81])
        for case .remoteForwardReply(let token, let success, let port) in c.takeEvents() {
            forwarder.remoteForwardReply(token: token, success: success, port: port)
        }
        try c.handle(forwardedOpen(sender: 6, port: 1080))
        guard case .forwardedChannelOpened(let id, _, _, _, _)? = c.takeEvents().first else { return XCTFail("not accepted") }
        try forwarder.forwardedChannelOpened(id, port: 1080, connection: c)
        _ = helper.sent(t)
        var w = SSHWriter()
        w.writeByte(94); w.writeUInt32(id); w.writeString([5, 1, 0] + [5, 1, 0, 3, 11] + Array("slow.target".utf8) + [0, 80])
        try c.handle(w.bytes)
        for case .data(id, let bytes) in c.takeEvents() { try forwarder.received(id, bytes, connection: c) }
        try forwarder.pump(connection: c)
        let replies = helper.sent(t).compactMap { p -> [UInt8]? in
            guard p.first == 94 else { return nil }
            var r = SSHReader(p, from: 1); _ = try? r.readUInt32(); return try? r.readString()
        }
        XCTAssertEqual(replies.joined().map { $0 }, [5, 0] + [5, 1, 0, 1, 0, 0, 0, 0, 0, 0], "method reply, then general failure")
        XCTAssertEqual(forwarder.activeTunnels, 0)
        XCTAssertEqual(slow.calls <= TCPConnector.maximumLookups, true, "no lookup started for it")
        for _ in fillers { slow.gate.signal() }
        XCTAssertTrue(waitFor { TCPConnector.lookupsRunning == 0 })
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
