import XCTest
@testable import SheepSSH

/// The connection layer against scripted server messages, sans-I/O: the
/// transport is put in its post-kex state with no cipher, so what the
/// connection sends comes back out as cleartext packets.
final class ConnectionTests: XCTestCase {
    func connection() -> (SSHConnection, SSHTransport) {
        let t = SSHTransport(configuration: .init(hostKeyValidator: { _ in true }))
        t._testEnterRunningInTheClear()
        return (SSHConnection(transport: t), t)
    }

    /// The payloads of every cleartext packet the transport has queued.
    func sent(_ t: SSHTransport) -> [[UInt8]] {
        let bytes = t.takeOutgoing()
        var out: [[UInt8]] = []
        var i = 0
        while i + 5 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let padding = Int(bytes[i + 4])
            out.append(Array(bytes[(i + 5)..<(i + 4 + length - padding)]))
            i += 4 + length
        }
        XCTAssertEqual(i, bytes.count, "whole packets only")
        return out
    }

    func confirmation(local: UInt32, remote: UInt32) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(91)
        w.writeUInt32(local)
        w.writeUInt32(remote)
        w.writeUInt32(1 << 20)
        w.writeUInt32(32 * 1024)
        return w.bytes
    }

    func channelClose(_ recipient: UInt32) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(97)
        w.writeUInt32(recipient)
        return w.bytes
    }

    func openFailure(_ recipient: UInt32) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(92)
        w.writeUInt32(recipient)
        w.writeUInt32(2)                        // CONNECT_FAILED
        w.writeString("no")
        w.writeString("")
        return w.bytes
    }

    /// close() while the open is in flight: the confirmation is answered
    /// with the CLOSE it is owed (to the server's number), `.channelOpened`
    /// never surfaces, and the server's CLOSE completes it as `.closed`.
    func testCloseBeforeOpenConfirmationSendsCloseOnConfirmation() throws {
        let (c, t) = connection()
        let id = try c.openSession()
        XCTAssertEqual(sent(t).map(\.first), [90])
        try c.close(id)
        XCTAssertEqual(sent(t), [], "nothing to send before the server named its end")
        XCTAssertFalse(c.isOpen(id))

        try c.handle(confirmation(local: id, remote: 77))
        XCTAssertEqual(sent(t), [[97, 0, 0, 0, 77]], "CHANNEL_CLOSE to the server's channel number")
        XCTAssertEqual(c.takeEvents(), [], "no .channelOpened for a channel nobody wants")
        XCTAssertFalse(c.isOpen(id))

        try c.handle(channelClose(id))
        XCTAssertEqual(c.takeEvents(), [.closed(id)])
        XCTAssertEqual(sent(t), [], "the CLOSE went once")
        XCTAssertThrowsError(try c.close(id), "the number is free") {
            XCTAssertEqual($0 as? ConnectionError, .unknownChannel(id))
        }
    }

    /// The quiet twin: no close() — the confirmation surfaces
    /// `.channelOpened` and sends nothing on its own.
    func testConfirmationWithoutCloseOpensTheChannel() throws {
        let (c, t) = connection()
        let id = try c.openSession()
        _ = sent(t)
        try c.handle(confirmation(local: id, remote: 5))
        XCTAssertEqual(c.takeEvents(), [.channelOpened(id)])
        XCTAssertEqual(sent(t), [])
        XCTAssertTrue(c.isOpen(id))
    }

    /// OPEN_FAILURE for a channel the caller already closed completes that
    /// close (`.closed`), not an open failure nobody is waiting on.
    func testOpenFailureAfterCloseReportsClosed() throws {
        let (c, t) = connection()
        let id = try c.openSession()
        try c.close(id)
        _ = sent(t)
        try c.handle(openFailure(id))
        XCTAssertEqual(c.takeEvents(), [.closed(id)])
        XCTAssertEqual(sent(t), [], "nothing is owed to a channel that never opened")
        XCTAssertThrowsError(try c.close(id))
    }

    /// Twin: an open the caller still wants reports the failure.
    func testOpenFailureWithoutCloseIsReported() throws {
        let (c, t) = connection()
        let id = try c.openSession()
        _ = sent(t)
        try c.handle(openFailure(id))
        XCTAssertEqual(c.takeEvents(), [.channelOpenFailed(id, reason: 2, description: "no")])
        XCTAssertEqual(sent(t), [])
    }
}
