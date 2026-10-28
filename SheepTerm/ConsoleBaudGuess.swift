import Foundation

// "Garbled? Try 115200" (6.0 (12), the user 2026-10-28): an Aruba CX's RJ45
// console runs 115200, and through a generic console cable (FTDI, Prolific,
// CH340) `ConsoleBaud` cannot know that — the tab opens at 9600 and shows
// junk until the speed is changed by hand.
//
// What a UART makes of a line at the wrong speed (Tests: the bit-level
// 8N1 simulator in ConsoleBaudGuessTests replays real logs through it):
// - fast sent, read slow (115200 → 9600): every received byte samples ~12
//   sent bits, so it is noise — much of it ≥ 0x80 and not UTF-8 or a stray
//   control, and only a twelfth as many bytes as were sent;
// - slow sent, read fast (9600 → 115200): every sent falling edge becomes a
//   framing-error 0x00 (one sent bit outlasts a whole received frame).
// Real device output — a banner, ANSI colour, Thai UTF-8, a login prompt —
// is printable ASCII, valid UTF-8, the usual controls and escape sequences,
// with essentially NO junk; the gap is wide, so the rule can be simple.
//
// Passive: fed the bytes a serial session RECEIVES; nothing is ever sent.
// Foundation only and in `sharedSources` (root Package.swift) so SheepTerm
// for Windows asks the same rule.
public nonisolated enum ConsoleBaudGuess {
    /// Which speeds to offer, in order: the Aruba CX's 115200 first (the
    /// case that made this), then the network-gear standard, then the rest.
    public static let order = [115_200, 9_600, 38_400, 57_600, 19_200, 230_400]

    /// Whether the line counts as busy for the hint (`Detector.feed`): an
    /// XMODEM transfer, a Safe Paste paced run — or the top-right status HUD
    /// still on screen (6.0 (12) review: between a transfer's or run's end
    /// and the HUD going away, a hint could land on top of it; the bytes
    /// then are still the protocol's tail, not the device's text).
    public static func lineBusy(transferring: Bool, pacingPaste: Bool, statusHUDShown: Bool) -> Bool {
        transferring || pacingPaste || statusHUDShown
    }

    /// The next speed to offer at `current` after `tried` (this tab session):
    /// nil when every one has been tried.
    public static func suggestion(current: Int, tried: Set<Int>) -> Int? {
        order.first { $0 != current && !tried.contains($0) }
    }

    /// The decision: at least `minJunk` junk bytes among the last `window`
    /// classified. Not a share of junk: a table of spaces re-read at the
    /// wrong speed comes out mostly as printable punctuation ('!', '#', '1'),
    /// so the junk in a mismatch can be as little as a tenth; while in every
    /// real capture (Tests: 165 logs, 11.9 MB) no window of 128 holds even
    /// ONE junk byte. 12 is above a cable's plug-in noise.
    public static let window = 128
    public static let minJunk = 12
    /// NUL is not junk on its own: a FortiGate pads every BS with twelve
    /// of them, a console server puts one after CR. A slow line read fast
    /// is NOTHING but NULs, so a run this long with no other byte decides.
    public static let nulRun = 32

    /// Streaming classifier + sliding window. `consume` answers true ONCE,
    /// on the chunk that tipped it; `reset()` re-arms it (a new speed).
    public struct Detector: Sendable {
        /// What is in the window (true = junk), as a ring.
        private var ring = [Bool](repeating: false, count: ConsoleBaudGuess.window)
        private var head = 0
        private var filled = 0
        private var junk = 0
        public private(set) var fired = false
        private var nuls = 0

        // Classifier state, carried across chunks.
        private enum Mode: Sendable { case text, escape, csi, string, charset }
        private var mode = Mode.text
        /// Bytes of the escape sequence / UTF-8 sequence being read: they
        /// are counted when it ends (good) or breaks (junk).
        private var pending = 0
        private var utf8Left = 0
        private var utf8Min: UInt8 = 0x80, utf8Max: UInt8 = 0xBF
        private var stringLength = 0

        public init() {}

        public mutating func reset() {
            self = Detector()
        }

        /// `consume` for a serial tab whose line may be BUSY — a Safe Paste
        /// paced run or an XMODEM send. Both own the terminal's top-right
        /// corner (their progress HUD) where the hint sits, and what comes
        /// back meanwhile (the echo of pasted lines, ACK/NAK) is not the
        /// device's own text. So a busy line is never judged and starts the
        /// detector over (a hint already fired re-arms): after the run, only
        /// the stream that arrives THEN can bring the hint back — it shows
        /// again if the line is still garbled, and not if it is clean.
        public mutating func feed(_ bytes: [UInt8], lineBusy: Bool) -> Bool {
            if lineBusy {
                reset()
                return false
            }
            return consume(bytes)
        }

        /// Classifies `bytes`; true once when the stream looks like a speed
        /// mismatch.
        public mutating func consume(_ bytes: [UInt8]) -> Bool {
            guard !fired else { return false }
            for byte in bytes {
                if byte == 0x00, utf8Left == 0, mode == .text {
                    nuls += 1
                    if nuls >= ConsoleBaudGuess.nulRun { fired = true; return true }
                    continue
                }
                nuls = 0
                classify(byte)
                if junk >= ConsoleBaudGuess.minJunk {
                    fired = true
                    return true
                }
            }
            return false
        }

        private mutating func note(_ isJunk: Bool, count: Int = 1) {
            for _ in 0..<count {
                if filled == ring.count {
                    if ring[head] { junk -= 1 }
                } else {
                    filled += 1
                }
                ring[head] = isJunk
                if isJunk { junk += 1 }
                head = (head + 1) % ring.count
            }
        }

        /// The sequence being read broke on `byte`: what it held was junk,
        /// and `byte` starts over as plain text.
        private mutating func broke(on byte: UInt8) {
            note(true, count: pending)
            pending = 0
            utf8Left = 0
            mode = .text
            classify(byte)
        }

        private mutating func classify(_ byte: UInt8) {
            if utf8Left > 0 {
                guard byte >= utf8Min, byte <= utf8Max else { return broke(on: byte) }
                pending += 1
                utf8Min = 0x80; utf8Max = 0xBF
                utf8Left -= 1
                if utf8Left == 0 { note(false, count: pending); pending = 0 }
                return
            }
            switch mode {
            case .text:
                text(byte)
            case .escape:
                pending += 1
                switch byte {
                case 0x5B: mode = .csi                               // ESC [
                case 0x5D, 0x50, 0x5F, 0x5E, 0x58:                   // OSC, DCS, APC, PM, SOS
                    mode = .string; stringLength = 0
                case 0x28, 0x29, 0x2A, 0x2B, 0x23, 0x25, 0x20:       // charset / DEC line / ESC SP
                    mode = .charset
                case 0x30...0x7E:                                    // ESC 7, ESC =, ESC M …
                    note(false, count: pending); pending = 0; mode = .text
                default:
                    pending -= 1
                    broke(on: byte)
                }
            case .charset:
                pending += 1
                if (0x20...0x7E).contains(byte) {
                    note(false, count: pending); pending = 0; mode = .text
                } else {
                    pending -= 1
                    broke(on: byte)
                }
            case .csi:
                switch byte {
                case 0x20...0x3F:                                    // parameters, intermediates
                    pending += 1
                    if pending > 40 { broke(on: byte) }
                case 0x40...0x7E:                                    // final
                    note(false, count: pending + 1); pending = 0; mode = .text
                default:
                    broke(on: byte)
                }
            case .string:
                // Ends on BEL or ESC \ (ST); printable / UTF-8 inside.
                if byte == 0x07 || byte == 0x9C {
                    note(false, count: pending + 1); pending = 0; mode = .text
                } else if byte == 0x1B {
                    note(false, count: pending); pending = 1; mode = .escape
                } else if (0x20...0x7E).contains(byte) || byte >= 0x80 {
                    pending += 1
                    stringLength += 1
                    if stringLength > 512 { note(false, count: pending); pending = 0; mode = .text }
                } else {
                    broke(on: byte)
                }
            }
        }

        private mutating func text(_ byte: UInt8) {
            switch byte {
            case 0x20...0x7E:
                note(false)
            case 0x1B:
                pending = 1
                mode = .escape
            // BEL BS TAB LF VT FF CR SO SI, XON XOFF: what a device sends.
            case 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x13:
                note(false)
            case 0xC2...0xDF:
                pending = 1; utf8Left = 1
            case 0xE0:
                pending = 1; utf8Left = 2; utf8Min = 0xA0
            case 0xE1...0xEC, 0xEE, 0xEF:
                pending = 1; utf8Left = 2
            case 0xED:
                pending = 1; utf8Left = 2; utf8Max = 0x9F
            case 0xF0:
                pending = 1; utf8Left = 3; utf8Min = 0x90
            case 0xF1...0xF3:
                pending = 1; utf8Left = 3
            case 0xF4:
                pending = 1; utf8Left = 3; utf8Max = 0x8F
            default:
                // The other C0 controls, DEL, a stray continuation
                // byte, C0/C1/F5–FF leads: nothing a device prints.
                note(true)
            }
        }
    }
}
