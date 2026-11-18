import Foundation

// The device's SSH login banner (SSH_MSG_USERAUTH_BANNER, 6.1 (58)) — the
// "Authorized access only" text a switch sends before the password is
// checked. Printed into the terminal above the shell's output, the way
// OpenSSH and PuTTY show it (`SSHTerminalController.printBanner`); never a
// page of the connection card, never the session log. Foundation only and in
// `sharedSources` (root Package.swift): Windows and Linux show it the same.
// ARCHITECTURE.md §4 "SSH".
//
// The text is the server's, received BEFORE authentication, so nothing in it
// may reach the terminal as a control: each line goes through the same
// character table as every other piece of server text (`printable`), which
// this file owns. A server may send any number of banner messages, each up to
// a whole packet, so what one connection prints is capped (`Budget`).
//
// The same path carries the other texts a login sends to the PERSON and that
// have no other place: a keyboard-interactive round's name and instruction
// (`interactiveText` — where PAM / RADIUS / TACACS say "your password expires
// in 3 days", a disclaimer, the text of a challenge; a round with no prompts
// is nothing else) and the server's words with a password-change request.
// They share the one budget, and a block already printed in this login is not
// printed again (servers repeat the instruction on every retry round).

public nonisolated enum LoginBanner {
    /// Lines printed per connection, across every banner message.
    public static let maxLines = 64
    /// UTF-8 bytes of text printed per connection, across every banner message.
    public static let maxBytes = 8 * 1024
    /// Unicode scalars per line (not characters: one character can carry
    /// thousands of combining marks). A longer line is cut and ends in "…",
    /// so one endless line cannot fill the scrollback on its own.
    public static let maxLineScalars = 512
    /// Tab stops in a banner line, every 8 columns (a terminal's default).
    public static let tabStop = 8

    /// THE table for server text reaching the terminal (version line,
    /// DISCONNECT reason, algorithm names, prompts, the banner): C0/C1
    /// controls, DEL and bidi controls become U+FFFD; line breaks and tabs a
    /// space. An escape sequence there could rewrite the clipboard (OSC 52)
    /// or repaint a forged host-key warning. (OpenSSH strnvis-escapes the
    /// same strings.) The bidi set is every explicit directional formatting
    /// character: the embeddings/overrides (U+202A–202E), the isolates
    /// (U+2066–2069) AND the three marks — LRM U+200E, RLM U+200F, ALM U+061C
    /// — which reorder neutral runs (digits, "-", ":") just as well and are
    /// enough to make "host key refused" text or a fingerprint read
    /// differently. `SSHWorker.printable` is this, scalar by scalar.
    public static func printable(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D: return " "
        case 0x00...0x1F, 0x7F, 0x80...0x9F, 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return "\u{FFFD}"
        default: return scalar
        }
    }

    /// One banner message as printable lines, broken where a terminal would
    /// break it:
    /// - a run of one or more CR followed by LF is ONE break with that LF
    ///   (CRLF, and the CR CR LF some gear ends lines with — single-spaced);
    /// - LF alone is a break, and one CR right after it belongs to it (LFCR,
    ///   as old gear sends it) — unless that CR starts a CR run ending in LF,
    ///   which is then its own break: "A\n\r\r\nB" is LF, then CR CR LF —
    ///   two breaks, ["A", "", "B"], as a terminal draws two line feeds;
    /// - every other CR is a break of its own ("A\r\rB" → ["A", "", "B"]).
    /// A tab is spaces up to the next stop of `tabStop`, as the terminal would
    /// draw it (6.1 (61)): a banner whose columns are lined up with tabs stays
    /// lined up (columns counted in scalars, like the cut). Everywhere else a
    /// tab stays one space (`printable`) — those texts are one line.
    /// Each line goes through `printable` and is cut at `maxLineScalars`;
    /// trailing blank lines dropped (inner and leading ones kept). Blank or
    /// empty → []. Not budgeted — `Budget.take` is what the worker calls.
    public static func lines(_ banner: String) -> [String] {
        var out: [String] = []
        var line = String.UnicodeScalarView()
        var count = 0
        var cut = false
        func endLine() {
            let text = String(line)
            // A cut line of spaces alone (a run of tabs) stays blank, so the
            // trailing-blank rule below still drops it.
            out.append(text + (cut && !isBlank(text) ? "…" : ""))
            line = String.UnicodeScalarView()
            count = 0
            cut = false
        }
        func put(_ scalar: Unicode.Scalar) {
            if count < maxLineScalars {
                line.append(scalar)
                count += 1
            } else {
                cut = true
            }
        }
        let scalars = Array(banner.unicodeScalars)
        /// The end of the CR run starting at `i` (the first index past it).
        func endOfCRs(from i: Int) -> Int {
            var j = i
            while j < scalars.count, scalars[j] == "\r" { j += 1 }
            return j
        }
        func isLineFeed(_ j: Int) -> Bool { j < scalars.count && scalars[j] == "\n" }
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "\r" {
                // The whole run at once: a run of CRs is scanned once, never
                // once per CR (a packet of bare CRs stays linear).
                let end = endOfCRs(from: i)
                if isLineFeed(end) {
                    endLine()
                    i = end + 1
                } else {
                    for _ in i..<end { endLine() }
                    i = end
                }
                continue
            }
            if scalar == "\n" {
                endLine()
                i += 1
                if i < scalars.count, scalars[i] == "\r", !isLineFeed(endOfCRs(from: i)) { i += 1 }
                continue
            }
            i += 1
            if scalar == "\t" {
                for _ in 0..<(tabStop - count % tabStop) { put(" ") }
                continue
            }
            put(printable(scalar))
        }
        endLine()
        while let last = out.last, isBlank(last) { out.removeLast() }
        return out
    }

    private static func isBlank(_ line: String) -> Bool {
        line.unicodeScalars.allSatisfy { $0 == " " }
    }

    /// What a keyboard-interactive INFO_REQUEST says to the person: its name,
    /// then its instruction, each only when not blank; "" = nothing. The
    /// prompts are not here — they are the card's questions.
    public static func interactiveText(name: String, instruction: String) -> String {
        [name, instruction].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    /// What one connection may still print. One per `authenticate` run (a
    /// jump hop has its own): every banner message, interactive name and
    /// instruction and password-change text of that login draws on it.
    public struct Budget: Sendable {
        public private(set) var linesUsed = 0
        public private(set) var bytesUsed = 0
        /// Set once something was dropped; nothing is printed after it.
        public private(set) var exhausted = false
        /// Every block printed so far (bounded by the budget itself).
        private var shown: [[String]] = []

        public init() {}

        /// The lines of `banner` still in budget, whole lines only. `truncated`
        /// is true exactly once per connection — on the message where the
        /// budget ran out — so the caller prints one "truncated" notice. A
        /// block identical to one already printed in this login yields
        /// nothing: a wrong password must not stack copies of the instruction
        /// the server sends again with every round.
        public mutating func take(_ banner: String) -> (lines: [String], truncated: Bool) {
            guard !exhausted else { return ([], false) }
            let block = LoginBanner.lines(banner)
            guard !block.isEmpty, !shown.contains(block) else { return ([], false) }
            shown.append(block)
            var kept: [String] = []
            for line in block {
                let bytes = line.utf8.count
                guard linesUsed < LoginBanner.maxLines, bytesUsed + bytes <= LoginBanner.maxBytes else {
                    exhausted = true
                    return (kept, true)
                }
                linesUsed += 1
                bytesUsed += bytes
                kept.append(line)
            }
            return (kept, false)
        }
    }
}
