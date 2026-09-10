import Combine
import Foundation

enum ConnectionKind: String, Codable {
    case ssh
    case serial
    case local

    var badge: String {
        switch self {
        case .ssh: return "SSH"
        case .serial: return "SER"
        case .local: return "ZSH"
        }
    }
}

/// Which device family a session talks to. Selects the highlight rule pack:
/// the eleven rule NAMES are the same everywhere, but their keyword lists and
/// a few shape flags come from `HighlightScanner.Profile` for this vendor.
///
/// `auto` is the vendor-NEUTRAL CORE, not a union: addresses, masks, CIDR,
/// MACs, VLAN ids, and the state words that mean the same thing on every box.
/// It deliberately carries NO `interface` and NO `cx-port` rule, because an
/// interface name is the most vendor-specific token there is and guessing it
/// is what tore `ge-0/0/0` in half and would put FortiGate's `port1` and a
/// service `port 443` in the same colour.
///
/// So a host that has never been given a family colours LESS than it did
/// before packs existed — port names stay plain until a family is picked.
/// That is the intended trade: never mislead, rather than always colour.
/// Picking a family adds its port names and re-reads the words whose MEANING
/// is vendor specific — `deny` is a fault on a switch and an intended policy
/// action on a firewall, and FortiOS ends nearly every config line in
/// enable/disable.
///
/// Adding a device family is meant to be one `Profile` literal and one case
/// here — never a change to a matcher, a rule bit, or the start table.
nonisolated enum Vendor: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case cisco
    case arubaCX
    case arubaOS
    case huawei
    case comware
    case juniper
    case panos
    case fortios
    case gaia
    case linux

    var id: String { rawValue }

    /// Tolerant of raw values this build does not know. The synthesized
    /// decoder THROWS on an unrecognised string, and `Vendor?` does not save
    /// you — optionality covers a missing key, not a bad value — so one
    /// stale or hand-edited entry would fail the whole `[HostGroup]` decode
    /// and send hosts.json to the corrupt-file quarantine. Unknown reads as
    /// `.auto`, which is exactly what "we don't know this device" means.
    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(Vendor.init(rawValue:)) ?? .auto
    }

    var label: String {
        switch self {
        case .auto: return "Auto (all vendors)"
        case .cisco: return "Cisco IOS / IOS-XE / NX-OS"
        case .arubaCX: return "Aruba CX"
        case .arubaOS: return "ArubaOS (Controller / MM)"
        case .huawei: return "Huawei VRP"
        case .comware: return "H3C / HPE Comware"
        case .juniper: return "Juniper Junos"
        case .panos: return "Palo Alto PAN-OS"
        case .fortios: return "Fortinet FortiOS"
        case .gaia: return "Check Point Gaia"
        case .linux: return "Linux / server"
        }
    }

    /// Dense index into `Highlighter`'s per-vendor rule table. Written out
    /// rather than derived from `allCases` because the matching path reads it
    /// once per text run — thousands of times per escape-heavy chunk.
    var slot: Int {
        switch self {
        case .auto: return 0
        case .cisco: return 1
        case .arubaCX: return 2
        case .arubaOS: return 3
        case .huawei: return 4
        case .comware: return 5
        case .juniper: return 6
        case .panos: return 7
        case .fortios: return 8
        case .gaia: return 9
        case .linux: return 10
        }
    }

    /// Short form for the status bar and the tab context menu.
    var badge: String {
        switch self {
        case .auto: return "Auto"
        case .cisco: return "Cisco"
        case .arubaCX: return "Aruba CX"
        case .arubaOS: return "ArubaOS"
        case .huawei: return "Huawei"
        case .comware: return "Comware"
        case .juniper: return "Junos"
        case .panos: return "PAN-OS"
        case .fortios: return "FortiOS"
        case .gaia: return "Gaia"
        case .linux: return "Linux"
        }
    }
}

enum CipherMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case modern
    case legacy

    /// Tolerant for the reason `Vendor` is: one unknown string in one entry
    /// must not send the whole of hosts.json to the corrupt-file quarantine.
    /// Unknown reads as `.auto`, which is what "no particular cipher policy"
    /// means anyway.
    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(CipherMode.init(rawValue:)) ?? .auto
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (recommended)"
        case .modern: return "Modern only"
        case .legacy: return "Legacy allowed"
        }
    }
}

struct Host: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: ConnectionKind
    var address: String = ""
    var port: Int = 22
    var username: String = ""
    var credentialID: UUID? = nil
    var cipherMode: CipherMode? = nil
    /// ForwardAgent for this host. Optional (not a defaulted Bool) so hosts
    /// written by an older build still decode — a missing key would throw.
    var agentForward: Bool? = nil
    /// Highlight rule pack. Optional for the same forward-compat reason as
    /// `agentForward`; a missing key means `.auto`, so hosts saved before
    /// this existed keep the union behaviour they were coloured with.
    var vendor: Vendor? = nil

    /// The pack to actually highlight with — `vendor` with the nil hole filled.
    var highlightVendor: Vendor { vendor ?? .auto }

    /// Connection identity used for recents dedup and "same target"
    /// matching — the UUID is NOT part of it, so a recent entry and the
    /// host it came from (different ids) still match.
    var connectionKey: String {
        "\(kind.rawValue)\u{0}\(address)\u{0}\(port)\u{0}\(username)"
    }

    func sameConnection(as other: Host) -> Bool {
        connectionKey == other.connectionKey
    }

    /// Fills the holes a `.needsCompletion` target leaves from the saved host
    /// on the same endpoint. `.complete` returns `self` untouched — that is
    /// the whole point of the flag. See `HostCompleteness`.
    ///
    /// Pure on purpose: this rule decides which credential a session
    /// authenticates with, and it was previously buried inside `AppModel.open`
    /// where nothing without a window could reach it. `saved` is every host in
    /// every group (`store.groups.flatMap(\.hosts)`).
    ///
    /// The `.needsCompletion` branch is the pre-existing rule, moved verbatim:
    ///   • only SSH, and only when no credential is named — a target that
    ///     already names one is not missing anything;
    ///   • the first host with the same address and port whose username does
    ///     not contradict this one (either side empty counts as agreement);
    ///   • fields are taken only where this host has none. A `vendor` that is
    ///     a literal `.auto` is a value, not a hole, so it is kept —
    ///     recents.json has carried literal `auto` since 3.0.
    func completed(from saved: [Host], when completeness: HostCompleteness) -> Host {
        guard completeness == .needsCompletion, kind == .ssh, credentialID == nil else { return self }
        guard let match = saved.first(where: {
            $0.kind == .ssh && $0.address == address && $0.port == port
                && (username.isEmpty || $0.username.isEmpty || $0.username == username)
        }) else { return self }
        var filled = self
        filled.credentialID = match.credentialID
        if filled.username.isEmpty { filled.username = match.username }
        if filled.cipherMode == nil { filled.cipherMode = match.cipherMode }
        if filled.agentForward == nil { filled.agentForward = match.agentForward }
        if filled.vendor == nil { filled.vendor = match.vendor }
        return filled
    }
}

/// Whether a `Host` on its way to `AppModel.open` is an ANSWER or a TARGET.
///
/// `Host` cannot say this by itself, and that was a bug, not a cosmetic gap.
/// `credentialID == nil` is written both by a form where the user picked
/// "Enter manually" and by a recents row that never carried a credential at
/// all; `vendor == nil` is written both by "Auto" and by an entry saved before
/// device families existed. One value, two meanings — so `open` had to guess,
/// and it guessed the second: a Quick Connect to an endpoint that also has a
/// saved Cisco host came up ON THAT HOST'S CREDENTIAL with passive detection
/// switched off, discarding both of the choices the user had just made. There
/// is no cleverer guess to write there; the caller is the only thing that
/// knows, so the caller now says.
///
/// This is a property of the REQUEST, not of the host, which is why it is a
/// separate value and not a new field on `Host`: it must never reach
/// hosts.json, must not join `Hashable`/`sameConnection`, and must not survive
/// a round trip through disk — a host read back out of the store is a target
/// again unless the caller has its own reason to say otherwise.
nonisolated enum HostCompleteness: Sendable, Equatable {
    /// Every field is the user's answer. `credentialID == nil` MEANS "enter
    /// manually — ask me", `vendor == nil`/`.auto` MEANS "detect it", an empty
    /// username MEANS "prompt". Nothing is inherited from anywhere.
    ///
    /// Quick Connect's Connect button, and any reconnect: by the time a
    /// session exists its controller holds the host it actually connected
    /// with, already completed once, and re-running the lookup against
    /// today's store is how a session drifts onto a credential it never had.
    case complete
    /// A target, not a configuration: a Recents row, a `user@host` typed into
    /// the sidebar connect box, a Quick Search match — and, as things stand,
    /// a saved host opened from the sidebar. The first three genuinely omit
    /// the credential/cipher/family, so those may be taken from the saved
    /// host on the same endpoint. The last does not always: a saved entry
    /// whose credential is "None (enter manually)" is a full configuration,
    /// yet if another saved entry on the same endpoint (compatible username)
    /// comes first in group order, it logs in with THAT one's Keychain
    /// password and no prompt. Pre-existing, and left in place on purpose
    /// because the same nil is what a `.sheepterm` import leaves behind
    /// (credentials never travel), and inheriting your own credential onto an
    /// imported entry is the case the rule exists for. Making the sidebar say
    /// `.complete` would end both. Decide, do not drift.
    case needsCompletion
}

struct HostGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var hosts: [Host]
}

/// `port` is a plain `Int` on disk and it means two different things: a TCP
/// port for `.ssh` and the BAUD RATE for `.serial`. Nothing on the way in
/// narrowed it — `HostEditSheet` range-checks `.ssh` only, `ShareCodec` does
/// not look, and a backup's `validate` only asks whether the bytes decode —
/// so the value that reaches a worker is whatever some file said. These are
/// the ranges the workers can actually represent.
extension Host {
    /// libssh takes the port as `UInt32`; `SSHWorker.connect` refuses
    /// anything outside this politely instead of trapping on the conversion.
    nonisolated static let sshPortRange = 1...65_535
    nonisolated static let defaultSSHPort = 22

    /// `SerialWorker` hands the baud to `cfsetspeed`, whose `speed_t` is
    /// UNSIGNED: `speed_t(-1)` is a Swift trap, not a failed guard, and it
    /// took the whole process down — every other open session with it.
    ///
    /// The bounds are deliberately wider than the two pickers' six rates
    /// (9600…230400). A console cable really is run at 1200 on old kit and at
    /// 921600 on a modern USB adapter, and refusing a rate the hardware
    /// supports would be a worse bug than the crash being fixed. 50 is the
    /// slowest rate termios has a constant for (B50) and 4 Mbaud is past
    /// every USB-serial part sold; outside that it is not a baud rate, it is
    /// a number that got into the file some other way.
    nonisolated static let serialBaudRange = 50...4_000_000
    nonisolated static let defaultSerialBaud = 9600

    /// True when `port` is something this host's worker can actually use.
    /// `.local` has no port at all, so there is nothing to be out of range.
    var hasUsablePort: Bool {
        switch kind {
        case .ssh: return Host.sshPortRange.contains(port)
        case .serial: return Host.serialBaudRange.contains(port)
        case .local: return true
        }
    }
}

/// Hygiene for a configuration that came from SOMEWHERE ELSE — a `.sheepterm`
/// import or a `.sheeptermbackup` restore. The two are the same operation
/// from the app's point of view (someone else's file becoming your
/// configuration) and only the import was ever hardened: the restore wrote
/// the payload's bytes verbatim, which is how a stored baud of −1 reached
/// `cfsetspeed` and how a 500-character name reached `SessionLogger`.
///
/// Nothing is ever DROPPED. A name is shortened, a port is replaced, and the
/// host still lands — this runs on the user's own data, where losing a host
/// would be the worse outcome. What changed is COUNTED so the dialog that
/// asked for the import or the restore can say it.
///
/// Every pass is idempotent: running it twice changes nothing and reports
/// nothing, which is what lets `BackupManager.apply` re-run it as its own
/// guarantee without double-counting what `restore` already showed.
enum ConfigurationHygiene {
    /// Long enough for "core-sw-01.bkk.example.com", short enough that the
    /// name still fits inside a log file name: at 229 ASCII characters the
    /// name overruns the volume's 255-byte NAME_MAX, `SessionLogger.init?`
    /// returns nil, and the session logs nothing at all. 64 is the cap
    /// `AppModel.confirmImport` has always applied; it is kept, not widened.
    static let maxNameLength = 64

    /// What a pass changed. Additive so a payload with several files can
    /// report one total.
    struct Report: Equatable {
        /// Names that carried control characters or were over the cap.
        var shortenedNames = 0
        /// Names that were empty afterwards and had to be given one.
        var replacedNames = 0
        /// `.ssh` hosts whose port was not a port.
        var narrowedPorts = 0
        /// `.serial` hosts whose baud rate was not a baud rate.
        var narrowedBauds = 0
        /// Addresses or usernames that carried control characters (a newline
        /// in an address reaches libssh and the sidebar detail line as is).
        var cleanedFields = 0

        var isEmpty: Bool {
            shortenedNames == 0 && replacedNames == 0 && narrowedPorts == 0 && narrowedBauds == 0
                && cleanedFields == 0
        }

        static func + (lhs: Report, rhs: Report) -> Report {
            Report(shortenedNames: lhs.shortenedNames + rhs.shortenedNames,
                   replacedNames: lhs.replacedNames + rhs.replacedNames,
                   narrowedPorts: lhs.narrowedPorts + rhs.narrowedPorts,
                   narrowedBauds: lhs.narrowedBauds + rhs.narrowedBauds,
                   cleanedFields: lhs.cleanedFields + rhs.cleanedFields)
        }

        /// Shown to the user as-is, or nil when nothing was touched. Says
        /// what was changed AND that the entry still arrived, because a
        /// silent fix on someone's own hosts is indistinguishable from data
        /// loss when they go looking for the value they typed.
        var summary: String? {
            guard !isEmpty else { return nil }
            var lines: [String] = []
            if shortenedNames > 0 {
                lines.append("• \(shortenedNames) name(s) were shortened to "
                             + "\(ConfigurationHygiene.maxNameLength) characters "
                             + "or had control characters removed.")
            }
            if replacedNames > 0 {
                lines.append("• \(replacedNames) entr(ies) had no usable name left and were named after "
                             + "their address.")
            }
            if cleanedFields > 0 {
                lines.append("• \(cleanedFields) address(es) or username(s) had control characters removed.")
            }
            if narrowedPorts > 0 {
                lines.append("• \(narrowedPorts) SSH host(s) had a port outside "
                             + "\(Host.sshPortRange.lowerBound)–\(Host.sshPortRange.upperBound) "
                             + "and were set to \(Host.defaultSSHPort).")
            }
            if narrowedBauds > 0 {
                lines.append("• \(narrowedBauds) serial host(s) had a baud rate SheepTerm cannot use "
                             + "and were set to \(Host.defaultSerialBaud).")
            }
            return "Some entries were corrected on the way in — every one of them was kept:\n"
                + lines.joined(separator: "\n")
        }
    }

    /// A file inside a payload that does not hold what its name says.
    enum HygieneError: LocalizedError {
        case undecodable(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .undecodable(let name, let reason):
                return "the \(name) it carries could not be read (\(reason))."
            }
        }
    }

    /// Strips control characters and caps the length — exactly what
    /// `AppModel.confirmImport` did inline. It lives here so the restore path
    /// applies the same rule rather than a copy of it that can drift.
    static func sanitizedName(_ text: String) -> String {
        let noControls = text.components(separatedBy: .controlCharacters).joined()
        return String(noControls.prefix(maxNameLength))
    }

    static func sanitize(_ hosts: inout [Host]) -> Report {
        var report = Report()
        for index in hosts.indices {
            let cleaned = sanitizedName(hosts[index].name)
            if cleaned != hosts[index].name {
                hosts[index].name = cleaned
                report.shortenedNames += 1
            }
            // Control characters only — no length cap here: an address is
            // handed to libssh / the serial open, and a username to the login,
            // where a newline is a different (wrong) value, not a long one.
            for keyPath in [\Host.address, \Host.username] {
                let value = hosts[index][keyPath: keyPath]
                let cleaned = value.components(separatedBy: .controlCharacters).joined()
                if cleaned != value {
                    hosts[index][keyPath: keyPath] = cleaned
                    report.cleanedFields += 1
                }
            }
            if hosts[index].name.isEmpty {
                // A nameless host is unreadable in the sidebar and unusable
                // as a log file name. The address is what the user would have
                // called it anyway; "Untitled Host" only when there is not
                // even one of those.
                let address = sanitizedName(hosts[index].address)
                hosts[index].name = address.isEmpty ? "Untitled Host" : address
                report.replacedNames += 1
            }
            if !hosts[index].hasUsablePort {
                switch hosts[index].kind {
                case .serial:
                    hosts[index].port = Host.defaultSerialBaud
                    report.narrowedBauds += 1
                default:
                    hosts[index].port = Host.defaultSSHPort
                    report.narrowedPorts += 1
                }
            }
        }
        return report
    }

    static func sanitize(_ groups: inout [HostGroup], emptyGroupName: String) -> Report {
        var report = Report()
        for index in groups.indices {
            let cleaned = sanitizedName(groups[index].name)
            if cleaned != groups[index].name {
                groups[index].name = cleaned
                report.shortenedNames += 1
            }
            if groups[index].name.isEmpty {
                groups[index].name = emptyGroupName
                report.replacedNames += 1
            }
            report = report + sanitize(&groups[index].hosts)
        }
        return report
    }

    /// The restore's entry point: the same pass applied to the raw file bytes
    /// a `.sheeptermbackup` carries, so what lands on disk is what an import
    /// would have written instead of the payload verbatim. Files this does
    /// not know about are left alone; a file that does not decode throws,
    /// because a restore must fail before it writes rather than half-way.
    static func sanitize(configurationFiles files: inout [String: Data]) throws -> Report {
        var report = Report()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = files["hosts.json"] {
            do {
                var groups = try JSONDecoder().decode([HostGroup].self, from: data)
                report = report + sanitize(&groups, emptyGroupName: "Untitled Group")
                files["hosts.json"] = try encoder.encode(groups)
            } catch {
                throw HygieneError.undecodable(name: "hosts.json", reason: error.localizedDescription)
            }
        }
        if let data = files["recents.json"] {
            do {
                var recents = try JSONDecoder().decode([Host].self, from: data)
                report = report + sanitize(&recents)
                files["recents.json"] = try encoder.encode(recents)
            } catch {
                throw HygieneError.undecodable(name: "recents.json", reason: error.localizedDescription)
            }
        }
        return report
    }
}

/// How many automatic reconnects one host may be given, and when.
///
/// A value type in Models rather than three lines inside `AppModel` because
/// the rule is subtle enough to have been wrong twice, and a rule that cannot
/// be tested without an AppKit window does not get tested. Both mistakes came
/// from the same shape: deciding in one place and charging in another.
///  - Charging when the timer fired rather than when the decision was made let
///    fifteen tabs all pass a cap of ten, because none of them had recorded
///    anything yet when the others asked.
///  - Then charging only the first attempt, while the CHECK still asked
///    `count < cap` every time, turned the cap into a knife: with nine drops on
///    the record, the tenth admitted one tab and refused every other tab that
///    fell with it, plus the admitted tab's own retries.
///
/// So there is one method. It answers and charges together, and the unit it
/// counts is a DROP: ten an hour per host, each costing every affected tab up
/// to three attempts.
struct ReconnectBudget {
    static let dropsPerHour = 10
    /// Drops on one host inside this window are one event. A link goes down
    /// once; the tabs on it do not each constitute a separate emergency.
    static let burstWindow: TimeInterval = 5
    static let window: TimeInterval = 3600

    private var history: [String: [Date]] = [:]

    static func key(for host: Host) -> String {
        "\(host.username)@\(host.address):\(host.port)"
    }

    /// True when this attempt may go ahead. `attempt` is the tab's own count
    /// for this drop (0, 1, 2), which the caller has already limited to three.
    mutating func claim(host: Host, attempt: Int, now: Date = Date()) -> Bool {
        let key = Self.key(for: host)
        var recent = (history[key] ?? []).filter { $0 > now.addingTimeInterval(-Self.window) }
        defer { history[key] = recent }
        // A retry rides the admission its first attempt already paid for.
        if attempt > 0 { return true }
        // So does a sibling tab that went down in the same burst.
        if let last = recent.last, now.timeIntervalSince(last) < Self.burstWindow { return true }
        guard recent.count < Self.dropsPerHour else { return false }
        recent.append(now)
        return true
    }

    /// Drops charged to this host inside the window (tests, diagnostics).
    func charges(for host: Host, now: Date = Date()) -> Int {
        (history[Self.key(for: host)] ?? []).filter { $0 > now.addingTimeInterval(-Self.window) }.count
    }
}

/// Parses "admin@192.168.1.1", "admin@sw01:2222", "admin@2001:db8::1" or
/// "user@[2001:db8::1]:2222" into an ad-hoc SSH target.
enum ConnectParser {
    /// `requireHostShape` is the difference between the sidebar's connect box
    /// and a form's Host field. The box shares its text with the host SEARCH,
    /// so "core" must stay a search and not become a connect row — it demands
    /// a dot, a user@, or an IPv6 address. A Host field has no such ambiguity:
    /// whatever is in it is meant to be a host, so `switch1:2222` must parse
    /// there. It used to fail that test, fall back to the raw string, and be
    /// handed to libssh whole as a hostname.
    /// Hex groups and colons, an optional embedded IPv4 tail, an optional
    /// `%zone` — nothing else. Not a validator (`:::::` passes), only the
    /// spelling test that keeps a name with two colons in it from being
    /// taken for an address.
    static func looksLikeIPv6(_ text: String) -> Bool {
        let parts = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let address = parts.first, !address.isEmpty else { return false }
        guard address.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return false }
        if parts.count == 2 {
            let zone = parts[1]
            guard !zone.isEmpty, zone.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return false }
        }
        return true
    }

    static func parse(_ text: String, requireHostShape: Bool = true) -> Host? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // No whitespace may survive anywhere in the target — a pasted
        // newline/tab/inner space would otherwise reach libssh raw.
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        var username = ""
        var rest = trimmed
        // The LAST "@", the way ssh(1) does it (`strrchr`). A hostname cannot
        // contain one, but a username can — `user@corp.com@10.0.0.1` is an
        // everyday UPN login on an AD or jump-host estate, and splitting at the
        // first "@" cut the username to "user" and left "corp.com@10.0.0.1" as
        // the address, which then failed as an unreadable DNS error.
        if let at = trimmed.lastIndex(of: "@") {
            username = String(trimmed[..<at])
            rest = String(trimmed[trimmed.index(after: at)...])
        }

        var port = 22
        var isIPv6 = false
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            // Bracketed IPv6 — [2001:db8::1]:2222; the brackets are not
            // part of the address.
            let after = rest.index(after: close)
            if after < rest.endIndex {
                guard rest[after] == ":",
                      let parsed = Int(rest[rest.index(after: after)...]) else { return nil }
                port = parsed
            }
            rest = String(rest[rest.index(after: rest.startIndex)..<close])
            isIPv6 = true
        } else if rest.hasPrefix("[") {
            // `[2001:db8::1` — the bracket was opened and never closed. Falling
            // through to the bare-IPv6 branch kept the bracket in the address
            // and failed later as a DNS error nobody could read.
            return nil
        } else if rest.filter({ $0 == ":" }).count > 1 {
            // Bare IPv6 (2001:db8::1): several colons and no brackets
            // means the whole thing is the address — no port split. Only
            // when it is spelled like one: `sw:1:2` typed into the sidebar
            // search used to become a Connect row to host "sw:1:2".
            guard Self.looksLikeIPv6(rest) else { return nil }
            isIPv6 = true
        } else if let colon = rest.lastIndex(of: ":") {
            // Exactly one colon means host:port. A port that doesn't parse
            // ("user@host:abc") is a reject, not a silent fallback to 22.
            guard let parsed = Int(rest[rest.index(after: colon)...]) else { return nil }
            port = parsed
            rest = String(rest[..<colon])
        }

        // libssh takes the port as UInt32 — reject values it can't
        // represent here instead of trapping at connect time.
        guard (1...65535).contains(port) else { return nil }

        guard !rest.isEmpty else { return nil }
        // Require either user@ or something host-shaped, so plain-name
        // searches don't turn into connect rows.
        if requireHostShape {
            guard !username.isEmpty || rest.contains(".") || isIPv6 else { return nil }
        }

        return Host(
            name: username.isEmpty ? rest : "\(username)@\(rest)",
            kind: .ssh,
            address: rest,
            port: port,
            username: username
        )
    }
}

@MainActor
final class HostStore: ObservableObject {
    @Published var groups: [HostGroup] { didSet { revision &+= 1 } }
    @Published var recents: [Host] { didSet { revision &+= 1 } }
    /// Bumped on every change to either list. The sidebar compares this
    /// instead of rebuilding every SidebarItem and joining a String from
    /// every row just to discover nothing changed — which it did on every
    /// AppModel publish, including each frame of a divider drag.
    private(set) var revision = 0

    /// Non-nil when a data file existed at launch but failed to decode.
    /// The original is preserved next to it as "<name>.corrupt-<timestamp>";
    /// AppModel can surface this message to the user.
    @Published private(set) var dataLoadWarning: String?

    /// Hard cap on stored recents — the sidebar's "show N recents"
    /// setting can never ask for more than this.
    static let maxRecents = 20

    /// Last known modification dates of the files on disk — recorded at
    /// load and after each save so a save can tell whether another
    /// running copy wrote in between (last-writer-wins mitigation).
    private var knownGroupsMtime: Date?
    private var knownRecentsMtime: Date?
    /// Hosts and groups THIS copy removed since launch. The merge-on-save
    /// union below treats "on disk, not in memory" as "another copy added
    /// it", which is also exactly what a host this copy just deleted looks
    /// like once any other copy has saved anything — so a deletion was
    /// silently undone by the very next save. Deleted ids are remembered for
    /// the life of the process and never re-adopted from disk.
    private var deletedHostIDs = Set<UUID>()
    private var deletedGroupIDs = Set<UUID>()
    /// The same tombstone for Recents, keyed the way recents identify an entry
    /// (`connectionKey`) rather than by id — a recent gets a fresh id on every
    /// note, so an id would tombstone nothing. Without this the twin of the
    /// bug above lives on here: a row the user removed comes back from a
    /// newer recents.json on the next merge. Cleared by `noteRecent`, because
    /// connecting to that target again is the user asking for it back.
    private var deletedRecentKeys = Set<String>()

    /// Set when a corrupt file was found at launch: blocks automatic
    /// writes until the first explicit user mutation, so a corrupt
    /// original is never overwritten by empty in-memory state.
    private var suppressWritesAfterCorruptLoad = false

    /// Test hook: when set, hosts/recents live here instead of
    /// Application Support. Production code never sets it.
    static var testBaseDirectory: URL?

    private static var baseDirectory: URL {
        if let testBaseDirectory { return testBaseDirectory }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var fileURL: URL { baseDirectory.appendingPathComponent("hosts.json") }
    private static var recentsURL: URL { baseDirectory.appendingPathComponent("recents.json") }

    init() {
        let groupsLoad = Self.loadList([HostGroup].self, from: Self.fileURL)
        groups = groupsLoad.value
        let recentsLoad = Self.loadList([Host].self, from: Self.recentsURL)
        recents = recentsLoad.value
        let warnings = [groupsLoad.warning, recentsLoad.warning].compactMap { $0 }
        if !warnings.isEmpty {
            dataLoadWarning = warnings.joined(separator: "\n")
            suppressWritesAfterCorruptLoad = true
        }
        knownGroupsMtime = Self.mtime(of: Self.fileURL)
        knownRecentsMtime = Self.mtime(of: Self.recentsURL)
    }

    /// Loads a Codable list from disk. A missing file is normal (fresh
    /// install) and yields an empty list. A file that exists but fails to
    /// decode is data the user had, so it is moved aside to
    /// "<name>.corrupt-<timestamp>" instead of being silently dropped,
    /// and a human-readable warning comes back for the UI.
    private static func loadList<T: Decodable>(_ type: [T].Type, from url: URL) -> (value: [T], warning: String?) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // A file that is simply not there is a normal first launch. One
            // that exists but cannot be READ (permissions, an I/O error, a
            // cloud file that never downloaded) must NOT look like an empty
            // list: saving over it would destroy the data it is guarding.
            if !FileManager.default.fileExists(atPath: url.path) { return ([], nil) }
            let warning = "\(url.lastPathComponent) could not be read (\(error.localizedDescription)). "
                + "SheepTerm started with an empty list and will not overwrite the file until you change something."
            NSLog("SheepTerm: %@", warning)
            return ([], warning)
        }
        do {
            return (try JSONDecoder().decode(type, from: data), nil)
        } catch {
            let corruptURL = url.appendingPathExtension("corrupt-\(corruptStamp())")
            do {
                try FileManager.default.moveItem(at: url, to: corruptURL)
            } catch {
                NSLog("SheepTerm: could not move corrupt %@ aside: %@",
                      url.lastPathComponent, error.localizedDescription)
            }
            let warning = "\(url.lastPathComponent) was unreadable; the original was preserved as \(corruptURL.lastPathComponent) and the list starts empty."
            NSLog("SheepTerm: %@ (decode error: %@)", warning, error.localizedDescription)
            return ([], warning)
        }
    }

    /// Same rule as the log and backup file names: a timestamp that ends up
    /// in a FILE NAME is always Gregorian + POSIX. A Thai-locale Mac would
    /// otherwise preserve the file as "hosts.json.corrupt-25690826-131403",
    /// which sorts nowhere near the data it was rescued from.
    private static func corruptStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Re-reads both files, replacing whatever is in memory — used after a
    /// backup restore has written new files underneath us. Same corrupt-file
    /// handling as `init`, and the mtimes are re-recorded so the next save
    /// doesn't think another copy of the app wrote in between.
    func reloadFromDisk() {
        let groupsLoad = Self.loadList([HostGroup].self, from: Self.fileURL)
        let recentsLoad = Self.loadList([Host].self, from: Self.recentsURL)
        groups = groupsLoad.value
        recents = recentsLoad.value
        let warnings = [groupsLoad.warning, recentsLoad.warning].compactMap { $0 }
        dataLoadWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        suppressWritesAfterCorruptLoad = !warnings.isEmpty
        knownGroupsMtime = Self.mtime(of: Self.fileURL)
        knownRecentsMtime = Self.mtime(of: Self.recentsURL)
        // The dataset was replaced wholesale, so what this session had deleted
        // from the PREVIOUS one says nothing about it. Keeping the tombstones
        // meant a restore that brought an entry back was undone by the next
        // merge, which is the one thing a restore must not do.
        deletedHostIDs.removeAll()
        deletedGroupIDs.removeAll()
        deletedRecentKeys.removeAll()
    }

    /// Every public mutator calls this first — the user's own change is
    /// what re-arms saving after a corrupt load.
    private func noteUserMutation() {
        suppressWritesAfterCorruptLoad = false
    }

    /// For the one caller that mutates `groups` directly instead of going
    /// through a mutator here (Quick Connect's save-to-group).
    func noteExplicitUserMutation() {
        noteUserMutation()
    }

    func save() {
        mergeGroupsFromDiskIfNeeded()
        if write(groups, to: Self.fileURL) {
            knownGroupsMtime = Self.mtime(of: Self.fileURL)
        }
    }

    private func saveRecents() {
        mergeRecentsFromDiskIfNeeded()
        if write(recents, to: Self.recentsURL) {
            knownRecentsMtime = Self.mtime(of: Self.recentsURL)
        }
    }

    /// Two running copies (e.g. via `open -n`) each rewrite the whole file;
    /// when the file on disk is NEWER than our last known state, merge it in
    /// before overwriting. The merge is host-level, not just group-level —
    /// a coarse "groups only, by id" merge silently dropped a host the other
    /// copy added to a group that also exists here (whole new groups
    /// survived; new hosts inside a shared group did not). The rule:
    /// groups present only on disk are kept as-is; for a group present in
    /// both, hosts are unioned by host id — the in-memory host wins on a
    /// same-id conflict (unchanged rule), and hosts that exist only on disk
    /// are appended to the in-memory group's host list, after its existing
    /// hosts, so the user's order is never reshuffled; other group-level
    /// attributes (name, etc.) keep the in-memory value. `groups` is only
    /// reassigned when the disk actually contributed something, so the
    /// overwhelmingly common single-instance case (the mtime guard above
    /// returns early) never publishes from inside a view update.
    /// The disk file is NEWER than what we loaded but cannot be read or
    /// decoded. Preserve it before the save about to happen overwrites it.
    ///
    /// The guard chain that used to be at the top of both merges treated this
    /// exactly like "nothing new on disk" — so a hosts.json written by another
    /// copy of the app, or half-written by a file-sync client (this repository
    /// lives in OneDrive), was silently replaced by whatever was in memory. The
    /// only copy left was the rolling `.bak`, which the NEXT save overwrites.
    /// The load path has quarantined unreadable files since the beginning; this
    /// path simply never learned to.
    ///
    /// Returns true when something was set aside, so the caller can say so.
    private func quarantineUnreadable(_ url: URL) -> Bool {
        let corruptURL = url.appendingPathExtension("corrupt-\(Self.corruptStamp())")
        do {
            try FileManager.default.moveItem(at: url, to: corruptURL)
        } catch {
            // The save that follows will overwrite the file we could not move,
            // so this is the last moment anyone can be told. NSLog alone left
            // the only warning in a place nobody looks — the same silence the
            // quarantine exists to break.
            NSLog("SheepTerm: could not set aside unreadable %@: %@",
                  url.lastPathComponent, error.localizedDescription)
            let warning = "\(url.lastPathComponent) was changed by something else, could not be read, "
                + "and could not be set aside either (\(error.localizedDescription)). "
                + "SheepTerm saved what it had, which replaced it."
            dataLoadWarning = [dataLoadWarning, warning].compactMap { $0 }.joined(separator: "\n")
            return false
        }
        let warning = "\(url.lastPathComponent) was changed by something else and could not be read. "
            + "It was preserved as \(corruptURL.lastPathComponent); SheepTerm saved what it had."
        NSLog("SheepTerm: %@", warning)
        dataLoadWarning = [dataLoadWarning, warning].compactMap { $0 }.joined(separator: "\n")
        return true
    }

    private func mergeGroupsFromDiskIfNeeded() {
        guard let diskMtime = Self.mtime(of: Self.fileURL),
              knownGroupsMtime == nil || diskMtime > knownGroupsMtime! else { return }
        guard let data = try? Data(contentsOf: Self.fileURL),
              let diskGroups = try? JSONDecoder().decode([HostGroup].self, from: data) else {
            _ = quarantineUnreadable(Self.fileURL)
            return
        }

        // uniquingKeysWith, never uniqueKeysWithValues: this is user data that
        // has been through imports, shares and restores, and a duplicate group
        // id in the file would TRAP — a crash on save is a far worse outcome
        // than merging against the first of the duplicates.
        let diskGroupsByID = Dictionary(diskGroups.map { ($0.id, $0) },
                                        uniquingKeysWith: { first, _ in first })
        let knownIDs = Set(groups.map(\.id))
        var merged = groups
        var changed = false

        // Every host id in memory, in ANY group — not the group's own. The
        // other copy may have MOVED a host between groups: it is then "only
        // on disk" in its new group while still in memory in the old one,
        // and appending it there put one id into two groups (two sidebar
        // rows sharing one item object; `updateHost` editing only the
        // first). Deduped across the whole store, and never a host this copy
        // deleted (see `deletedHostIDs`).
        var seenHostIDs = Set(groups.flatMap(\.hosts).map(\.id)).union(deletedHostIDs)
        for i in merged.indices {
            guard let diskGroup = diskGroupsByID[merged[i].id] else { continue }
            // Deduped by id for the same reason the group merge below is: a
            // disk group can carry the same host id twice, and appending both
            // puts two rows with one identity into the outline.
            let hostsOnlyOnDisk = diskGroup.hosts.filter { seenHostIDs.insert($0.id).inserted }
            guard !hostsOnlyOnDisk.isEmpty else { continue }
            merged[i].hosts.append(contentsOf: hostsOnlyOnDisk)
            changed = true
        }

        // Deduped by id, not just filtered: a file can carry the SAME group
        // id twice (imports, LAN shares and restores all copy ids), and
        // appending both would put two groups with one id into `groups` —
        // colliding SwiftUI row identities, the same class of bug that made
        // recents get a fresh id per entry.
        var seenGroupIDs = knownIDs.union(deletedGroupIDs)
        let groupsOnlyOnDisk = diskGroups.filter { seenGroupIDs.insert($0.id).inserted }
            .map { group -> HostGroup in
                // A group new to us can still carry hosts we already hold
                // elsewhere or have deleted — same rule as above.
                var g = group
                g.hosts = g.hosts.filter { seenHostIDs.insert($0.id).inserted }
                return g
            }
        if !groupsOnlyOnDisk.isEmpty {
            merged.append(contentsOf: groupsOnlyOnDisk)
            changed = true
        }

        if changed {
            groups = merged
        }
    }

    /// Same merge for recents: most-recent-first (in-memory order wins),
    /// deduped by (address, port, username), capped at the usual limit.
    /// Only publishes when the capped/deduped result actually differs from
    /// what's already in memory — same "don't publish from a view update
    /// for nothing" reasoning as the groups merge above.
    private func mergeRecentsFromDiskIfNeeded() {
        guard let diskMtime = Self.mtime(of: Self.recentsURL),
              knownRecentsMtime == nil || diskMtime > knownRecentsMtime! else { return }
        guard let data = try? Data(contentsOf: Self.recentsURL),
              let diskRecents = try? JSONDecoder().decode([Host].self, from: data) else {
            _ = quarantineUnreadable(Self.recentsURL)
            return
        }
        // OUR list first and whole: the tombstone speaks about what the other
        // copy's file may put back, never about what this copy is holding.
        // Seeding one shared filter with it (which is how this was first
        // written) also dropped entries from `recents` itself, so a row a
        // BACKUP RESTORE had just put back vanished at the next merge — the
        // group/host merge never had that hole because its result starts as
        // the in-memory list and the filter only ever guards the disk side.
        var seen = Set<String>()
        var merged: [Host] = []
        for host in recents where seen.insert(host.connectionKey).inserted {
            merged.append(host)
        }
        for host in diskRecents {
            guard !deletedRecentKeys.contains(host.connectionKey) else { continue }
            if seen.insert(host.connectionKey).inserted { merged.append(host) }
        }
        let capped = Array(merged.prefix(Self.maxRecents))
        if capped != recents {
            recents = capped
        }
    }

    private static func mtime(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Every write first copies the existing file to "<name>.bak" (a
    /// failed backup only logs — it must not block the save) and reports
    /// success, because a silently lost write means hosts vanish on the
    /// next launch.
    @discardableResult
    private func write(_ value: some Encodable, to url: URL) -> Bool {
        guard !suppressWritesAfterCorruptLoad else {
            NSLog("SheepTerm: write to %@ suppressed until the first user change (corrupt previous file was preserved)",
                  url.lastPathComponent)
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            if FileManager.default.fileExists(atPath: url.path) {
                // Copy beside the old .bak and swap, so a failed copy leaves
                // the PREVIOUS backup in place instead of no backup at all.
                let backupURL = url.appendingPathExtension("bak")
                let stagingURL = url.appendingPathExtension("bak.tmp")
                do {
                    try? FileManager.default.removeItem(at: stagingURL)
                    try FileManager.default.copyItem(at: url, to: stagingURL)
                    _ = try FileManager.default.replaceItemAt(backupURL, withItemAt: stagingURL)
                } catch {
                    try? FileManager.default.removeItem(at: stagingURL)
                    NSLog("SheepTerm: could not back up %@: %@",
                          url.lastPathComponent, error.localizedDescription)
                }
            }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("SheepTerm: failed to write %@: %@", url.lastPathComponent, error.localizedDescription)
            return false
        }
    }

    // MARK: Recents

    func noteRecent(_ host: Host) {
        // NOT a user mutation: a connection succeeding is not the user
        // changing anything, and re-arming writes here let the first connect
        // after a launch that found recents.json unreadable overwrite that
        // file — the .bak copy of an unreadable file fails too, so with no
        // backup at all. The recent is kept in memory; it reaches disk with
        // the next real edit, exactly as the launch warning promises.
        // Recents always get a fresh id — reusing the host's id made two
        // entries share one id (colliding SwiftUI row identities).
        var entry = host
        entry.id = UUID()
        // Connecting to it again is the user asking for it back.
        deletedRecentKeys.remove(entry.connectionKey)
        recents.removeAll { $0.sameConnection(as: entry) }
        recents.insert(entry, at: 0)
        if recents.count > Self.maxRecents {
            recents = Array(recents.prefix(Self.maxRecents))
        }
        saveRecents()
    }

    func removeRecent(_ host: Host) {
        noteUserMutation()
        // Match by connection key, not id: the caller hands us a host
        // whose id need not be the recent entry's id.
        deletedRecentKeys.insert(host.connectionKey)
        recents.removeAll { $0.sameConnection(as: host) }
        saveRecents()
    }

    // MARK: Group management

    func addGroup(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !groups.contains(where: { $0.name == trimmed }) else { return }
        // After the guard, like `renameGroup`: a rejected add is not a user
        // change and must not re-arm writes over a quarantined file.
        noteUserMutation()
        groups.append(HostGroup(name: trimmed, hosts: []))
        save()
    }

    /// Same duplicate-name rule as addGroup — renaming into an existing
    /// name would make the two groups indistinguishable in pickers.
    /// Returns false (and changes nothing) when the name is taken.
    @discardableResult
    func renameGroup(_ group: HostGroup, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == group.id }) else { return false }
        guard !groups.contains(where: { $0.id != group.id && $0.name == trimmed }) else { return false }
        // AFTER validation: a rejected rename is not a user change, and
        // re-arming writes on one would let the next automatic save overwrite
        // a file that was deliberately quarantined.
        noteUserMutation()
        groups[index].name = trimmed
        save()
        return true
    }

    func deleteGroup(_ group: HostGroup) {
        noteUserMutation()
        deletedGroupIDs.insert(group.id)
        for gone in groups where gone.id == group.id {
            deletedHostIDs.formUnion(gone.hosts.map(\.id))
        }
        groups.removeAll { $0.id == group.id }
        save()
    }

    /// The group an import would merge into — same id first, then same
    /// name — or nil when the import lands as a brand-new group (0.4 ก).
    func existingGroup(matching incoming: HostGroup) -> HostGroup? {
        groups.first { $0.id == incoming.id } ?? groups.first { $0.name == incoming.name }
    }

    /// "Name 2", "Name 3", … — the first numbered variant not taken, so an
    /// import never creates an accidental duplicate group name (0.4 ค4).
    func uniqueGroupName(base: String) -> String {
        if !groups.contains(where: { $0.name == base }) { return base }
        var number = 2
        while groups.contains(where: { $0.name == "\(base) \(number)" }) { number += 1 }
        return "\(base) \(number)"
    }

    /// Incoming hosts that collide with an existing host (same id, or same
    /// address+port+username) AND differ in content — the pairs the
    /// Replace/Keep dialog asks about (0.4 ข).
    func conflictingHosts(incoming: HostGroup, existing: HostGroup) -> [(incoming: Host, existing: Host)] {
        incoming.hosts.compactMap { inc in
            guard let current = existing.hosts.first(where: {
                // `sameConnection`, not address+port+username spelled out
                // again: that copy was blind to `kind`, so a serial entry
                // whose device path happened to equal an SSH host's address
                // would be offered as a conflict with it. Same omission the
                // quick-connect duplicate check had, and the same fix — there
                // is one definition of "the same target" in this app.
                $0.id == inc.id || $0.sameConnection(as: inc)
            }), !Self.sameForImport(current, inc) else { return nil }
            return (incoming: inc, existing: current)
        }
    }

    /// Equality for import conflict detection, excluding id and
    /// credentialID: the id is a local implementation detail (a file from
    /// another machine carries different ids for the same hosts) and
    /// import files never carry credentials — a host differing only in
    /// those two fields is not a conflict worth asking about, or every
    /// re-import would re-ask about hosts the user already resolved.
    ///
    /// Compared as EFFECTIVE values, the way `AppModel.savedHostChanges`
    /// does: a nil cipher is auto and a nil family is auto. An entry saved
    /// before those fields existed carries nil; one saved by Quick Connect or
    /// Edit Host carries a literal `auto` — the same host, and a re-import
    /// must not raise Replace/Keep over the spelling.
    static func sameForImport(_ a: Host, _ b: Host) -> Bool {
        a.name == b.name && a.kind == b.kind && a.address == b.address
            && a.port == b.port && a.username == b.username
            && (a.cipherMode ?? .auto) == (b.cipherMode ?? .auto)
            && (a.agentForward ?? false) == (b.agentForward ?? false)
            // The device family travels in the file and decides which
            // highlight pack a session gets. Leaving it out of this test made
            // a file that changed ONLY the family (Cisco → Aruba CX) look
            // identical: no conflict was raised, and the merge below skipped
            // the host on the same test, so even answering Replace kept the
            // old family.
            && a.highlightVendor == b.highlightVendor
    }

    /// Applies an import after the dialog decided the outcome (0.4).
    /// `.merge` adds new hosts and replaces/keeps conflicts per `replace`
    /// (incoming host id → true = use the file's version); `.createNew`
    /// appends the group under a unique numbered name with a fresh id.
    /// Invariants (0.4 ค): the existing group's name is never changed,
    /// hosts only in the existing group are never deleted, and a replaced
    /// host keeps its credentialID — the file carries none.
    @discardableResult
    func applyImport(_ incoming: HostGroup, action: ImportGroupAction, replace: [UUID: Bool]) -> GroupImportStats {
        noteUserMutation()
        var stats = GroupImportStats()
        switch action {
        case .createNew:
            var group = incoming
            group.id = UUID()
            group.name = uniqueGroupName(base: incoming.name)
            group.hosts = Self.freshIDs(group.hosts)
            groups.append(group)
            stats.addedGroup = true
            stats.addedHosts = group.hosts.count
        case .merge:
            guard let index = groups.firstIndex(where: { $0.id == incoming.id })
                ?? groups.firstIndex(where: { $0.name == incoming.name }) else {
                // The match vanished between dialog and apply — land as a
                // new group instead of failing silently.
                var group = incoming
                group.id = UUID()
                group.name = uniqueGroupName(base: incoming.name)
                group.hosts = Self.freshIDs(group.hosts)
                groups.append(group)
                stats.addedGroup = true
                stats.addedHosts = group.hosts.count
                break
            }
            // 0.4 (ค)2: never rename the existing group after the file.
            for inc in incoming.hosts {
                // `sameConnection`, the same test `conflictingHosts` uses.
                // This copy was blind to `kind`: a serial host whose device
                // path equalled an SSH host's address matched it here, was
                // "the same" for neither test, had no Replace answer — and was
                // neither replaced nor added. Dropped, with stats saying 0/0.
                if let hostIndex = groups[index].hosts.firstIndex(where: {
                    $0.id == inc.id || $0.sameConnection(as: inc)
                }) {
                    let current = groups[index].hosts[hostIndex]
                    guard !Self.sameForImport(current, inc) else { continue }
                    // No decision (aborted dialog) defaults to keep.
                    guard replace[inc.id] == true else { continue }
                    var merged = inc
                    // 0.4 (ค)1: a replaced host keeps OUR credential
                    // reference — the file carries none — and OUR id, so
                    // open tabs and the sidebar keep pointing at it.
                    merged.credentialID = current.credentialID
                    merged.id = current.id
                    groups[index].hosts[hostIndex] = merged
                    stats.replacedHosts += 1
                } else {
                    var added = inc
                    added.id = UUID()
                    groups[index].hosts.append(added)
                    stats.addedHosts += 1
                }
            }
        }
        save()
        return stats
    }

    /// A host id must be unique across ALL groups: removeHost and updateHost
    /// look hosts up by id, and the sidebar caches rows by it. The file's
    /// own ids are kept out on purpose — importing the same file twice as
    /// two groups used to give both groups hosts with identical ids, so one
    /// delete removed the host from BOTH and an edit reached only the first.
    /// Conflict matching does not need them (address+port+username).
    private static func freshIDs(_ hosts: [Host]) -> [Host] {
        hosts.map { var host = $0; host.id = UUID(); return host }
    }

    /// Records a live device-family switch everywhere this connection is
    /// remembered. Matched by connection identity, not id, so a tab opened
    /// from a recent entry still updates the saved host it belongs to.
    ///
    /// EVERY match is written, not just the first: the same box can be saved
    /// in two groups, and leaving the others stale means the choice silently
    /// depends on which copy you happened to launch from. Recents are written
    /// too — a Quick Connect target or a serial console that is not a saved
    /// host has nowhere else to keep it, and that is precisely the case where
    /// the family had to be identified by eye and must not be asked again.
    func setVendor(_ vendor: Vendor, matching target: Host) {
        var changedHosts = false
        for groupIndex in groups.indices {
            for hostIndex in groups[groupIndex].hosts.indices
            where groups[groupIndex].hosts[hostIndex].sameConnection(as: target)
                && groups[groupIndex].hosts[hostIndex].vendor != vendor {
                if !changedHosts { noteUserMutation(); changedHosts = true }
                groups[groupIndex].hosts[hostIndex].vendor = vendor
            }
        }
        if changedHosts { save() }

        var changedRecents = false
        for index in recents.indices
        where recents[index].sameConnection(as: target) && recents[index].vendor != vendor {
            // Before the write, not after: this is a user action, and under
            // post-corrupt write suppression an un-armed saveRecents() drops
            // it silently — which is exactly the Quick Connect / serial
            // console case this method exists for.
            if !changedRecents { noteUserMutation(); changedRecents = true }
            recents[index].vendor = vendor
        }
        if changedRecents { saveRecents() }
    }

    func updateHost(_ host: Host) {
        noteUserMutation()
        for groupIndex in groups.indices {
            if let hostIndex = groups[groupIndex].hosts.firstIndex(where: { $0.id == host.id }) {
                let old = groups[groupIndex].hosts[hostIndex]
                groups[groupIndex].hosts[hostIndex] = host
                // Recents keyed by the old address+port+username follow
                // the edit instead of pointing at a stale connection.
                updateRecents(from: old, to: host)
                save()
                return
            }
        }
    }

    /// Recents matching old's connection key take over the new values;
    /// dedup afterwards in case the new values now collide with another
    /// recent entry.
    private func updateRecents(from old: Host, to new: Host) {
        var changed = false
        for index in recents.indices where recents[index].sameConnection(as: old) {
            recents[index].name = new.name
            recents[index].kind = new.kind
            recents[index].address = new.address
            recents[index].port = new.port
            recents[index].username = new.username
            recents[index].credentialID = new.credentialID
            recents[index].cipherMode = new.cipherMode
            recents[index].agentForward = new.agentForward
            recents[index].vendor = new.vendor
            changed = true
        }
        guard changed else { return }
        var seen = Set<String>()
        recents = recents.filter { seen.insert($0.connectionKey).inserted }
        if recents.count > Self.maxRecents {
            recents = Array(recents.prefix(Self.maxRecents))
        }
        saveRecents()
    }

    func removeHost(_ host: Host) {
        noteUserMutation()
        deletedHostIDs.insert(host.id)
        for index in groups.indices {
            groups[index].hosts.removeAll { $0.id == host.id }
        }
        // A removed host must not linger in Recent — it can no longer be
        // connected to.
        let countBefore = recents.count
        recents.removeAll { $0.sameConnection(as: host) }
        if recents.count != countBefore { saveRecents() }
        save()
    }

    // MARK: Credential references

    /// How many saved hosts reference a credential — shown in the delete
    /// confirmation before the credential is removed.
    /// Counts recents too: the delete dialog quoting a smaller number than
    /// the change actually affects is worse than no number.
    func hostCount(usingCredential id: UUID) -> Int {
        groups.reduce(0) { $0 + $1.hosts.filter { $0.credentialID == id }.count }
            + recents.filter { $0.credentialID == id }.count
    }

    /// Detaches a credential from every host that references it (used
    /// when the credential itself is deleted, so hosts fall back to
    /// manual login instead of pointing at a dead Keychain entry).
    func clearCredentialID(_ id: UUID) {
        noteUserMutation()
        var changed = false
        for groupIndex in groups.indices {
            for hostIndex in groups[groupIndex].hosts.indices
            where groups[groupIndex].hosts[hostIndex].credentialID == id {
                groups[groupIndex].hosts[hostIndex].credentialID = nil
                changed = true
            }
        }
        if changed { save() }
        // Recents carry credentialID too (updateRecents propagates it on an
        // edit), so leaving them behind pointed at a Keychain entry that no
        // longer exists.
        var changedRecents = false
        for index in recents.indices where recents[index].credentialID == id {
            recents[index].credentialID = nil
            changedRecents = true
        }
        if changedRecents { saveRecents() }
    }

    /// Where a host currently lives, as (group index, index in that group).
    /// Public twin of `locateHost` — the sidebar needs it to work out which
    /// side of the row under the pointer the insertion gap belongs on.
    func location(ofHost id: UUID) -> (group: Int, index: Int)? {
        locateHost(id)
    }

    /// Position of a group in the sidebar order.
    func location(ofGroup id: UUID) -> Int? {
        groups.firstIndex { $0.id == id }
    }

    /// Where a host currently lives, as (group index, index in that group).
    private func locateHost(_ id: UUID) -> (group: Int, index: Int)? {
        for groupIndex in groups.indices {
            if let hostIndex = groups[groupIndex].hosts.firstIndex(where: { $0.id == id }) {
                return (groupIndex, hostIndex)
            }
        }
        return nil
    }


    /// Index-based group move — the sidebar's NSOutlineView reports a drop
    /// as "insert before child N of the root", counted BEFORE the dragged row
    /// is taken out, so the destination shifts down by one when the row came
    /// from above it. Every index is clamped: the list can change under a
    /// drag that is still in flight.
    func moveGroup(withID id: UUID, toIndex index: Int) {
        guard let from = groups.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(index, groups.count))
        let destination = target > from ? target - 1 : target
        guard destination != from else { return }
        noteUserMutation()
        let group = groups.remove(at: from)
        groups.insert(group, at: min(destination, groups.count))
        save()
    }

    /// Index-based host move, within a group or into another one. Same
    /// before-removal index convention as `moveGroup`.
    func moveHost(withID id: UUID, toGroupID groupID: UUID, atIndex index: Int) {
        guard let from = locateHost(id),
              let destGroup = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var destination = max(0, min(index, groups[destGroup].hosts.count))
        if destGroup == from.group {
            if destination > from.index { destination -= 1 }
            guard destination != from.index else { return }
        }
        noteUserMutation()
        let host = groups[from.group].hosts.remove(at: from.index)
        groups[destGroup].hosts.insert(host, at: min(destination, groups[destGroup].hosts.count))
        save()
    }

    /// Moves a host into the group with this NAME, **creating it when there is
    /// no such name**. That last part makes it wrong for anything driven by
    /// the UI — a group renamed in another window between opening a menu and
    /// choosing from it would fork a second group under the old name — so the
    /// sidebar uses `moveHost(withID:toGroupID:atIndex:)` instead. What is
    /// left here is the test harness, which uses the create-on-demand to seed
    /// groups. Do not call it from app code.
    func move(host: Host, toGroupNamed name: String) {
        noteUserMutation()
        for index in groups.indices {
            groups[index].hosts.removeAll { $0.id == host.id }
        }
        if let index = groups.firstIndex(where: { $0.name == name }) {
            groups[index].hosts.append(host)
        } else {
            groups.append(HostGroup(name: name, hosts: [host]))
        }
        save()
    }

}

/// How an imported group should land — decided by the import dialog (0.4 ก).
enum ImportGroupAction {
    case merge
    case createNew
}

/// Outcome of HostStore.applyImport — callers can show what an import
/// actually did ("added 3 hosts, updated 1").
struct GroupImportStats {
    /// True when the group was appended as a brand-new group.
    var addedGroup = false
    /// Hosts appended to an existing (or new) group.
    var addedHosts = 0
    /// Existing hosts overwritten by an incoming host with the same id
    /// or address+port+username.
    var replacedHosts = 0
}

extension String {
    /// Sidebar / Quick Search matching: case- and diacritic-insensitive, so
    /// `cafe` finds `café-sw1`. Thai has neither, so it is unaffected.
    func matchesSearch(_ query: String) -> Bool {
        range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
    }
}
