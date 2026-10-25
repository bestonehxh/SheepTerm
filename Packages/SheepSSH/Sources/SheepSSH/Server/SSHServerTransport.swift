// The SSH transport layer, SERVER role (RFC 4253) — a sans-I/O state machine
// mirroring SSHTransport: the owner feeds socket bytes to `receive`, drains
// `takeOutgoing`, and reads `takeEvents`. Differences from the client role:
//
//  - the server speaks its version line and first KEXINIT first;
//  - negotiation follows the CLIENT's preference order (RFC 4253 §7.1);
//  - the server SIGNS the exchange hash with its host key instead of
//    verifying (a rekey must present the same key);
//  - key derivation directions are swapped: outbound = server→client.
//
// Group exchange is deliberately not offered: a server role needs a moduli
// source for it, and every client that speaks only GEX also speaks
// curve25519 or fixed groups.
//
// Ported from SheepDrop (its built-in SFTP/SCP server, proven against real
// Aruba gear). Changes for SheepTerm's File Server: the KEXINIT offers only
// what this server can really run (kex methods with a server half, host-key
// algorithms a configured key signs) — an offer the server could not honour
// ended the handshake after negotiation instead of during it; V_C goes into
// H as the received bytes; the DH exponent is sized like the client's.
import Foundation

extension AlgorithmPreferences {
    /// The server role's offer: modern first so a current client is never
    /// downgraded, then the legacy entries old switches need (DH group1 /
    /// group14-sha1, CBC, 3DES, hmac-sha1/md5, ssh-rsa). The client's order
    /// picks among them (RFC 4253 §7.1).
    public static let server = AlgorithmPreferences(
        kex: [.curve25519, .curve25519LibSSH, .ecdhP256, .ecdhP384, .ecdhP521,
              .dhGroup14SHA256, .dhGroup14SHA1, .dhGroup1],
        hostKeys: [.ed25519, .rsaSHA512, .rsaSHA256, .rsaSHA1],
        ciphers: [.chacha20Poly1305, .aes256GCM, .aes128GCM, .aes256CTR, .aes192CTR, .aes128CTR,
                  .aes256CBC, .aes192CBC, .aes128CBC, .tripleDESCBC],
        macs: [.hmacSHA256ETM, .hmacSHA512ETM, .hmacSHA1ETM, .hmacSHA256, .hmacSHA512, .hmacSHA1, .hmacMD5])
}

public final class SSHServerTransport {
    /// Not Sendable: SSHSigner (an agent identity, say) makes no promise. The
    /// transport lives on its owner's queue, like libssh's session did.
    public struct Configuration {
        public var preferences: AlgorithmPreferences
        /// Without "SSH-2.0-".
        public var softwareVersion: String
        public var strictKex: Bool
        public var rekeyAfterBytes: UInt64
        /// One signer per host key type offered, in KEXINIT order. An
        /// ed25519 key covers "ssh-ed25519"; an RSA key covers
        /// "ssh-rsa", "rsa-sha2-256" and "rsa-sha2-512".
        public var hostKeys: [SSHSigner]
        /// Sent before the version line completes (none by default).
        public var banner: String?

        public init(preferences: AlgorithmPreferences = .server,
                    softwareVersion: String = "SheepSSH_1.0",
                    strictKex: Bool = true,
                    rekeyAfterBytes: UInt64 = 1 << 30,
                    hostKeys: [SSHSigner],
                    banner: String? = nil) {
            self.preferences = preferences
            self.softwareVersion = softwareVersion
            self.strictKex = strictKex
            self.rekeyAfterBytes = rekeyAfterBytes
            self.hostKeys = hostKeys
            self.banner = banner
        }
    }

    public enum Event: Sendable, Equatable {
        /// The first key exchange finished; `send` now reaches the client.
        case ready
        case keysChanged(NegotiatedAlgorithms)
        /// A message for the layers above (service, userauth, connection).
        case message([UInt8])
    }

    private enum Phase {
        case versionExchange
        case running
        case failed
    }

    private struct KexRound {
        var serverKexInit: KexInit
        var clientKexInit: KexInit?
        var negotiated: NegotiatedAlgorithms?
        var method: ServerKexMethod?
        /// The client's first_kex_packet_follows guess was wrong: drop its
        /// next kex-method packet.
        var ignoreNextClientKexPacket = false
        var sentNewKeys = false
        var pendingInbound: DirectionKeys?
        var outcome: KexOutcome?
    }

    public let configuration: Configuration
    public let serverVersion: String
    public private(set) var clientVersion: String?
    public private(set) var negotiated: NegotiatedAlgorithms?
    /// H of the first key exchange.
    public private(set) var sessionID: [UInt8]?
    public private(set) var isStrictKex = false
    public private(set) var packetsReceived: UInt64 = 0
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
    private var heldPayloads: [[UInt8]] = []
    public private(set) var heldPayloadBytes = 0
    /// The client's version line exactly as received (V_C in the hash).
    private(set) var clientVersionBytes: [UInt8] = []
    private var versionBytesSeen = 0
    private var bytesSinceKex: UInt64 = 0

    static let maximumVersionPreamble = 64 * 1024

    /// What KEXINIT actually offers: `preferences` minus what this build
    /// cannot run, kex methods without a server half, and host-key
    /// algorithms no configured key signs.
    public let offer: AlgorithmPreferences

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.serverVersion = "SSH-2.0-" + configuration.softwareVersion
        let available = configuration.preferences.available
        let keyTypes = Set(configuration.hostKeys.map(\.publicKey.keyType))
        self.offer = AlgorithmPreferences(
            kex: available.kex.filter { ServerKexFactory.supported.contains($0) },
            hostKeys: available.hostKeys.filter { keyTypes.contains($0.keyType) && Self.signs($0) },
            ciphers: available.ciphers, macs: available.macs)
    }

    /// Host-key algorithms the server role can sign with (ed25519, RSA).
    private static func signs(_ algorithm: HostKeyAlgorithm) -> Bool {
        switch algorithm {
        case .ed25519, .rsaSHA512, .rsaSHA256, .rsaSHA1: return true
        default: return false
        }
    }

    // MARK: Driving

    /// Queues our (optional banner,) version line and first KEXINIT. Call once.
    public func start() {
        if let banner = configuration.banner {
            for line in banner.split(separator: "\n", omittingEmptySubsequences: true) {
                outgoing.append(contentsOf: Array((line + "\r\n").utf8))
            }
        }
        outgoing.append(contentsOf: Array((serverVersion + "\r\n").utf8))
        beginKex()
    }

    public func takeOutgoing() -> [UInt8] {
        guard !outgoing.isEmpty else { return [] }
        let out = outgoing
        outgoing = []
        return out
    }

    public func takeEvents() -> [Event] {
        defer { events.removeAll() }
        return events
    }

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

    public func requestRekey() {
        guard phase == .running, kex == nil, sessionID != nil else { return }
        beginKex()
    }

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

    // MARK: Processing

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
            if isFirstKex, inboundSequence == UInt32.max {
                throw .protocolError("sequence number wrapped during the initial key exchange")
            }
            inboundSequence &+= 1
            bytesSinceKex &+= UInt64(size)
            try handle(payload, sequence: sequence)
            if kex == nil, sessionID != nil, bytesSinceKex >= configuration.rekeyAfterBytes { beginKex() }
        }
    }

    private func wrapPacket<T>(_ body: () throws(PacketError) -> T) throws(SSHTransportError) -> T {
        do { return try body() } catch { throw .packet(error) }
    }

    /// Returns true once the client's version line has been read.
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
            guard line.starts(with: Array("SSH-".utf8)) else {
                if versionBytesSeen > Self.maximumVersionPreamble {
                    throw .versionExchange("client sent more than 64 KiB before its version line")
                }
                continue
            }
            let text = String(decoding: line, as: UTF8.self)
            guard text.hasPrefix("SSH-2.0-") || text.hasPrefix("SSH-1.99-") else {
                throw .versionExchange("client speaks \(text), not SSH-2.0")
            }
            clientVersion = text
            clientVersionBytes = line
            phase = .running
            return true
        }
    }

    // MARK: Packets in

    private func handle(_ payload: [UInt8], sequence: UInt32) throws(SSHTransportError) {
        guard let type = payload.first else { throw .protocolError("empty packet") }

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
            return                          // ext-info-c is of no use to the server
        default:
            guard negotiated != nil else {
                throw .protocolError("message \(type) before the first key exchange finished")
            }
            events.append(.message(payload))
        }
    }

    // MARK: Key exchange

    private func beginKex() {
        var cookie = [UInt8](repeating: 0, count: 16)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<16 { cookie[i] = UInt8.random(in: 0...255, using: &rng) }
        let prefs = offer
        var kexNames = prefs.kex.map(\.rawValue)
        if isFirstKex, configuration.strictKex {
            kexNames.append(KexExtension.strictServer)
        }
        let kexInit = KexInit(cookie: cookie, kexAlgorithms: kexNames,
                              hostKeyAlgorithms: prefs.hostKeys.map(\.rawValue),
                              ciphers: prefs.ciphers.map(\.rawValue), macs: prefs.macs.map(\.rawValue))
        kex = KexRound(serverKexInit: kexInit)
        try? sealAndQueue(kexInit.payload)
    }

    private func receiveKexInit(_ payload: [UInt8], sequence: UInt32) throws(SSHTransportError) {
        let clientInit: KexInit
        do { clientInit = try KexInit(payload: payload) } catch { throw .protocolError("malformed KEXINIT") }
        if kex == nil { beginKex() }            // client-initiated rekey
        guard var round = kex, round.clientKexInit == nil else {
            throw .protocolError("second KEXINIT during one key exchange")
        }
        if isFirstKex, !isStrictKex, configuration.strictKex,
           clientInit.kexAlgorithms.contains(KexExtension.strictClient) {
            isStrictKex = true
            guard sequence == 0 else {
                throw .protocolError("strict key exchange: KEXINIT was not the client's first packet")
            }
        }
        round.clientKexInit = clientInit
        let chosen: NegotiatedAlgorithms
        do {
            chosen = try Negotiation.negotiateServer(client: clientInit, server: offer)
        } catch {
            throw .negotiation(error)
        }
        round.negotiated = chosen
        // RFC 4253 §7: a wrong client guess means its next kex packet is
        // discarded — the guess is right only if both first entries match.
        if clientInit.firstKexPacketFollows,
           clientInit.kexAlgorithms.first != chosen.kex.rawValue
           || clientInit.hostKeyAlgorithms.first != chosen.hostKey.rawValue {
            round.ignoreNextClientKexPacket = true
        }
        kex = round

        guard let signer = signer(for: chosen.hostKey) else {
            throw .protocolError("no host key for the negotiated algorithm \(chosen.hostKey.rawValue)")
        }
        // V_C ‖ V_S in the exchange hash: the client's line bytes, then ours.
        let prefix = ServerExchangePrefix(clientVersion: clientVersionBytes,
                                          serverVersion: Array(serverVersion.utf8),
                                          clientKexInit: clientInit.payload,
                                          serverKexInit: round.serverKexInit.payload)
        let method: ServerKexMethod
        do {
            method = try ServerKexFactory.make(chosen.kex, prefix: prefix,
                                               hostKeyBlob: signer.publicKey.blob, signer: signer,
                                               signatureAlgorithm: chosen.hostKey.rawValue,
                                               exponentBits: KeyDerivation.dhExponentBits(for: chosen))
        } catch {
            throw .keyExchange(error)
        }
        round.method = method
        kex = round
    }

    private func receiveKexMessage(_ payload: [UInt8]) throws(SSHTransportError) {
        guard var round = kex, let method = round.method, round.outcome == nil else {
            throw .protocolError("key exchange message \(payload[0]) outside a key exchange")
        }
        if round.ignoreNextClientKexPacket {
            round.ignoreNextClientKexPacket = false
            kex = round
            return
        }
        let step: (outcome: KexOutcome, reply: [UInt8])
        do { step = try method.handle(payload) } catch { throw .keyExchange(error) }
        round.outcome = step.outcome
        kex = round
        try finishKex(step.outcome, reply: step.reply)
    }

    private func finishKex(_ outcome: KexOutcome, reply: [UInt8]) throws(SSHTransportError) {
        guard var round = kex, let chosen = round.negotiated else { throw .protocolError("kex state lost") }
        let session = sessionID ?? outcome.exchangeHash
        let keys = KeyDerivation.keys(for: chosen, hash: chosen.kex.hash, encodedSecret: outcome.encodedSecret,
                                      exchangeHash: outcome.exchangeHash, sessionID: session)
        sessionID = session
        // NEWKEYS goes out under the old keys; everything after under the new.
        try sealAndQueue(reply)
        try sealAndQueue([SSHMessage.newKeys])
        do {
            outbound = try PacketProtection(keys: keys.serverToClient, encrypting: true)
        } catch {
            throw .packet(error)
        }
        if isStrictKex { outboundSequence = 0 }
        round.sentNewKeys = true
        round.pendingInbound = keys.clientToServer
        kex = round
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

    /// The signer whose key type covers the negotiated host key algorithm.
    private func signer(for algorithm: HostKeyAlgorithm) -> SSHSigner? {
        configuration.hostKeys.first { signer in
            switch signer.publicKey.keyType {
            case "ssh-ed25519": return algorithm == .ed25519
            case "ssh-rsa": return algorithm == .rsaSHA1 || algorithm == .rsaSHA256 || algorithm == .rsaSHA512
            default: return false
            }
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
