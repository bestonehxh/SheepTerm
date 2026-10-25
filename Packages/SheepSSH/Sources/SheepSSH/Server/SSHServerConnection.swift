// The connection protocol (RFC 4254), SERVER role, plus the userauth server
// (RFC 4252 password method) — the mirror of SSHConnection for SheepTerm's
// File Server (SFTP/SCP a switch connects to). Sans-I/O on top of
// SSHServerTransport, like the client connection is on SSHTransport.
// Ported from SheepDrop; changes: ONE login (user + password, both compared
// in constant time through `ServerAuth`), a cap on failed passwords and on
// userauth requests, the "ssh-connection" service check, GLOBAL_REQUEST
// answered, data past our window refused, `pendingOutput` for senders.
//
// What it answers itself: SERVICE_REQUEST, USERAUTH (password only; the
// authenticator closure decides; a "none" probe gets a failure that names
// password, as OpenSSH's client relies on), session CHANNEL_OPEN,
// WINDOW_ADJUST, CHANNEL_CLOSE, EOF, and CHANNEL_REQUEST replies. Ending a
// channel from our side is the owner's call: `finish` (EOF + CLOSE after
// the queue drains) or `close`. What it
// hands up as events: the subsystem/exec request the owner serves, channel
// data, EOF and close.
import Foundation

public final class SSHServerConnection {
    public enum Event: Sendable, Equatable {
        /// The client authenticated with the password method.
        case authenticated
        /// The password method itself was rejected. A "none" probe or an
        /// unknown method is NOT this — clients probe first, then send the
        /// password; the owner must not hang up on a probe.
        case passwordRejected(String)
        case channelOpened(UInt32)
        case channelRequest(UInt32, ChannelRequest)
        case data(UInt32, [UInt8])
        case eof(UInt32)
        case closed(UInt32)
    }

    public enum ChannelRequest: Equatable, Sendable {
        case subsystem(String)
        case exec(String)
        /// Anything else (pty-req, shell, …) — answered CHANNEL_FAILURE at
        // once; the event exists for logging.
        case refused(String)
    }

    public struct Configuration: Sendable {
        /// The one login. An empty password lets nobody in.
        public var username: String
        public var password: String
        /// Rejected passwords before the connection is dropped.
        public var maximumPasswordAttempts: Int
        /// USERAUTH_REQUESTs of any method (probes included) before the
        /// connection is dropped.
        public var maximumAuthRequests: Int
        /// Sessions at once (closed-but-unconfirmed included).
        public var maximumSessions: Int

        public init(username: String, password: String, maximumPasswordAttempts: Int = 3,
                    maximumAuthRequests: Int = 12, maximumSessions: Int = 4) {
            self.username = username
            self.password = password
            self.maximumPasswordAttempts = maximumPasswordAttempts
            self.maximumAuthRequests = maximumAuthRequests
            self.maximumSessions = maximumSessions
        }
    }

    public static let windowSize: UInt64 = 2 * 1024 * 1024
    public static let maxPacket: Int = 32 * 1024
    static let maximumRemotePacket = PacketProtection.maximumPacketLength - 1024

    public let configuration: Configuration
    public private(set) var isAuthenticated = false
    public private(set) var authenticatedUser: String?
    public private(set) var passwordFailures = 0
    private var authRequests = 0
    private var userauthAccepted = false

    private let transport: SSHServerTransport
    private var events: [Event] = []

    final class Channel {
        let local: UInt32
        var remote: UInt32 = 0
        var open = false
        var remoteWindow: UInt64 = 0
        var remoteMaxPacket = 0
        var localWindow: UInt64
        var consumedSinceAdjust: UInt64 = 0
        var outgoing: [UInt8] = []
        var outgoingStart = 0
        var pendingCount: Int { outgoing.count - outgoingStart }
        var eofPending = false
        var eofSent = false
        /// `finish` was called: CLOSE follows our EOF once the queue drains.
        var closeAfterEOF = false
        var eofReceived = false
        var closeSent = false
        var closeReceived = false
        /// Subsystem/exec requests waiting for the owner's answer, oldest
        /// first: true = the client wants a reply.
        var pendingReplies: [Bool] = []

        init(local: UInt32) {
            self.local = local
            self.localWindow = SSHServerConnection.windowSize
        }
    }

    private var channels: [UInt32: Channel] = [:]
    private var nextChannel: UInt32 = 0

    public init(transport: SSHServerTransport, configuration: Configuration) {
        self.transport = transport
        self.configuration = configuration
    }

    public func takeEvents() -> [Event] {
        defer { events.removeAll() }
        return events
    }

    // MARK: Incoming

    /// Feed every transport `.message`.
    public func handle(_ payload: [UInt8]) throws {
        guard let type = payload.first else { return }
        var r = SSHReader(payload, from: 1)
        // RFC 4252 §6: nothing of the connection protocol before userauth
        // succeeds. Without this gate a client could skip USERAUTH, open a
        // session and run sftp/scp unauthenticated (the libssh
        // CVE-2018-10933 class). Connection-layer numbers are 80…127.
        if !isAuthenticated, type >= 80 {
            throw ConnectionError.protocolError("message \(type) before authentication")
        }
        switch type {
        case SSHMessage.serviceRequest:
            // RFC 4252 §5: the client asks for "ssh-userauth"; the
            // userauth requests themselves then carry "ssh-connection".
            let service = (try? r.readUTF8()) ?? ""
            guard service == "ssh-userauth" else { return }
            userauthAccepted = true
            try send(mkServiceAccept())
        case 50:                                    // USERAUTH_REQUEST
            guard userauthAccepted else {
                throw ConnectionError.protocolError("userauth before service request")
            }
            try handleAuth(&r)
        case 80:                                    // GLOBAL_REQUEST
            _ = try r.readUTF8()
            if try r.readBool() { try send([82]) }  // REQUEST_FAILURE
        case 90:                                    // CHANNEL_OPEN
            try incomingOpen(&r)
        case 93:                                    // WINDOW_ADJUST
            let channel = try known(try r.readUInt32())
            let add = UInt64(try r.readUInt32())
            channel.remoteWindow = min(channel.remoteWindow + add, UInt64(UInt32.max))
            try flush(channel)
        case 94:                                    // CHANNEL_DATA
            let channel = try known(try r.readUInt32())
            let data = try r.readString()
            // A client that ignores our window would grow the owner's buffers
            // without bound; OpenSSH and every real client respect it.
            guard UInt64(data.count) <= channel.localWindow else {
                throw ConnectionError.protocolError("data past the channel window")
            }
            channel.localWindow -= UInt64(data.count)
            channel.consumedSinceAdjust += UInt64(data.count)
            if !data.isEmpty { events.append(.data(channel.local, data)) }
            try replenish(channel)
        case 96:                                    // EOF
            let channel = try known(try r.readUInt32())
            channel.eofReceived = true
            events.append(.eof(channel.local))
        case 97:                                    // CHANNEL_CLOSE
            let channel = try known(try r.readUInt32())
            channel.closeReceived = true
            if !channel.closeSent {
                channel.closeSent = true
                try sendClose(channel)
            }
            finishIfClosed(channel)
        case 98:                                    // CHANNEL_REQUEST
            try channelRequest(&r)
        default:
            break                                   // ignore what we don't serve
        }
    }

    private func handleAuth(_ r: inout SSHReader) throws {
        guard !isAuthenticated else { return }      // RFC 4252 §5.1: ignored
        authRequests += 1
        guard authRequests <= configuration.maximumAuthRequests else {
            transport.disconnect(reason: .noMoreAuthMethodsAvailable, description: "too many authentication requests")
            throw ConnectionError.protocolError("too many authentication requests")
        }
        let user = (try? r.readUTF8()) ?? ""
        let service = (try? r.readUTF8()) ?? ""
        let method = (try? r.readUTF8()) ?? ""

        // "none" (and any method but password) gets a failure naming the one
        // method that exists; only a REJECTED password is an auth failure.
        if method == "password", (try? r.readBool()) == false,
           let password = try? r.readUTF8() {
            // Both compares always run (computed before the test), each over
            // fixed-size digests: the timing says nothing about which one
            // failed or how long the real secret is.
            let userOK = ServerAuth.secretsEqual(user, configuration.username)
            let passwordOK = ServerAuth.secretsEqual(password, configuration.password)
            if userOK && passwordOK && !configuration.password.isEmpty && service == "ssh-connection" {
                isAuthenticated = true
                authenticatedUser = user
                try send([52])                      // USERAUTH_SUCCESS
                events.append(.authenticated)
                return
            }
            passwordFailures += 1
            events.append(.passwordRejected(user))
            if passwordFailures >= configuration.maximumPasswordAttempts {
                transport.disconnect(reason: .noMoreAuthMethodsAvailable, description: "too many authentication failures")
                throw ConnectionError.protocolError("too many authentication failures")
            }
            try sendAuthFailure()
            return
        }
        try sendAuthFailure()
    }

    private func sendAuthFailure() throws {
        var w = SSHWriter()
        w.writeByte(51)                             // USERAUTH_FAILURE
        w.writeNameList(["password"])
        w.writeBool(false)                          // no partial success
        try send(w.bytes)
    }

    private func mkServiceAccept() -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(SSHMessage.serviceAccept)
        w.writeString("ssh-userauth")
        return w.bytes
    }

    private func incomingOpen(_ r: inout SSHReader) throws {
        let type = try r.readUTF8()
        let sender = try r.readUInt32()
        let window = try r.readUInt32()
        let maxPacket = try r.readUInt32()
        guard type == "session",
              channels.values.count < configuration.maximumSessions else {
            var w = SSHWriter()
            w.writeByte(92)                         // OPEN_FAILURE
            w.writeUInt32(sender)
            w.writeUInt32(1)                        // administratively prohibited
            w.writeString("not supported")
            w.writeString("")
            try send(w.bytes)
            return
        }
        let channel = Channel(local: nextChannel)
        nextChannel &+= 1
        channel.remote = sender
        channel.remoteWindow = UInt64(window)
        channel.remoteMaxPacket = Int(min(maxPacket == 0 ? UInt32(Self.maxPacket) : maxPacket, Self.maximumRemotePacket))
        channel.open = true
        channels[channel.local] = channel
        var w = SSHWriter()
        w.writeByte(91)                             // OPEN_CONFIRMATION
        w.writeUInt32(sender)
        w.writeUInt32(channel.local)
        w.writeUInt32(UInt32(Self.windowSize))
        w.writeUInt32(UInt32(Self.maxPacket))
        try send(w.bytes)
        events.append(.channelOpened(channel.local))
    }

    private func channelRequest(_ r: inout SSHReader) throws {
        let channel = try known(try r.readUInt32())
        let name = try r.readUTF8()
        let wantReply = try r.readBool()
        switch name {
        case "subsystem":
            let subsystem = (try? r.readUTF8()) ?? ""
            channel.pendingReplies.append(wantReply)
            events.append(.channelRequest(channel.local, .subsystem(subsystem)))
        case "exec":
            let command = (try? r.readUTF8()) ?? ""
            channel.pendingReplies.append(wantReply)
            events.append(.channelRequest(channel.local, .exec(command)))
        default:
            if wantReply {
                var w = SSHWriter()
                w.writeByte(100)                    // CHANNEL_FAILURE
                w.writeUInt32(channel.remote)
                try send(w.bytes)
            }
            events.append(.channelRequest(channel.local, .refused(name)))
        }
    }

    // MARK: Outgoing surface

    /// Answers the oldest subsystem/exec request the owner received on this
    /// channel (sent only when the client asked for a reply).
    public func replyRequest(_ id: UInt32, success: Bool) {
        guard let channel = channels[id], !channel.pendingReplies.isEmpty else { return }
        guard channel.pendingReplies.removeFirst(), !channel.closeSent else { return }
        var w = SSHWriter()
        w.writeByte(success ? 99 : 100)             // CHANNEL_SUCCESS / FAILURE
        w.writeUInt32(channel.remote)
        try? send(w.bytes)
    }

    /// Bytes queued on the channel that the client's window has not let out.
    public func pendingOutput(_ id: UInt32) -> Int {
        channels[id]?.pendingCount ?? 0
    }

    /// True while the channel can still carry our data.
    public func isWritable(_ id: UInt32) -> Bool {
        guard let channel = channels[id] else { return false }
        return channel.open && !channel.eofPending && !channel.closeSent
    }

    /// Queues bytes for the channel; they go out as the client's window allows.
    public func write(_ id: UInt32, _ bytes: [UInt8]) throws {
        guard let channel = channels[id], channel.open else { return }
        guard !channel.eofPending, !channel.closeSent else { return }
        channel.outgoing.append(contentsOf: bytes)
        try flush(channel)
    }

    /// Sends the exec channel's exit status (the SCP handler reports 0/1).
    public func sendExitStatus(channel id: UInt32, code: Int32) {
        guard let channel = channels[id] else { return }
        var w = SSHWriter()
        w.writeByte(98)                             // CHANNEL_REQUEST
        w.writeUInt32(channel.remote)
        w.writeString("exit-status")
        w.writeBool(false)
        w.writeUInt32(UInt32(bitPattern: code))
        try? send(w.bytes)
    }

    public func sendEOF(_ id: UInt32) throws {
        guard let channel = channels[id] else { return }
        channel.eofPending = true
        try flush(channel)
    }

    /// Ends the channel from our side the way a finished subsystem does:
    /// EOF, then CLOSE — both only after every queued byte has gone out
    /// (`close` alone would drop output the client's window still holds
    /// back). The SFTP subsystem calls this when the client sends EOF:
    /// OpenSSH's `sftp` closes its write side on exit and then waits for
    /// the server's CLOSE, so ignoring the EOF left it hanging forever.
    public func finish(_ id: UInt32) throws {
        guard let channel = channels[id], !channel.closeSent else { return }
        channel.eofPending = true
        channel.closeAfterEOF = true
        try flush(channel)
    }

    public func close(_ id: UInt32) throws {
        guard let channel = channels[id] else { return }
        guard !channel.closeSent else { return }
        channel.closeSent = true
        try sendClose(channel)
        finishIfClosed(channel)
    }

    private func sendClose(_ channel: Channel) throws {
        var w = SSHWriter()
        w.writeByte(97)
        w.writeUInt32(channel.remote)
        try send(w.bytes)
    }

    private func flush(_ channel: Channel) throws {
        while channel.pendingCount > 0, channel.remoteWindow > 0, !channel.closeSent {
            let n = min(channel.pendingCount, channel.remoteMaxPacket, Int(min(channel.remoteWindow, UInt64(Int.max))))
            guard n > 0 else { break }
            var w = SSHWriter(capacity: n + 16)
            w.writeByte(94)                         // CHANNEL_DATA
            w.writeUInt32(channel.remote)
            w.writeString(channel.outgoing[channel.outgoingStart..<(channel.outgoingStart + n)])
            try send(w.bytes)
            channel.outgoingStart += n
            channel.remoteWindow -= UInt64(n)
        }
        if channel.pendingCount == 0 {
            channel.outgoing.removeAll(keepingCapacity: true)
            channel.outgoingStart = 0
        }
        if channel.eofPending, !channel.eofSent, channel.pendingCount == 0, !channel.closeSent {
            channel.eofSent = true
            var w = SSHWriter()
            w.writeByte(96)
            w.writeUInt32(channel.remote)
            try send(w.bytes)
        }
        if channel.closeAfterEOF, channel.eofSent, !channel.closeSent {
            channel.closeSent = true
            try sendClose(channel)
            finishIfClosed(channel)
        }
    }

    /// Tops the client's window back up once half of it has been used.
    private func replenish(_ channel: Channel) throws {
        guard channel.consumedSinceAdjust >= Self.windowSize / 2, !channel.closeSent else { return }
        let add = channel.consumedSinceAdjust
        channel.consumedSinceAdjust = 0
        channel.localWindow += add
        var w = SSHWriter()
        w.writeByte(93)                             // WINDOW_ADJUST
        w.writeUInt32(channel.remote)
        w.writeUInt32(UInt32(add))
        try send(w.bytes)
    }

    private func finishIfClosed(_ channel: Channel) {
        guard channel.closeSent, channel.closeReceived else { return }
        channels[channel.local] = nil
        events.append(.closed(channel.local))
    }

    private func known(_ id: UInt32) throws -> Channel {
        guard let channel = channels[id], channel.open else {
            throw ConnectionError.unknownChannel(id)
        }
        return channel
    }

    private func send(_ payload: [UInt8]) throws {
        try transport.send(payload)
    }
}
