import Foundation

/// Telnet (RFC 854) as a sans-I/O state machine: bytes from the socket go in,
/// the session's own bytes and the protocol's replies come out. No socket, no
/// queue, no AppKit — `TelnetWorker` owns the I/O and the harness drives this
/// directly (`Tests/tests/TelnetTests.swift`). Foundation only and in
/// `sharedSources` (root Package.swift): SheepTerm for Windows runs the same
/// protocol under its own worker.
///
/// What it negotiates, and nothing more:
///  - ours (WILL): NAWS (window size, RFC 1073), TERMINAL-TYPE (RFC 1091),
///    BINARY (RFC 856, 8-bit clean — UTF-8 prompts) when the server asks;
///  - theirs (DO): ECHO and SUPPRESS-GO-AHEAD (character-at-a-time, the mode
///    every network device and console server runs in), BINARY.
/// Every other option is refused. Replies go out only when an option's state
/// actually changes (RFC 1143's rule, reduced to on/off + "we asked"), so two
/// ends can never answer each other in a loop.
///
/// These replies are the protocol's own bytes, not text: nothing here types
/// a character into the device's CLI. There is no auto-login.
public nonisolated struct TelnetProtocol: Sendable {
    // Commands
    public static let IAC: UInt8 = 255
    public static let DONT: UInt8 = 254
    public static let DO: UInt8 = 253
    public static let WONT: UInt8 = 252
    public static let WILL: UInt8 = 251
    public static let SB: UInt8 = 250
    public static let BRK: UInt8 = 243
    public static let SE: UInt8 = 240
    // Options
    public static let BINARY: UInt8 = 0
    public static let ECHO: UInt8 = 1
    public static let SGA: UInt8 = 3
    public static let TTYPE: UInt8 = 24
    public static let NAWS: UInt8 = 31
    // TERMINAL-TYPE sub-commands
    public static let IS: UInt8 = 0
    public static let SEND: UInt8 = 1

    /// What we say we are. xterm-256color is what the renderer implements.
    public static let terminalType = "XTERM-256COLOR"
    /// A subnegotiation longer than this is not one we would act on (ours
    /// are a few bytes); the rest is dropped so a hostile server cannot grow
    /// the buffer without limit.
    public static let maxSubnegotiation = 1024

    /// Options we perform ourselves when asked.
    private static let ours: Set<UInt8> = [BINARY, TTYPE, NAWS]
    /// Options we want the server to perform.
    private static let theirs: Set<UInt8> = [BINARY, ECHO, SGA]

    private enum State: Sendable { case data, iac, command(UInt8), sb, sbIAC }
    private var state: State = .data
    /// A CR was the last data byte: a NUL right after it is the NVT's
    /// "bare CR" filler and is dropped.
    private var afterCR = false
    private var sbBuffer: [UInt8] = []

    /// Enabled on our side / on theirs.
    public private(set) var usEnabled: Set<UInt8> = []
    public private(set) var himEnabled: Set<UInt8> = []
    /// WILL/DO we sent and not yet had answered — the answer is not answered.
    private var usAsked: Set<UInt8> = []
    private var himAsked: Set<UInt8> = []

    /// The server answered about ECHO at least once (WILL or WONT).
    private var echoAnswered = false

    private var size: (cols: Int, rows: Int)
    private var sentSize: (cols: Int, rows: Int)?

    public init(cols: Int, rows: Int) {
        size = (cols, rows)
    }

    /// The first bytes on the wire: what we will do and what we want. Sent
    /// once, right after connect — a server that negotiates nothing at all
    /// (a raw console port) just ignores them.
    public mutating func opening() -> [UInt8] {
        var out: [UInt8] = []
        for option in [Self.NAWS, Self.TTYPE] {
            usAsked.insert(option)
            out += [Self.IAC, Self.WILL, option]
        }
        for option in [Self.SGA, Self.ECHO] {
            himAsked.insert(option)
            out += [Self.IAC, Self.DO, option]
        }
        return out
    }

    /// Bytes from the socket → the session's text (`data`, for the terminal
    /// and the log) and the protocol replies to send back (`reply`).
    public mutating func receive(_ bytes: [UInt8]) -> (data: [UInt8], reply: [UInt8]) {
        var data: [UInt8] = []
        data.reserveCapacity(bytes.count)
        var reply: [UInt8] = []
        for byte in bytes {
            switch state {
            case .data:
                if byte == Self.IAC {
                    state = .iac
                } else if afterCR && byte == 0 && !himEnabled.contains(Self.BINARY) {
                    afterCR = false
                } else {
                    afterCR = byte == 0x0D
                    data.append(byte)
                }
            case .iac:
                switch byte {
                case Self.IAC:
                    afterCR = false
                    data.append(Self.IAC)
                    state = .data
                case Self.WILL, Self.WONT, Self.DO, Self.DONT:
                    state = .command(byte)
                case Self.SB:
                    sbBuffer.removeAll(keepingCapacity: true)
                    state = .sb
                default:
                    // NOP, GA, DM, AYT, a stray SE …: nothing to do.
                    state = .data
                }
            case .command(let command):
                reply += negotiate(command, byte)
                state = .data
            case .sb:
                if byte == Self.IAC {
                    state = .sbIAC
                } else if sbBuffer.count < Self.maxSubnegotiation {
                    sbBuffer.append(byte)
                }
            case .sbIAC:
                if byte == Self.SE {
                    reply += subnegotiation(sbBuffer)
                    state = .data
                } else if byte == Self.IAC {
                    if sbBuffer.count < Self.maxSubnegotiation { sbBuffer.append(Self.IAC) }
                    state = .sb
                } else {
                    // IAC <not SE> inside SB: a broken server. End the
                    // subnegotiation and read the byte as a command.
                    state = .iac
                    let (more, moreReply) = receive([byte])
                    data += more
                    reply += moreReply
                }
            }
        }
        return (data, reply)
    }

    /// The terminal's grid changed. Returns the NAWS report to send, or
    /// nothing when NAWS is off or the size is the one already reported.
    public mutating func resize(cols: Int, rows: Int) -> [UInt8] {
        size = (cols, rows)
        return nawsIfChanged()
    }

    /// The user's bytes as they go on the wire: IAC doubled, and (outside
    /// BINARY) a CR followed by NUL — NVT's bare carriage return — so the
    /// device reads Return as one Return and not as CR + whatever came next.
    public func encode(_ bytes: [UInt8]) -> [UInt8] {
        let binary = usEnabled.contains(Self.BINARY)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        for byte in bytes {
            out.append(byte)
            if byte == Self.IAC {
                out.append(Self.IAC)
            } else if byte == 0x0D && !binary {
                out.append(0)
            }
        }
        return out
    }

    /// Asks for BINARY both ways (RFC 856) — an 8-bit-clean line for a file
    /// transfer, so a CR inside a block is not followed by a NUL. Nothing
    /// for a direction already binary or already asked.
    public mutating func requestBinary() -> [UInt8] {
        var out: [UInt8] = []
        if !usEnabled.contains(Self.BINARY), usAsked.insert(Self.BINARY).inserted {
            out += [Self.IAC, Self.WILL, Self.BINARY]
        }
        if !himEnabled.contains(Self.BINARY), himAsked.insert(Self.BINARY).inserted {
            out += [Self.IAC, Self.DO, Self.BINARY]
        }
        return out
    }

    /// Our side sends binary (the server agreed to it).
    public var sendsBinary: Bool { usEnabled.contains(Self.BINARY) }

    /// Telnet's BREAK. A console server (reverse telnet) turns it into a
    /// break condition on the serial line behind it.
    public static let breakCommand: [UInt8] = [IAC, BRK]

    /// True once the server echoes for us.
    public var serverEchoes: Bool { himEnabled.contains(Self.ECHO) }

    /// The server SAID it will not echo (WONT ECHO, or never agreed after
    /// answering): the client echoes what is typed, as telnet clients do. A
    /// raw TCP port that never negotiates echoes by itself and gets none —
    /// doubling every key there would be worse than the rare silent box.
    public var needsLocalEcho: Bool { echoAnswered && !serverEchoes }

    /// What a client shows for the bytes it sends while echoing locally:
    /// text as typed, Return as a new line, Backspace/Delete as a rub-out.
    /// Arrow keys and other escape sequences are not drawn (the server did
    /// not ask for them to be), nor are other control keys.
    public static func localEcho(_ bytes: [UInt8]) -> [UInt8] {
        guard !bytes.contains(0x1B) else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            switch byte {
            case 0x0D, 0x0A: out += [0x0D, 0x0A]
            case 0x08, 0x7F: out += [0x08, 0x20, 0x08]
            case 0x09: out.append(0x09)
            case 0x00..<0x20: continue
            default: out.append(byte)
            }
        }
        return out
    }

    // MARK: - Negotiation

    private mutating func negotiate(_ command: UInt8, _ option: UInt8) -> [UInt8] {
        switch command {
        case Self.WILL:
            if option == Self.ECHO { echoAnswered = true }
            let asked = himAsked.remove(option) != nil
            guard Self.theirs.contains(option) else { return [Self.IAC, Self.DONT, option] }
            guard !himEnabled.contains(option) else { return [] }
            himEnabled.insert(option)
            return asked ? [] : [Self.IAC, Self.DO, option]
        case Self.WONT:
            if option == Self.ECHO { echoAnswered = true }
            himAsked.remove(option)
            guard himEnabled.remove(option) != nil else { return [] }
            return [Self.IAC, Self.DONT, option]
        case Self.DO:
            let asked = usAsked.remove(option) != nil
            guard Self.ours.contains(option) else { return [Self.IAC, Self.WONT, option] }
            guard !usEnabled.contains(option) else { return [] }
            usEnabled.insert(option)
            var out: [UInt8] = asked ? [] : [Self.IAC, Self.WILL, option]
            if option == Self.NAWS {
                sentSize = nil
                out += nawsIfChanged()
            }
            return out
        default: // DONT
            usAsked.remove(option)
            guard usEnabled.remove(option) != nil else { return [] }
            return [Self.IAC, Self.WONT, option]
        }
    }

    private func subnegotiation(_ body: [UInt8]) -> [UInt8] {
        guard body.count >= 2, body[0] == Self.TTYPE, body[1] == Self.SEND,
              usEnabled.contains(Self.TTYPE) else { return [] }
        return [Self.IAC, Self.SB, Self.TTYPE, Self.IS] + Array(Self.terminalType.utf8) + [Self.IAC, Self.SE]
    }

    private mutating func nawsIfChanged() -> [UInt8] {
        guard usEnabled.contains(Self.NAWS) else { return [] }
        let cols = min(max(size.cols, 1), 0xFFFF), rows = min(max(size.rows, 1), 0xFFFF)
        if let sentSize, sentSize == (cols, rows) { return [] }
        sentSize = (cols, rows)
        var out: [UInt8] = [Self.IAC, Self.SB, Self.NAWS]
        // A 255 inside the four size bytes is doubled like any other IAC.
        for byte in [UInt8(cols >> 8), UInt8(cols & 0xFF), UInt8(rows >> 8), UInt8(rows & 0xFF)] {
            out.append(byte)
            if byte == Self.IAC { out.append(Self.IAC) }
        }
        return out + [Self.IAC, Self.SE]
    }
}
