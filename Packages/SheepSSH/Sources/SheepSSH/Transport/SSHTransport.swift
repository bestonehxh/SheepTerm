// The SSH transport layer (RFC 4253) as a sans-I/O state machine: the owner
// feeds it bytes read from the socket (`receive`), writes out whatever it
// queues (`takeOutgoing`), and reads what happened (`takeEvents`). It never
// touches a socket, a thread or a clock, so the same object runs inside
// SSHWorker's poll loop and inside a unit test that plays both ends.
//
// Not thread-safe: one transport is driven from one queue, like libssh's
// session was.
//
// Security properties it enforces:
//  - strict kex ("kex-strict-*-v00@openssh.com", the Terrapin fix): offered by
//    default; when the server also offers it, the server's KEXINIT must be
//    its first packet, nothing but kex messages is accepted until the first
//    NEWKEYS, and sequence numbers restart at 0 after every NEWKEYS;
//  - the host key is checked (signature over H, then the caller's
//    `hostKeyValidator`) before any NEWKEYS is sent; on rekey the server must
//    present the very same key;
//  - every packet is authenticated before its payload is looked at;
//  - rekey after `rekeyAfterBytes` in either direction.

public enum SSHTransportError: Error, Equatable, Sendable {
    case versionExchange(String)
    case protocolError(String)
    case negotiation(NegotiationError)
    case keyExchange(KexError)
    case signature(SignatureError)
    case packet(PacketError)
    /// The caller's validator refused the server's host key.
    case hostKeyRejected
    /// The server presented a different host key during a rekey.
    case hostKeyChangedDuringRekey
    /// The server sent SSH_MSG_DISCONNECT.
    case disconnectedByServer(reason: UInt32, description: String)
    /// `send` after the transport failed or was closed.
    case closed
}

public final class SSHTransport {
    public struct Configuration: Sendable {
        public var preferences: AlgorithmPreferences
        /// Without "SSH-2.0-" — e.g. "SheepSSH_1.0".
        public var softwareVersion: String
        public var strictKex: Bool
        /// Advertise ext-info-c so the server tells us which signature
        /// algorithms it accepts for user authentication (RFC 8308).
        public var extensionInfo: Bool
        public var rekeyAfterBytes: UInt64
        /// DH group exchange: acceptable modulus sizes and the size asked for.
        public var groupExchangeBits: ClosedRange<Int>
        public var groupExchangePreferred: Int
        /// Called once, during the first key exchange, after the server has
        /// proved it holds the key. Return false to refuse the connection.
        public var hostKeyValidator: @Sendable (SSHPublicKey) -> Bool

        public init(preferences: AlgorithmPreferences = .modern,
                    softwareVersion: String = "SheepSSH_1.0",
                    strictKex: Bool = true,
                    extensionInfo: Bool = true,
                    rekeyAfterBytes: UInt64 = 1 << 30,
                    groupExchangeBits: ClosedRange<Int> = 2048...8192,
                    groupExchangePreferred: Int = 4096,
                    hostKeyValidator: @escaping @Sendable (SSHPublicKey) -> Bool) {
            self.preferences = preferences
            self.softwareVersion = softwareVersion
            self.strictKex = strictKex
            self.extensionInfo = extensionInfo
            self.rekeyAfterBytes = rekeyAfterBytes
            self.groupExchangeBits = groupExchangeBits
            self.groupExchangePreferred = groupExchangePreferred
            self.hostKeyValidator = hostKeyValidator
        }
    }

    public enum Event: Sendable, Equatable {
        /// The first key exchange finished; `send` now reaches the server.
        case ready
        /// A key exchange (first or rekey) finished with these algorithms.
        case keysChanged(NegotiatedAlgorithms)
        /// A message for the layers above (userauth, connection).
        case message([UInt8])
    }

    private enum Phase {
        case versionExchange
        case running
        case failed
    }

    /// One key exchange in progress.
    private struct KexRound {
        var clientKexInit: KexInit
        var serverKexInit: KexInit?
        var negotiated: NegotiatedAlgorithms?
        var method: KexMethod?
        /// The server's first_kex_packet_follows guess was wrong: drop its
        /// next kex-method packet.
        var ignoreNextServerKexPacket = false
        var sentNewKeys = false
        var pendingInbound: DirectionKeys?
        var outcome: KexOutcome?
    }

    public let configuration: Configuration
    public let clientVersion: String
    public private(set) var serverVersion: String?
    public private(set) var negotiated: NegotiatedAlgorithms?
    /// H of the first key exchange (RFC 4253 §7.2); userauth signs over it.
    public private(set) var sessionID: [UInt8]?
    public private(set) var hostKey: SSHPublicKey?
    /// server-sig-algs from SSH_MSG_EXT_INFO, if the server sent it.
    public private(set) var serverSignatureAlgorithms: [String]?
    public private(set) var isStrictKex = false
    /// Whole packets received and authenticated so far. Liveness checks count
    /// these, not socket bytes: a stream that only feeds a discarded packet
    /// (below) proves nothing about the peer.
    public private(set) var packetsReceived: UInt64 = 0
    /// A non-ETM block cipher decrypted an impossible length and the
    /// transport is swallowing up to a maximum-size packet before failing it
    /// (CVE-2008-5161). Lets the owner name the cause if it times out first.
    public var isDiscardingCorruptPacket: Bool { inbound.discarding }
    public var isEstablished: Bool { sessionID != nil && kex == nil && phase == .running }

    private var phase = Phase.versionExchange
    private var inbound = PacketProtection()
    private var outbound = PacketProtection()
    private var inboundSequence: UInt32 = 0
    private var outboundSequence: UInt32 = 0
    private var buffer: [UInt8] = []
    private var bufferStart = 0
    private var outgoing: [UInt8] = []
    private var events: [Event] = []
    private var kex: KexRound?
    private var isFirstKex = true
    /// Application payloads queued while a key exchange runs.
    private var heldPayloads: [[UInt8]] = []
    /// Bytes in `heldPayloads`: the owner counts them as backlog, or a rekey
    /// the server never finishes would swallow input unseen and unbounded.
    public private(set) var heldPayloadBytes = 0
    /// The version line exactly as received: V_S in the exchange hash must
    /// be the server's bytes, not a lossy UTF-8 round trip of them.
    private(set) var serverVersionBytes: [UInt8] = []
    private var bytesSinceKex: UInt64 = 0
    private var versionBytesSeen = 0

    static let maximumVersionPreamble = 64 * 1024

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.clientVersion = "SSH-2.0-" + configuration.softwareVersion
    }

    // MARK: Driving

    /// Queues our version line and first KEXINIT. Call once.
    public func start() {
        outgoing.append(contentsOf: Array((clientVersion + "\r\n").utf8))
        beginKex()
    }

    public func takeOutgoing() -> [UInt8] {
        guard !outgoing.isEmpty else { return [] }
        let out = outgoing
        outgoing = []
        return out
    }

    /// Moves the sealed bytes into the owner's queue: one copy, and the
    /// buffer keeps its capacity for the next burst (no regrowth, and no
    /// copy-on-write reallocation since nothing else holds it).
    public func drainOutgoing(into queue: inout ByteQueue) {
        guard !outgoing.isEmpty else { return }
        queue.append(contentsOf: outgoing)
        outgoing.removeAll(keepingCapacity: true)
    }

    /// Sealed bytes not yet taken by the owner.
    public var outgoingByteCount: Int { outgoing.count }

    public func takeEvents() -> [Event] {
        defer { events.removeAll() }
        return events
    }

    /// Feeds bytes from the socket. Throws on anything that must end the
    /// connection; the transport is unusable afterwards.
    public func receive<C: Collection>(_ bytes: C) throws(SSHTransportError) where C.Element == UInt8 {
        guard phase != .failed else { throw .closed }
        buffer.append(contentsOf: bytes)
        do {
            try process()
        } catch {
            phase = .failed
            throw error
        }
        compactBuffer()
    }

    /// Sends a message payload (message byte first). Held back while a key
    /// exchange runs and released, in order, when it finishes.
    public func send(_ payload: [UInt8]) throws(SSHTransportError) {
        guard phase == .running, sessionID != nil else {
            if phase == .failed { throw .closed }
            throw .protocolError("send before the first key exchange finished")
        }
        if let kex, !kex.sentNewKeys {
            heldPayloads.append(payload)
            heldPayloadBytes += payload.count
            return
        }
        try sealAndQueue(payload)
        if kex == nil, bytesSinceKex >= configuration.rekeyAfterBytes { beginKex() }
    }

    /// Tests only (reachable through `@testable import`, never public): the
    /// state after the first key exchange with NO cipher installed, so the
    /// connection layer can be driven sans-I/O and what it sends read back
    /// as cleartext packets.
    func _testEnterRunningInTheClear() {
        phase = .running
        sessionID = [0]
    }

    /// Starts a key exchange now (no-op while one is running).
    public func requestRekey() {
        guard phase == .running, kex == nil, sessionID != nil else { return }
        beginKex()
    }

    /// Queues SSH_MSG_DISCONNECT. The owner should flush and close after.
    public func disconnect(reason: DisconnectReason = .byApplication, description: String = "") {
        guard phase != .failed else { return }
        var w = SSHWriter()
        w.writeByte(SSHMessage.disconnect)
        w.writeUInt32(reason.rawValue)
        w.writeString(description)
        w.writeString("")
        if phase == .running { try? sealAndQueue(w.bytes) }
        phase = .failed
    }

    // MARK: Buffer

    private var available: ArraySlice<UInt8> { buffer[bufferStart...] }

    private func consume(_ n: Int) { bufferStart += n }

    private func compactBuffer() {
        if bufferStart > 0, bufferStart >= buffer.count / 2 || bufferStart > 64 * 1024 {
            buffer.removeFirst(bufferStart)
            bufferStart = 0
        }
    }

    // MARK: Version exchange (RFC 4253 §4.2)

    private func process() throws(SSHTransportError) {
        if phase == .versionExchange {
            guard try readVersion() else { return }
        }
        while phase == .running {
            guard let size = try wrapPacket({ () throws(PacketError) in try inbound.packetSize(in: available, sequence: inboundSequence) }),
                  available.count >= size else { return }
            let packet = available.prefix(size)
            let payload = try wrapPacket({ () throws(PacketError) in try inbound.open(packet, sequence: inboundSequence) })
            consume(size)
            packetsReceived &+= 1
            let sequence = inboundSequence
            // A wrap during the first exchange would let 2³² injected
            // IGNOREs put KEXINIT back at sequence 0 for the strict-kex
            // check; OpenSSH refuses it too.
            if isFirstKex, inboundSequence == UInt32.max {
                throw .protocolError("sequence number wrapped during the initial key exchange")
            }
            inboundSequence &+= 1
            bytesSinceKex &+= UInt64(size)
            try handle(payload, sequence: sequence)
            // Mostly-download sessions (a terminal is one) must rekey too.
            if kex == nil, sessionID != nil, bytesSinceKex >= configuration.rekeyAfterBytes { beginKex() }
        }
    }

    private func wrapPacket<T>(_ body: () throws(PacketError) -> T) throws(SSHTransportError) -> T {
        do { return try body() } catch { throw .packet(error) }
    }

    /// Returns true once the server's version line has been read.
    private func readVersion() throws(SSHTransportError) -> Bool {
        while true {
            let slice = available
            guard let newline = slice.firstIndex(of: 0x0A) else {
                if slice.count > 8192 { throw .versionExchange("no version line within 8 KiB") }
                return false
            }
            var line = Array(slice[slice.startIndex..<newline])
            if line.last == 0x0D { line.removeLast() }
            let length = newline - slice.startIndex + 1
            consume(length)
            versionBytesSeen += length
            // Lines before the version line are allowed (a banner); only
            // "SSH-" starts the real one.
            guard line.starts(with: Array("SSH-".utf8)) else {
                if versionBytesSeen > Self.maximumVersionPreamble {
                    throw .versionExchange("server sent more than 64 KiB before its version line")
                }
                continue
            }
            let text = String(decoding: line, as: UTF8.self)
            guard text.hasPrefix("SSH-2.0-") || text.hasPrefix("SSH-1.99-") else {
                throw .versionExchange("server speaks \(text), not SSH-2.0")
            }
            serverVersion = text
            serverVersionBytes = line
            phase = .running
            return true
        }
    }

    // MARK: Packets in

    private func handle(_ payload: [UInt8], sequence: UInt32) throws(SSHTransportError) {
        guard let type = payload.first else { throw .protocolError("empty packet") }

        // Strict kex, first exchange: only kex messages (and DISCONNECT).
        if isStrictKex, isFirstKex, kex != nil, !SSHMessage.isKexMessage(type), type != SSHMessage.disconnect {
            throw .protocolError("strict key exchange: unexpected message \(type) before NEWKEYS")
        }

        switch type {
        case SSHMessage.disconnect:
            var r = SSHReader(payload, from: 1)
            let reason = (try? r.readUInt32()) ?? 0
            let description = (try? r.readText()) ?? ""
            throw .disconnectedByServer(reason: reason, description: description)
        case SSHMessage.ignore, SSHMessage.debug, SSHMessage.unimplemented:
            return
        case SSHMessage.kexInit:
            try receiveKexInit(payload, sequence: sequence)
        case SSHMessage.newKeys:
            try receiveNewKeys()
        case 30...49:
            try receiveKexMessage(payload)
        case SSHMessage.extInfo:
            // RFC 8308: only after the server's first NEWKEYS. Earlier it
            // would be cleartext an attacker could inject (without strict
            // kex nothing else refuses it) to steer server-sig-algs. Ignored,
            // as OpenSSH does (its handler is only installed after NEWKEYS).
            guard negotiated != nil else { return }
            parseExtInfo(payload)
        default:
            // `negotiated`, not `sessionID`: the session id exists once WE
            // sent NEWKEYS, but until the server's NEWKEYS arrives inbound
            // packets are cleartext — without strict kex an attacker could
            // slip a SERVICE_ACCEPT or USERAUTH reply in there.
            guard negotiated != nil else {
                throw .protocolError("message \(type) before the first key exchange finished")
            }
            events.append(.message(payload))
        }
    }

    private func parseExtInfo(_ payload: [UInt8]) {
        var r = SSHReader(payload, from: 1)
        guard let count = try? r.readUInt32() else { return }
        for _ in 0..<min(count, 1024) {
            guard let name = try? r.readUTF8(), let value = try? r.readString() else { return }
            if name == "server-sig-algs" {
                serverSignatureAlgorithms = String(decoding: value, as: UTF8.self).split(separator: ",").map(String.init)
            }
        }
    }

    // MARK: Key exchange

    private func beginKex() {
        var cookie = [UInt8](repeating: 0, count: 16)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<16 { cookie[i] = UInt8.random(in: 0...255, using: &rng) }
        let prefs = configuration.preferences.available
        var kexNames = prefs.kex.map(\.rawValue)
        // The pseudo-algorithms only go in the first KEXINIT (ext-info-c and
        // the strict-kex marker are defined for the initial exchange).
        if isFirstKex {
            if configuration.extensionInfo { kexNames.append(KexExtension.extInfoClient) }
            if configuration.strictKex { kexNames.append(KexExtension.strictClient) }
        }
        let kexInit = KexInit(cookie: cookie, kexAlgorithms: kexNames,
                              hostKeyAlgorithms: prefs.hostKeys.map(\.rawValue),
                              ciphers: prefs.ciphers.map(\.rawValue), macs: prefs.macs.map(\.rawValue))
        kex = KexRound(clientKexInit: kexInit)
        // Sealing can only fail inside a cipher, and a failure there fails
        // every later packet too — the next send reports it.
        try? sealAndQueue(kexInit.payload)
    }

    private func receiveKexInit(_ payload: [UInt8], sequence: UInt32) throws(SSHTransportError) {
        let serverInit: KexInit
        do { serverInit = try KexInit(payload: payload) } catch { throw .protocolError("malformed KEXINIT") }
        if kex == nil { beginKex() }            // server-initiated rekey
        guard var round = kex, round.serverKexInit == nil else {
            throw .protocolError("second KEXINIT during one key exchange")
        }
        if isFirstKex, configuration.strictKex, serverInit.kexAlgorithms.contains(KexExtension.strictServer) {
            isStrictKex = true
            // Terrapin: anything the server "sent" before KEXINIT would have
            // shifted the sequence number.
            guard sequence == 0 else { throw .protocolError("strict key exchange: KEXINIT was not the server's first packet") }
        }
        round.serverKexInit = serverInit
        let chosen: NegotiatedAlgorithms
        do {
            chosen = try Negotiation.negotiate(client: configuration.preferences.available, server: serverInit)
        } catch {
            throw .negotiation(error)
        }
        round.negotiated = chosen
        // RFC 4253 §7: a wrong guess means the server's next kex packet is
        // discarded. The guess is right only if both its first kex and first
        // host key algorithm are what negotiation chose.
        if serverInit.firstKexPacketFollows,
           serverInit.kexAlgorithms.first != chosen.kex.rawValue || serverInit.hostKeyAlgorithms.first != chosen.hostKey.rawValue {
            round.ignoreNextServerKexPacket = true
        }
        let prefix = ExchangeHashPrefix(clientVersion: clientVersion, serverVersion: serverVersionBytes,
                                        clientKexInit: round.clientKexInit.payload, serverKexInit: serverInit.payload)
        let method = KexFactory.make(chosen.kex, prefix: prefix,
                                     exponentBits: KeyDerivation.dhExponentBits(for: chosen),
                                     gexBits: configuration.groupExchangeBits,
                                     gexPreferred: configuration.groupExchangePreferred)
        round.method = method
        kex = round
        do {
            try sealAndQueue(try method.start())
        } catch let error as SSHTransportError {
            throw error
        } catch let error as KexError {
            throw .keyExchange(error)
        } catch {
            throw .protocolError("key exchange start failed")
        }
    }

    private func receiveKexMessage(_ payload: [UInt8]) throws(SSHTransportError) {
        guard var round = kex, let method = round.method, round.outcome == nil else {
            throw .protocolError("key exchange message \(payload[0]) outside a key exchange")
        }
        if round.ignoreNextServerKexPacket {
            round.ignoreNextServerKexPacket = false
            kex = round
            return
        }
        let step: KexStep
        do { step = try method.handle(payload) } catch { throw .keyExchange(error) }
        switch step {
        case .send(let message):
            try sealAndQueue(message)
        case .done(let outcome):
            round.outcome = outcome
            kex = round
            try finishKex(outcome)
        }
    }

    private func finishKex(_ outcome: KexOutcome) throws(SSHTransportError) {
        guard var round = kex, let chosen = round.negotiated else { throw .protocolError("kex state lost") }
        let key: SSHPublicKey
        do { key = try SSHPublicKey(blob: outcome.hostKeyBlob) } catch {
            throw .signature(.malformed("server host key: \(error)"))
        }
        do {
            try SignatureVerifier.verify(signatureBlob: outcome.signatureBlob, data: outcome.exchangeHash,
                                         key: key, algorithm: chosen.hostKey)
        } catch {
            throw .signature(error)
        }
        if let known = hostKey {
            guard known.blob == key.blob else { throw .hostKeyChangedDuringRekey }
        } else {
            guard configuration.hostKeyValidator(key) else { throw .hostKeyRejected }
            hostKey = key
        }
        let session = sessionID ?? outcome.exchangeHash
        let keys = KeyDerivation.keys(for: chosen, hash: chosen.kex.hash, encodedSecret: outcome.encodedSecret,
                                      exchangeHash: outcome.exchangeHash, sessionID: session)
        sessionID = session
        // NEWKEYS goes out under the old keys; everything after under the new.
        try sealAndQueue([SSHMessage.newKeys])
        do {
            outbound = try PacketProtection(keys: keys.clientToServer, encrypting: true)
        } catch {
            throw .packet(error)
        }
        if isStrictKex { outboundSequence = 0 }
        round.sentNewKeys = true
        round.pendingInbound = keys.serverToClient
        kex = round
        // Messages held during the exchange may go now.
        let held = heldPayloads
        heldPayloads.removeAll()
        heldPayloadBytes = 0
        for payload in held { try sealAndQueue(payload) }
    }

    private func receiveNewKeys() throws(SSHTransportError) {
        guard let round = kex, let keys = round.pendingInbound, let chosen = round.negotiated else {
            throw .protocolError("NEWKEYS before the key exchange finished")
        }
        do {
            inbound = try PacketProtection(keys: keys, encrypting: false)
        } catch {
            throw .packet(error)
        }
        if isStrictKex { inboundSequence = 0 }
        negotiated = chosen
        kex = nil
        bytesSinceKex = 0
        events.append(.keysChanged(chosen))
        if isFirstKex {
            isFirstKex = false
            events.append(.ready)
        }
    }

    // MARK: Packets out

    private func sealAndQueue(_ payload: [UInt8]) throws(SSHTransportError) {
        let sealed = try wrapPacket({ () throws(PacketError) in try outbound.seal(payload: payload, sequence: outboundSequence) })
        outboundSequence &+= 1
        bytesSinceKex &+= UInt64(sealed.count)
        outgoing.append(contentsOf: sealed)
    }
}
