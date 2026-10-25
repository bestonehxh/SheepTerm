import XCTest
@testable import SheepSSH
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// PortForwarder end to end: a local client → our loopback listener → a
/// direct-tcpip channel through a throwaway sshd → a TCP server on loopback.
final class ForwardingLiveTests: XCTestCase {
    /// A loopback TCP server: `echo` sends back what it gets; `stream`
    /// writes `streamBytes` as fast as the connection takes them, then closes.
    final class Target: @unchecked Sendable {
        enum Mode { case echo, stream }
        let port: UInt16
        private let fd: Int32
        let mode: Mode
        let streamBytes: Int
        init(_ mode: Mode, streamBytes: Int = 0) throws {
            self.mode = mode
            self.streamBytes = streamBytes
            let fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            listen(fd, 16)
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            port = UInt16(bigEndian: a.sin_port)
            self.fd = fd
            let listener = fd
            Thread.detachNewThread { [self] in
                while true {
                    let c = accept(listener, nil, nil)
                    if c < 0 { return }
                    Thread.detachNewThread { self.serve(c) }
                }
            }
        }
        private func serve(_ c: Int32) {
            var on: Int32 = 1
            #if canImport(Darwin)
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            #endif
            defer { close(c) }
            switch mode {
            case .echo:
                var b = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = b.withUnsafeMutableBytes { read(c, $0.baseAddress, $0.count) }
                    if n <= 0 { return }
                    var off = 0
                    while off < n {
                        let w = b[off..<n].withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
                        if w <= 0 { return }
                        off += w
                    }
                }
            case .stream:
                let chunk = [UInt8](repeating: 0x5A, count: 65536)
                var left = streamBytes
                while left > 0 {
                    let w = chunk.prefix(left).withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
                    if w <= 0 { return }
                    left -= w
                }
            }
        }
        func stop() { close(fd) }
    }

    /// Runs the session and the forwarder until `done()` (checked every pass).
    private func drive(_ s: LiveSession, _ f: PortForwarder, timeout: TimeInterval = 30, until done: @escaping () -> Bool) throws -> Bool {
        var seen = s.events.count
        var failure: Error?
        let ok = try s.pump(timeout: timeout) { events in
            do {
                while seen < events.count {
                    switch events[seen] {
                    case .channelOpened(let id) where f.owns(id): try f.channelOpened(id, connection: s.connection)
                    case .channelOpenFailed(let id, let reason, let text) where f.owns(id): f.channelOpenFailed(id, reason: reason, description: text)
                    case .data(let id, let bytes) where f.owns(id): try f.received(id, bytes, connection: s.connection)
                    case .remoteForwardReply(let token, let success, let port): f.remoteForwardReply(token: token, success: success, port: port)
                    case .forwardedChannelOpened(let id, _, let port, _, _): try f.forwardedChannelOpened(id, port: port, connection: s.connection)
                    case .eof(let id) where f.owns(id): f.channelEOF(id)
                    case .closed(let id): f.channelClosed(id)
                    default: break
                    }
                    seen += 1
                }
                try f.pump(connection: s.connection)
            } catch { failure = error }
            return done() || failure != nil
        }
        if let failure { throw failure }
        return ok
    }

    /// A blocking loopback client on its own thread.
    private static func client(port: Int, _ body: @escaping @Sendable (Int32) -> Void) {
        Thread.detachNewThread {
            guard let fd = try? LiveSSHD.connect(port: UInt16(port)) else { return }
            var on: Int32 = 1
            #if canImport(Darwin)
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            #endif
            body(fd)
            close(fd)
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8] {
        var out: [UInt8] = []
        var b = [UInt8](repeating: 0, count: 65536)
        while out.count < count {
            let n = b.withUnsafeMutableBytes { read(fd, $0.baseAddress, min($0.count, count - out.count)) }
            if n <= 0 { break }
            out += b[0..<n]
        }
        return out
    }

    func testLocalForwardCarriesTwoConnectionsAtOnce() throws {
        let target = try Target(.echo)
        defer { target.stop() }
        let s = try LiveSession()
        let bind = Int(LiveSSHD.freePort())
        let f = PortForwarder(rules: [.local(bindPort: bind, host: "127.0.0.1", port: Int(target.port))])
        defer { f.closeAll() }
        XCTAssertEqual(f.start(), f.rules)
        XCTAssertEqual(f.takeNotices(), [])
        let results = LockedResults()
        for i in 0..<2 {
            let payload = (0..<(600_000 + i)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ i) }
            Self.client(port: bind) { fd in
                Thread.detachNewThread { _ = Self.writeAll(fd, payload) }
                results.put(i, Self.readExactly(fd, payload.count) == payload)
            }
        }
        XCTAssertTrue(try drive(s, f) { results.count == 2 }, "\(s.sshd.log())")
        XCTAssertEqual(results.all, [true, true], "both echoed byte-exact")
    }

    func testSOCKSForwardConnectsAndRefuses() throws {
        let target = try Target(.echo)
        defer { target.stop() }
        let closedPort = LiveSSHD.freePort()
        let s = try LiveSession()
        let bind = Int(LiveSSHD.freePort())
        let f = PortForwarder(rules: [.dynamic(bindPort: bind)])
        defer { f.closeAll() }
        f.start()
        let results = LockedResults()
        let port = target.port
        Self.client(port: bind) { fd in
            // Greeting and request in separate writes, then payload.
            _ = Self.writeAll(fd, [5, 1, 0])
            let method = Self.readExactly(fd, 2)
            _ = Self.writeAll(fd, [5, 1, 0, 3, 9] + Array("localhost".utf8) + [UInt8(port >> 8), UInt8(port & 0xFF)])
            let reply = Self.readExactly(fd, 10)
            _ = Self.writeAll(fd, Array("ping through socks".utf8))
            let echo = Self.readExactly(fd, 18)
            results.put(0, method == [5, 0] && reply == SOCKSHandshake.succeeded() && echo == Array("ping through socks".utf8))
        }
        Self.client(port: bind) { fd in
            _ = Self.writeAll(fd, [5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, UInt8(closedPort >> 8), UInt8(closedPort & 0xFF)])
            let replies = Self.readExactly(fd, 12)
            // A refused target: method answer, then "connection refused"
            // (or a general failure, depending on how sshd words it), then EOF.
            results.put(1, replies.prefix(2) == [5, 0] && replies.count == 12 && replies[3] != 0 && Self.readExactly(fd, 1).isEmpty)
        }
        XCTAssertTrue(try drive(s, f) { results.count == 2 }, "\(s.sshd.log())")
        XCTAssertEqual(results.all, [true, true])
    }

    func testRefusedTargetIsReportedOnceAndTheClientIsClosed() throws {
        let closedPort = Int(LiveSSHD.freePort())
        let s = try LiveSession()
        let bind = Int(LiveSSHD.freePort())
        let f = PortForwarder(rules: [.local(bindPort: bind, host: "127.0.0.1", port: closedPort)])
        defer { f.closeAll() }
        f.start()
        let results = LockedResults()
        for i in 0..<3 {
            Self.client(port: bind) { fd in results.put(i, Self.readExactly(fd, 1).isEmpty) }
        }
        var notices: [String] = []
        XCTAssertTrue(try drive(s, f) { notices += f.takeNotices(); return results.count == 3 })
        XCTAssertEqual(results.all, [true, true, true], "each client sees EOF")
        XCTAssertEqual(notices.count, 1, "reported once, not per connection: \(notices)")
        XCTAssertTrue(notices.first?.hasPrefix("forward \(bind) → 127.0.0.1:\(closedPort): ") == true, "\(notices)")
    }

    func testABusyPortIsReportedAndTheOthersStart() throws {
        let busy = try Target(.echo)
        defer { busy.stop() }
        let free = Int(LiveSSHD.freePort())
        let f = PortForwarder(rules: [.dynamic(bindPort: Int(busy.port)), .dynamic(bindPort: free)])
        defer { f.closeAll() }
        XCTAssertEqual(f.start(), [.dynamic(bindPort: free)])
        XCTAssertEqual(f.takeNotices(), ["forward \(busy.port) SOCKS not started: port in use on this Mac"])
    }

    func testAClientThatStopsReadingStopsTheFarEnd() throws {
        // Conditions, not a clock: the run must hold on a loaded machine
        // (it failed at 2 s / 60 s while other harnesses ran beside it).
        let total = 6 * 1024 * 1024
        let target = try Target(.stream, streamBytes: total)
        defer { target.stop() }
        let s = try LiveSession()
        let bind = Int(LiveSSHD.freePort())
        let f = PortForwarder(rules: [.local(bindPort: bind, host: "127.0.0.1", port: Int(target.port))])
        defer { f.closeAll() }
        f.start()
        let paused = LockedFlag(true)
        let results = LockedResults()
        Self.client(port: bind) { fd in
            // Small receive buffer, so the pause backs up into us quickly.
            var small: Int32 = 16 * 1024
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
            while paused.value { usleep(10_000) }
            results.put(0, Self.readExactly(fd, total + 1).count == total)
        }
        // With the client not reading, the backlog forms and then STOPS
        // growing: data has arrived, and twenty passes in a row add nothing.
        var largest = 0
        var stillPasses = 0
        XCTAssertTrue(try drive(s, f, timeout: 120) {
            let now = f.largestClientQueue
            if now > largest { largest = now; stillPasses = 0 } else if largest > 0 { stillPasses += 1 }
            return stillPasses >= 20
        }, "the backlog formed and settled (largest \(largest))")
        XCTAssertGreaterThan(largest, 0, "data did arrive")
        XCTAssertLessThanOrEqual(largest, Int(SSHConnection.windowSize) + SSHConnection.maxPacket,
                                 "the window holds the far end back")
        XCTAssertEqual(results.count, 0, "the stream was held, not finished")
        paused.value = false
        XCTAssertTrue(try drive(s, f, timeout: 300) { results.count == 1 })
        XCTAssertEqual(results.all, [true], "all \(total) bytes arrive once the client reads, then EOF")
    }
}

extension ForwardingLiveTests {
    /// -R: the server listens; a client connecting THERE reaches a target
    /// on this side. (Here both are loopback on one machine — the sshd is
    /// local — which is exactly the shape of the real thing.)
    func testRemoteForwardCarriesConnectionsBack() throws {
        let target = try Target(.echo)
        defer { target.stop() }
        let s = try LiveSession()
        let remotePort = Int(LiveSSHD.freePort())
        let f = PortForwarder(rules: [.remote(bindAddress: "", bindPort: remotePort, host: "127.0.0.1", port: Int(target.port))])
        defer { f.closeAll() }
        XCTAssertEqual(f.start(), [], "nothing listens on this Mac for -R")
        XCTAssertEqual(try f.requestRemote(connection: s.connection), f.rules)
        var notices: [String] = []
        XCTAssertTrue(try drive(s, f) { notices += f.takeNotices(); return !notices.isEmpty })
        XCTAssertEqual(notices, ["forwarding R \(remotePort) → 127.0.0.1:\(target.port) — listening on the server"])
        XCTAssertEqual(f.listening, f.rules)
        let results = LockedResults()
        for i in 0..<2 {
            let payload = (0..<(300_000 + i)).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ i) }
            Self.client(port: remotePort) { fd in
                Thread.detachNewThread { _ = Self.writeAll(fd, payload) }
                results.put(i, Self.readExactly(fd, payload.count) == payload)
            }
        }
        XCTAssertTrue(try drive(s, f) { results.count == 2 }, "\(s.sshd.log())")
        XCTAssertEqual(results.all, [true, true], "both carried back byte-exact")
    }

    func testRemotePortZeroIsPickedByTheServer() throws {
        let target = try Target(.echo)
        defer { target.stop() }
        let s = try LiveSession()
        let f = PortForwarder(rules: [.remote(bindAddress: "", bindPort: 0, host: "127.0.0.1", port: Int(target.port))])
        defer { f.closeAll() }
        try f.requestRemote(connection: s.connection)
        var notices: [String] = []
        XCTAssertTrue(try drive(s, f) { notices += f.takeNotices(); return !notices.isEmpty })
        let picked = notices.first.flatMap { $0.range(of: "picked port ") }.map { notices[0][$0.upperBound...].prefix { $0.isNumber } }
        guard let picked, let port = Int(picked), port > 0 else { return XCTFail("\(notices)") }
        let results = LockedResults()
        Self.client(port: port) { fd in
            _ = Self.writeAll(fd, Array("zero".utf8))
            results.put(0, Self.readExactly(fd, 4) == Array("zero".utf8))
        }
        XCTAssertTrue(try drive(s, f) { results.count == 1 })
        XCTAssertEqual(results.all, [true])
    }

    func testRemoteSOCKSLeavesFromThisSide() throws {
        let target = try Target(.echo)
        defer { target.stop() }
        let s = try LiveSession()
        let remotePort = Int(LiveSSHD.freePort())
        let f = PortForwarder(rules: [.remoteDynamic(bindAddress: "", bindPort: remotePort)])
        defer { f.closeAll() }
        try f.requestRemote(connection: s.connection)
        var notices: [String] = []
        XCTAssertTrue(try drive(s, f) { notices += f.takeNotices(); return !notices.isEmpty })
        let results = LockedResults()
        let port = target.port
        let dead = LiveSSHD.freePort()
        Self.client(port: remotePort) { fd in
            // SOCKS5 by name, greeting + request in one write.
            _ = Self.writeAll(fd, [5, 1, 0, 5, 1, 0, 3, 9] + Array("localhost".utf8) + [UInt8(port >> 8), UInt8(port & 0xFF)])
            let replies = Self.readExactly(fd, 12)
            _ = Self.writeAll(fd, Array("reverse".utf8))
            results.put(0, replies == [5, 0, 5, 0, 0, 1, 0, 0, 0, 0, 0, 0] && Self.readExactly(fd, 7) == Array("reverse".utf8))
        }
        Self.client(port: remotePort) { fd in
            // SOCKS4 to a port nothing listens on: refused (0x5B), then EOF.
            _ = Self.writeAll(fd, [4, 1, UInt8(dead >> 8), UInt8(dead & 0xFF), 127, 0, 0, 1, 0])
            results.put(1, Self.readExactly(fd, 8) == [0, 0x5B, 0, 0, 0, 0, 0, 0] && Self.readExactly(fd, 1).isEmpty)
        }
        XCTAssertTrue(try drive(s, f) { results.count == 2 }, "\(s.sshd.log())")
        XCTAssertEqual(results.all, [true, true])
    }

    func testRemoteTargetRefusedIsReportedOnceAndARefusedServerPortIsReported() throws {
        let deadPort = Int(LiveSSHD.freePort())
        // A port below 1024: a non-root sshd cannot listen there, so the
        // server refuses the request (as it would for a port in use).
        let privileged = 1
        let s = try LiveSession()
        let remotePort = Int(LiveSSHD.freePort())
        let f = PortForwarder(rules: [.remote(bindAddress: "", bindPort: remotePort, host: "127.0.0.1", port: deadPort),
                                      .remote(bindAddress: "", bindPort: privileged, host: "127.0.0.1", port: 1)])
        defer { f.closeAll() }
        try f.requestRemote(connection: s.connection)
        var notices: [String] = []
        XCTAssertTrue(try drive(s, f) { notices += f.takeNotices(); return notices.count >= 2 })
        XCTAssertTrue(notices.contains("forward R \(privileged) → 127.0.0.1:1 not started: the server refused it (port in use there, or remote forwarding not allowed)"), "\(notices)")
        let results = LockedResults()
        for i in 0..<3 { Self.client(port: remotePort) { fd in results.put(i, Self.readExactly(fd, 1).isEmpty) } }
        XCTAssertTrue(try drive(s, f) { notices += f.takeNotices(); return results.count == 3 })
        XCTAssertEqual(results.all, [true, true, true], "each server-side client sees EOF")
        let refused = notices.filter { $0.hasPrefix("forward R \(remotePort) → 127.0.0.1:\(deadPort): ") }
        XCTAssertEqual(refused.count, 1, "reported once: \(notices)")
    }
}

extension ForwardingLiveTests {
    func testStopAndStartWhileConnected() throws {
        let target = try Target(.echo)
        defer { target.stop() }
        let s = try LiveSession()
        let bind = Int(LiveSSHD.freePort()), remotePort = Int(LiveSSHD.freePort())
        let local = ForwardRule.local(bindPort: bind, host: "127.0.0.1", port: Int(target.port))
        let remote = ForwardRule.remote(bindAddress: "", bindPort: remotePort, host: "127.0.0.1", port: Int(target.port))
        let f = PortForwarder(rules: [local, remote])
        defer { f.closeAll() }
        f.start()
        try f.requestRemote(connection: s.connection)
        XCTAssertTrue(try drive(s, f) { f.status.allSatisfy(\.active) })
        // A held connection is counted.
        let held = LockedFlag(true)
        let results = LockedResults()
        Self.client(port: bind) { fd in
            _ = Self.writeAll(fd, Array("x".utf8))
            results.put(0, Self.readExactly(fd, 1) == Array("x".utf8))
            while held.value { usleep(10_000) }
        }
        XCTAssertTrue(try drive(s, f) { results.count == 1 && f.status.first { $0.rule == local }?.connections == 1 })
        // Stop the local listener: new connections refused, the held one lives on.
        try f.setEnabled(local, false, connection: s.connection)
        XCTAssertFalse(f.status.first { $0.rule == local }?.active ?? true)
        XCTAssertThrowsError(try LiveSSHD.connect(port: UInt16(bind)), "stopped listener refuses")
        XCTAssertEqual(f.status.first { $0.rule == local }?.connections, 1, "the carried connection keeps going")
        held.value = false
        try f.setEnabled(local, true, connection: s.connection)
        Self.client(port: bind) { fd in
            _ = Self.writeAll(fd, Array("again".utf8))
            results.put(1, Self.readExactly(fd, 5) == Array("again".utf8))
        }
        XCTAssertTrue(try drive(s, f) { results.count == 2 })
        XCTAssertEqual(results.all, [true, true])
        // Stop the -R: the server stops listening; start asks again.
        try f.setEnabled(remote, false, connection: s.connection)
        XCTAssertTrue(try drive(s, f, timeout: 10) { (try? LiveSSHD.connect(port: UInt16(remotePort))).map { close($0); return false } ?? true })
        try f.setEnabled(remote, true, connection: s.connection)
        XCTAssertTrue(try drive(s, f) { f.status.first { $0.rule == remote }?.active == true })
        Self.client(port: remotePort) { fd in
            _ = Self.writeAll(fd, Array("back".utf8))
            results.put(2, Self.readExactly(fd, 4) == Array("back".utf8))
        }
        XCTAssertTrue(try drive(s, f) { results.count == 3 })
        XCTAssertEqual(results.all, [true, true, true])
    }
}

final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: Bool] = [:]
    func put(_ i: Int, _ v: Bool) { lock.lock(); values[i] = v; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values.keys.sorted().map { values[$0]! } }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ v: Bool) { flag = v }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}
