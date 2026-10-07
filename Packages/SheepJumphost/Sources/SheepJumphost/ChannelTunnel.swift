import Foundation
import SheepSSH

/// A bastion's direct-tcpip channel, seen as the wire under an inner SSH
/// transport. Sans-I/O: the owner pumps the bastion socket into the bastion
/// transport, hands this object the bastion connection's events, takes the
/// inner transport's inbound bytes from `takeInbound`, and writes the inner
/// transport's outgoing bytes with `write`. Nothing here touches a socket.
///
/// Rules the tests pin:
///   * only `.data` for THIS channel is inbound; every other event is handed
///     back to the owner untouched (agent channels, global replies);
///   * EOF or CLOSE on the channel means the far end hung up — once the bytes
///     that came with it have been taken, the owner reports "closed by peer";
///   * `write` after the channel closed fails rather than buffering for ever.
public final class ChannelTunnel {
    public let connection: SSHConnection
    public let channel: UInt32
    private var inbound = ByteQueue()
    /// EOF or CLOSE was seen for the channel.
    public private(set) var peerClosed = false

    public init(connection: SSHConnection, channel: UInt32) {
        self.connection = connection
        self.channel = channel
    }

    // MARK: - opening

    /// Ask `connection` for a direct-tcpip channel to `host:port`. The owner
    /// waits for the answer (`outcome(of:channel:)`) before wrapping the
    /// channel in a tunnel.
    public static func open(on connection: SSHConnection, host: String, port: Int) throws(ConnectionError) -> UInt32 {
        try connection.openDirectTCPIP(host: host, port: port)
    }

    public enum OpenOutcome: Equatable, Sendable {
        case opened
        /// The bastion could not (or may not) connect; `description` is the
        /// server's text, often empty.
        case failed(reason: UInt32, description: String)
    }

    /// The channel's open answer among `events`, if it has arrived.
    public static func outcome(of events: [SSHConnection.Event], channel: UInt32) -> OpenOutcome? {
        for event in events {
            switch event {
            case .channelOpened(let id) where id == channel:
                return .opened
            case .channelOpenFailed(let id, let reason, let description) where id == channel:
                return .failed(reason: reason, description: description)
            default:
                continue
            }
        }
        return nil
    }

    /// What a refused open means, in words the user can act on. Reason 2 is
    /// CONNECT_FAILED (the bastion could not reach the host), 1 is
    /// ADMINISTRATIVELY_PROHIBITED (`AllowTcpForwarding no`).
    public static func explain(_ outcome: OpenOutcome, target: String) -> String? {
        guard case .failed(let reason, let description) = outcome else { return nil }
        let detail = description.isEmpty ? "" : " (\(description))"
        switch reason {
        case 1: return "the jump host does not allow TCP forwarding" + detail
        case 2: return "the jump host could not reach \(target)" + detail
        default: return "the jump host refused the tunnel to \(target)" + detail
        }
    }

    // MARK: - inbound

    /// Route the bastion connection's events: data for this channel is kept
    /// for `takeInbound`, EOF/CLOSE for it sets `peerClosed`, and everything
    /// else comes back for the owner to handle (or ignore).
    @discardableResult
    public func absorb(_ events: [SSHConnection.Event]) -> [SSHConnection.Event] {
        var others: [SSHConnection.Event] = []
        for event in events {
            switch event {
            case .data(let id, let bytes) where id == channel:
                inbound.append(contentsOf: bytes)
            case .eof(let id) where id == channel, .closed(let id) where id == channel:
                peerClosed = true
            default:
                others.append(event)
            }
        }
        return others
    }

    /// Bytes received for the inner transport since the last call.
    public func takeInbound() -> [UInt8] {
        guard !inbound.isEmpty else { return [] }
        let bytes = Array(inbound.unread)
        inbound.consume(bytes.count)
        return bytes
    }

    public var hasInbound: Bool { !inbound.isEmpty }

    // MARK: - outbound

    /// Whether the channel can still carry bytes.
    public var isOpen: Bool { !peerClosed && connection.isOpen(channel) }

    /// Queue inner-transport bytes on the channel (the bastion connection's
    /// window and the owner's flush of the bastion socket decide when they
    /// leave). Fails once the channel is gone.
    public func write(_ bytes: [UInt8]) throws(ConnectionError) {
        guard !bytes.isEmpty else { return }
        try connection.write(channel, bytes)
    }

    /// Bytes queued on the channel that the bastion has not been handed yet.
    public var pendingOutput: Int { connection.pendingOutput(channel) }

    /// EOF then CLOSE, if the channel is still open. Idempotent.
    public func close() {
        guard connection.isOpen(channel) else { return }
        try? connection.sendEOF(channel)
        try? connection.close(channel)
    }
}
