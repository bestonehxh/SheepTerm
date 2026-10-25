// Port forwarding, client side:
//   `ssh -L`  127.0.0.1:port on this Mac → host:port as the server sees it
//   `ssh -D`  127.0.0.1:port on this Mac is a SOCKS proxy through the server
//   `ssh -R`  port on the SERVER → host:port as this Mac sees it
//   `ssh -R port`  port on the server is a SOCKS proxy out through this Mac
// Local listeners are loopback only. Each connection is one channel on the
// owner's SSH connection (direct-tcpip for -L/-D, forwarded-tcpip for -R).
// Non-blocking throughout, like AgentForwarder: the owner's poll loop
// includes `descriptors` and calls `pump` every pass.
//
// Every buffer is bounded. Toward the far end, the Mac-side socket is read
// only while the channel's queue is short and the owner's socket drains;
// toward the Mac-side socket, the channel's window reopens only as bytes
// reach it (`SSHConnection.consumed`), so a socket that stops reading stops
// the far end instead of growing our memory.
//
// The socket calls are ForwardSocket's: POSIX on the Mac, WinSock in the
// Windows port (same class, same rules, same tests).
import Foundation

public enum ForwardRule: Equatable, Hashable, Sendable {
    /// 127.0.0.1:`bindPort` → `host`:`port` as seen from the server.
    case local(bindPort: Int, host: String, port: Int)
    /// 127.0.0.1:`bindPort` is a SOCKS proxy through the server.
    case dynamic(bindPort: Int)
    /// The server listens on `bindAddress`:`bindPort` ("" = its loopback,
    /// as OpenSSH asks by default) → `host`:`port` as seen from this Mac.
    case remote(bindAddress: String, bindPort: Int, host: String, port: Int)
    /// The server listens on `bindAddress`:`bindPort` as a SOCKS proxy whose
    /// connections leave from this Mac (OpenSSH 7.6's `-R port`).
    case remoteDynamic(bindAddress: String, bindPort: Int)

    public var bindPort: Int {
        switch self {
        case .local(let port, _, _), .dynamic(let port), .remote(_, let port, _, _), .remoteDynamic(_, let port): return port
        }
    }

    /// Listens on the server rather than on this Mac.
    public var isRemote: Bool {
        switch self {
        case .remote, .remoteDynamic: return true
        case .local, .dynamic: return false
        }
    }

    /// `8080 → 10.0.0.1:80`, `1080 SOCKS`, `R 9000 → 127.0.0.1:3000`, `R 1080 SOCKS`.
    public var label: String {
        func target(_ host: String, _ port: Int) -> String { "\(host.contains(":") ? "[\(host)]" : host):\(port)" }
        func remoteBind(_ address: String, _ port: Int) -> String {
            address.isEmpty || address == "localhost" ? "R \(port)" : "R \(target(address, port))"
        }
        switch self {
        case .local(let bind, let host, let port): return "\(bind) → \(target(host, port))"
        case .dynamic(let bind): return "\(bind) SOCKS"
        case .remote(let address, let bind, let host, let port): return "\(remoteBind(address, bind)) → \(target(host, port))"
        case .remoteDynamic(let address, let bind): return "\(remoteBind(address, bind)) SOCKS"
        }
    }
}

/// One rule's state for the UI: whether it is listening (here, or confirmed
/// by the server for -R) and how many connections it carries right now.
public struct ForwardStatus: Equatable, Sendable {
    public let rule: ForwardRule
    public let active: Bool
    public let connections: Int
    public init(rule: ForwardRule, active: Bool, connections: Int) {
        self.rule = rule; self.active = active; self.connections = connections
    }
}

public final class PortForwarder {
    final class Listener {
        let rule: ForwardRule
        var fd: ForwardDescriptor
        init(rule: ForwardRule, fd: ForwardDescriptor) { self.rule = rule; self.fd = fd }
    }

    final class Tunnel {
        enum Stage {
            /// -D: the Mac-side client is speaking SOCKS.
            case socks
            /// -L/-D: waiting for the server to open the channel.
            case opening
            /// -R SOCKS: the server-side client is speaking SOCKS on the channel.
            case channelSocks
            /// -R: connecting to the Mac-side target.
            case connecting
            case open
        }
        let rule: ForwardRule
        /// The Mac-side socket; `ForwardSocket.invalid` while it does not
        /// exist yet (-R) or once released.
        var fd: ForwardDescriptor
        var stage: Stage
        var channel: UInt32?
        var socks = SOCKSHandshake()
        var connector: TCPConnector?
        /// For the channel, held until it opens (a -D client's first bytes).
        var held: [UInt8] = []
        /// For the Mac-side socket.
        var toSocket = ByteQueue()
        var socketEOF = false
        var channelEOF = false
        var shutWrite = false
        /// Close the socket once `toSocket` is written (a SOCKS refusal).
        var closeAfterFlush = false
        var throttledByUnsent = false
        /// A write to the socket hit EAGAIN with bytes still queued.
        var blocked = false
        var released = false
        var isLive: Bool { !released }
        var hasSocket: Bool { fd != ForwardSocket.invalid }
        init(rule: ForwardRule, fd: ForwardDescriptor, stage: Stage) { self.rule = rule; self.fd = fd; self.stage = stage }
    }

    /// Tunnels open at once, over every rule.
    public static let maximumTunnels = 256
    /// Channel queue (waiting for the far end's window) per tunnel before
    /// the Mac-side socket is no longer read.
    public static let maximumQueued = 256 * 1024
    /// The owner's unsent bytes (sealed, not yet on its socket) above which
    /// no Mac-side socket is read. Above SSHWorker's 256 KiB input mark, so
    /// typing is never starved by a transfer — and below the agent
    /// forwarder's 320 KiB, so a signature request is not either.
    public static let maximumUnsent = 288 * 1024

    public let rules: [ForwardRule]
    private var listeners: [Listener] = []
    private var tunnels: [Tunnel] = []
    private var buffer = [UInt8](repeating: 0, count: 32 * 1024)
    private var notices: [String] = []
    /// Rules whose last attempt failed — reported once until one succeeds.
    private var failing: Set<ForwardRule> = []
    /// -R requests awaiting the server's answer, by token.
    private var remoteRequests: [UInt32: ForwardRule] = [:]
    /// Server-side port → the -R rule it serves (the port the server
    /// confirmed, which differs from the rule's when it asked for 0).
    private var remoteByPort: [Int: ForwardRule] = [:]

    public init(rules: [ForwardRule]) {
        self.rules = rules
    }

    deinit { closeAll() }

    /// Binds every local rule's listener on loopback. A port that cannot be
    /// bound (in use, or below 1024) is reported in `takeNotices()`; the
    /// others still start. Returns the local rules that are listening.
    @discardableResult
    public func start() -> [ForwardRule] {
        for rule in rules where !rule.isRemote && !listeners.contains(where: { $0.rule.bindPort == rule.bindPort }) {
            switch ForwardSocket.listenLoopback(port: rule.bindPort) {
            case .success(let fd): listeners.append(Listener(rule: rule, fd: fd))
            case .failure(let why): notices.append("forward \(rule.label) not started: \(why)")
            }
        }
        return listeners.map(\.rule)
    }

    /// Asks the server to listen for every -R rule. The answers arrive as
    /// `.remoteForwardReply` (→ `remoteForwardReply`). Returns the rules asked.
    @discardableResult
    public func requestRemote(connection: SSHConnection) throws(ConnectionError) -> [ForwardRule] {
        var asked: [ForwardRule] = []
        for rule in rules where rule.isRemote && !remoteRequests.values.contains(where: { $0.bindPort == rule.bindPort }) {
            let address: String
            switch rule {
            case .remote(let a, _, _, _), .remoteDynamic(let a, _): address = a
            default: continue
            }
            let token = try connection.requestRemoteForward(address: address, port: rule.bindPort)
            remoteRequests[token] = rule
            asked.append(rule)
        }
        return asked
    }

    /// Local rules listening, plus -R rules the server has confirmed.
    public var listening: [ForwardRule] {
        listeners.filter { $0.fd != ForwardSocket.invalid }.map(\.rule) + rules.filter { r in remoteByPort.values.contains(r) }
    }

    /// Things the user should read (a port that would not bind, a target that
    /// could not be reached, the server's answer to -R). Cleared on read.
    public func takeNotices() -> [String] {
        defer { notices.removeAll() }
        return notices
    }

    /// Tunnels currently carrying a connection.
    public var activeTunnels: Int { tunnels.lazy.filter(\.isLive).count }

    /// Every rule, in order: listening or not, and its live connections.
    public var status: [ForwardStatus] {
        let listeningNow = Set(listening)
        return rules.map { rule in
            ForwardStatus(rule: rule, active: listeningNow.contains(rule),
                          connections: tunnels.lazy.filter { $0.isLive && $0.rule == rule }.count)
        }
    }

    /// Stops or restarts one rule while connected. Stopping closes the local
    /// listener (or cancels the -R on the server); connections already
    /// carried keep going, as with OpenSSH's `~C -KL`. Restarting binds or
    /// asks again — a refusal is a notice, as at connect time.
    public func setEnabled(_ rule: ForwardRule, _ enabled: Bool, connection: SSHConnection) throws(ConnectionError) {
        guard rules.contains(rule) else { return }
        if rule.isRemote {
            if enabled {
                guard !remoteByPort.values.contains(rule), !remoteRequests.values.contains(rule) else { return }
                let address: String
                switch rule {
                case .remote(let a, _, _, _), .remoteDynamic(let a, _): address = a
                default: return
                }
                remoteRequests[try connection.requestRemoteForward(address: address, port: rule.bindPort)] = rule
            } else {
                for (port, r) in remoteByPort where r == rule {
                    remoteByPort[port] = nil
                    let address: String
                    switch rule {
                    case .remote(let a, _, _, _), .remoteDynamic(let a, _): address = a
                    default: address = ""
                    }
                    try connection.cancelRemoteForward(address: address, port: port)
                }
            }
            return
        }
        if enabled {
            guard !listeners.contains(where: { $0.rule == rule && $0.fd != ForwardSocket.invalid }) else { return }
            switch ForwardSocket.listenLoopback(port: rule.bindPort) {
            case .success(let fd): listeners.append(Listener(rule: rule, fd: fd))
            case .failure(let why): notices.append("forward \(rule.label) not started: \(why)")
            }
        } else {
            for l in listeners where l.rule == rule && l.fd != ForwardSocket.invalid { ForwardSocket.close(l.fd); l.fd = ForwardSocket.invalid }
            listeners.removeAll { $0.rule == rule }
        }
    }

    /// The most any one tunnel holds for its Mac-side socket (tests: bounded
    /// by the channel window when that socket stops reading).
    var largestClientQueue: Int { tunnels.map(\.toSocket.count).max() ?? 0 }

    /// For the owner's poll set (POLLIN): listeners, and Mac-side sockets
    /// that have something to say and somewhere to put it.
    public var descriptors: [ForwardDescriptor] {
        listeners.compactMap { $0.fd != ForwardSocket.invalid ? $0.fd : nil } + tunnels.compactMap { t in
            guard t.isLive, t.hasSocket, !t.socketEOF, !t.throttledByUnsent, !t.closeAfterFlush else { return nil }
            return t.stage == .socks || t.stage == .open ? t.fd : nil
        }
    }

    /// Poll with a short timeout meanwhile: a Mac-side socket is full (its
    /// writability is not in the poll set), waits on the unsent budget, or
    /// a -R connect is in progress (lookup on a thread, connect polled).
    public var wantsPromptPump: Bool {
        tunnels.contains { $0.isLive && ($0.blocked || $0.throttledByUnsent || $0.stage == .connecting) }
    }

    public func owns(_ channel: UInt32) -> Bool { tunnels.contains { $0.channel == channel } }

    private func tunnel(_ channel: UInt32) -> Tunnel? { tunnels.first { $0.channel == channel } }

    // MARK: Connection events

    public func channelOpened(_ channel: UInt32, connection: SSHConnection) throws(ConnectionError) {
        guard let t = tunnel(channel) else { return }
        failing.remove(t.rule)
        guard t.isLive else { try connection.close(channel); return }
        t.stage = .open
        if case .dynamic = t.rule { t.toSocket.append(contentsOf: t.socks.successReply()) }
        if !t.held.isEmpty {
            try connection.write(channel, t.held)
            t.held.removeAll()
        }
    }

    public func channelOpenFailed(_ channel: UInt32, reason: UInt32, description: String) {
        guard let t = tunnel(channel) else { return }
        t.channel = nil
        if case .dynamic = t.rule, t.isLive {
            // The browser hears "refused" and shows its own error page.
            t.toSocket.append(contentsOf: t.socks.failureReply(SOCKSHandshake.code(forOpenFailure: reason)))
            t.closeAfterFlush = true
        } else {
            reportOnce(t.rule, description.isEmpty ? "the server refused the connection (reason \(reason))" : description)
            release(t)
        }
    }

    /// The server's answer to one of `requestRemote`'s requests.
    public func remoteForwardReply(token: UInt32, success: Bool, port: Int?) {
        guard let rule = remoteRequests.removeValue(forKey: token) else { return }
        if success, let port {
            remoteByPort[port] = rule
            let picked = port != rule.bindPort ? " (the server picked port \(port))" : ""
            notices.append("forwarding \(rule.label) — listening on the server\(picked)")
        } else {
            notices.append("forward \(rule.label) not started: the server refused it (port in use there, or remote forwarding not allowed)")
        }
    }

    /// The server accepted a connection on one of our -R ports.
    public func forwardedChannelOpened(_ channel: UInt32, port: Int, connection: SSHConnection) throws(ConnectionError) {
        guard let rule = remoteByPort[port], activeTunnels < Self.maximumTunnels else {
            try connection.close(channel)
            return
        }
        switch rule {
        case .remote(_, _, let host, let targetPort):
            let t = Tunnel(rule: rule, fd: ForwardSocket.invalid, stage: .connecting)
            t.channel = channel
            t.connector = TCPConnector(host: host, port: targetPort)
            tunnels.append(t)
        case .remoteDynamic:
            let t = Tunnel(rule: rule, fd: ForwardSocket.invalid, stage: .channelSocks)
            t.channel = channel
            tunnels.append(t)
        default:
            try connection.close(channel)
        }
    }

    public func received(_ channel: UInt32, _ bytes: [UInt8], connection: SSHConnection) throws(ConnectionError) {
        guard let t = tunnel(channel), t.isLive else { return }
        guard t.stage == .channelSocks else {
            // Bounded by the channel window: nothing reopens it until written.
            t.toSocket.append(contentsOf: bytes)
            return
        }
        // The handshake is ours to read: its bytes reopen the window now.
        try connection.consumed(channel, bytes.count)
        switch t.socks.receive(bytes) {
        case .pending:
            break
        case .reply(let reply):
            try connection.write(channel, reply)
        case .refuse(let reply):
            if !reply.isEmpty { try connection.write(channel, reply) }
            try finishChannel(t, connection: connection)
        case .connect(let host, let port, let leftover):
            t.toSocket.append(contentsOf: leftover)
            t.connector = TCPConnector(host: host, port: port)
            t.stage = .connecting
        }
    }

    public func channelEOF(_ channel: UInt32) {
        tunnel(channel)?.channelEOF = true
    }

    public func channelClosed(_ channel: UInt32) {
        guard let index = tunnels.firstIndex(where: { $0.channel == channel }) else { return }
        let t = tunnels[index]
        // A server sends the last data, EOF and CLOSE together: what is
        // still queued for the socket is written first, then it goes.
        if t.isLive, t.hasSocket, !t.toSocket.isEmpty {
            t.channel = nil
            t.closeAfterFlush = true
            return
        }
        release(t)
        tunnels.remove(at: index)
    }

    // MARK: Pump

    public func pump(connection: SSHConnection, unsentBytes: () -> Int = { 0 }) throws(ConnectionError) {
        for listener in listeners where listener.fd != ForwardSocket.invalid { try accept(listener, connection: connection) }
        for t in tunnels where t.isLive {
            if t.stage == .connecting { try advanceConnect(t, connection: connection) }
            guard t.isLive, t.hasSocket else { continue }
            try writeToSocket(t, connection: connection)
            guard t.isLive else { continue }
            try readFromSocket(t, connection: connection, unsentBytes: unsentBytes)
            guard t.isLive else { continue }
            // Both directions done: the channel goes, the socket with it.
            if t.socketEOF, t.channelEOF, t.toSocket.isEmpty, let channel = t.channel {
                release(t)
                try connection.close(channel)
            }
        }
        // Tunnels that never got (or already lost) a channel are gone now.
        tunnels.removeAll { !$0.isLive && $0.channel == nil }
    }

    private func advanceConnect(_ t: Tunnel, connection: SSHConnection) throws(ConnectionError) {
        guard let connector = t.connector else { return }
        switch connector.step() {
        case .pending:
            return
        case .connected(let fd):
            ForwardSocket.configure(fd)
            t.fd = fd
            t.connector = nil
            t.stage = .open
            failing.remove(t.rule)
            if case .remoteDynamic = t.rule, let channel = t.channel {
                try connection.write(channel, t.socks.successReply())
            }
        case .failed(let why):
            t.connector = nil
            if case .remoteDynamic = t.rule, let channel = t.channel {
                // The far client hears "refused"; one bad name is not news here.
                try? connection.write(channel, t.socks.failureReply(5))
            } else {
                reportOnce(t.rule, why)
            }
            try finishChannel(t, connection: connection)
        }
    }

    /// Ends a tunnel that has no Mac-side socket to drain.
    private func finishChannel(_ t: Tunnel, connection: SSHConnection) throws(ConnectionError) {
        release(t)
        if let channel = t.channel {
            try connection.sendEOF(channel)
            try connection.close(channel)
        }
    }

    private func reportOnce(_ rule: ForwardRule, _ why: String) {
        guard !failing.contains(rule) else { return }
        failing.insert(rule)
        notices.append("forward \(rule.label): \(why)")
    }

    private func accept(_ listener: Listener, connection: SSHConnection) throws(ConnectionError) {
        while true {
            guard let (fd, originPort) = ForwardSocket.accept(listener.fd) else { return }
            guard activeTunnels < Self.maximumTunnels else {
                ForwardSocket.close(fd)
                if !notices.contains(where: { $0.hasPrefix("forward: more than") }) {
                    notices.append("forward: more than \(Self.maximumTunnels) connections at once — new ones are refused")
                }
                continue
            }
            ForwardSocket.configure(fd)
            switch listener.rule {
            case .local(_, let host, let port):
                let t = Tunnel(rule: listener.rule, fd: fd, stage: .opening)
                t.channel = try connection.openDirectTCPIP(host: host, port: port, originatorHost: "127.0.0.1",
                                                           originatorPort: originPort, manualWindow: true)
                tunnels.append(t)
            case .dynamic:
                tunnels.append(Tunnel(rule: listener.rule, fd: fd, stage: .socks))
            case .remote, .remoteDynamic:
                ForwardSocket.close(fd)
            }
        }
    }

    private func readFromSocket(_ t: Tunnel, connection: SSHConnection, unsentBytes: () -> Int) throws(ConnectionError) {
        t.throttledByUnsent = false
        guard !t.socketEOF, !t.closeAfterFlush, t.stage == .socks || t.stage == .open else { return }
        while true {
            if t.stage == .open, let channel = t.channel {
                if connection.pendingOutput(channel) >= Self.maximumQueued { return }   // WINDOW_ADJUST wakes the SSH socket
                if unsentBytes() >= Self.maximumUnsent { t.throttledByUnsent = true; return }
            }
            switch buffer.withUnsafeMutableBytes({ ForwardSocket.read(t.fd, into: $0) }) {
            case .bytes(let n):
                let bytes = Array(buffer[0..<n])
                if t.stage == .socks {
                    try socks(t, bytes, connection: connection)
                    if t.stage != .open { return }
                } else if let channel = t.channel {
                    try connection.write(channel, bytes)
                }
            case .eof:
                t.socketEOF = true
                if t.stage == .socks { release(t); return }
                if let channel = t.channel { try connection.sendEOF(channel) }
                return
            case .wouldBlock:
                return
            case .failed:
                try abort(t, connection: connection)
                return
            }
        }
    }

    private func socks(_ t: Tunnel, _ bytes: [UInt8], connection: SSHConnection) throws(ConnectionError) {
        switch t.socks.receive(bytes) {
        case .pending:
            break
        case .reply(let reply):
            t.toSocket.append(contentsOf: reply)
        case .refuse(let reply):
            t.toSocket.append(contentsOf: reply)
            t.closeAfterFlush = true
        case .connect(let host, let port, let leftover):
            t.held = leftover
            t.stage = .opening
            t.channel = try connection.openDirectTCPIP(host: host, port: port, originatorHost: "127.0.0.1",
                                                       originatorPort: 0, manualWindow: true)
        }
    }

    private func writeToSocket(_ t: Tunnel, connection: SSHConnection) throws(ConnectionError) {
        t.blocked = false
        while !t.toSocket.isEmpty {
            switch t.toSocket.unread.withUnsafeBytes({ ForwardSocket.write(t.fd, $0) }) {
            case .bytes(let n):
                t.toSocket.consume(n)
                // SOCKS replies to a -D client were never channel data; only
                // open-stage bytes reopen the window.
                if t.stage == .open, let channel = t.channel { try connection.consumed(channel, n) }
            case .wouldBlock:
                t.blocked = true
                return
            case .eof, .failed:
                try abort(t, connection: connection)
                return
            }
        }
        if t.closeAfterFlush {
            release(t)
            if let channel = t.channel { try connection.close(channel) }
            return
        }
        if t.channelEOF, !t.shutWrite {
            t.shutWrite = true
            ForwardSocket.shutdownWrite(t.fd)
        }
    }

    private func abort(_ t: Tunnel, connection: SSHConnection) throws(ConnectionError) {
        release(t)
        t.toSocket.removeAll(keepingCapacity: false)
        if let channel = t.channel { try connection.close(channel) }
    }

    private func release(_ t: Tunnel) {
        if t.hasSocket { ForwardSocket.close(t.fd) }
        t.fd = ForwardSocket.invalid
        t.connector = nil
        t.released = true
    }

    public func closeAll() {
        for t in tunnels { release(t) }
        tunnels.removeAll()
        for l in listeners where l.fd != ForwardSocket.invalid { ForwardSocket.close(l.fd); l.fd = ForwardSocket.invalid }
        listeners.removeAll()
    }
}
