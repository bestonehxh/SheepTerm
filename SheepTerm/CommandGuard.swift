import Foundation

// Danger Command Guard (5.0 (22)): a command that restarts, erases or
// factory-resets the device is held until the user says Send. Foundation
// only and in `sharedSources` (root Package.swift), like SafePastePlan: the
// rules are the same on Windows. The hook (holding the Return, the card) is
// `SessionTerminalHost`; ARCHITECTURE.md §25.
//
// The list is FIXED, like the highlight packs — no user editing. It is
// deliberately short: everything on it ends the session or the device's
// configuration in one line. Interface `shutdown` and `clear …` are NOT on
// it (the user's call, 2026-10-16): a pasted config is full of them, and a
// question on every one would teach the user to click Send without reading.

public nonisolated enum CommandGuard {
    /// One dangerous command: its words, each with the shortest abbreviation
    /// the device accepts (`wr er` is `write erase` on IOS), and a test for
    /// the words after them.
    struct Rule: Sendable {
        /// Display form ("write erase"), also what a test names.
        let name: String
        let words: [(full: String, minimum: Int)]
        let arguments: Arguments
        /// Only outside configuration mode: Aruba CX's `boot system`
        /// reboots from the exec prompt, IOS's is a harmless config line.
        let execOnly: Bool
        /// nil = every family. Linux's `shutdown` is the machine; on a
        /// switch the same word shuts one interface — so it belongs to the
        /// families where it means the first.
        let vendors: Set<Vendor>?

        enum Arguments: Sendable {
            case any
            /// Nothing after the words (`boot` alone, not `boot system …`)
            case none
            /// `reload cancel` undoes a scheduled reload.
            case notFirst(String, minimum: Int)
            /// `delete flash:…` — a file on the box. Junos/FortiOS `delete`
            /// edits config (and an IPv6 address has colons too), so only a
            /// file-system prefix counts.
            case fileSystem
            /// `init 0` / `init 6`, not `init` alone.
            case exactly(Set<String>)
        }

        /// `"wr:ite e:rase"` — the part before `:` is the shortest
        /// abbreviation; no `:` means the whole word.
        init(_ spec: String, _ arguments: Arguments = .any, execOnly: Bool = false, vendors: Set<Vendor>? = nil) {
            var words: [(String, Int)] = []
            var display: [String] = []
            for part in spec.split(separator: " ") {
                let pieces = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let full = pieces.joined()
                words.append((full, pieces.count == 2 ? pieces[0].count : full.count))
                display.append(full)
            }
            self.name = display.joined(separator: " ")
            self.words = words
            self.arguments = arguments
            self.execOnly = execOnly
            self.vendors = vendors
        }
    }

    static let rules: [Rule] = [
        // Cisco IOS / IOS-XE / NX-OS, ArubaOS, Comware, Aruba CX
        Rule("rel:oad", .notFirst("cancel", minimum: 2)),
        Rule("wr:ite e:rase"),
        Rule("er:ase"),
        Rule("form:at"),
        Rule("del:ete", .fileSystem),
        Rule("factory:-reset"),
        Rule("cry:pto k:ey z:eroize"),
        Rule("boot sys:tem", execOnly: true),
        // ArubaOS-Switch / ProCurve: `boot` alone reboots (exec prompt only).
        Rule("boot", .none, execOnly: true),
        // NX-OS image install (reloads the switch)
        Rule("ins:tall all"),
        // MikroTik RouterOS — absolute (`/system reboot`) or from the root
        // prompt (`system reboot`); one leading `/` is dropped in `match`.
        Rule("sys:tem reb:oot"),
        Rule("sys:tem res:et-configuration"),
        Rule("reset-c:onfiguration"),          // inside RouterOS's /system menu
        // Huawei VRP, Comware, Linux, Gaia
        Rule("reb:oot"),
        Rule("res:et sa:ved-configuration"),
        Rule("res:et fa:ctory-configuration"),
        // FortiOS
        Rule("exe:cute reb:oot"),
        Rule("exe:cute shu:tdown"),
        Rule("exe:cute fac:toryreset"),
        Rule("exe:cute factoryreset2"),
        Rule("exe:cute formatl:ogdisk"),
        Rule("exe:cute erase-d:isk"),
        Rule("exe:cute disk f:ormat"),
        Rule("exe:cute res:tore"),
        // Junos
        Rule("req:uest sys:tem reb:oot"),
        Rule("req:uest sys:tem h:alt"),
        Rule("req:uest sys:tem power-o:ff"),
        Rule("req:uest sys:tem z:eroize"),
        Rule("req:uest vmh:ost reb:oot"),
        // PAN-OS
        Rule("req:uest res:tart sys:tem"),
        Rule("req:uest shu:tdown sys:tem"),
        Rule("req:uest sys:tem private-data-reset"),
        // systemd: unambiguous on any host
        Rule("systemctl reboot"),
        Rule("systemctl poweroff"),
        Rule("systemctl halt"),
        // Linux / Check Point Gaia only (see `vendors`)
        Rule("shutdown", .notFirst("-c", minimum: 2), vendors: [.linux, .gaia]),   // -c cancels one
        Rule("halt", vendors: [.linux, .gaia]),
        Rule("poweroff", vendors: [.linux, .gaia]),
        Rule("init", .exactly(["0", "6"]), vendors: [.linux, .gaia]),
    ]

    /// Words in front of a command that run it from somewhere else: IOS
    /// `do` in config mode, Junos `run`, a server's `sudo`.
    static let passThrough: Set<String> = ["do", "run", "sudo"]

    /// `/sbin/reboot`, `/usr/sbin/halt`: the program is what counts.
    static let binDirectories: Set<String> = ["bin", "sbin", "usr"]

    static let fileSystems = ["flash", "bootflash", "nvram", "disk", "slot", "usb", "usbflash",
                              "sdflash", "sd", "harddisk", "cfcard", "bootdisk"]

    /// The rule `command` hits, or nil. `prompt` is the device's prompt in
    /// front of it on screen (nil for a pasted line): `(config` in it means
    /// configuration mode. `vendor` = the session's family (`.auto` when
    /// unknown — the family-only rules then stay quiet).
    static func match(_ command: String, prompt: String? = nil, vendor: Vendor = .auto) -> Rule? {
        let inConfig = prompt?.lowercased().contains("(config") ?? false
        // `show run | i x; reload` — a server shell runs every part.
        for segment in segments(of: command) {
            var words = segment
            while let first = words.first, passThrough.contains(first) {
                words.removeFirst()
                // `sudo -n reboot`: the wrapper's own flags go with it —
                // and the value of the ones that take one (`-u root`).
                while let flag = words.first, flag.hasPrefix("-") {
                    words.removeFirst()
                    if ["-u", "-g", "-h", "-p", "-c", "-r", "-t"].contains(flag), !words.isEmpty { words.removeFirst() }
                }
            }
            guard !words.isEmpty else { continue }
            // RouterOS: `/system reboot` is `system reboot` from the root,
            // and v7's `/sys/reb` the same words joined by slashes. A
            // server's `/sbin/reboot` is the program at the end of the path.
            if words[0].hasPrefix("/") { words[0].removeFirst() }
            if words[0].contains("/") {
                let parts = words[0].split(separator: "/").map(String.init)
                if let first = parts.first, binDirectories.contains(first), let program = parts.last {
                    words[0] = program
                } else {
                    words.replaceSubrange(0...0, with: parts)
                }
                guard !words.isEmpty else { continue }
            }
            for rule in rules {
                if let vendors = rule.vendors, !vendors.contains(vendor) { continue }
                // Exec-only needs a prompt that says exec: a pasted IOS
                // `show run` holds `boot system flash:…` config lines.
                if rule.execOnly, prompt == nil || inConfig { continue }
                if matches(rule, words) { return rule }
            }
        }
        return nil
    }

    static func isDangerous(_ command: String, prompt: String? = nil, vendor: Vendor = .auto) -> Bool {
        match(command, prompt: prompt, vendor: vendor) != nil
    }

    /// Dangerous for at least one of `vendors` (Broadcast: one question for
    /// tabs of several families).
    static func isDangerous(_ command: String, anyOf vendors: Set<Vendor>) -> Bool {
        vendors.contains { isDangerous(command, vendor: $0) }
    }

    /// What to do with a Return the user just typed.
    public enum ReturnDecision: Equatable, Sendable {
        case send
        /// Hold it and ask; the text is what the card shows.
        case ask(String)
        /// The screen is behind the keys and the keys alone do not tell:
        /// hold it until the echo arrives (`afterEcho`), at most a moment.
        case waitForEcho
    }

    /// `typed` = `TypedLine.text`; `screen` = the cursor's line cut into
    /// prompt and command (nil when it is not one); `screenIsCurrent` =
    /// the echo of the last key has arrived (`HistoryEchoGate`).
    static func onReturn(typed: String?, screen: (prompt: String, command: String)?,
                                screenIsCurrent: Bool, vendor: Vendor) -> ReturnDecision {
        // The keys spell it: no need to wait for anything. The screen's
        // prompt (even a stale one) still says whether this is config mode.
        if let typed {
            let command = typed.trimmingCharacters(in: .whitespaces)
            if isDangerous(command, prompt: screen?.prompt, vendor: vendor) { return .ask(command) }
        }
        if screenIsCurrent {
            guard let screen, isDangerous(screen.command, prompt: screen.prompt, vendor: vendor) else { return .send }
            return .ask(screen.command)
        }
        // Behind, but every key since the last Return was a plain one and
        // they spell nothing on the list: the line IS those keys.
        return typed != nil ? .send : .waitForEcho
    }

    /// After the wait: whatever the screen shows now decides. A line still
    /// half-echoed is checked as it stands — the rules accept abbreviations,
    /// so `rel` already counts.
    static func afterEcho(screen: (prompt: String, command: String)?, vendor: Vendor) -> ReturnDecision {
        guard let screen, isDangerous(screen.command, prompt: screen.prompt, vendor: vendor) else { return .send }
        return .ask(screen.command)
    }

    /// Indices of the lines of a paste/snippet that hit a rule.
    static func dangerousLines(_ lines: [String], vendor: Vendor = .auto) -> [Int] {
        lines.indices.filter { isDangerous(lines[$0], vendor: vendor) }
    }

    /// Safe Paste's review: " 2 of them can restart or erase the device."
    /// after its own sentence — nothing when none.
    public static func reviewNote(_ count: Int) -> String {
        switch count {
        case 0: return ""
        case 1: return " One of them can restart or erase the device."
        default: return " \(count) of them can restart or erase the device."
        }
    }

    /// Each line's UTF-16 range in `lines.joined(separator: "\n")` (the
    /// review's text view, to colour the dangerous ones).
    public static func lineRanges(_ lines: [String]) -> [NSRange] {
        var location = 0
        return lines.map { line in
            let length = (line as NSString).length
            defer { location += length + 1 }
            return NSRange(location: location, length: length)
        }
    }

    /// Lowercased words, split at `;`, `&&`, `||` and cut at a pipe.
    static func segments(of command: String) -> [[String]] {
        guard command.utf8.count <= 4096 else { return [] }
        var out: [[String]] = []
        var current: [String] = []
        var word = ""
        var skipping = false
        func endWord() {
            if !word.isEmpty, !skipping { current.append(word) }
            word = ""
        }
        func endSegment() {
            endWord()
            if !current.isEmpty { out.append(current) }
            current = []
            skipping = false
        }
        var chars = Array(command.lowercased())
        chars.append(" ")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == ";" || (c == "&" && next == "&") || (c == "|" && next == "|") {
                endSegment()
                if c != ";" { i += 1 }
            } else if c == "|" {
                // `cmd | include x`: the rest is a filter, not a command —
                // until the next `;`.
                endWord()
                skipping = true
            } else if c == " " || c == "\t" {
                endWord()
            } else {
                word.append(c)
            }
            i += 1
        }
        endSegment()
        return out
    }

    static func matches(_ rule: Rule, _ words: [String]) -> Bool {
        guard words.count >= rule.words.count else { return false }
        for (index, spec) in rule.words.enumerated() {
            let typed = words[index]
            guard typed.count >= spec.minimum, spec.full.hasPrefix(typed) else { return false }
        }
        let rest = words.dropFirst(rule.words.count)
        switch rule.arguments {
        case .any:
            return true
        case .none:
            return rest.isEmpty
        case .notFirst(let word, let minimum):
            guard let first = rest.first else { return true }
            return !(first.count >= minimum && word.hasPrefix(first))
        case .fileSystem:
            return rest.contains(where: isFileSystemPath)
        case .exactly(let allowed):
            return rest.count == 1 && allowed.contains(rest[rest.startIndex])
        }
    }

    /// `flash:x.bin`, `bootflash:/x`, `disk0:`, `usb1:` — a name from the
    /// list, optional digits, a colon.
    static func isFileSystemPath(_ word: String) -> Bool {
        guard let colon = word.firstIndex(of: ":") else { return false }
        var name = word[..<colon]
        while let last = name.last, last.isNumber { name.removeLast() }
        return fileSystems.contains(String(name))
    }
}

/// The same rules for a caller that holds the family as its raw name
/// (`Vendor.rawValue`; Windows keeps no `Vendor`), as `CoreHighlight` does
/// for the highlight packs. An unknown name reads as `.auto`.
extension CommandGuard {
    public static func isDangerous(_ command: String, prompt: String? = nil, vendor name: String) -> Bool {
        isDangerous(command, prompt: prompt, vendor: Vendor(rawValue: name) ?? .auto)
    }

    /// Broadcast: dangerous for any of the ticked tabs' families.
    public static func isDangerous(_ command: String, anyOf names: [String]) -> Bool {
        isDangerous(command, anyOf: Set(names.map { Vendor(rawValue: $0) ?? .auto }))
    }

    public static func onReturn(typed: String?, screen: (prompt: String, command: String)?,
                                screenIsCurrent: Bool, vendor name: String) -> ReturnDecision {
        onReturn(typed: typed, screen: screen, screenIsCurrent: screenIsCurrent, vendor: Vendor(rawValue: name) ?? .auto)
    }

    public static func afterEcho(screen: (prompt: String, command: String)?, vendor name: String) -> ReturnDecision {
        afterEcho(screen: screen, vendor: Vendor(rawValue: name) ?? .auto)
    }

    public static func dangerousLines(_ lines: [String], vendor name: String) -> [Int] {
        dangerousLines(lines, vendor: Vendor(rawValue: name) ?? .auto)
    }

    /// The command as the dangerous-command card shows it: one line of at
    /// most `maxChars` characters (a monospaced line) that always keeps the
    /// part that made it dangerous in view — `show int ; reload ; show …`
    /// must not read as a harmless `show int…` (review 6.0 (11)). A part
    /// longer than the line keeps its start and its end; context around it
    /// is added both ways while it fits, `…` marking what was cut. Any
    /// family's rule counts (the card does not know the session's).
    public static func shown(_ command: String, maxChars: Int) -> String {
        let chars = Array(command)
        guard chars.count > maxChars, maxChars >= 3 else { return command }
        // The raw parts, at `;`, `&&` and `||` as `segments(of:)` splits them.
        var parts: [Range<Int>] = []
        var start = 0, i = 0
        while i < chars.count {
            let c = chars[i], next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == ";" || (c == "&" && next == "&") || (c == "|" && next == "|") {
                parts.append(start..<i)
                i += c == ";" ? 1 : 2
                start = i
            } else { i += 1 }
        }
        parts.append(start..<chars.count)
        let every = Set(Vendor.allCases)
        var hit = parts.first { isDangerous(String(chars[$0]), anyOf: every) } ?? 0..<chars.count
        // Without the blanks around it.
        while hit.lowerBound < hit.upperBound, chars[hit.lowerBound] == " " { hit = (hit.lowerBound + 1)..<hit.upperBound }
        while hit.upperBound > hit.lowerBound, chars[hit.upperBound - 1] == " " { hit = hit.lowerBound..<(hit.upperBound - 1) }
        if hit.count + 2 >= maxChars {
            // The part alone is too long: its start and its end.
            let room = maxChars - 1, head = (room + 1) / 2, tail = room - head
            return String(chars[hit.lowerBound..<(hit.lowerBound + head)]) + "…" + String(chars[(hit.upperBound - tail)..<hit.upperBound])
        }
        var lo = hit.lowerBound, hi = hit.upperBound
        func width() -> Int { (hi - lo) + (lo > 0 ? 1 : 0) + (hi < chars.count ? 1 : 0) }
        var grew = true
        while grew {
            grew = false
            if lo > 0 { lo -= 1; if width() > maxChars { lo += 1 } else { grew = true } }
            if hi < chars.count { hi += 1; if width() > maxChars { hi -= 1 } else { grew = true } }
        }
        return (lo > 0 ? "…" : "") + String(chars[lo..<hi]) + (hi < chars.count ? "…" : "")
    }
}

/// What the user has typed on the current line, rebuilt from the keys —
/// valid only while every key since the last Return was a plain character,
/// Backspace or ⌃U. Anything the device could have expanded or replaced
/// (Tab, `?`, an arrow, a paste) makes it `nil`, and the screen decides.
///
/// It exists for speed: a fast typist's Return reaches the guard before the
/// device's echo of the last letters, so the screen still shows `relo`.
/// When the keys alone spell a dangerous command, the guard needs no echo.
public nonisolated struct TypedLine: Sendable, Equatable {
    public private(set) var text: String? = ""
    public static let maxLength = 300

    public init() {}

    /// Bytes the user typed (one key's worth, as the view sends them).
    public mutating func typed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if bytes == [0x0D] || bytes == [0x0D, 0x0A] || bytes == [0x0A] || bytes == [0x03] || bytes == [0x15] {
            // Return (or ⌃J), ⌃C, ⌃U: a new, empty line.
            text = ""
            return
        }
        if bytes == [0x7F] || bytes == [0x08] {
            if text?.isEmpty == false { text?.removeLast() }
            return
        }
        // Printable text only (UTF-8 included). `?` is help on network CLIs
        // and the device redraws the line — not ours to predict.
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }),
              let string = String(bytes: bytes, encoding: .utf8), !string.contains("?") else {
            text = nil
            return
        }
        guard let current = text, current.count + string.count <= Self.maxLength else {
            text = nil
            return
        }
        text = current + string
    }

    /// Bytes that reached the line some other way (a paste, a snippet, a
    /// history pick): the line is no longer what the keys say.
    public mutating func other() {
        text = nil
    }

    /// Bytes the app sent that the user did not type: a paste, a snippet, a
    /// Safe Paste line, a terminal reply. Ending in Return leaves an empty
    /// line; printable text leaves a line we cannot spell; a reply (ESC …)
    /// changes nothing on it.
    public mutating func sent(_ bytes: [UInt8]) {
        if bytes.starts(with: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) {
            // A bracketed paste (ESC [200~ …): text on the line we cannot spell.
            text = nil
        } else if bytes.last == 0x0D || bytes.last == 0x0A {
            text = ""
        } else if bytes.first.map({ $0 >= 0x20 && $0 != 0x7F }) ?? false {
            text = nil
        }
    }
}

/// What a held Return lets go of when it is released (the echo came in
/// clean, or the user said Send): the Return itself and the keys typed
/// before it went out, but NOT what was typed behind a later Return — those
/// keys are a new line, and `show ver⏎reload⏎` typed fast used to send the
/// `reload⏎` with nobody asked. `again` goes back through the gate as if
/// just typed, so its first Return is checked (and held) like any other.
public nonisolated enum HeldKeys {
    /// Return, CR LF (LNM) or ⌃J — what the gate holds.
    public static func isReturn(_ key: [UInt8]) -> Bool {
        key == [0x0D] || key == [0x0D, 0x0A] || key == [0x0A]
    }

    public static func release(_ keys: [[UInt8]]) -> (now: [[UInt8]], again: [[UInt8]]) {
        guard let first = keys.firstIndex(where: isReturn) else { return (keys, []) }
        return (Array(keys[...first]), Array(keys[(first + 1)...]))
    }
}
