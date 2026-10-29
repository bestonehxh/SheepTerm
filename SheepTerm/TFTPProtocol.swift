import Foundation

// TFTP (RFC 1350 + options RFC 2347, blksize RFC 2348, timeout/tsize RFC 2349)
// as a sans-I/O state machine, shared by the File Server (`TFTPServer`, the
// device pulls / pushes) and the Files tab (`TFTPClient`). Foundation only, no
// sockets, no clock: a driver feeds every datagram into `receive`, calls
// `tick` when `nextDeadline` passes, and performs the returned `Action`s in
// order. Time is injected, so loss, duplication, reordering, wrong TIDs, late
// packets and every timeout are covered by the harness without a network
// (Tests/tests/TFTPProtocolTests.swift).
//
// Why a state machine (6.0 (13)): the old server mixed protocol decisions into
// Network.framework callbacks — a refusal's ERROR was queued on a flow that was
// cancelled on the next line, and Network.framework drops a queued datagram on
// cancel (measured: 42 % of "file not found" replies and 8 % of "file too
// large" replies never left the Mac). Here the protocol only ever says "send
// these bytes"; the drivers send them with a synchronous sendto(2) before they
// close anything.
//
// Rules that must not be "simplified":
// - A sender never retransmits on a duplicate ACK, only on its own timer
//   (Sorcerer's Apprentice, RFC 1123 §4.2.3.1). A receiver answers a duplicate
//   of the block it last ACKed with that ACK again (the sender lost it) and
//   ignores any other block number.
// - A datagram from another port of the peer's host (another TID) gets ERROR 5
//   (a few times, then silence) and never touches the transfer.
// - The server never retransmits to a peer that has not answered yet (a
//   spoofed request must not turn this Mac into a reflector): it waits
//   `unprovenLimit` quietly instead. A peer that repeats its own request gets
//   the reply again — one answer per request, never more.
// - Before a pushing device's FIRST data block the OACK / ACK 0 is not
//   repeated by the timer (`repeatBeforeFirstData`): an Aruba CX that hears
//   the OACK twice restarts its numbering one block late.
// - Block numbers wrap 65535 → 0 and the transfer goes on (what tftpd-hpa,
//   curl and the BSD tftp do); offsets come from a 64-bit block COUNT, never
//   from the 16-bit number. Size caps bound every transfer instead.
// - windowsize (RFC 7440) is not offered: lock-step only. A server ignores it
//   (it is left out of the OACK), so a client asking for it falls back.

public nonisolated enum TFTPOpcode: UInt16, Sendable {
    case rrq = 1, wrq = 2, data = 3, ack = 4, error = 5, oack = 6
}

/// RFC 1350 / 2347 error codes.
public nonisolated enum TFTPErrorCode {
    public static let notDefined: UInt16 = 0
    public static let fileNotFound: UInt16 = 1
    public static let accessViolation: UInt16 = 2
    public static let diskFull: UInt16 = 3
    public static let illegalOperation: UInt16 = 4
    public static let unknownTID: UInt16 = 5
    public static let fileExists: UInt16 = 6
    public static let noSuchUser: UInt16 = 7
    public static let optionRefused: UInt16 = 8
}

public nonisolated struct TFTPOption: Equatable, Sendable {
    /// Lower-cased (option names are case-insensitive, RFC 2347).
    public let name: String
    public let value: String
    public init(_ name: String, _ value: String) {
        self.name = name.lowercased()
        self.value = value
    }
}

public nonisolated struct TFTPRequest: Equatable, Sendable {
    public var isWrite: Bool
    public var name: String
    /// Lower-cased: "octet" or "netascii" are served (netascii as is).
    public var mode: String
    public var options: [TFTPOption]

    public init(isWrite: Bool, name: String, mode: String, options: [TFTPOption]) {
        self.isWrite = isWrite
        self.name = name
        self.mode = mode
        self.options = options
    }

    /// The first value given for `name` (a repeated option counts once).
    public func option(_ name: String) -> String? {
        options.first { $0.name == name }?.value
    }
}

public nonisolated enum TFTPPacket: Equatable, Sendable {
    case request(TFTPRequest)
    case data(block: UInt16, payload: Data)
    case ack(block: UInt16)
    case error(code: UInt16, message: String)
    case oack([TFTPOption])

    public static func opcode(of bytes: Data) -> UInt16? {
        guard bytes.count >= 2 else { return nil }
        return UInt16(bytes[bytes.startIndex]) << 8 | UInt16(bytes[bytes.startIndex + 1])
    }

    /// NUL-terminated strings after the opcode; a trailing unterminated
    /// piece is not a field.
    private static func fields(_ bytes: Data) -> [String] {
        var out: [String] = []
        var current = Data()
        for byte in bytes.dropFirst(2) {
            if byte == 0 {
                out.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        return out
    }

    private static func options(_ fields: ArraySlice<String>) -> [TFTPOption] {
        var out: [TFTPOption] = []
        var index = fields.startIndex
        while index + 1 < fields.endIndex {
            out.append(TFTPOption(fields[index], fields[index + 1]))
            index += 2
        }
        return out
    }

    /// Nil for anything that is not a well-formed packet (too short, unknown
    /// opcode, a request without name and mode).
    public static func parse(_ bytes: Data) -> TFTPPacket? {
        guard let op = opcode(of: bytes).flatMap(TFTPOpcode.init(rawValue:)) else { return nil }
        let s = bytes.startIndex
        switch op {
        case .rrq, .wrq:
            let f = fields(bytes)
            guard f.count >= 2 else { return nil }
            return .request(TFTPRequest(isWrite: op == .wrq, name: f[0], mode: f[1].lowercased(),
                                        options: options(f[2...])))
        case .data:
            guard bytes.count >= 4 else { return nil }
            return .data(block: UInt16(bytes[s + 2]) << 8 | UInt16(bytes[s + 3]), payload: Data(bytes.dropFirst(4)))
        case .ack:
            guard bytes.count >= 4 else { return nil }
            return .ack(block: UInt16(bytes[s + 2]) << 8 | UInt16(bytes[s + 3]))
        case .error:
            guard bytes.count >= 4 else { return nil }
            let text = String(decoding: bytes.dropFirst(4).prefix { $0 != 0 }, as: UTF8.self)
            return .error(code: UInt16(bytes[s + 2]) << 8 | UInt16(bytes[s + 3]), message: text)
        case .oack:
            return .oack(options(fields(bytes)[...]))
        }
    }

    public var encoded: Data {
        func word(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
        func string(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }
        switch self {
        case .request(let r):
            var out = word(r.isWrite ? 2 : 1) + string(r.name) + string(r.mode)
            for o in r.options { out += string(o.name) + string(o.value) }
            return Data(out)
        case .data(let block, let payload):
            var out = Data(word(3) + word(block))
            out.append(payload)
            return out
        case .ack(let block):
            return Data(word(4) + word(block))
        case .error(let code, let message):
            return Data(word(5) + word(code) + string(message))
        case .oack(let options):
            var out = word(6)
            for o in options { out += string(o.name) + string(o.value) }
            return Data(out)
        }
    }
}

// MARK: - Option negotiation

public nonisolated enum TFTPNegotiation {
    /// The largest block the server agrees to (RFC 2348 allows 65464; 8 KB
    /// is plenty and keeps one datagram's buffer small).
    public static let serverMaximumBlockSize = 8192

    public struct Server: Equatable, Sendable {
        public var blockSize = 512
        /// RFC 2349 `timeout` the client asked for (1–255 s): the server's
        /// retransmit interval.
        public var timeout: Int?
        /// A write's announced size (`tsize`), echoed.
        public var expectedSize: Int64?
        /// What goes into the OACK; empty = no OACK (plain RFC 1350 start).
        public var acknowledged: [TFTPOption] = []
    }

    public struct Refusal: Error, Equatable, Sendable {
        public let code: UInt16
        public let message: String
        public init(code: UInt16, message: String) { self.code = code; self.message = message }
    }

    /// A write's announced size over `limit`: refused before anything else
    /// (ERROR 3), so a huge push is turned away before a name is looked up.
    public static func writeRefusal(_ request: TFTPRequest, limit: Int64) -> Refusal? {
        guard request.isWrite, let size = request.option("tsize").flatMap({ Int64($0) }), size > limit else { return nil }
        return Refusal(code: TFTPErrorCode.diskFull, message: "file too large")
    }

    /// What the server agrees to. `fileSize` is the read's file size (for
    /// `tsize`); unknown options (windowsize, …) and bad values are left out
    /// of the OACK, never reflected back.
    public static func server(_ request: TFTPRequest, fileSize: Int64?) -> Server {
        var out = Server()
        var seen = Set<String>()
        for option in request.options where seen.insert(option.name).inserted {
            switch option.name {
            case "blksize":
                // RFC 2348: 8–65464; the server may answer lower, never higher.
                guard let asked = Int(option.value), asked >= 8 else { continue }
                out.blockSize = min(asked, serverMaximumBlockSize)
                out.acknowledged.append(TFTPOption("blksize", "\(out.blockSize)"))
            case "tsize":
                guard let size = Int64(option.value), size >= 0 else { continue }
                if request.isWrite {
                    out.expectedSize = size
                    out.acknowledged.append(TFTPOption("tsize", "\(size)"))
                } else if let fileSize {
                    out.acknowledged.append(TFTPOption("tsize", "\(fileSize)"))
                }
            case "timeout":
                guard let seconds = Int(option.value), (1...255).contains(seconds) else { continue }
                out.timeout = seconds
                out.acknowledged.append(TFTPOption("timeout", "\(seconds)"))
            default:
                continue
            }
        }
        return out
    }

    public struct Client: Equatable, Sendable {
        public var blockSize: Int
        public var size: Int64?
        public init(blockSize: Int, size: Int64?) { self.blockSize = blockSize; self.size = size }
    }

    /// The client's view of an OACK: the server may only lower blksize
    /// (RFC 2348), never below 8.
    public static func client(_ oack: [TFTPOption], askedBlockSize: Int) -> Result<Client, Refusal> {
        var blockSize = 512
        var size: Int64?
        for option in oack {
            switch option.name {
            case "blksize":
                guard let value = Int(option.value), (8...askedBlockSize).contains(value) else {
                    return .failure(Refusal(code: TFTPErrorCode.optionRefused, message: "bad block size"))
                }
                blockSize = value
            case "tsize":
                size = Int64(option.value)
            default:
                continue
            }
        }
        return .success(Client(blockSize: blockSize, size: size))
    }
}

// MARK: - One transfer

public nonisolated struct TFTPTransfer: Sendable {
    public enum Role: Sendable, Equatable {
        /// Sends the file: the server answering a read, the client putting.
        case sender
        /// Takes the file: the server answering a write, the client getting.
        case receiver
    }

    /// How the transfer opens.
    public enum Opening: Sendable, Equatable {
        /// Client: this request goes to the server's port; the first reply
        /// from the server's host locks its TID. The reply may be an OACK
        /// when the request carried options (`askedBlockSize`).
        case request(TFTPRequest, askedBlockSize: Int)
        /// Server: answer the request with this OACK.
        case oack([TFTPOption])
        /// Server: a request without options — DATA 1 (sender) or ACK 0.
        case plain
    }

    public struct Policy: Sendable, Equatable {
        /// First retransmit after this long without a step forward.
        public var interval: TimeInterval
        /// Each further retransmit waits twice as long, up to this.
        public var maxInterval: TimeInterval
        /// No step forward for this long from a peer that has answered =
        /// timed out.
        public var stallLimit: TimeInterval
        /// No answer at all for this long = timed out.
        public var unprovenLimit: TimeInterval
        /// Retransmit before the peer has answered (the client: it is the
        /// one asking; the server: never, see the file header).
        public var retransmitUnproven: Bool
        /// Receiver only: repeat ACK 0 / the OACK while no data has arrived.
        public var repeatBeforeFirstData: Bool
        /// Receiver only, with `repeatBeforeFirstData` false: how long to
        /// wait for the first data block (a switch can take seconds to render
        /// its config).
        public var firstDataWait: TimeInterval
        /// Receiver: stay this long after the final ACK, answering a repeat of
        /// the last block with that ACK (RFC 1350 §6).
        public var dally: TimeInterval
        /// ERROR 5 replies to other TIDs, then strays are dropped silently.
        public var maxStrayReplies = 8

        public init(interval: TimeInterval, maxInterval: TimeInterval, stallLimit: TimeInterval, unprovenLimit: TimeInterval,
                    retransmitUnproven: Bool, repeatBeforeFirstData: Bool, firstDataWait: TimeInterval, dally: TimeInterval,
                    maxStrayReplies: Int = 8) {
            self.interval = interval
            self.maxInterval = maxInterval
            self.stallLimit = stallLimit
            self.unprovenLimit = unprovenLimit
            self.retransmitUnproven = retransmitUnproven
            self.repeatBeforeFirstData = repeatBeforeFirstData
            self.firstDataWait = firstDataWait
            self.dally = dally
            self.maxStrayReplies = maxStrayReplies
        }

        /// The File Server. `timeout` = the RFC 2349 value the client asked
        /// for, which sets the retransmit interval.
        public static func server(timeout: Int? = nil) -> Policy {
            let interval = TimeInterval(timeout ?? 1)
            return Policy(interval: interval, maxInterval: max(interval, 4),
                          stallLimit: max(20, interval * 6), unprovenLimit: max(5, interval * 2),
                          retransmitUnproven: false, repeatBeforeFirstData: false,
                          firstDataWait: 30, dally: 3)
        }

        /// The Files tab: 2 s, five retransmits, 12 s without a step = gone.
        public static let client = Policy(interval: 2, maxInterval: 2, stallLimit: 12, unprovenLimit: 12,
                                   retransmitUnproven: true, repeatBeforeFirstData: true,
                                   firstDataWait: 12, dally: 2)
    }

    public enum Failure: Error, Equatable, Sendable {
        case timedOut
        /// The peer sent ERROR.
        case peer(code: UInt16, message: String)
        /// Past `limit` (or an announced size past it): ERROR 3 was sent.
        case tooLarge(announced: Int64?)
        /// The announced size (`expectedSize`) did not arrive whole: ERROR 3.
        case sizeMismatch(got: Int64, expected: Int64)
        /// A client could not accept the OACK (ERROR 8 was sent).
        case badOption(String)
        /// The driver ended it (`abort` / `reject`): that ERROR was sent.
        case aborted(code: UInt16, message: String)
    }

    public enum Outcome: Equatable, Sendable {
        case done(bytes: Int64)
        case failed(Failure)
    }

    public enum Action: Equatable, Sendable {
        /// One datagram to the peer's host, this port.
        case send(Data, port: UInt16)
        /// Receiver: append these bytes to the file.
        case deliver(Data)
        /// Bytes moved so far (every step; drivers throttle).
        case progress(Int64)
        /// Receiver: everything arrived (`total` bytes). The driver makes the
        /// file real and answers with `commit` or `reject` before anything
        /// else is fed in: the final ACK goes out only once the file is safe.
        case lastBlock(total: Int64)
        /// Once per transfer. A receiver may stay open after it (dally) —
        /// `isClosed` says when the driver may let go.
        case finished(Outcome)
    }

    public enum Phase: Sendable, Equatable {
        case notStarted
        case running
        case awaitingCommit
        case dallying(until: TimeInterval)
        case closed
    }

    /// Bytes for the sender, read on demand: (offset, count) → up to count
    /// bytes; fewer = end of file.
    public typealias Source = (_ offset: Int64, _ count: Int) throws -> Data

    public let role: Role
    public let policy: Policy
    public private(set) var phase: Phase = .notStarted
    /// The peer's TID (UDP port).
    public private(set) var peerPort: UInt16
    public private(set) var tidLocked: Bool
    public private(set) var blockSize: Int
    /// Receiver: refuse past this many bytes. Sender: unused.
    public let limit: Int64
    /// Receiver: the size the peer announced; a different total is refused.
    public private(set) var expectedSize: Int64?
    /// Client: the size the server's OACK announced.
    public private(set) var announcedSize: Int64?
    /// Bytes delivered (receiver) or acknowledged (sender).
    public private(set) var bytes: Int64 = 0
    /// Has the peer answered on this transfer (an ACK, a DATA, an OACK)?
    public private(set) var proven = false
    public private(set) var strayReplies = 0

    private let opening: Opening
    /// Last DATA sent (sender) / last block ACKed (receiver).
    private var block: UInt16 = 0
    /// Blocks sent or taken: the 64-bit count behind the wrapping number.
    private var blockCount: Int64 = 0
    private var finalSent = false
    /// Sender: bytes in the DATA block in flight (counted once ACKed).
    private var inFlight = 0
    private var lastPacket = Data()
    private var startedAt: TimeInterval = 0
    private var lastStep: TimeInterval = 0
    private var retransmitAt: TimeInterval = 0
    private var interval: TimeInterval
    private var awaitingOACK: Bool

    public init(role: Role, opening: Opening, peerPort: UInt16, blockSize: Int = 512,
         limit: Int64 = .max, expectedSize: Int64? = nil, policy: Policy) {
        self.role = role
        self.opening = opening
        self.peerPort = peerPort
        self.blockSize = blockSize
        self.limit = limit
        self.expectedSize = expectedSize
        self.policy = policy
        self.interval = policy.interval
        switch opening {
        case .request(let r, _):
            tidLocked = false
            awaitingOACK = !r.options.isEmpty
        case .oack, .plain:
            tidLocked = true
            awaitingOACK = false
        }
    }

    public var isFinished: Bool {
        switch phase {
        case .dallying, .closed: return true
        default: return false
        }
    }
    public var isClosed: Bool { phase == .closed }

    /// When `tick` wants to run next; nil = no timer (closed, or waiting
    /// for the driver's commit).
    public var nextDeadline: TimeInterval? {
        switch phase {
        case .notStarted, .awaitingCommit, .closed: return nil
        case .dallying(let until): return until
        case .running:
            if waitingForFirstData { return startedAt + policy.firstDataWait }
            if !proven && !policy.retransmitUnproven { return lastStep + policy.unprovenLimit }
            let limit = proven ? policy.stallLimit : policy.unprovenLimit
            return min(retransmitAt, lastStep + limit)
        }
    }

    /// A receiver that must not repeat its first answer, still before block 1.
    private var waitingForFirstData: Bool {
        role == .receiver && !policy.repeatBeforeFirstData && blockCount == 0 && !awaitingOACK
    }

    // MARK: Driver entry points

    public mutating func start(now: TimeInterval, source: Source = { _, _ in Data() }) -> [Action] {
        guard phase == .notStarted else { return [] }
        phase = .running
        startedAt = now
        lastStep = now
        retransmitAt = now + interval
        switch opening {
        case .request(let r, _):
            return [transmit(TFTPPacket.request(r).encoded)]
        case .oack(let options):
            return [transmit(TFTPPacket.oack(options).encoded)]
        case .plain:
            return role == .sender ? sendNextBlock(source: source) : [transmit(TFTPPacket.ack(block: 0).encoded)]
        }
    }

    /// One datagram from the peer's host (the driver drops other hosts),
    /// from UDP port `port`.
    public mutating func receive(_ datagram: Data, from port: UInt16, now: TimeInterval,
                          source: Source = { _, _ in Data() }) -> [Action] {
        switch phase {
        case .notStarted, .closed, .awaitingCommit:
            return []
        case .dallying:
            // Only the TID's repeat of the last block, answered with the
            // final ACK again.
            guard port == peerPort, case .data(let b, _)? = TFTPPacket.parse(datagram), b == block else { return [] }
            return [.send(lastPacket, port: peerPort)]
        case .running:
            break
        }
        if tidLocked, port != peerPort {
            return strayReply(datagram, to: port)
        }
        // Parse BEFORE locking: a garbage datagram from the server's host
        // must not lock the TID to its port (the real reply would then be
        // treated as a stranger).
        guard let packet = TFTPPacket.parse(datagram) else { return [] }
        if !tidLocked {
            tidLocked = true
            peerPort = port
        }
        switch packet {
        case .error(let code, let message):
            phase = .closed
            return [.finished(.failed(.peer(code: code, message: message)))]
        case .oack(let options):
            return handleOACK(options, now: now, source: source)
        case .ack(let b):
            guard role == .sender else { return [] }
            return handleAck(b, now: now, source: source)
        case .data(let b, let payload):
            guard role == .receiver else { return [] }
            return handleData(b, payload, now: now)
        case .request:
            return []
        }
    }

    /// The peer repeated its request (same TID) while this transfer is
    /// open: before it has answered anything, it gets the first reply
    /// again — one answer per request. Later repeats are ignored.
    public mutating func repeatedRequest() -> [Action] {
        guard phase == .running, !proven, !lastPacket.isEmpty else { return [] }
        return [.send(lastPacket, port: peerPort)]
    }

    public mutating func tick(now: TimeInterval) -> [Action] {
        switch phase {
        case .dallying(let until):
            if now >= until { phase = .closed }
            return []
        case .running:
            break
        default:
            return []
        }
        if waitingForFirstData {
            guard now >= startedAt + policy.firstDataWait else { return [] }
            return timedOut()
        }
        if !proven && !policy.retransmitUnproven {
            guard now >= lastStep + policy.unprovenLimit else { return [] }
            return timedOut()
        }
        if now >= lastStep + (proven ? policy.stallLimit : policy.unprovenLimit) { return timedOut() }
        guard now >= retransmitAt else { return [] }
        interval = min(interval * 2, policy.maxInterval)
        retransmitAt = now + interval
        return [.send(lastPacket, port: peerPort)]
    }

    /// Receiver after `.lastBlock`: the file is safe — final ACK, then dally.
    public mutating func commit(now: TimeInterval) -> [Action] {
        guard phase == .awaitingCommit else { return [] }
        let ack = TFTPPacket.ack(block: block).encoded
        lastPacket = ack
        phase = policy.dally > 0 ? .dallying(until: now + policy.dally) : .closed
        return [.send(ack, port: peerPort), .finished(.done(bytes: bytes))]
    }

    /// Ends the transfer with an ERROR to the peer (after `.lastBlock`, or
    /// at any time: writes switched off, a disk error, a user's cancel).
    public mutating func abort(code: UInt16, message: String) -> [Action] {
        switch phase {
        case .running, .awaitingCommit, .notStarted: break
        default: return []
        }
        return fail(.aborted(code: code, message: message), error: (code, message))
    }

    // MARK: Steps

    private mutating func transmit(_ packet: Data) -> Action {
        lastPacket = packet
        return .send(packet, port: peerPort)
    }

    private mutating func stepForward(now: TimeInterval) {
        proven = true
        lastStep = now
        interval = policy.interval
        retransmitAt = now + interval
    }

    private mutating func timedOut() -> [Action] {
        phase = .closed
        return [.finished(.failed(.timedOut))]
    }

    private mutating func fail(_ failure: Failure, error: (UInt16, String)?) -> [Action] {
        phase = .closed
        var out: [Action] = []
        if let (code, message) = error {
            out.append(.send(TFTPPacket.error(code: code, message: message).encoded, port: peerPort))
        }
        out.append(.finished(.failed(failure)))
        return out
    }

    private mutating func strayReply(_ datagram: Data, to port: UInt16) -> [Action] {
        // Never answer an ERROR with an ERROR; a few replies, then silence
        // (this end must not become a reflector).
        guard TFTPPacket.opcode(of: datagram) != TFTPOpcode.error.rawValue,
              strayReplies < policy.maxStrayReplies else { return [] }
        strayReplies += 1
        return [.send(TFTPPacket.error(code: TFTPErrorCode.unknownTID, message: "unknown transfer ID").encoded, port: port)]
    }

    private mutating func handleOACK(_ options: [TFTPOption], now: TimeInterval, source: Source) -> [Action] {
        guard case .request(_, let asked) = opening else { return [] }
        guard awaitingOACK else {
            // The server repeated its OACK: our ACK 0 was lost. Answer it
            // again (a receiver still before block 1 only) — the server
            // ignores duplicate ACKs, so this cannot snowball.
            if role == .receiver, blockCount == 0 { return [.send(lastPacket, port: peerPort)] }
            return []
        }
        awaitingOACK = false
        switch TFTPNegotiation.client(options, askedBlockSize: asked) {
        case .failure(let refusal):
            return fail(.badOption(refusal.message), error: (refusal.code, refusal.message))
        case .success(let agreed):
            blockSize = agreed.blockSize
            announcedSize = agreed.size
            stepForward(now: now)
            if role == .receiver {
                if let size = agreed.size, size > limit {
                    return fail(.tooLarge(announced: size), error: (TFTPErrorCode.diskFull, "file too large"))
                }
                return [transmit(TFTPPacket.ack(block: 0).encoded)]
            }
            return sendNextBlock(source: source)
        }
    }

    private mutating func handleAck(_ b: UInt16, now: TimeInterval, source: Source) -> [Action] {
        // Only the ACK for the block in flight moves on; a duplicate is never
        // answered (no Sorcerer's Apprentice) — the timer resends.
        guard b == block else { return [] }
        if awaitingOACK { awaitingOACK = false }   // a server that ignored our options: plain ACK 0
        stepForward(now: now)
        bytes += Int64(inFlight)
        inFlight = 0
        if finalSent {
            phase = .closed
            return [.progress(bytes), .finished(.done(bytes: bytes))]
        }
        var out: [Action] = blockCount > 0 ? [.progress(bytes)] : []
        out += sendNextBlock(source: source)
        return out
    }

    private mutating func sendNextBlock(source: Source) -> [Action] {
        let offset = blockCount * Int64(blockSize)
        let chunk: Data
        do {
            chunk = try source(offset, blockSize)
        } catch {
            return fail(.aborted(code: TFTPErrorCode.notDefined, message: "read failed"),
                        error: (TFTPErrorCode.notDefined, "read failed"))
        }
        block &+= 1
        blockCount += 1
        inFlight = chunk.count
        finalSent = chunk.count < blockSize
        return [transmit(TFTPPacket.data(block: block, payload: chunk.prefix(blockSize)).encoded)]
    }

    private mutating func handleData(_ b: UInt16, _ payload: Data, now: TimeInterval) -> [Action] {
        if b == block &+ 1 {
            // DATA instead of an OACK: the server ignored our options.
            if awaitingOACK { awaitingOACK = false }
            guard payload.count <= blockSize else { return [] }   // not a block of this transfer
            guard bytes + Int64(payload.count) <= limit else {
                return fail(.tooLarge(announced: announcedSize ?? expectedSize),
                            error: (TFTPErrorCode.diskFull, "file too large"))
            }
            stepForward(now: now)
            block = b
            blockCount += 1
            bytes += Int64(payload.count)
            var out: [Action] = [.deliver(payload), .progress(bytes)]
            if payload.count < blockSize {
                // A file that did not arrive whole (a size was announced) is
                // refused, never saved as a silently short copy.
                if let expected = expectedSize, expected > 0, bytes != expected {
                    return out + fail(.sizeMismatch(got: bytes, expected: expected),
                                      error: (TFTPErrorCode.diskFull, "size mismatch: got \(bytes) of \(expected) bytes"))
                }
                phase = .awaitingCommit
                out.append(.lastBlock(total: bytes))
                return out
            }
            out.append(transmit(TFTPPacket.ack(block: b).encoded))
            return out
        }
        // The block we last ACKed, again: that ACK was lost — send it again.
        // Anything else (an old block, one from the future) is ignored.
        if b == block, blockCount > 0 { return [.send(lastPacket, port: peerPort)] }
        return []
    }
}
