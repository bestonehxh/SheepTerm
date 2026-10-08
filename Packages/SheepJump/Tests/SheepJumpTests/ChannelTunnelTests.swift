import XCTest
import SheepSSH
@testable import SheepJump

final class ChannelTunnelTests: XCTestCase {
    /// A connection whose transport never ran: enough for the routing rules,
    /// which only look at events. (The wire format of the open is pinned in
    /// SheepSSH's own ConnectionTests.)
    private func tunnel(channel: UInt32 = 3) -> ChannelTunnel {
        let transport = SSHTransport(configuration: .init(hostKeyValidator: { _ in true }))
        return ChannelTunnel(connection: SSHConnection(transport: transport), channel: channel)
    }

    func testOnlyThisChannelsDataIsInbound() {
        let t = tunnel(channel: 3)
        let others = t.absorb([
            .data(3, [1, 2, 3]),
            .data(4, [9, 9]),                 // another channel
            .extendedData(3, [7]),            // stderr: not a wire
            .globalReply(success: true),
            .data(3, [4]),
        ])
        XCTAssertEqual(t.takeInbound(), [1, 2, 3, 4])
        XCTAssertEqual(t.takeInbound(), [])
        XCTAssertFalse(t.hasInbound)
        XCTAssertEqual(others, [.data(4, [9, 9]), .extendedData(3, [7]), .globalReply(success: true)])
        XCTAssertFalse(t.peerClosed)
    }

    func testEOFAndCloseMeanThePeerHungUpButTheBytesWithThemStillCount() {
        let t = tunnel(channel: 5)
        t.absorb([.data(5, [1]), .eof(5)])
        XCTAssertTrue(t.peerClosed)
        XCTAssertEqual(t.takeInbound(), [1])          // delivered before "closed by peer"
        let u = tunnel(channel: 5)
        u.absorb([.closed(5)])
        XCTAssertTrue(u.peerClosed)
        let v = tunnel(channel: 5)
        v.absorb([.eof(6), .closed(6)])               // someone else's channel
        XCTAssertFalse(v.peerClosed)
    }

    func testOpenOutcomeIsReadFromTheEvents() {
        XCTAssertNil(ChannelTunnel.outcome(of: [.data(1, [0]), .channelOpened(2)], channel: 1))
        XCTAssertEqual(ChannelTunnel.outcome(of: [.globalReply(success: true), .channelOpened(1)], channel: 1), .opened)
        XCTAssertEqual(ChannelTunnel.outcome(of: [.channelOpenFailed(1, reason: 2, description: "Connection refused")], channel: 1),
                       .failed(reason: 2, description: "Connection refused"))
    }

    func testRefusalsAreExplained() {
        XCTAssertNil(ChannelTunnel.explain(.opened, target: "10.0.0.5:22"))
        XCTAssertEqual(ChannelTunnel.explain(.failed(reason: 1, description: ""), target: "10.0.0.5:22"),
                       "the jump host does not allow TCP forwarding")
        XCTAssertEqual(ChannelTunnel.explain(.failed(reason: 2, description: "Connection refused"), target: "10.0.0.5:22"),
                       "the jump host could not reach 10.0.0.5:22 (Connection refused)")
        XCTAssertEqual(ChannelTunnel.explain(.failed(reason: 4, description: ""), target: "x"),
                       "the jump host refused the tunnel to x")
    }

    func testWritingOnAChannelThatIsNotOpenFails() {
        let t = tunnel(channel: 9)
        XCTAssertFalse(t.isOpen)
        XCTAssertThrowsError(try t.write([1, 2]))
        XCTAssertNoThrow(try t.write([]))             // nothing to send is not an error
        t.close()                                     // idempotent on a channel that never opened
        XCTAssertEqual(t.pendingOutput, 0)
    }

    func testHopLabel() {
        XCTAssertEqual(JumpHop(host: "bastion.example", port: 22, username: "u").label, "bastion.example")
        XCTAssertEqual(JumpHop(host: "10.0.0.1", port: 2222, username: "u").label, "10.0.0.1:2222")
        XCTAssertEqual(JumpHop(host: "fe80::1", port: 2222, username: "u").label, "[fe80::1]:2222")
        XCTAssertEqual(JumpHop(host: "h", port: 22, username: "u").cipherPolicy, .auto)
    }
}
