import Foundation

// XMODEM / XMODEM-1K / YMODEM sender for pushing an image to a device in
// ROMMON / BootROM over a serial console (Cisco `xmodem -c`, Huawei/Aruba/
// Comware "download via XMODEM"). Sans-I/O and Foundation only: the serial
// worker owns the port, feeds whatever the device sends into `receive`, calls
// `tick` when `nextDeadline` passes, and writes back whatever either returns.
// Time is injected, so every retry and timeout path is covered by the
// standalone harness (Tests/tests/XModemTests.swift) without a cable.
//
// Behaviour follows Chuck Forsberg's "XMODEM/YMODEM PROTOCOL REFERENCE"
// (ymodem.txt, 1988) and what lrzsz's `sz` does where the text leaves room.

/// One file sent with XMODEM, XMODEM-1K or (a batch of one) YMODEM.
public nonisolated struct XModemSender: Sendable {
    public enum Mode: Sendable, Equatable {
        /// 128-byte SOH blocks.
        case xmodem
        /// 1024-byte STX blocks; a tail of ≤ 128 bytes goes as one SOH block.
        case xmodem1K
        /// Block 0 header (name + size), then 1K data blocks, then the
        /// empty block 0 that ends the batch.
        case ymodem
    }

    public enum Failure: Sendable, Equatable {
        /// No `C`/NAK within `startTimeout` (or, in YMODEM, after the header).
        case noReceiver
        /// Two CANs in a row from the device.
        case receiverCancelled
        /// One block was refused or unanswered `maxAttempts` times. Block 0
        /// is the YMODEM header; data blocks count from 1 and do not wrap.
        case tooManyRetries(block: Int)
        /// The end of transmission was never acknowledged.
        case eotNotAcknowledged
        case cancelledByUser
        /// Never set by the sender: its driver's session (the serial port)
        /// ended under it.
        case sessionEnded
    }

    public enum Phase: Sendable, Equatable {
        case waitingForReceiver
        case sending
        case finishing
        case done
        case failed(Failure)
    }

    public static let SOH: UInt8 = 0x01
    public static let STX: UInt8 = 0x02
    public static let EOT: UInt8 = 0x04
    public static let ACK: UInt8 = 0x06
    public static let BS: UInt8 = 0x08
    public static let NAK: UInt8 = 0x15
    public static let CAN: UInt8 = 0x18
    public static let SUB: UInt8 = 0x1A
    public static let crcStart: UInt8 = 0x43   // "C"

    /// The reference's receiver retries its `C`/NAK for about a minute;
    /// a device still printing its banner gets the same.
    public static let startTimeout: Double = 60
    /// Per-block answer timeout (the reference's 10 s).
    public static let answerTimeout: Double = 10
    /// Transmissions of one block before giving up — sz's RETRYMAX: the
    /// original plus nine resends, i.e. the tenth NAK/timeout fails.
    public static let maxAttempts = 10

    /// 8×CAN then 8×BS: sz's abort. The backspaces erase the CANs if the
    /// device has already dropped back to its command line.
    public static let cancelSequence: [UInt8] =
        [UInt8](repeating: 0x18, count: 8) + [UInt8](repeating: 0x08, count: 8)

    private enum Stage: Sendable, Equatable {
        case awaitStart
        case awaitHeaderAck
        case awaitDataStart
        case awaitBlockAck
        case awaitEOTAck
        case awaitBatchEnd
        case awaitNullAck
        case done
        case failed(Failure)
    }

    public let mode: Mode
    /// The name as it goes into the YMODEM header (`ymodemName`).
    public let fileName: String
    public var totalBytes: Int { data.count }
    /// Payload bytes of acknowledged blocks — padding never counts.
    public private(set) var bytesAcknowledged = 0
    public private(set) var nextDeadline: Double?
    /// The bytes of the last `receive` that came after the transfer ended —
    /// the driver hands them to the terminal.
    public private(set) var leftover: [UInt8] = []

    // Never mutated, so the struct's own mutation never copies the image.
    private let data: [UInt8]
    private var stage: Stage = .awaitStart
    private var useCRC = true
    private var blockSize = 128
    private var offset = 0          // first data byte of the block in flight
    private var blockLength = 0     // payload bytes of the block in flight
    private var blockIndex = 0      // 1-based, unwrapped
    private var attempts = 0
    private var sawCAN = false
    private var previousByte: UInt8 = 0

    public init(data: [UInt8], fileName: String, mode: Mode, now: Double) {
        self.data = data
        self.mode = mode
        self.fileName = XModemSender.ymodemName(fileName)
        self.nextDeadline = now + XModemSender.startTimeout
    }

    public var phase: Phase {
        switch stage {
        case .awaitStart: return .waitingForReceiver
        case .awaitHeaderAck, .awaitDataStart, .awaitBlockAck: return .sending
        case .awaitEOTAck, .awaitBatchEnd, .awaitNullAck: return .finishing
        case .done: return .done
        case .failed(let f): return .failed(f)
        }
    }

    private var isFinished: Bool {
        switch stage {
        case .done, .failed: return true
        default: return false
        }
    }

    // MARK: - Driving

    /// Bytes from the device, in any chunking: each byte is handled in turn,
    /// so a chunk holding several answers can produce several frames
    /// (concatenated in order).
    public mutating func receive(_ bytes: [UInt8], now: Double) -> [UInt8] {
        var out: [UInt8] = []
        leftover = []
        for (index, b) in bytes.enumerated() {
            defer { previousByte = b; lastByteAt = now }
            if isFinished {
                // The device talks again after the end ("Download complete",
                // its prompt): that is the terminal's, not the protocol's.
                leftover = Array(bytes[index...])
                break
            }
            if b == Self.CAN {
                // One CAN is line noise; two in a row is the receiver aborting.
                if sawCAN {
                    finish(.failed(.receiverCancelled))
                    leftover = Array(bytes[(index + 1)...])
                    break
                }
                sawCAN = true
                continue
            }
            sawCAN = false
            // The device's banner ("Cisco …", "Ready to receive file …") may
            // hold a capital C. A receiver's C stands alone or in a run of
            // C's; a run touching any other printable character is text,
            // and taking it would send block 1 to a device not listening yet
            // — 10 s and a retry lost.
            if stage == .awaitStart, b == Self.crcStart {
                if pendingStart != nil { continue }              // the run goes on
                // After a quiet moment a C starts afresh: banner text comes
                // in a burst, a receiver polls seconds apart — a prompt that
                // ends in "now." must not lock its later C's out (review 3).
                let fresh = now - lastByteAt >= Self.startSettle
                if !fresh, previousByte == Self.crcStart ? runIsText : Self.isWordByte(previousByte) {
                    runIsText = true
                    continue
                }
                var end = index + 1
                while end < bytes.count, bytes[end] == Self.crcStart { end += 1 }
                guard end < bytes.count else {
                    // The run ends the chunk (a slow console delivers a byte
                    // at a time): the next byte, or a moment of quiet, says.
                    pendingStart = nextDeadline
                    nextDeadline = now + Self.startSettle
                    continue
                }
                if Self.isWordByte(bytes[end]) { runIsText = true; continue }
            } else if let restore = pendingStart {
                // The byte after a run that ended the last chunk.
                pendingStart = nil
                nextDeadline = restore
                if Self.isWordByte(b) {
                    runIsText = true
                } else {
                    handle(Self.crcStart, now: now, into: &out)
                }
            }
            if b != Self.crcStart { runIsText = false }
            handle(b, now: now, into: &out)
        }
        return out
    }

    /// How long a C at the end of a chunk waits for the byte after it.
    public static let startSettle: Double = 0.1
    /// A C waiting for its next byte: holds the deadline it displaced.
    private var pendingStart: Double??
    /// The current run of C's was found to be part of a word.
    private var runIsText = false
    /// When the last byte arrived (`receive`'s `now`).
    private var lastByteAt = -Double.infinity

    /// Any printable character but `C` and space: a receiver's C stands
    /// beside another C, a control byte or nothing — `(C)`, `+C>`, `Cisco`
    /// are banner text (review 5.0 (22): Huawei's "Copyright (C)", Comware's
    /// "Press <Ctrl+C>").
    private static func isWordByte(_ b: UInt8) -> Bool {
        b != crcStart && b > 0x20 && b < 0x7F
    }

    public mutating func tick(now: Double) -> [UInt8] {
        guard !isFinished, let deadline = nextDeadline, now >= deadline else { return [] }
        var out: [UInt8] = []
        if let restore = pendingStart {
            // Nothing followed the C: it stood alone — a receiver's start.
            pendingStart = nil
            nextDeadline = restore
            handle(Self.crcStart, now: now, into: &out)
            return out
        }
        switch stage {
        case .awaitStart, .awaitDataStart:
            finish(.failed(.noReceiver))
        case .awaitHeaderAck, .awaitBlockAck, .awaitEOTAck, .awaitNullAck:
            retry(now: now, into: &out)
        case .awaitBatchEnd:
            // The EOT was acknowledged, so the file is delivered; the empty
            // block 0 only closes the batch and is not worth failing over.
            finish(.done)
        case .done, .failed:
            break
        }
        return out
    }

    public mutating func cancel() -> [UInt8] {
        guard !isFinished else { return [] }
        finish(.failed(.cancelledByUser))
        return Self.cancelSequence
    }

    private mutating func finish(_ end: Stage) {
        stage = end
        nextDeadline = nil
    }

    private mutating func handle(_ b: UInt8, now: Double, into out: inout [UInt8]) {
        switch stage {
        case .awaitStart:
            // Banner text and anything else is ignored until C or NAK.
            guard b == Self.crcStart || b == Self.NAK else { return }
            negotiate(b)
            if mode == .ymodem {
                stage = .awaitHeaderAck
                attempts = 1
                sendHeader(now: now, into: &out)
            } else {
                sendNextBlock(now: now, into: &out)
            }
        case .awaitHeaderAck:
            // A `C` here is a receiver still repeating its start, never an ACK.
            if b == Self.ACK {
                stage = .awaitDataStart
                nextDeadline = now + Self.startTimeout
            } else if b == Self.NAK {
                retry(now: now, into: &out)
            }
        case .awaitDataStart:
            guard isStartByte(b) else { return }
            negotiate(b)
            sendNextBlock(now: now, into: &out)
        case .awaitBlockAck:
            if b == Self.ACK {
                offset += blockLength
                bytesAcknowledged = min(offset, data.count)
                sendNextBlock(now: now, into: &out)
            } else if b == Self.NAK {
                retry(now: now, into: &out)
            }
        case .awaitEOTAck:
            // Many receivers NAK the first EOT (to rule out a line-noise EOT);
            // a direct ACK is accepted too.
            if b == Self.ACK {
                if mode == .ymodem {
                    stage = .awaitBatchEnd
                    nextDeadline = now + Self.answerTimeout
                } else {
                    finish(.done)
                }
            } else if b == Self.NAK {
                retry(now: now, into: &out)
            }
        case .awaitBatchEnd:
            guard isStartByte(b) else { return }
            negotiate(b)
            stage = .awaitNullAck
            attempts = 1
            sendNullBlock(now: now, into: &out)
        case .awaitNullAck:
            if b == Self.ACK { finish(.done) } else if b == Self.NAK { retry(now: now, into: &out) }
        case .done, .failed:
            break
        }
    }

    /// After the YMODEM header (and after EOT) the receiver asks again. `C`
    /// always means CRC; a NAK there only counts when checksum was already
    /// in use, because a CRC receiver's NAK is about a block, not a start.
    private func isStartByte(_ b: UInt8) -> Bool {
        b == Self.crcStart || (b == Self.NAK && !useCRC)
    }

    /// `C` = CRC-16; NAK = 8-bit checksum. A checksum receiver also gets
    /// 128-byte blocks even in 1K/YMODEM mode: the reference allows 1K blocks
    /// only with CRC (a one-byte sum over 1024 bytes misses too much), and a
    /// receiver old enough to want checksums may not take STX at all.
    private mutating func negotiate(_ b: UInt8) {
        useCRC = b == Self.crcStart
        blockSize = (mode == .xmodem || !useCRC) ? 128 : 1024
    }

    private mutating func retry(now: Double, into out: inout [UInt8]) {
        if attempts >= Self.maxAttempts {
            switch stage {
            case .awaitNullAck:
                finish(.done)   // see .awaitBatchEnd in tick
            case .awaitEOTAck:
                finish(.failed(.eotNotAcknowledged))
                out += Self.cancelSequence
            case .awaitHeaderAck:
                finish(.failed(.tooManyRetries(block: 0)))
                out += Self.cancelSequence
            default:
                finish(.failed(.tooManyRetries(block: blockIndex)))
                out += Self.cancelSequence
            }
            return
        }
        attempts += 1
        switch stage {
        case .awaitHeaderAck: sendHeader(now: now, into: &out)
        case .awaitBlockAck: sendCurrentBlock(now: now, into: &out)
        case .awaitEOTAck: out.append(Self.EOT); nextDeadline = now + Self.answerTimeout
        case .awaitNullAck: sendNullBlock(now: now, into: &out)
        default: break
        }
    }

    // MARK: - Frames

    private mutating func sendNextBlock(now: Double, into out: inout [UInt8]) {
        attempts = 1
        let remaining = data.count - offset
        if remaining <= 0 {
            stage = .awaitEOTAck
            out.append(Self.EOT)
            nextDeadline = now + Self.answerTimeout
            return
        }
        stage = .awaitBlockAck
        blockIndex += 1
        blockLength = min(remaining, blockSize)
        sendCurrentBlock(now: now, into: &out)
    }

    private mutating func sendCurrentBlock(now: Double, into out: inout [UInt8]) {
        // A tail of ≤ 128 bytes in 1K mode goes as a 128-byte SOH block: at
        // 9600 baud a padded 1K block costs ~1 s for nothing.
        let frame = blockLength <= 128 ? 128 : 1024
        appendFrame(into: &out, number: UInt8(truncatingIfNeeded: blockIndex),
                    body: data[offset..<(offset + blockLength)], size: frame, pad: Self.SUB)
        nextDeadline = now + Self.answerTimeout
    }

    private mutating func sendHeader(now: Double, into out: inout [UInt8]) {
        let body = Self.headerPayload(fileName: fileName, size: data.count)
        appendFrame(into: &out, number: 0, body: body[...], size: 128, pad: 0)
        nextDeadline = now + Self.answerTimeout
    }

    private mutating func sendNullBlock(now: Double, into out: inout [UInt8]) {
        appendFrame(into: &out, number: 0, body: [], size: 128, pad: 0)
        nextDeadline = now + Self.answerTimeout
    }

    private func appendFrame(into out: inout [UInt8], number: UInt8, body: ArraySlice<UInt8>,
                             size: Int, pad: UInt8) {
        out.reserveCapacity(out.count + 3 + size + 2)
        out.append(size == 1024 ? Self.STX : Self.SOH)
        out.append(number)
        out.append(~number)
        let start = out.count
        out.append(contentsOf: body)
        if body.count < size { out.append(contentsOf: repeatElement(pad, count: size - body.count)) }
        let payload = out[start..<out.count]
        if useCRC {
            let crc = Self.crc16(payload)
            out.append(UInt8(crc >> 8))
            out.append(UInt8(crc & 0xFF))
        } else {
            out.append(Self.checksum(payload))
        }
    }

    // MARK: - Pure helpers

    /// CRC-16/XMODEM: poly 0x1021, init 0, no reflection, no final XOR.
    public static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        let table = crcTable
        for b in bytes {
            crc = (crc << 8) ^ table[Int(UInt8(crc >> 8) ^ b)]
        }
        return crc
    }

    public static func crc16(_ bytes: [UInt8]) -> UInt16 { crc16(bytes[...]) }

    /// The original XMODEM check: the low 8 bits of the byte sum.
    public static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var sum: UInt8 = 0
        for b in bytes { sum &+= b }
        return sum
    }

    private static let crcTable: [UInt16] = (0..<256).map { i -> UInt16 in
        var c = UInt16(i) << 8
        for _ in 0..<8 { c = (c & 0x8000) != 0 ? (c << 1) ^ 0x1021 : c << 1 }
        return c
    }

    /// YMODEM wants a bare name ("no spaces", ASCII): the last path component
    /// with every non-printable-ASCII character (and space) turned into `_`.
    /// BootROM menus echo this name back, so a stable ASCII form matters more
    /// than fidelity.
    public static func ymodemName(_ path: String) -> String {
        let base = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let safe = String(base.map { c -> Character in
            if let a = c.asciiValue, a > 0x20, a < 0x7F { return c }
            return "_"
        })
        return safe.isEmpty ? "file" : safe
    }

    /// Block 0's body: name, NUL, decimal size, NUL (the frame pads the rest
    /// with zeros). A name too long for the 128-byte block keeps its
    /// extension and loses the end of its stem.
    public static func headerPayload(fileName: String, size: Int) -> [UInt8] {
        let sizeField = Array(String(size).utf8)
        var name = Array(fileName.utf8)
        let room = 128 - 2 - sizeField.count
        if name.count > room {
            let ext: [UInt8]
            if let dot = name.lastIndex(of: UInt8(ascii: ".")), name.count - dot <= 16, dot > 0 {
                ext = Array(name[dot...])
            } else {
                ext = []
            }
            name = Array(name.prefix(room - ext.count)) + ext
        }
        return name + [0] + sizeField + [0]
    }
}
