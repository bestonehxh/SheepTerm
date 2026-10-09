import Darwin
import Foundation

/// Names a session after the device's own prompt (5.0 (1)).
///
/// A serial session is called after its cable (`cu.usbserial-1420`) and an
/// SSH session typed as a bare address after that address, so ten console
/// logs in a row were ten `cu.usbserial-1420 <stamp>.log`. Once the device's
/// prompt has been seen, the tab and the open log take its name instead:
/// `Core-SW (cu.usbserial-1420)` / `Core-SW (cu.usbserial-1420) <stamp>.log`.
///
/// Modelled on `VendorFingerprint`: PASSIVE (the app never sends a byte to
/// provoke a prompt — a console nobody pressed Enter on keeps the cable
/// name), ONE-SHOT (decide once, then the controller drops the detector), and
/// BOUNDED (gives up after `byteBudget` bytes without a confident name).
///
/// What counts as a prompt: the line the cursor is sitting on at the END of a
/// chunk — the device has stopped talking and is waiting — matching one of
/// the prompt shapes in `name(inLine:)`. One sighting is not enough: banners
/// and MOTDs end in `#` or `>` too, so the SAME name must be seen on at least
/// two separate prompt lines (`requiredSightings`). A line counts once no
/// matter how many chunk ends land on it (a byte-at-a-time stream reaches
/// `Core-SW#` and then `Core-SW# ` on the same line).
///
/// Cost: per chunk, at most the last `maxLineBytes` raw bytes are looked at
/// (the line at the cursor), never the whole chunk — so a 4 MB `show tech`
/// burst costs the same as a keystroke echo. Pure, no AppKit — compiled into
/// `Tests/run.sh tests` (PromptNameTests).
nonisolated struct PromptNameDetector {
    /// Give up after this much output without a confident name. A console
    /// boot log runs to tens of KB before "Press RETURN"; a megabyte covers
    /// that with room to spare and still ends the scan on a `show tech`.
    static let byteBudget = 1 << 20
    /// Same name on this many separate prompt lines before it is believed.
    static let requiredSightings = 2
    /// Raw bytes (escapes included) one line may take before it is no prompt.
    static let maxLineBytes = 4096
    /// Printable characters a prompt line may hold.
    static let maxPrintable = 256
    /// Distinct candidate names remembered; junk past this is not counted.
    static let maxCandidates = 16

    /// The name, once locked. `consume` returns it exactly once.
    private(set) var locked: String?
    /// True once the budget is spent without a lock — the controller drops
    /// the detector either way.
    private(set) var gaveUp = false
    var finished: Bool { locked != nil || gaveUp }
    private(set) var consumed = 0

    // The line the cursor is on, as the terminal would show it (escapes
    // stripped, backspace honoured), carried across chunks.
    private var line: [UInt8] = []
    private var rawInLine = 0
    /// The text since the cursor last went to a fresh line is not a prompt
    /// (a control character, non-ASCII, too long). A cursor move clears it.
    private var tainted = false
    /// Too many raw bytes on one line: stop looking until a CR/LF. This is
    /// the cost bound, so unlike `tainted` a cursor move does not clear it.
    private var overflow = false
    /// The first parameter byte of the CSI being parsed (`2` of `ESC[2K`).
    private var csiParam: UInt8 = 0
    /// This line already produced a sighting.
    private var counted = false
    private var escape: EscapeState = .ground
    private var sightings: [(name: String, count: Int)] = []

    private enum EscapeState { case ground, esc, escIntermediate, csi, string, stringEsc }

    init() {}

    /// Feed what the terminal was just fed. Returns the name the first time
    /// it is confident, nil otherwise (and forever after).
    mutating func consume(_ chunk: [UInt8]) -> String? {
        guard !finished, !chunk.isEmpty else { return nil }
        consumed += chunk.count
        // Only the line the cursor ends on matters. Look back at most
        // `maxLineBytes` for its start; a line longer than that is no prompt.
        let lookBack = max(chunk.startIndex, chunk.endIndex - Self.maxLineBytes)
        var start: Int? = nil
        var i = chunk.endIndex
        while i > lookBack {
            i -= 1
            if chunk[i] == 0x0A || chunk[i] == 0x0D { start = i + 1; break }
        }
        if let start {
            resetLine()
            feedLine(chunk[start...])
        } else if chunk.count > Self.maxLineBytes {
            resetLine()
            overflow = true
        } else {
            feedLine(chunk[...])
        }
        if !tainted, !overflow, !counted, escape == .ground, let name = Self.name(inLine: line) {
            counted = true
            if let found = note(Self.knownDevice(inLine: line, among: sightings.map(\.name)) ?? name) {
                locked = found
                release()
                return found
            }
        }
        if consumed >= Self.byteBudget {
            gaveUp = true
            release()
        }
        return nil
    }

    private mutating func release() {
        line = []
        sightings = []
    }

    private mutating func resetLine() {
        line.removeAll(keepingCapacity: true)
        rawInLine = 0
        tainted = false
        overflow = false
        counted = false
        escape = .ground
    }

    /// The cursor went somewhere new without a CR/LF: the text after this
    /// point is a new line as far as a prompt is concerned.
    private mutating func startFreshLine() {
        line.removeAll(keepingCapacity: true)
        tainted = false
        counted = false
    }

    private mutating func note(_ name: String) -> String? {
        if let index = sightings.firstIndex(where: { $0.name == name }) {
            sightings[index].count += 1
            return sightings[index].count >= Self.requiredSightings ? name : nil
        }
        guard sightings.count < Self.maxCandidates else { return nil }
        sightings.append((name, 1))
        return Self.requiredSightings <= 1 ? name : nil
    }

    private mutating func feedLine(_ bytes: ArraySlice<UInt8>) {
        guard !overflow else { return }
        rawInLine += bytes.count
        if rawInLine > Self.maxLineBytes { overflow = true; return }
        for byte in bytes {
            switch escape {
            case .ground:
                switch byte {
                case 0x1B: escape = .esc
                case 0x08, 0x7F:
                    if !line.isEmpty { line.removeLast() }
                case 0x07, 0x00:
                    break                                  // BEL / NUL: no glyph
                case 0x20...0x7E:
                    guard !tainted else { break }
                    line.append(byte)
                    if line.count > Self.maxPrintable { tainted = true }
                default:
                    // Tab, other C0 controls, non-ASCII: not a prompt we name
                    // a file after. (Hostnames are ASCII by RFC 952/1123.)
                    tainted = true
                }
            case .esc:
                switch byte {
                case 0x5B: escape = .csi; csiParam = 0                        // [
                case 0x5D, 0x50, 0x5F, 0x5E, 0x58: escape = .string           // ] P _ ^ X
                case 0x20...0x2F: escape = .escIntermediate
                default: escape = .ground
                }
            case .escIntermediate:
                if (0x30...0x7E).contains(byte) { escape = .ground }
            case .csi:
                if (0x40...0x7E).contains(byte) {
                    escape = .ground
                    // A device that paints its prompt with cursor addressing
                    // (ArubaOS-Switch / ProCurve: `ESC[24;1H` then the prompt,
                    // no CR LF) starts a fresh line this way. Erase-line 1/2
                    // and erase-display too. Other CSIs (colour) change nothing.
                    switch byte {
                    case 0x48, 0x66, 0x47, 0x4A: startFreshLine()                  // H f G J
                    case 0x4B where csiParam == 0x31 || csiParam == 0x32: startFreshLine()   // K 1/2
                    default: break
                    }
                } else if csiParam == 0 {
                    csiParam = byte
                }
            case .string:
                if byte == 0x07 { escape = .ground } else if byte == 0x1B { escape = .stringEsc }
            case .stringEsc:
                escape = byte == 0x5C ? .ground : .string
            }
        }
    }

    // MARK: - prompt shapes

    /// A hostname as a prompt shows it: starts with a letter or digit, then
    /// letters, digits, `-`, `_`, `.`; at most 63 characters (one DNS label's
    /// limit, and plenty for a device name); at least one letter (an
    /// all-digit "name" is a counter or a page number, and an address is
    /// what the tab already says).
    static func isHostname<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
        guard let first = bytes.first, bytes.count <= 63, isAlnum(first) else { return false }
        var letter = false
        for b in bytes {
            if isAlpha(b) { letter = true; continue }
            if isDigit(b) || b == 0x2D || b == 0x5F || b == 0x2E { continue }
            return false
        }
        return letter && !denied.contains(String(decoding: bytes, as: UTF8.self).lowercased())
    }

    /// Words that sit alone at the end of a line in shapes a prompt has and
    /// are not device names: help output (`<cr>`), markup (`<div>`), and the
    /// answers a question offers.
    static let denied: Set<String> = [
        "cr", "more", "password", "username", "login", "yes", "no", "y", "n", "enter", "return",
        "html", "head", "body", "div", "span", "p", "br", "hr", "table", "tr", "td", "th", "li", "ul",
        "ol", "pre", "script", "style", "title", "meta", "link", "xml", "a", "b", "i",
        // Status words printed alone in brackets: Juniper's `[edit]` above
        // every config prompt, `[OK]` after `write memory`, `[confirm]`.
        "edit", "ok", "done", "confirm", "abort", "error", "warning", "info", "failed",
    ]

    @inline(__always) static func isAlpha(_ b: UInt8) -> Bool { (b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A }
    @inline(__always) static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    @inline(__always) static func isAlnum(_ b: UInt8) -> Bool { isAlpha(b) || isDigit(b) }
    @inline(__always) static func isNameByte(_ b: UInt8) -> Bool {
        isAlnum(b) || b == 0x2D || b == 0x5F || b == 0x2E
    }

    /// The device name a prompt line carries, or nil when the line is not a
    /// prompt. `line` is printable ASCII (the detector has already stripped
    /// escapes and refused anything else). Shapes, trailing spaces allowed:
    ///
    ///   Cisco / Aruba / Aruba CX   `Core-SW#` `Core-SW>` `Core-SW(config-if)#`
    ///   FortiGate                  `FGT60F # ` `FGT60F (vdom) # `
    ///   Huawei / H3C               `<HW-S5736>` `[HW-S5736]` `[~HW-S5736]`
    ///                              `[*HW-S5736-GigabitEthernet0/0/1]` → HW-S5736
    ///   Juniper / PAN-OS           `user@MX1>` `user@MX1#` → MX1
    ///   Linux                      `user@host:~$` `[user@host ~]$` `[admin@MikroTik] > `
    static func name(inLine line: [UInt8]) -> String? {
        var end = line.count
        while end > 0, line[end - 1] == 0x20 { end -= 1 }
        guard end >= 2 else { return nil }
        let body = line[0..<end]
        let last = body[end - 1]
        let first = body[0]

        // Huawei / H3C: the whole line is <NAME> or [~*NAME(-view)].
        if first == 0x3C, last == 0x3E {                               // < >
            let inner = body[1..<(end - 1)]
            return isHostname(inner) ? String(decoding: inner, as: UTF8.self) : nil
        }
        if first == 0x5B, last == 0x5D {                               // [ ]
            var from = 1
            if from < end - 1, body[from] == 0x7E || body[from] == 0x2A { from += 1 }   // ~ *
            let inner = Array(body[from..<(end - 1)])
            if inner.contains(0x40) { return userAtHost(inner) }       // [user@host] (no terminator)
            return huaweiDevice(inner)
        }

        // Everything else ends in a terminator.
        guard last == 0x23 || last == 0x3E || last == 0x24 || last == 0x25 else { return nil }   // # > $ %
        var stem = Array(body[0..<(end - 1)])
        // `[user@host path]$`, `[admin@MikroTik] >`
        if stem.first == 0x5B {
            while stem.last == 0x20 { stem.removeLast() }
            guard stem.last == 0x5D else { return nil }
            let inner = Array(stem[1..<(stem.count - 1)])
            guard inner.contains(0x40) else { return nil }
            let userHost = inner.prefix { $0 != 0x20 }
            return userAtHost(Array(userHost))
        }
        // user@host…  (Juniper `user@MX1>`, Linux `user@host:~$`)
        if let at = stem.firstIndex(of: 0x40) {
            // The host runs to `:` (Linux path) or to the terminator. A
            // `:path` may hold anything; without one, nothing may follow.
            let hostEnd = stem[(at + 1)...].firstIndex(of: 0x3A) ?? stem.count
            if hostEnd == stem.count, last == 0x24 { return nil }      // `user@host$` is not a shape
            return userAtHost(Array(stem[0..<hostEnd]))
        }
        guard last == 0x23 || last == 0x3E || (last == 0x24 && stem.last == 0x20) else { return nil }
        // FortiGate: `NAME # ` / `NAME (vdom) # ` — a space before the
        // terminator, and the trailing space after it is required (the
        // device always sends it; a sentence ending "Total #" does not).
        if stem.last == 0x20 {
            guard end < line.count else { return nil }                 // trailing space required
            while stem.last == 0x20 { stem.removeLast() }
            if stem.last == 0x29 {                                     // (vdom)
                guard let open = stem.lastIndex(of: 0x28) else { return nil }
                let vdom = stem[(open + 1)..<(stem.count - 1)]
                guard !vdom.isEmpty, vdom.allSatisfy(isNameByte) else { return nil }
                stem = Array(stem[0..<open])
                guard stem.last == 0x20 else { return nil }
                while stem.last == 0x20 { stem.removeLast() }
            }
            return isHostname(stem) ? String(decoding: stem, as: UTF8.self) : nil
        }
        guard last != 0x24 else { return nil }
        // Cisco / Aruba: NAME or NAME(mode), no space anywhere.
        if stem.last == 0x29 {
            guard let open = stem.firstIndex(of: 0x28) else { return nil }
            let mode = stem[(open + 1)..<(stem.count - 1)]
            guard !mode.isEmpty, mode.allSatisfy({ isNameByte($0) || $0 == 0x2F || $0 == 0x3A }) else { return nil }
            stem = Array(stem[0..<open])
        }
        return isHostname(stem) ? String(decoding: stem, as: UTF8.self) : nil
    }

    /// A Huawei/H3C view prompt names the device by prefix: once `<Core-VLAN-GW>`
    /// has been seen, `[Core-VLAN-GW-Vlanif10]` is that device — whatever the
    /// keyword table would have cut it to. The longest known name wins.
    static func knownDevice(inLine line: [UInt8], among known: [String]) -> String? {
        var end = line.count
        while end > 0, line[end - 1] == 0x20 { end -= 1 }
        guard end >= 3, line[0] == 0x5B, line[end - 1] == 0x5D else { return nil }
        var from = 1
        if line[from] == 0x7E || line[from] == 0x2A { from += 1 }
        guard from < end - 1 else { return nil }
        let inner = String(decoding: line[from..<(end - 1)], as: UTF8.self)
        return known.filter { inner == $0 || inner.hasPrefix($0 + "-") }.max { $0.count < $1.count }
    }

    /// `user@host` → host. Both halves must look like names.
    private static func userAtHost(_ bytes: [UInt8]) -> String? {
        guard let at = bytes.firstIndex(of: 0x40) else { return nil }
        let user = bytes[0..<at]
        let host = bytes[(at + 1)...]
        guard !user.isEmpty, user.allSatisfy(isNameByte), isHostname(host) else { return nil }
        return String(decoding: host, as: UTF8.self)
    }

    /// Huawei VRP / H3C views append `-<view>` to the device name inside the
    /// brackets. The device name is what comes before the view: before the
    /// `-` that starts an interface name (the last `-` ahead of the first
    /// `/`), or before a known view keyword.
    static func huaweiDevice(_ inner: [UInt8]) -> String? {
        if isHostname(inner) {
            // A plain name, or NAME-<keyword view> such as HW-Vlanif10.
            let text = String(decoding: inner, as: UTF8.self)
            let lower = text.lowercased()
            for keyword in viewKeywords {
                if let range = lower.range(of: "-" + keyword), range.lowerBound > lower.startIndex {
                    let device = String(text[text.startIndex..<range.lowerBound])
                    if isHostname(Array(device.utf8)) { return device }
                }
            }
            return text
        }
        // An interface view: `HW-S5736-GigabitEthernet0/0/1`.
        guard let slash = inner.firstIndex(of: 0x2F),
              let dash = inner[0..<slash].lastIndex(of: 0x2D) else { return nil }
        let device = inner[0..<dash]
        return isHostname(device) ? String(decoding: device, as: UTF8.self) : nil
    }

    /// Lower-case view names VRP/Comware put after the device name. An
    /// interface with a slash is found by the slash rule; these are the
    /// views without one.
    static let viewKeywords = [
        "vlanif", "vlan-interface", "vlan", "loopback", "eth-trunk", "bridge-aggregation", "route-aggregation",
        "tunnel", "null", "meth", "nve", "vbdif", "ospf", "ospfv3", "bgp", "isis", "rip", "aaa", "ui-", "user-interface",
        "line-", "acl-", "radius-", "hwtacacs-", "domain-", "luser-", "local-user-", "stp-", "mst-", "vpn-instance",
        "route-policy", "ip-pool", "traffic-", "qos-", "policy-", "ntp", "snmp", "lldp", "dhcp", "nqa-", "isp-",
        "gigabitethernet", "xgigabitethernet", "ethernet", "10ge", "25ge", "40ge", "100ge", "multige",
    ]
}

/// The controllers' half: one detector per session, dropped the moment it
/// decides (or gives up), plus the name it learned. A reconnect hands the
/// learned name to the successor with `carry`, which also means the
/// successor never scans — the decision was made once, for the tab.
nonisolated struct PromptNaming {
    private var detector: PromptNameDetector?
    private(set) var learned: String?

    init(applies: Bool) {
        detector = applies ? PromptNameDetector() : nil
    }

    /// True while the stream is still being watched.
    var scanning: Bool { detector != nil }

    mutating func carry(_ name: String) {
        learned = name
        detector = nil
    }

    /// The learned name, once; nil otherwise. A nil detector costs one check.
    mutating func consume(_ bytes: [UInt8]) -> String? {
        guard var current = detector else { return nil }
        let found = current.consume(bytes)
        if let found {
            learned = found
            detector = nil
            return found
        }
        detector = current.finished ? nil : current
        return nil
    }

    /// What the session is called: `Core-SW (cu.usbserial-1420)` once
    /// learned, the original name until then.
    func sessionName(original: String) -> String {
        learned.map { PromptName.title(learned: $0, original: original) } ?? original
    }
}

/// Whether a session's name is one the app chose (cable, bare address) and
/// may therefore be replaced by the prompt's, and how the new title reads.
nonisolated enum PromptName {
    /// Serial: the name is the cable (`cu.usbserial-1420`, the full device
    /// path, or nothing). SSH: the name is the address (as typed, or any IP
    /// literal) or nothing. A saved host with a real name keeps it; a local
    /// shell is never renamed.
    static func applies(name: String, address: String, kind: ConnectionKind) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .local:
            return false
        case .serial:
            return name.isEmpty || name == address || name == (address as NSString).lastPathComponent
        case .ssh:
            return name.isEmpty || name.caseInsensitiveCompare(address.trimmingCharacters(in: .whitespaces)) == .orderedSame
                || isIPLiteral(name)
        }
    }

    /// `Core-SW (cu.usbserial-1420)`. The original stays in the title — it
    /// is how the user tells two consoles of one device apart, and how a
    /// log is found again by its cable or address.
    static func title(learned: String, original: String) -> String {
        let original = original.trimmingCharacters(in: .whitespaces)
        if original.isEmpty || original.caseInsensitiveCompare(learned) == .orderedSame { return learned }
        return "\(learned) (\(original))"
    }

    static func isIPLiteral(_ text: String) -> Bool {
        var s = text
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        if let zone = s.firstIndex(of: "%") { s = String(s[..<zone]) }
        var v4 = in_addr()
        var v6 = in6_addr()
        return s.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}
