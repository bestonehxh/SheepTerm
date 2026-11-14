import Foundation

// ZMODEM (6.1 (37), the owner: "ทำทั้ง Y และ Z"): `sz file` on the far end
// sends a file down the terminal's own line, `rz` takes one — through any
// number of jump hosts, where SFTP has no way in. Sans-I/O and Foundation
// only, like `XModemSender`: the owner feeds what the far end sends into
// `receive`, writes back what comes out, and calls `tick` when
// `nextDeadline` passes. Time is injected.
//
// Follows Chuck Forsberg's "The ZMODEM Inter Application File Transfer
// Protocol" (zmodem.txt, 1988) and what lrzsz 0.12/0.13 does where the text
// leaves room; `Tests/run.sh zmodem` runs both directions against the real
// `sz` / `rz` over a pty.
//
// What is NOT here, on purpose: ZCOMMAND (the far end asking us to run a
// command) is refused; ZSINIT's attention string is acknowledged and never
// sent; compression and encryption are not offered; a receiver never
// resumes or overwrites (its owner picks a fresh name).

/// Framing: headers, data subpackets, the two CRCs, ZDLE escaping.
public nonisolated enum ZModem {
    public static let ZPAD: UInt8 = 0x2A   // "*"
    public static let ZDLE: UInt8 = 0x18
    public static let ZBIN: UInt8 = 0x41   // "A": binary header, CRC-16
    public static let ZHEX: UInt8 = 0x42   // "B": hex header, CRC-16
    public static let ZBIN32: UInt8 = 0x43 // "C": binary header, CRC-32
    public static let XON: UInt8 = 0x11

    public enum FrameType: UInt8, Sendable {
        case zrqinit = 0, zrinit, zsinit, zack, zfile, zskip, znak, zabort, zfin, zrpos,
             zdata, zeof, zferr, zcrc, zchallenge, zcompl, zcan, zfreecnt, zcommand
    }

    /// How a data subpacket ends.
    public enum End: UInt8, Sendable {
        /// The frame ends; a header follows.
        case crcE = 0x68
        /// More subpackets follow, no answer expected.
        case crcG = 0x69
        /// More follow; a ZACK is expected.
        case crcQ = 0x6A
        /// The frame ends; a ZACK is expected.
        case crcW = 0x6B

        var endsFrame: Bool { self == .crcE || self == .crcW }
    }

    /// ZRINIT's capability bits (ZF0).
    public static let canFullDuplex: UInt8 = 0x01
    public static let canOverlapIO: UInt8 = 0x02
    public static let canCRC32: UInt8 = 0x20
    /// The receiver wants every control character escaped.
    public static let escapeControl: UInt8 = 0x40

    public struct Header: Equatable, Sendable {
        public var type: FrameType
        /// The four header bytes as sent: a position is little-endian in
        /// them (ZP0…ZP3); flags are ZF3, ZF2, ZF1, ZF0.
        public var bytes: [UInt8]

        public init(_ type: FrameType, position: UInt32 = 0) {
            self.type = type
            bytes = [UInt8(position & 0xFF), UInt8((position >> 8) & 0xFF), UInt8((position >> 16) & 0xFF), UInt8(position >> 24)]
        }

        public init(_ type: FrameType, flags f0: UInt8, f1: UInt8 = 0, f2: UInt8 = 0, f3: UInt8 = 0) {
            self.type = type
            bytes = [f3, f2, f1, f0]
        }

        public var position: UInt32 {
            UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        }
        public var f0: UInt8 { bytes[3] }
    }

    // MARK: CRC

    /// CRC-16/XMODEM (poly 0x1021, init 0), as XMODEM-CRC and YMODEM use.
    public static func crc16(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    private static let crc32Table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        return value
    }

    /// CRC-32 (the zlib / Ethernet one).
    public static func crc32(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }

    // MARK: Writing

    /// Bytes that never travel bare: ZDLE itself, DLE, XON, XOFF (and the
    /// same with the high bit), and a CR after "@" (a Telenet escape). With
    /// `allControl` (the far end asked: ESCCTL), every control character.
    static func escaped(_ bytes: some Sequence<UInt8>, allControl: Bool, last: inout UInt8) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.underestimatedCount + 16)
        for byte in bytes {
            let low = byte & 0x7F
            let must: Bool
            switch byte {
            case 0x18, 0x10, 0x11, 0x13, 0x90, 0x91, 0x93, 0x7F, 0xFF: must = true
            case 0x0D, 0x8D: must = allControl || last & 0x7F == 0x40
            default: must = allControl && low < 0x20
            }
            if must {
                out.append(ZDLE)
                // 0x7F and 0xFF have their own letters; the rest flip bit 6.
                out.append(byte == 0x7F ? 0x6C : byte == 0xFF ? 0x6D : byte ^ 0x40)
            } else {
                out.append(byte)
            }
            last = byte
        }
        return out
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// A hex header: readable on a line, what both ends open with.
    public static func hexHeader(_ header: Header) -> [UInt8] {
        let body = [header.type.rawValue] + header.bytes
        let crc = crc16(body)
        var out: [UInt8] = [ZPAD, ZPAD, ZDLE, ZHEX]
        for byte in body + [UInt8(crc >> 8), UInt8(crc & 0xFF)] {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        out += [0x0D, 0x0A]
        // XON releases a far end that a stray XOFF stopped — not after ZACK / ZFIN.
        if header.type != .zack && header.type != .zfin { out.append(XON) }
        return out
    }

    /// A binary header, CRC-32 when the receiver takes it.
    public static func binaryHeader(_ header: Header, crc32 wide: Bool, allControl: Bool = false) -> [UInt8] {
        var body = [header.type.rawValue] + header.bytes
        if wide {
            let crc = crc32(body)
            body += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
        } else {
            let crc = crc16(body)
            body += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        }
        var last: UInt8 = 0
        return [ZPAD, ZDLE, wide ? ZBIN32 : ZBIN] + escaped(body, allControl: allControl, last: &last)
    }

    /// One data subpacket: the data escaped, ZDLE + how it ends, the CRC
    /// (over the data and the end byte) escaped.
    public static func subpacket(_ data: some Collection<UInt8>, end: End, crc32 wide: Bool, allControl: Bool = false) -> [UInt8] {
        var last: UInt8 = 0
        var out = escaped(data, allControl: allControl, last: &last)
        out += [ZDLE, end.rawValue]
        let covered = Array(data) + [end.rawValue]
        let crcBytes: [UInt8]
        if wide {
            let crc = crc32(covered)
            crcBytes = [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
        } else {
            let crc = crc16(covered)
            crcBytes = [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        }
        last = 0
        out += escaped(crcBytes, allControl: allControl, last: &last)
        // lrzsz's zsdata: an XON after a ZCRCW packet, so the answer can come.
        if end == .crcW { out.append(XON) }
        return out
    }

    /// The abort both ends understand: CANs (five end a session), then
    /// backspaces that rub them out of a shell's command line.
    public static let cancelSequence: [UInt8] = [UInt8](repeating: 0x18, count: 8) + [UInt8](repeating: 0x08, count: 10)

    // MARK: Reading

    public enum Event: Equatable, Sendable {
        case header(Header)
        /// A data subpacket whose CRC was right.
        case data([UInt8], End)
        /// A header or subpacket that did not check out (the frame is dropped).
        case garbled
        /// Five CANs in a row: the far end gave up.
        case cancelled
    }

    /// The incoming byte stream cut into headers and data subpackets.
    /// Anything that is not part of a frame is skipped (a shell's echo, a
    /// banner, the "rz" a sender prints first).
    public struct Parser: Sendable {
        private enum State: Sendable {
            /// Looking for ZPAD … ZDLE + a format letter.
            case hunt(pads: Int, sawZDLE: Bool)
            case hex([UInt8])
            case binary(wide: Bool, body: [UInt8], escape: Bool)
            case data(wide: Bool, body: [UInt8], escape: Bool, end: End?, crc: [UInt8])
        }

        private var state: State = .hunt(pads: 0, sawZDLE: false)
        private var cans = 0
        /// The CRC of the frame being read: its header's.
        private var frameWide = false
        /// The largest subpacket taken; a sender's are 1024 (8192 with -8).
        public static let maxSubpacket = 16 * 1024

        public init() {}

        /// Whether the next bytes are a data subpacket (after ZFILE, ZDATA, ZSINIT).
        public var expectsData: Bool {
            if case .data = state { return true }
            return false
        }

        /// The frame in progress is dropped; the parser hunts for a header.
        public mutating func resync() { state = .hunt(pads: 0, sawZDLE: false) }

        public mutating func feed(_ bytes: some Sequence<UInt8>) -> [Event] {
            var events: [Event] = []
            for byte in bytes {
                if byte == ZModem.ZDLE {
                    cans += 1
                    if cans >= 5 {
                        cans = 0
                        state = .hunt(pads: 0, sawZDLE: false)
                        events.append(.cancelled)
                        continue
                    }
                } else {
                    cans = 0
                }
                step(byte, &events)
            }
            return events
        }

        private mutating func step(_ byte: UInt8, _ events: inout [Event]) {
            switch state {
            case .hunt(let pads, let sawZDLE):
                if sawZDLE {
                    switch byte {
                    case ZModem.ZHEX: state = .hex([])
                    case ZModem.ZBIN: state = .binary(wide: false, body: [], escape: false)
                    case ZModem.ZBIN32: state = .binary(wide: true, body: [], escape: false)
                    case ZModem.ZDLE: break   // a run of CANs
                    default: state = .hunt(pads: byte == ZModem.ZPAD ? 1 : 0, sawZDLE: false)
                    }
                } else if byte == ZModem.ZPAD {
                    state = .hunt(pads: pads + 1, sawZDLE: false)
                } else if byte == ZModem.ZDLE, pads > 0 {
                    state = .hunt(pads: pads, sawZDLE: true)
                } else {
                    state = .hunt(pads: 0, sawZDLE: false)
                }

            case .hex(var digits):
                // Seven bytes as fourteen hex digits; parity may ride on bit 7.
                let value: UInt8
                switch byte & 0x7F {
                case 0x30...0x39: value = (byte & 0x7F) - 0x30
                case 0x61...0x66: value = (byte & 0x7F) - 0x61 + 10
                default:
                    state = .hunt(pads: 0, sawZDLE: false)
                    events.append(.garbled)
                    return
                }
                digits.append(value)
                guard digits.count == 14 else { state = .hex(digits); return }
                let body = stride(from: 0, to: 14, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
                finishHeader(body, wide: false, &events)

            case .binary(let wide, var body, let escape):
                guard let plain = unescape(byte, escape: escape, body: &body, wide: wide) else { return }
                if plain == nil {
                    // A frame end inside a header: not a header.
                    state = .hunt(pads: 0, sawZDLE: false)
                    events.append(.garbled)
                    return
                }
                guard body.count == (wide ? 9 : 7) else { state = .binary(wide: wide, body: body, escape: false); return }
                finishHeader(body, wide: wide, &events)

            case .data(let wide, var body, let escape, let end, var crc):
                if let end {
                    // The CRC bytes, escaped like the data.
                    var scratch: [UInt8] = []
                    guard let plain = unescape(byte, escape: escape, body: &scratch, wide: wide, end: end, crc: crc, data: body) else { return }
                    guard plain != nil, let value = scratch.first else {
                        state = .hunt(pads: 0, sawZDLE: false)
                        events.append(.garbled)
                        return
                    }
                    crc.append(value)
                    guard crc.count == (wide ? 4 : 2) else { state = .data(wide: wide, body: body, escape: false, end: end, crc: crc); return }
                    let covered = body + [end.rawValue]
                    let good: Bool
                    if wide {
                        let sum = ZModem.crc32(covered)
                        good = crc == [UInt8(sum & 0xFF), UInt8((sum >> 8) & 0xFF), UInt8((sum >> 16) & 0xFF), UInt8(sum >> 24)]
                    } else {
                        let sum = ZModem.crc16(covered)
                        good = crc == [UInt8(sum >> 8), UInt8(sum & 0xFF)]
                    }
                    if good {
                        events.append(.data(body, end))
                        state = end.endsFrame ? .hunt(pads: 0, sawZDLE: false) : .data(wide: wide, body: [], escape: false, end: nil, crc: [])
                    } else {
                        events.append(.garbled)
                        state = .hunt(pads: 0, sawZDLE: false)
                    }
                    return
                }
                if escape {
                    if let ending = End(rawValue: byte) {
                        state = .data(wide: wide, body: body, escape: false, end: ending, crc: [])
                        return
                    }
                    guard let plain = Self.plain(afterZDLE: byte) else {
                        state = .hunt(pads: 0, sawZDLE: false)
                        events.append(.garbled)
                        return
                    }
                    body.append(plain)
                } else if byte == ZModem.ZDLE {
                    state = .data(wide: wide, body: body, escape: true, end: nil, crc: [])
                    return
                } else if byte == 0x11 || byte == 0x13 || byte == 0x91 || byte == 0x93 {
                    // Flow control a modem slipped in: never data (it is always escaped).
                    return
                } else {
                    body.append(byte)
                }
                if body.count > Self.maxSubpacket {
                    state = .hunt(pads: 0, sawZDLE: false)
                    events.append(.garbled)
                    return
                }
                state = .data(wide: wide, body: body, escape: false, end: nil, crc: [])
            }
        }

        /// ZDLE + `byte` as the byte it stands for; nil = not an escape.
        private static func plain(afterZDLE byte: UInt8) -> UInt8? {
            switch byte {
            case 0x6C: return 0x7F
            case 0x6D: return 0xFF
            default: return byte & 0x60 == 0x40 ? byte ^ 0x40 : nil
            }
        }

        /// One byte of a header or of a CRC. Returns nil = nothing yet (the
        /// ZDLE itself, or a skipped XON/XOFF; the state is updated here);
        /// `.some(nil)` = garbage; `.some(value)` = appended to `body`.
        private mutating func unescape(_ byte: UInt8, escape: Bool, body: inout [UInt8], wide: Bool,
                                       end: End? = nil, crc: [UInt8] = [], data: [UInt8] = []) -> UInt8??  {
            func pending(_ escape: Bool) -> State {
                if let end { return .data(wide: wide, body: data, escape: escape, end: end, crc: crc) }
                return .binary(wide: wide, body: body, escape: escape)
            }
            if escape {
                guard let plain = Self.plain(afterZDLE: byte) else { return .some(nil) }
                body.append(plain)
                return .some(plain)
            }
            if byte == ZModem.ZDLE { state = pending(true); return nil }
            if byte == 0x11 || byte == 0x13 || byte == 0x91 || byte == 0x93 { state = pending(false); return nil }
            body.append(byte)
            return .some(byte)
        }

        private mutating func finishHeader(_ body: [UInt8], wide: Bool, _ events: inout [Event]) {
            state = .hunt(pads: 0, sawZDLE: false)
            let good: Bool
            if wide {
                let sum = ZModem.crc32(body.prefix(5))
                good = Array(body.suffix(4)) == [UInt8(sum & 0xFF), UInt8((sum >> 8) & 0xFF), UInt8((sum >> 16) & 0xFF), UInt8(sum >> 24)]
            } else {
                let sum = ZModem.crc16(body.prefix(5))
                good = Array(body.suffix(2)) == [UInt8(sum >> 8), UInt8(sum & 0xFF)]
            }
            guard good, let type = FrameType(rawValue: body[0]) else { events.append(.garbled); return }
            var header = Header(type)
            header.bytes = Array(body[1...4])
            events.append(.header(header))
            frameWide = wide
            // These frames carry data subpackets, in their header's CRC.
            if type == .zfile || type == .zdata || type == .zsinit || type == .zcommand {
                state = .data(wide: wide, body: [], escape: false, end: nil, crc: [])
            }
        }
    }

    // MARK: File names

    /// A sender's file name as a name in Downloads: its last path component
    /// (either slash), no control characters, no leading dot (never a hidden
    /// file), not "." or ".." — "download" when nothing is left.
    public static func safeFileName(_ raw: String) -> String {
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var name = String(String.UnicodeScalarView(last.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && $0 != ":" }))
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        name = cut(name, toBytes: maxNameBytes)
        return name.isEmpty ? "download" : name
    }

    /// A name's ceiling in BYTES: the part file adds 25 around it and a
    /// volume takes 255 (6.1 (47) — 100 characters of Thai are 300 bytes).
    public static let maxNameBytes = 200

    /// `name` in at most `limit` UTF-8 bytes, cut between characters, its
    /// extension (a short one) kept.
    static func cut(_ name: String, toBytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        var ext = dot.map { String(name[$0...]) } ?? ""
        if ext.utf8.count > 20 { ext = "" }
        var stem = ext.isEmpty ? name : String(name[..<dot!])
        while stem.utf8.count + ext.utf8.count > limit, !stem.isEmpty { stem.removeLast() }
        return stem + ext
    }

    // MARK: Around a transfer (6.1 (47))

    /// The two "O"s `sz` signs off with after our ZFIN: taken off the head
    /// of what follows, across reads; any other byte ends the wait.
    ///
    /// Before them comes the rest of the far end's last hex header: the
    /// parser is done at its 14th digit, and the CR, LF (0x8A) and XON that
    /// close it are not the terminal's either (6.1 (49)) — after a send
    /// (`expect(os: 0)`) they are all there is.
    public struct SignOff: Sendable {
        public private(set) var left = 0
        /// Where the header's trailer stands: 0 = CR or LF may come, 1 = LF
        /// (after the CR), 2 = XON (after the LF), 3 = over. In that order
        /// only — a CR after the LF is the shell's (6.1 (50)).
        private var trailer = 3
        public init() {}
        public var isWaiting: Bool { left > 0 || trailer < 3 }
        public mutating func expect(os: Int = 2) { left = os; trailer = 0 }
        public mutating func clear() { left = 0; trailer = 3 }
        public mutating func strip(_ bytes: [UInt8]) -> [UInt8] {
            guard isWaiting, !bytes.isEmpty else { return bytes }
            var start = 0
            while start < bytes.count, isWaiting {
                let byte = bytes[start]
                if trailer == 0, byte == 0x0D {
                    trailer = 1
                } else if trailer <= 1, byte == 0x0A || byte == 0x8A {
                    trailer = 2
                } else if trailer == 2, byte == 0x11 {
                    trailer = 3
                } else if left > 0, byte == 0x4F {
                    left -= 1
                    trailer = 3
                } else {
                    clear()
                    break
                }
                start += 1
            }
            return start == 0 ? bytes : Array(bytes[start...])
        }
    }

    /// After WE cancel a transfer the far end is still sending what was on
    /// its way: file bytes, never the terminal's. They are swallowed until
    /// the line has been quiet for `quiet` seconds, `longest` at most.
    public struct Drain: Sendable {
        public static let quiet: Double = 1
        public static let longest: Double = 15
        private var quietUntil: Double
        private let hardUntil: Double
        public init(now: Double) {
            quietUntil = now + Self.quiet
            hardUntil = now + Self.longest
        }
        public func isOver(now: Double) -> Bool { now >= quietUntil || now >= hardUntil }
        /// Bytes arrived: false = the drain is over, they are the terminal's.
        public mutating func swallow(_ count: Int, now: Double) -> Bool {
            guard !isOver(now: now) else { return false }
            if count > 0 { quietUntil = now + Self.quiet }
            return true
        }
    }

    /// What a receive says when the sender signs off. `unfinished`: a file
    /// still open at its ZFIN (no ZEOF) — discarded, and said so, not
    /// "nothing was sent" (6.1 (52)).
    public static func receivedNotice(landed: [String], unfinished: String?) -> (text: String, error: Bool) {
        let kept = landed.isEmpty ? nil : "received \(landed.joined(separator: ", ")) → Downloads"
        guard let unfinished else { return ("ZMODEM: " + (kept ?? "nothing was sent"), false) }
        return ("ZMODEM: \(unfinished) did not arrive whole — not kept" + (kept.map { "; " + $0 } ?? ""), true)
    }

    /// `name`, or "name 2.ext", "name 3.ext" … — the first that is not taken.
    public static func freeFileName(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let stem = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        var number = 2
        while taken("\(stem) \(number)\(ext)") { number += 1 }
        return "\(stem) \(number)\(ext)"
    }

    // MARK: Spotting a transfer in a terminal's stream

    /// What the far end has just started.
    public enum Offer: Equatable, Sendable {
        /// `sz`: it wants to send (its ZRQINIT).
        case sending
        /// `rz`: it is waiting for a file (its ZRINIT).
        case receiving
    }

    /// Watches a terminal's output for the hex header a transfer opens with:
    /// "**" ZDLE "B00" (ZRQINIT) or "**" ZDLE "B01" (ZRINIT). Bytes pass
    /// through untouched; the watcher only says when one has gone by.
    public struct Watcher: Sendable {
        private static let lead: [UInt8] = [ZPAD, ZPAD, ZDLE, ZHEX, 0x30]
        private var matched = 0

        public init() {}

        /// The offer among `bytes`, and where it STARTS (the first "*"), or
        /// nil. A lead split across two calls is found; `start` is then 0
        /// and `carried` is the head of the header that went by in the
        /// earlier call — the owner puts it back before parsing.
        public mutating func scan(_ bytes: some Collection<UInt8>) -> (offer: Offer, start: Int, carried: [UInt8])? {
            for (index, byte) in bytes.enumerated() {
                if matched == Self.lead.count {
                    matched = 0
                    let offer: Offer? = byte == 0x30 ? .sending : byte == 0x31 ? .receiving : nil
                    let begin = index - Self.lead.count
                    if let offer { return (offer, max(0, begin), begin < 0 ? Array(Self.lead[..<(-begin)]) : []) }
                }
                if byte == Self.lead[matched] {
                    matched += 1
                } else if byte == ZPAD {
                    // "***" ZDLE …: still two pads behind us.
                    matched = matched >= 2 ? 2 : 1
                } else {
                    matched = 0
                }
            }
            return nil
        }
    }
}

/// What a receiver or a sender wants done after one call.
public nonisolated struct ZModemOutput: Sendable {
    /// Bytes for the far end, in order.
    public var send: [UInt8] = []
    public var events: [ZModemEvent] = []
}

public nonisolated enum ZModemEvent: Equatable, Sendable {
    /// A file begins: its name as the sender gave it (never trusted as a
    /// path — the owner takes the last component) and its size, 0 = unknown.
    case fileBegan(name: String, size: Int)
    /// The next bytes of the file, in order.
    case fileData([UInt8])
    case fileEnded
    /// The whole session ended well. A sender's `sent` is the files taken.
    case finished
    case failed(ZModemFailure)
}

public nonisolated enum ZModemFailure: Equatable, Sendable {
    case cancelledByPeer
    case cancelledByUser
    /// Nothing usable for too long.
    case timedOut
    /// The far end said it could not go on (ZFERR, ZABORT), or skipped the file.
    case refused(String)
    case sessionEnded
}

/// Takes the files `sz` sends. The owner writes `fileData` where it chose.
public nonisolated struct ZModemReceiver: Sendable {
    public static let answerTimeout: Double = 10
    public static let maxRetries = 10

    private enum Stage: Sendable { case idle, awaitFile, inFile, awaitData, done }

    private var parser = ZModem.Parser()
    private var stage: Stage = .idle
    private var received: UInt32 = 0
    /// Subpackets are dropped until the next ZDATA at our position.
    private var skipping = false
    private var deadline: Double
    private var retries = 0
    /// Broken frames in a row: a line that is not 8-bit clean never gets
    /// one through, and each answer would push the deadline for ever.
    private var garbled = 0
    public static let maxGarbled = 30
    private var lastAnswer: [UInt8] = []
    public private(set) var isFinished = false
    /// Bytes of the file being received so far.
    public var position: Int { Int(received) }

    public var nextDeadline: Double? { isFinished ? nil : deadline }

    public init(now: Double) {
        deadline = now + Self.answerTimeout
    }

    private static var readyHeader: [UInt8] {
        ZModem.hexHeader(ZModem.Header(.zrinit, flags: ZModem.canFullDuplex | ZModem.canOverlapIO | ZModem.canCRC32))
    }

    /// The first answer: "ready, CRC-32, no window".
    public mutating func start(now: Double) -> ZModemOutput {
        stage = .awaitFile
        return answer(Self.readyHeader, now: now)
    }

    private mutating func answer(_ bytes: [UInt8], now: Double, into out: inout ZModemOutput) {
        lastAnswer = bytes
        deadline = now + Self.answerTimeout
        out.send += bytes
    }

    private mutating func answer(_ bytes: [UInt8], now: Double) -> ZModemOutput {
        var out = ZModemOutput()
        answer(bytes, now: now, into: &out)
        return out
    }

    private mutating func fail(_ failure: ZModemFailure, into out: inout ZModemOutput, cancel: Bool) {
        guard !isFinished else { return }
        isFinished = true
        stage = .done
        if cancel { out.send += ZModem.cancelSequence }
        out.events.append(.failed(failure))
    }

    public mutating func cancel() -> ZModemOutput {
        var out = ZModemOutput()
        fail(.cancelledByUser, into: &out, cancel: true)
        return out
    }

    public mutating func tick(now: Double) -> ZModemOutput {
        var out = ZModemOutput()
        guard !isFinished, now >= deadline else { return out }
        retries += 1
        if retries > Self.maxRetries {
            fail(.timedOut, into: &out, cancel: true)
        } else {
            // Say again where we are: the sender starts over from there.
            parser.resync()
            if stage == .inFile || stage == .awaitData { skipping = true }
            answer(lastAnswer, now: now, into: &out)
        }
        return out
    }

    public mutating func receive(_ bytes: some Sequence<UInt8>, now: Double) -> ZModemOutput {
        var out = ZModemOutput()
        guard !isFinished else { return out }
        for event in parser.feed(bytes) {
            guard !isFinished else { break }
            switch event {
            case .cancelled:
                fail(.cancelledByPeer, into: &out, cancel: false)
            case .garbled:
                garbled += 1
                if garbled > Self.maxGarbled {
                    fail(.refused("the line is damaging the data — transfer ended"), into: &out, cancel: true)
                    break
                }
                // A broken data subpacket: ask again from what we have.
                if stage == .inFile {
                    skipping = true
                    answer(ZModem.hexHeader(ZModem.Header(.zrpos, position: received)), now: now, into: &out)
                } else if stage == .awaitData {
                    answer(ZModem.hexHeader(ZModem.Header(.znak)), now: now, into: &out)
                }
            case .header(let header):
                retries = 0
                handle(header, now: now, into: &out)
            case .data(let data, let end):
                retries = 0
                garbled = 0
                handle(data, end, now: now, into: &out)
            }
        }
        return out
    }

    /// `receive`, and what came AFTER the frame that ended the transfer in
    /// the same read (the sender's "OO", the shell's prompt): those bytes
    /// are the terminal's again.
    public mutating func receiveSplit(_ bytes: [UInt8], now: Double) -> (out: ZModemOutput, rest: [UInt8]) {
        let before = self
        var out = receive(bytes, now: now)
        guard isFinished else { return (out, []) }
        self = before
        out = ZModemOutput()
        for (index, byte) in bytes.enumerated() {
            let step = receive(CollectionOfOne(byte), now: now)
            out.send += step.send
            out.events += step.events
            if isFinished { return (out, Array(bytes[(index + 1)...])) }
        }
        return (out, [])
    }

    private mutating func handle(_ header: ZModem.Header, now: Double, into out: inout ZModemOutput) {
        switch header.type {
        case .zrqinit:
            // Still asking: our ZRINIT was lost.
            if stage == .awaitFile || stage == .idle { stage = .awaitFile; answer(Self.readyHeader, now: now, into: &out) }
        case .zsinit:
            stage = .awaitData   // its attention string follows; acknowledged, never used
            pendingIsFile = false
        case .zfile:
            stage = .awaitData
            pendingIsFile = true
        case .zdata:
            guard stage == .inFile else { return }
            if header.position == received {
                skipping = false
                deadline = now + Self.answerTimeout
            } else {
                skipping = true
                answer(ZModem.hexHeader(ZModem.Header(.zrpos, position: received)), now: now, into: &out)
            }
        case .zeof:
            guard stage == .inFile else { return }
            if header.position == received {
                out.events.append(.fileEnded)
                stage = .awaitFile
                answer(Self.readyHeader, now: now, into: &out)
            } else {
                // The end came before the data did: ask for what is missing.
                skipping = true
                answer(ZModem.hexHeader(ZModem.Header(.zrpos, position: received)), now: now, into: &out)
            }
        case .zfin:
            // "Over and out": our ZFIN, then the sender's two "O"s go by.
            out.send += ZModem.hexHeader(ZModem.Header(.zfin))
            isFinished = true
            stage = .done
            out.events.append(.finished)
        case .zcommand:
            // Never run anything the far end asks for.
            fail(.refused("the far end asked to run a command"), into: &out, cancel: true)
        case .zabort, .zferr, .zcan:
            fail(.refused("the sender stopped"), into: &out, cancel: false)
        case .zfreecnt:
            answer(ZModem.hexHeader(ZModem.Header(.zack, position: 0)), now: now, into: &out)
        default:
            break
        }
    }

    private mutating func handle(_ data: [UInt8], _ end: ZModem.End, now: Double, into out: inout ZModemOutput) {
        switch stage {
        case .awaitData:
            if pendingIsFile {
                // ZFILE's packet: name NUL "size mtime mode …" NUL.
                let nul = data.firstIndex(of: 0) ?? data.count
                let name = String(decoding: data[..<nul], as: UTF8.self)
                let rest = data.dropFirst(nul + 1).prefix { $0 != 0 }
                let size = Int(String(decoding: rest.prefix { $0 != 0x20 }, as: UTF8.self)) ?? 0
                received = 0
                skipping = false
                stage = .inFile
                out.events.append(.fileBegan(name: name, size: max(0, size)))
                answer(ZModem.hexHeader(ZModem.Header(.zrpos, position: 0)), now: now, into: &out)
            } else {
                // ZSINIT's attention string.
                stage = .awaitFile
                answer(ZModem.hexHeader(ZModem.Header(.zack, position: 1)), now: now, into: &out)
            }
        case .inFile:
            guard !skipping else { return }
            received &+= UInt32(data.count)
            deadline = now + Self.answerTimeout
            if !data.isEmpty { out.events.append(.fileData(data)) }
            if end == .crcQ || end == .crcW {
                // Not `answer`: a ZACK is not what a timeout should repeat.
                out.send += ZModem.hexHeader(ZModem.Header(.zack, position: received))
                lastAnswer = ZModem.hexHeader(ZModem.Header(.zrpos, position: received))
            }
        default:
            break
        }
    }

    /// The data packet awaited is ZFILE's (name and size), not ZSINIT's string.
    private var pendingIsFile = false
}

/// Sends one file to a waiting `rz`. Its data goes out in pieces the owner
/// asks for (`nextData`) while its line has room; what the far end says in
/// between (`receive`) can move the position back.
public nonisolated struct ZModemSender: Sendable {
    public static let answerTimeout: Double = 15
    public static let maxRetries = 10
    public static let subpacketSize = 1024
    /// Beyond `answerTimeout` with no piece taken while sending.
    public static let stalledAfter: Double = 45

    private enum Stage: Sendable { case awaitReady, awaitPosition, sending, awaitEOFAnswer, awaitFinish, done }

    private let name: String
    private let data: [UInt8]
    private var parser = ZModem.Parser()
    private var stage: Stage = .awaitReady
    private var wide = false
    private var allControl = false
    private var offset = 0
    private var needsDataHeader = true
    private var deadline: Double
    private var retries = 0
    public private(set) var isFinished = false

    public var position: Int { offset }
    public var total: Int { data.count }
    public var nextDeadline: Double? { isFinished ? nil : deadline }
    /// Whether `nextData` has anything: the owner calls it while its line has room.
    public var hasData: Bool { stage == .sending && !isFinished }

    public init(name: String, data: [UInt8], now: Double) {
        self.name = name
        self.data = data
        deadline = now + Self.answerTimeout
    }

    private func fileHeader() -> [UInt8] {
        // ZBIN conversion (ZF0 = 1): bytes as they are.
        let header = ZModem.binaryHeader(ZModem.Header(.zfile, flags: 1), crc32: wide, allControl: allControl)
        let info = Array(name.utf8) + [0] + Array("\(data.count) 0 100644 0 1 \(data.count)".utf8) + [0]
        return header + ZModem.subpacket(info, end: .crcW, crc32: wide, allControl: allControl)
    }

    private mutating func fail(_ failure: ZModemFailure, into out: inout ZModemOutput, cancel: Bool) {
        guard !isFinished else { return }
        isFinished = true
        stage = .done
        if cancel { out.send += ZModem.cancelSequence }
        out.events.append(.failed(failure))
    }

    public mutating func cancel() -> ZModemOutput {
        var out = ZModemOutput()
        fail(.cancelledByUser, into: &out, cancel: true)
        return out
    }

    public mutating func tick(now: Double) -> ZModemOutput {
        var out = ZModemOutput()
        guard !isFinished, now >= deadline else { return out }
        if stage == .sending {
            // Data waits for room on the line; a line that gives none for
            // this long is not coming back.
            if now >= deadline + Self.stalledAfter { fail(.timedOut, into: &out, cancel: true) }
            return out
        }
        retries += 1
        if retries > Self.maxRetries {
            fail(.timedOut, into: &out, cancel: true)
            return out
        }
        deadline = now + Self.answerTimeout
        switch stage {
        case .awaitPosition: out.send += fileHeader()
        case .awaitEOFAnswer: out.send += ZModem.hexHeader(ZModem.Header(.zeof, position: UInt32(truncatingIfNeeded: data.count)))
        case .awaitFinish: out.send += ZModem.hexHeader(ZModem.Header(.zfin))
        default: break
        }
        return out
    }

    /// The next piece of the file: a ZDATA header when the position was
    /// (re)set, then one subpacket; after the last, ZEOF.
    public mutating func nextData(now: Double) -> [UInt8] {
        guard stage == .sending, !isFinished else { return [] }
        var out: [UInt8] = []
        if needsDataHeader {
            out += ZModem.binaryHeader(ZModem.Header(.zdata, position: UInt32(truncatingIfNeeded: offset)), crc32: wide, allControl: allControl)
            needsDataHeader = false
        }
        let end = min(offset + Self.subpacketSize, data.count)
        let last = end == data.count
        out += ZModem.subpacket(data[offset..<end], end: last ? .crcE : .crcG, crc32: wide, allControl: allControl)
        offset = end
        deadline = now + Self.answerTimeout
        if last {
            out += ZModem.hexHeader(ZModem.Header(.zeof, position: UInt32(truncatingIfNeeded: data.count)))
            stage = .awaitEOFAnswer
        }
        return out
    }

    public mutating func receive(_ bytes: some Sequence<UInt8>, now: Double) -> ZModemOutput {
        var out = ZModemOutput()
        guard !isFinished else { return out }
        for event in parser.feed(bytes) {
            guard !isFinished else { break }
            switch event {
            case .cancelled:
                fail(.cancelledByPeer, into: &out, cancel: false)
            case .garbled, .data:
                break   // a receiver sends headers only; noise is skipped
            case .header(let header):
                retries = 0
                deadline = now + Self.answerTimeout
                handle(header, into: &out)
            }
        }
        return out
    }

    /// As `ZModemReceiver.receiveSplit`: what followed the end in the same read.
    public mutating func receiveSplit(_ bytes: [UInt8], now: Double) -> (out: ZModemOutput, rest: [UInt8]) {
        let before = self
        var out = receive(bytes, now: now)
        guard isFinished else { return (out, []) }
        self = before
        out = ZModemOutput()
        for (index, byte) in bytes.enumerated() {
            let step = receive(CollectionOfOne(byte), now: now)
            out.send += step.send
            out.events += step.events
            if isFinished { return (out, Array(bytes[(index + 1)...])) }
        }
        return (out, [])
    }

    private mutating func handle(_ header: ZModem.Header, into out: inout ZModemOutput) {
        switch header.type {
        case .zrinit:
            switch stage {
            case .awaitReady, .awaitPosition:
                wide = header.f0 & ZModem.canCRC32 != 0
                allControl = header.f0 & ZModem.escapeControl != 0
                stage = .awaitPosition
                out.send += fileHeader()
            case .awaitEOFAnswer, .sending:
                // The file is in: nothing more to send, say so.
                stage = .awaitFinish
                out.send += ZModem.hexHeader(ZModem.Header(.zfin))
            case .awaitFinish:
                out.send += ZModem.hexHeader(ZModem.Header(.zfin))
            case .done:
                break
            }
        case .zrpos:
            guard stage != .awaitReady, stage != .awaitFinish, stage != .done else { return }
            offset = min(Int(header.position), data.count)
            needsDataHeader = true
            stage = .sending
            // An empty file (or a resume at its end) is all sent already.
            if offset == data.count {
                out.send += ZModem.binaryHeader(ZModem.Header(.zdata, position: UInt32(truncatingIfNeeded: offset)), crc32: wide, allControl: allControl)
                out.send += ZModem.subpacket([UInt8](), end: .crcE, crc32: wide, allControl: allControl)
                out.send += ZModem.hexHeader(ZModem.Header(.zeof, position: UInt32(truncatingIfNeeded: data.count)))
                needsDataHeader = false
                stage = .awaitEOFAnswer
            }
        case .zack:
            break
        case .zcrc:
            // "What is the file's CRC?" (a receiver that has a file of that name).
            var answer = ZModem.Header(.zcrc)
            let crc = ZModem.crc32(data)
            answer.bytes = [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
            out.send += ZModem.hexHeader(answer)
        case .zskip:
            // The receiver will not take it (it has that name already).
            out.send += ZModem.hexHeader(ZModem.Header(.zfin))
            stage = .awaitFinish
            skipped = true
        case .zfin:
            guard stage == .awaitFinish else { return }
            // Over and out.
            out.send += [0x4F, 0x4F]
            isFinished = true
            stage = .done
            out.events.append(skipped ? .failed(.refused("the receiver skipped the file — it has one of that name")) : .finished)
        case .znak:
            if stage == .awaitPosition { out.send += fileHeader() }
        case .zferr, .zabort, .zcan:
            fail(.refused("the receiver stopped"), into: &out, cancel: false)
        case .zcommand, .zchallenge:
            fail(.refused("the far end asked for something this sender does not do"), into: &out, cancel: true)
        default:
            break
        }
    }

    private var skipped = false
}
