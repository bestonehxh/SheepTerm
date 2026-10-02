// ForwardAgent, client side: each auth-agent@openssh.com channel the server
// opens is spliced to a fresh connection to the local ssh-agent. Non-blocking
// throughout — the owner's poll loop calls `pump` whenever the SSH socket or
// any of `descriptors` is ready (or on a short tick).
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public final class AgentForwarder {
    enum Throttle { case window, unsent }

    final class Tunnel {
        let channel: UInt32
        /// -1 once released (a finished tunnel gives its fd back at once,
        /// not when the far end gets round to CLOSE).
        var fd: Int32
        var toAgent = ByteQueue()
        var agentEOF = false
        /// Not read this pass because the way out is full (see `pump`).
        var throttled: Throttle?
        /// The socket is open (not finished, not at agent EOF).
        var isLive: Bool { fd >= 0 }
        var channelEOF = false
        var finished = false
        init(channel: UInt32, fd: Int32) { self.channel = channel; self.fd = fd }
    }

    public let socketPath: String
    private var tunnels: [UInt32: Tunnel] = [:]
    private var buffer = [UInt8](repeating: 0, count: 16 * 1024)

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit { closeAll() }

    /// The agent sockets to include in the owner's poll set (for POLLIN).
    /// Left out while there is nothing to read from them for now — at EOF,
    /// or throttled — or poll() would return at once on every pass and the
    /// owner's loop would spin a core.
    public var descriptors: [Int32] {
        tunnels.values.filter { $0.isLive && $0.throttled == nil }.map(\.fd)
    }

    /// A tunnel waits for the owner's unsent bytes to drain. The owner
    /// should poll with a short timeout meanwhile: its fd is not in
    /// `descriptors`, and the drain may happen inside the owner's own flush
    /// with nothing else left to wake it. (A tunnel waiting for the far
    /// end's window needs no such care: WINDOW_ADJUST arrives on the SSH
    /// socket, which wakes poll.)
    public var isThrottledByUnsent: Bool { tunnels.values.contains { $0.isLive && $0.throttled == .unsent } }

    /// Agent sockets open at once. `ssh -A` hops use one or two; the fds
    /// come from the app's one table, shared by every tab, so a far end
    /// opening thousands must not be able to exhaust it. Tunnels whose fd
    /// is already closed (finished, or agent at EOF with the reply still
    /// going out) do not count — the connection bounds those
    /// (`SSHConnection.maximumAgentChannels`).
    public static let maximumTunnels = 16

    /// Everything the owner has not yet written to its socket may hold this
    /// much before agent replies wait. SSHWorker stops its own input at
    /// 256 KiB, so replies always have the 64 KiB above it: a long paste
    /// never holds a signature request back. The trade-off, accepted: a far
    /// end requesting replies faster than the link carries them can keep
    /// input waiting — as it can anyway by keeping its window shut.
    public static let maximumUnsent = 320 * 1024

    public func owns(_ channel: UInt32) -> Bool { tunnels[channel] != nil }

    /// Call on `.agentChannelOpened`. If the agent cannot be reached the
    /// channel is closed — the far end sees "agent refused", nothing worse.
    public func channelOpened(_ channel: UInt32, connection: SSHConnection) throws(ConnectionError) {
        guard tunnels.values.lazy.filter(\.isLive).count < Self.maximumTunnels, let fd = try? SSHAgent.connect(socketPath) else {
            try connection.close(channel)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        tunnels[channel] = Tunnel(channel: channel, fd: fd)
    }

    /// Call for `.data` on a channel this forwarder owns.
    /// Per-tunnel cap on bytes the agent has not read yet. Agent requests
    /// are a few KiB; a far end streaming more than this is not talking to
    /// an agent, and without a cap it could grow our memory without bound
    /// (the connection re-opens its window as soon as data is parsed).
    public static let maximumBuffered = 256 * 1024

    /// Call for `.data` on a channel this forwarder owns. Returns false when
    /// the tunnel was over its cap and has been closed.
    @discardableResult
    public func received(_ channel: UInt32, _ bytes: [UInt8], connection: SSHConnection) -> Bool {
        // A finished tunnel's socket is gone: whatever still arrives before
        // the far end confirms CLOSE has nowhere to go, so it is not kept.
        guard let t = tunnels[channel], t.isLive else { return true }
        guard t.toAgent.count + bytes.count <= Self.maximumBuffered else {
            finish(t)
            t.toAgent.removeAll(keepingCapacity: false)
            try? connection.close(channel)
            return false
        }
        t.toAgent.append(contentsOf: bytes)
        return true
    }

    public func channelEOF(_ channel: UInt32) {
        tunnels[channel]?.channelEOF = true
    }

    public func channelClosed(_ channel: UInt32) {
        guard let t = tunnels.removeValue(forKey: channel) else { return }
        release(t)
    }

    private func finish(_ t: Tunnel) {
        t.finished = true
        release(t)
    }

    private func release(_ t: Tunnel) {
        if t.fd >= 0 { _ = Self.closeFD(t.fd) }
        t.fd = -1
    }

    /// Moves bytes both ways without blocking. `unsentBytes`: what the owner
    /// has sealed or queued for the socket but not yet written, read afresh
    /// before every agent read — replies written in this very pass count.
    public func pump(connection: SSHConnection, unsentBytes: () -> Int = { 0 }) throws(ConnectionError) {
        // Called on every pass of the owner's loop; nearly always idle.
        guard tunnels.values.contains(where: { !$0.finished }) else { return }
        for t in tunnels.values where !t.finished {
            // Channel → agent.
            while t.isLive, !t.toAgent.isEmpty {
                let n = t.toAgent.unread.withUnsafeBytes { send(t.fd, $0.baseAddress, $0.count, Self.sendFlags) }
                if n > 0 { t.toAgent.consume(n) } else { break }
            }
            if t.isLive, t.channelEOF, t.toAgent.isEmpty { _ = shutdown(t.fd, Int32(SHUT_WR)) }
            // Agent → channel, but only while the way out drains: a far end
            // that keeps the window shut (or its TCP receive side) while
            // sending requests would otherwise have us buffer the agent's
            // larger replies without bound. The agent waits on its socket.
            func throttle() -> Throttle? {
                if connection.pendingOutput(t.channel) >= Self.maximumBuffered { return .window }
                if unsentBytes() >= Self.maximumUnsent { return .unsent }
                return nil
            }
            t.throttled = nil
            while !t.agentEOF {
                if let reason = throttle() { t.throttled = reason; break }
                let n = buffer.withUnsafeMutableBytes { read(t.fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    try connection.write(t.channel, Array(buffer[0..<n]))
                } else if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                    t.agentEOF = true
                    // EOF goes out after the queued reply (the connection
                    // defers it); CLOSE only once that reply is sent — a
                    // CLOSE now would drop what still waits for window. The
                    // socket itself is done: its fd goes back at once.
                    release(t)
                    t.toAgent.removeAll(keepingCapacity: false)
                    try connection.sendEOF(t.channel)
                } else {
                    break
                }
            }
            if t.agentEOF, connection.pendingOutput(t.channel) == 0 {
                finish(t)
                try connection.close(t.channel)
            }
        }
    }

    public func closeAll() {
        for t in tunnels.values { release(t) }
        tunnels.removeAll()
    }

#if canImport(Glibc)
    static let sendFlags = Int32(MSG_NOSIGNAL)
    static func closeFD(_ fd: Int32) -> Int32 { Glibc.close(fd) }
#else
    static let sendFlags: Int32 = 0
    static func closeFD(_ fd: Int32) -> Int32 { Darwin.close(fd) }
#endif
}
