// The connection protocol (RFC 4254), sans-I/O on top of SSHTransport, for
// what SheepTerm needs: one interactive session channel (pty + shell or
// exec), window changes, EOF/close, exit status, keepalive global requests,
// and forwarded ssh-agent channels opened by the server.
//
// Flow control: we advertise a window and top it up as data arrives (the
// app consumes immediately — back-pressure lives above, in SSHWorker's
// bounded queues). Outgoing data waits in a per-channel buffer until the
// server's window allows it and is cut into packets no larger than the
// server's maximum.

public enum ConnectionError: Error, Equatable, Sendable {
    case protocolError(String)
    case unknownChannel(UInt32)
    case transport(SSHTransportError)
}

public final class SSHConnection {
    public enum Event: Sendable, Equatable {
        case channelOpened(UInt32)
        case channelOpenFailed(UInt32, reason: UInt32, description: String)
        /// Answer to a want-reply channel request (pty-req, shell, exec, auth-agent-req).
        case channelRequestReply(UInt32, request: String, success: Bool)
        case data(UInt32, [UInt8])
        /// SSH_MSG_CHANNEL_EXTENDED_DATA type 1 (stderr).
        case extendedData(UInt32, [UInt8])
        case eof(UInt32)
        /// Both sides have sent CLOSE; the channel number is free.
        case closed(UInt32)
        case exitStatus(UInt32, UInt32)
        case exitSignal(UInt32, signal: String, message: String)
        /// Answer to our global request (keepalive), in order.
        case globalReply(success: Bool)
        /// The server opened an auth-agent@openssh.com channel and we accepted it.
        case agentChannelOpened(UInt32)
    }

    enum Kind { case session, agent }

    final class Channel {
        let local: UInt32
        let kind: Kind
        var remote: UInt32 = 0
        var open = false
        var remoteWindow: UInt64 = 0
        var remoteMaxPacket = 0
        var localWindow: UInt64
        var consumedSinceAdjust: UInt64 = 0
        var outgoing: [UInt8] = []
        /// Bytes of `outgoing` already sent (compacted lazily — removing the
        /// front per 32 KiB packet made a big paste quadratic).
        var outgoingStart = 0
        var pendingCount: Int { outgoing.count - outgoingStart }
        /// Channel data handed to the transport, ever.
        var dataSent: UInt64 = 0
        var eofPending = false
        var eofSent = false
        var eofReceived = false
        var closeSent = false
        var closeReceived = false
        /// Requests that asked for a reply, oldest first.
        var pendingReplies: [String] = []

        init(local: UInt32, kind: Kind, window: UInt64) {
            self.local = local
            self.kind = kind
            self.localWindow = window
        }
    }

    /// 2 MiB window, 32 KiB packets — OpenSSH's own client values.
    public static let windowSize: UInt64 = 2 * 1024 * 1024
    public static let maxPacket = 32 * 1024

    public let transport: SSHTransport
    /// Accept the server's auth-agent@openssh.com channels. Set only when the
    /// user asked for agent forwarding and we sent auth-agent-req.
    public var acceptAgentChannels = false
    /// The most channel data we put in one packet, whatever the server
    /// advertises: header, padding and MAC must still fit the 256 KiB packet
    /// limit (ours, and OpenSSH's PACKET_MAX_SIZE).
    static let maximumRemotePacket = PacketProtection.maximumPacketLength - 1024
    /// Agent channels at once, closed-but-unconfirmed included.
    public static let maximumAgentChannels = 64
    private var channels: [UInt32: Channel] = [:]
    private var nextChannel: UInt32 = 0
    private var events: [Event] = []

    public init(transport: SSHTransport) {
        self.transport = transport
    }

    public func takeEvents() -> [Event] {
        defer { events.removeAll() }
        return events
    }

    // MARK: Opening

    /// Opens a "session" channel; `.channelOpened(id)` follows.
    public func openSession() throws(ConnectionError) -> UInt32 {
        let channel = allocate(.session)
        var w = SSHWriter()
        w.writeByte(90)                         // CHANNEL_OPEN
        w.writeString("session")
        w.writeUInt32(channel.local)
        w.writeUInt32(UInt32(Self.windowSize))
        w.writeUInt32(UInt32(Self.maxPacket))
        try send(w.bytes)
        return channel.local
    }

    private func allocate(_ kind: Kind) -> Channel {
        while channels[nextChannel] != nil { nextChannel &+= 1 }
        let channel = Channel(local: nextChannel, kind: kind, window: Self.windowSize)
        channels[nextChannel] = channel
        nextChannel &+= 1
        return channel
    }

    // MARK: Channel requests

    private func request(_ id: UInt32, _ name: String, wantReply: Bool, _ body: (inout SSHWriter) -> Void = { _ in })
    throws(ConnectionError) {
        let channel = try openChannel(id)
        var w = SSHWriter()
        w.writeByte(98)                         // CHANNEL_REQUEST
        w.writeUInt32(channel.remote)
        w.writeString(name)
        w.writeBool(wantReply)
        body(&w)
        if wantReply { channel.pendingReplies.append(name) }
        try send(w.bytes)
    }

    /// pty-req. `modes` is the encoded terminal-modes string; the default is
    /// empty (just TTY_OP_END) — the server's defaults, which is what network
    /// gear expects.
    public func requestPTY(_ id: UInt32, term: String = "xterm-256color", columns: Int, rows: Int,
                           modes: [UInt8] = [0]) throws(ConnectionError) {
        try request(id, "pty-req", wantReply: true) { w in
            w.writeString(term)
            w.writeUInt32(UInt32(clamping: columns))
            w.writeUInt32(UInt32(clamping: rows))
            w.writeUInt32(0)
            w.writeUInt32(0)
            w.writeString(modes)
        }
    }

    public func requestShell(_ id: UInt32) throws(ConnectionError) {
        try request(id, "shell", wantReply: true)
    }

    public func requestExec(_ id: UInt32, command: String) throws(ConnectionError) {
        try request(id, "exec", wantReply: true) { $0.writeString(command) }
    }

    /// auth-agent-req@openssh.com, without asking for a reply — as OpenSSH
    /// and libssh send it: some devices never answer an unknown request,
    /// and waiting for one stalled the session. (A device that answers it
    /// anyway would have that reply matched to the next request awaiting
    /// one — OpenSSH's per-channel reply queue has the same exposure.)
    /// Also sets `acceptAgentChannels`.
    public func requestAgentForwarding(_ id: UInt32) throws(ConnectionError) {
        acceptAgentChannels = true
        try request(id, "auth-agent-req@openssh.com", wantReply: false)
    }

    /// window-change (no reply, per RFC 4254 §6.7).
    public func windowChange(_ id: UInt32, columns: Int, rows: Int) throws(ConnectionError) {
        try request(id, "window-change", wantReply: false) { w in
            w.writeUInt32(UInt32(clamping: columns))
            w.writeUInt32(UInt32(clamping: rows))
            w.writeUInt32(0)
            w.writeUInt32(0)
        }
    }

    /// keepalive@openssh.com with want-reply: a live server must answer
    /// (with REQUEST_FAILURE, since it does not know the name) — the answer
    /// is what proves the peer is there. Replies arrive as `.globalReply`.
    public func sendKeepalive() throws(ConnectionError) {
        var w = SSHWriter()
        w.writeByte(80)                         // GLOBAL_REQUEST
        w.writeString("keepalive@openssh.com")
        w.writeBool(true)
        try send(w.bytes)
    }

    // MARK: Data

    /// Queues bytes for the channel; they go out as the server's window allows.
    public func write(_ id: UInt32, _ bytes: [UInt8]) throws(ConnectionError) {
        let channel = try openChannel(id)
        guard !channel.eofPending, !channel.closeSent else { return }
        channel.outgoing.append(contentsOf: bytes)
        try flush(channel)
    }

    /// Bytes queued but not yet sent (waiting for window).
    public func pendingOutput(_ id: UInt32) -> Int {
        channels[id]?.pendingCount ?? 0
    }

    /// Channel data bytes sent on `id` so far (progress through the
    /// server's window, as opposed to keepalives and other traffic).
    public func dataSent(_ id: UInt32) -> UInt64 {
        channels[id]?.dataSent ?? 0
    }

    /// EOF after whatever is still queued.
    public func sendEOF(_ id: UInt32) throws(ConnectionError) {
        let channel = try openChannel(id)
        channel.eofPending = true
        try flush(channel)
    }

    public func close(_ id: UInt32) throws(ConnectionError) {
        guard let channel = channels[id] else { throw .unknownChannel(id) }
        guard !channel.closeSent else { return }
        if !channel.open {
            // Still awaiting OPEN_CONFIRMATION: CLOSE for an unconfirmed
            // channel is legal (RFC 4254 §5.3 — a recipient must accept it
            // for any channel it knows; OpenSSH does exactly this), and the
            // old behaviour — silently returning with nothing recorded —
            // meant the confirmation brought the channel ALIVE with no CLOSE
            // ever sent: the server-side session stayed open and the local
            // entry was never freed. Record it and let `case 91` finish the
            // close when the answer arrives (or `case 92`, which frees it and
            // reports `.closed`, not an open failure nobody asked about).
            channel.closeSent = true
            finishIfClosed(channel)
            return
        }
        channel.closeSent = true
        var w = SSHWriter()
        w.writeByte(97)                         // CHANNEL_CLOSE
        w.writeUInt32(channel.remote)
        try send(w.bytes)
        finishIfClosed(channel)
    }

    public func isOpen(_ id: UInt32) -> Bool { channels[id]?.open == true && channels[id]?.closeSent == false }

    private func flush(_ channel: Channel) throws(ConnectionError) {
        while channel.pendingCount > 0, channel.remoteWindow > 0, !channel.closeSent {
            let n = min(channel.pendingCount, channel.remoteMaxPacket, Int(min(channel.remoteWindow, UInt64(Int.max))))
            guard n > 0 else { break }
            var w = SSHWriter(capacity: n + 16)
            w.writeByte(94)                     // CHANNEL_DATA
            w.writeUInt32(channel.remote)
            w.writeString(channel.outgoing[channel.outgoingStart..<(channel.outgoingStart + n)])
            try send(w.bytes)
            channel.outgoingStart += n
            channel.dataSent &+= UInt64(n)
            channel.remoteWindow -= UInt64(n)
        }
        if channel.pendingCount == 0 {
            channel.outgoing.removeAll(keepingCapacity: true)
            channel.outgoingStart = 0
        } else if channel.outgoingStart >= 1 << 20 {
            channel.outgoing.removeFirst(channel.outgoingStart)
            channel.outgoingStart = 0
        }
        if channel.eofPending, !channel.eofSent, channel.pendingCount == 0, !channel.closeSent {
            channel.eofSent = true
            var w = SSHWriter()
            w.writeByte(96)                     // CHANNEL_EOF
            w.writeUInt32(channel.remote)
            try send(w.bytes)
        }
    }

    private func openChannel(_ id: UInt32) throws(ConnectionError) -> Channel {
        guard let channel = channels[id], channel.open else { throw .unknownChannel(id) }
        return channel
    }

    private func send(_ payload: [UInt8]) throws(ConnectionError) {
        do { try transport.send(payload) } catch { throw .transport(error) }
    }

    // MARK: Incoming

    /// Feed every transport `.message` after authentication.
    public func handle(_ payload: [UInt8]) throws(ConnectionError) {
        guard let type = payload.first else { throw .protocolError("empty message") }
        var r = SSHReader(payload, from: 1)
        do {
            switch type {
            case 80:                            // GLOBAL_REQUEST from the server
                _ = try r.readString()
                if try r.readBool() { try send([82]) }  // REQUEST_FAILURE: we offer nothing
            case 81, 82:
                events.append(.globalReply(success: type == 81))
            case 90:
                try incomingOpen(&r)
            case 91:                            // OPEN_CONFIRMATION
                let channel = try pending(try r.readUInt32())
                channel.remote = try r.readUInt32()
                channel.remoteWindow = UInt64(try r.readUInt32())
                // 0 (left unset by some embedded servers): neither OpenSSH
                // nor libssh checks it; use our own packet size.
                let advertised = try r.readUInt32()
                channel.remoteMaxPacket = Int(min(advertised == 0 ? UInt32(Self.maxPacket) : advertised, Self.maximumRemotePacket))
                channel.open = true
                if channel.closeSent {
                    // close() arrived while the open was in flight: the
                    // channel is dead on arrival — answer the confirmation
                    // with the CLOSE it is owed and never surface
                    // `.channelOpened` for a session nobody wants.
                    var w = SSHWriter()
                    w.writeByte(97)             // CHANNEL_CLOSE
                    w.writeUInt32(channel.remote)
                    try send(w.bytes)
                    finishIfClosed(channel)
                    return
                }
                events.append(.channelOpened(channel.local))
                try flush(channel)
            case 92:                            // OPEN_FAILURE
                let channel = try pending(try r.readUInt32())
                let reason = try r.readUInt32()
                let description = (try? r.readText()) ?? ""
                channels[channel.local] = nil
                // A channel the caller already closed while the open was in
                // flight: the refusal is just how that close completes — the
                // number is free, and nobody is waiting to hear why the open
                // failed. Report it as the `.closed` close() promised.
                events.append(channel.closeSent
                              ? .closed(channel.local)
                              : .channelOpenFailed(channel.local, reason: reason, description: description))
            case 93:                            // WINDOW_ADJUST
                let channel = try known(try r.readUInt32())
                let add = UInt64(try r.readUInt32())
                // RFC 4254 §5.2: the window may not exceed 2³² − 1.
                channel.remoteWindow = min(channel.remoteWindow + add, UInt64(UInt32.max))
                try flush(channel)
            case 94, 95:                        // DATA / EXTENDED_DATA
                let channel = try known(try r.readUInt32())
                let dataType: UInt32 = type == 95 ? try r.readUInt32() : 0
                let data = try r.readString()
                // Past the window: some embedded servers count it wrong. Like
                // libssh, take the data and clamp the window to 0 rather than
                // end a long `show tech` halfway (the top-up follows use).
                // Count only what was inside the window, or each top-up would
                // add back overrun bytes never taken off and the window drift up.
                let taken = min(UInt64(data.count), channel.localWindow)
                channel.localWindow -= taken
                channel.consumedSinceAdjust += taken
                if type == 94 {
                    events.append(.data(channel.local, data))
                } else if dataType == 1 {
                    events.append(.extendedData(channel.local, data))
                }
                try replenish(channel)
            case 96:
                let channel = try known(try r.readUInt32())
                channel.eofReceived = true
                events.append(.eof(channel.local))
            case 97:
                let channel = try known(try r.readUInt32())
                channel.closeReceived = true
                if !channel.closeSent {
                    channel.closeSent = true
                    var w = SSHWriter()
                    w.writeByte(97)
                    w.writeUInt32(channel.remote)
                    try send(w.bytes)
                }
                finishIfClosed(channel)
            case 98:                            // CHANNEL_REQUEST from the server
                let channel = try known(try r.readUInt32())
                let name = try r.readUTF8()
                let wantReply = try r.readBool()
                switch name {
                // A body not in RFC 4254's layout (old servers send a signal
                // NUMBER) is ignored, as libssh does — it must not turn a
                // normal `exit` into a failed session.
                case "exit-status":
                    if let status = try? r.readUInt32() { events.append(.exitStatus(channel.local, status)) }
                case "exit-signal":
                    if let signal = try? r.readText(), (try? r.readBool()) != nil {
                        let message = (try? r.readText()) ?? ""
                        events.append(.exitSignal(channel.local, signal: signal, message: message))
                    }
                default:
                    break
                }
                // RFC 4254 §5.3: nothing more on a channel after our CLOSE.
                if wantReply, !channel.closeSent {
                    var w = SSHWriter()
                    w.writeByte(100)            // CHANNEL_FAILURE
                    w.writeUInt32(channel.remote)
                    try send(w.bytes)
                }
            case 99, 100:                       // CHANNEL_SUCCESS / FAILURE
                let channel = try known(try r.readUInt32())
                // A reply nobody asked for (some devices answer a
                // window-change) is ignored, as OpenSSH and libssh do —
                // ending the session over it dropped the tab on a resize.
                guard !channel.pendingReplies.isEmpty else { break }
                let name = channel.pendingReplies.removeFirst()
                events.append(.channelRequestReply(channel.local, request: name, success: type == 99))
            default:
                // Nothing else is expected on a client connection; ignoring
                // it matches what libssh did with stray messages.
                break
            }
        } catch let error as ConnectionError {
            throw error
        } catch {
            throw .protocolError("malformed connection message \(type)")
        }
    }

    private func incomingOpen(_ r: inout SSHReader) throws {
        let type = try r.readUTF8()
        let sender = try r.readUInt32()
        let window = try r.readUInt32()
        let maxPacket = try r.readUInt32()
        // Agent channels live here until the far end confirms our CLOSE; a
        // server opening them and never confirming must not grow this
        // table without bound (the forwarder caps its fds separately).
        guard type == "auth-agent@openssh.com", acceptAgentChannels,
              channels.values.lazy.filter({ $0.kind == .agent }).count < Self.maximumAgentChannels else {
            // Everything else (x11, forwarded-tcpip, agent when not asked):
            // administratively prohibited.
            var w = SSHWriter()
            w.writeByte(92)
            w.writeUInt32(sender)
            w.writeUInt32(1)
            w.writeString("not supported")
            w.writeString("")
            try send(w.bytes)
            return
        }
        let channel = allocate(.agent)
        channel.remote = sender
        channel.remoteWindow = UInt64(window)
        channel.remoteMaxPacket = Int(min(maxPacket == 0 ? UInt32(Self.maxPacket) : maxPacket, Self.maximumRemotePacket))
        channel.open = true
        var w = SSHWriter()
        w.writeByte(91)
        w.writeUInt32(sender)
        w.writeUInt32(channel.local)
        w.writeUInt32(UInt32(Self.windowSize))
        w.writeUInt32(UInt32(Self.maxPacket))
        try send(w.bytes)
        events.append(.agentChannelOpened(channel.local))
    }

    /// Tops the local window back up once half of it has been used.
    private func replenish(_ channel: Channel) throws(ConnectionError) {
        guard channel.consumedSinceAdjust >= Self.windowSize / 2, !channel.closeSent else { return }
        let add = channel.consumedSinceAdjust
        channel.consumedSinceAdjust = 0
        channel.localWindow += add
        var w = SSHWriter()
        w.writeByte(93)
        w.writeUInt32(channel.remote)
        w.writeUInt32(UInt32(add))
        try send(w.bytes)
    }

    private func pending(_ id: UInt32) throws -> Channel {
        guard let channel = channels[id], !channel.open else { throw ConnectionError.unknownChannel(id) }
        return channel
    }

    private func known(_ id: UInt32) throws -> Channel {
        guard let channel = channels[id], channel.open else { throw ConnectionError.unknownChannel(id) }
        return channel
    }

    private func finishIfClosed(_ channel: Channel) {
        guard channel.closeSent, channel.closeReceived else { return }
        channels[channel.local] = nil
        events.append(.closed(channel.local))
    }
}
