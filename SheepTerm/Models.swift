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
    /// Sub-heading inside the host's group — a floor, a rack, a role. A
    /// LABEL, not a container: the group still holds a flat array of hosts
    /// and the sidebar gathers the ones that share a label under a row of
    /// their own, so there is nothing to keep in step and nothing to orphan.
    /// One level: a host is either loose in its group or under one of the
    /// group's sections.
    ///
    /// Optional so every file written before this build decodes unchanged,
    /// and so a file written by this build opens in an older build (which
    /// ignores the key and shows every host loose).
    ///
    /// Deliberately NOT part of `connectionKey`/`sameConnection`: it says
    /// where a host is FILED, not what it is, so re-filing a host must not
    /// make it a different target or a conflict on import.
    var section: String? = nil
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

    /// The section as a VALUE: nil, "" and "   " all mean "loose in the
    /// group", and every reader asks this rather than `section` so the three
    /// cannot behave differently.
    var sectionName: String? {
        guard let section else { return nil }
        let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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

extension Host {
    /// This host with the bookkeeping that belongs to THIS Mac taken from the
    /// entry already in the store: the `id` every sidebar row and open tab
    /// knows it by, and the `section` it is filed under.
    ///
    /// A heading is local filing, exactly like the id — a `.sheepterm` file
    /// does not get to say where you keep something, and neither does a Quick
    /// Connect form that has never heard of sections. Both of those hand over
    /// a host built somewhere that cannot know either field, and both used to
    /// write their nil straight over it: Replace on an import silently
    /// unfiled the host, and "Update Saved Host" wiped its heading.
    ///
    /// `credentialID` is deliberately NOT here: an import never carries one
    /// (so its caller keeps ours), while the Quick Connect form chooses one
    /// on purpose and must be allowed to change it.
    func carryingLocalFiling(from current: Host) -> Host {
        var copy = self
        copy.id = current.id
        copy.section = current.section
        return copy
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
                lines.append("• \(shortenedNames) name(s) or section label(s) were shortened to "
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
    /// C0 and C1 CONTROL characters only. `CharacterSet.controlCharacters`
    /// is Cc AND Cf, and Cf is the zero-width joiner in "🏳️‍🌈", the ZWNJ that
    /// Persian spelling depends on, the BOM: stripping those rewrote names
    /// and then reported "had control characters removed" on every import.
    static let controlOnly: CharacterSet = {
        var set = CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(0x1F))
        set.insert(charactersIn: Unicode.Scalar(0x7F)...Unicode.Scalar(0x9F))
        return set
    }()

    static func sanitizedName(_ text: String) -> String {
        let noControls = text.components(separatedBy: controlOnly).joined()
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
            // The section is a sidebar heading and a menu item, so it gets the
            // same pass the name gets. Nothing left of it = no section at all
            // (nil), never a placeholder: an invented heading would file the
            // host under something nobody named, where loose in its group is
            // the honest outcome.
            if let section = hosts[index].section {
                let cleaned = sanitizedName(section)
                if cleaned != section { report.shortenedNames += 1 }
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                hosts[index].section = trimmed.isEmpty ? nil : trimmed
            }
            // Control characters only — no length cap here: an address is
            // handed to libssh / the serial open, and a username to the login,
            // where a newline is a different (wrong) value, not a long one.
            for keyPath in [\Host.address, \Host.username] {
                let value = hosts[index][keyPath: keyPath]
                let cleaned = value.components(separatedBy: controlOnly).joined()
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
            // `cleanGroupName`, not `sanitizedName`: a group name is trimmed
            // as well, everywhere one is written, and a restored "  Lab  "
            // that kept its padding read as a different group from "Lab".
            let cleaned = HostStore.cleanGroupName(groups[index].name)
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
        // `isHexDigit` alone admits fullwidth Ａ–Ｆ／０–９, which made
        // "ＡＢ::１" a Connect row.
        guard address.allSatisfy({ ($0.isASCII && $0.isHexDigit) || $0 == ":" || $0 == "." }) else { return false }
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

/// The paste side of the "Add Hosts…" sheet: clipboard text → table rows →
/// `Host`. Pure, and deliberately in Models rather than beside the sheet —
/// the rules here (which column is which, what counts as an address, which
/// credential a name means) are the part that can be wrong in a way the user
/// only discovers weeks later, and a rule that needs a window to run does not
/// get tested.
///
/// It knows nothing about `Credential`/`CredentialStore` on purpose: the
/// saved credentials arrive as plain triples, so the harness (whose sources
/// stop at Models) can exercise the same code the sheet runs.
enum BulkHostParser {
    /// The three table columns a paste can land in.
    enum Column {
        case name
        case address
        case credential
        /// The host's own sub-heading inside its group (`Host.section`).
        /// Per ROW: two hosts of one paste can go under two headings.
        case section
    }

    /// Left to right, the way a pasted block's fields are read off when the
    /// paste carries no header. A block dropped on the Host / IP cell puts its
    /// second field in Credential, and fields that run off the right edge are
    /// dropped — the same rule a spreadsheet follows.
    static let columnOrder: [Column] = [.name, .address, .credential, .section]

    /// Where every cell of a pasted block lands, as offsets from the cell the
    /// paste started in: block row 0 goes in the anchor's own row, field 0 in
    /// the anchor's own column. Fields that run off the right edge are
    /// dropped, because there is no fourth column to put them in.
    ///
    /// Pure, and separate from the sheet, because "which cell does this end
    /// up in" is the whole of an Excel-style paste and the answer must not
    /// depend on a window being open.
    /// `columns` is a header row's mapping, when the paste carried one: it
    /// says what each field IS, so it wins over where the paste was anchored
    /// — a sheet whose first column is Section must not land its sections in
    /// the Name cells because the cursor happened to be there. Without a
    /// header the positions are read off `columnOrder` from the anchor.
    static func spread(block: [[String]],
                       from anchor: Column,
                       columns: [Column?]? = nil) -> [(row: Int, column: Column, value: String)] {
        var cells: [(row: Int, column: Column, value: String)] = []
        if let columns {
            for (rowOffset, fields) in block.enumerated() {
                for (fieldIndex, value) in fields.enumerated() {
                    guard fieldIndex < columns.count, let column = columns[fieldIndex] else { continue }
                    cells.append((row: rowOffset, column: column, value: value))
                }
            }
            return cells
        }
        guard let start = columnOrder.firstIndex(of: anchor) else { return [] }
        for (rowOffset, fields) in block.enumerated() {
            for (fieldIndex, value) in fields.enumerated() {
                let columnIndex = start + fieldIndex
                guard columnIndex < columnOrder.count else { break }
                cells.append((row: rowOffset, column: columnOrder[columnIndex], value: value))
            }
        }
        return cells
    }

    /// True when text could only have arrived in a single-line field by being
    /// pasted: Tab moves focus and Return submits, so neither character can be
    /// typed into one.
    static func carriesBlockSeparators(_ text: String) -> Bool {
        text.contains { $0 == "\t" || $0 == "\n" || $0 == "\r" }
    }

    /// The pasted text as ONE value, when that is all it is — or nil when it
    /// is a block and belongs to `spread`.
    ///
    /// ⌘V of a single cell out of Excel carries a trailing newline, so
    /// `carriesBlockSeparators` says "block" for it; a name like
    /// `Core, floor 3` was then split at the comma into two columns. One line
    /// (nothing but trailing newlines) with no tab in it is a value, and the
    /// comma inside it is part of the name — a delimiter needs a second line
    /// or a tab to be a delimiter.
    static func singleValue(ifPlain text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isNewline }),
              !trimmed.contains("\t") else { return nil }
        return trimmed
    }

    /// The ONLY headings this app accepts, lower-cased. A header row has to
    /// match these exactly (case and surrounding whitespace aside) or the
    /// paste is REFUSED — "close enough" was tried and the failure is silent
    /// and expensive: a sheet headed `Name,IP,Port` was not recognised at
    /// all, landed as a host called "Name" pointing at "IP", and shifted
    /// every real row's Port value into Credential, where it became that
    /// host's username.
    ///
    /// It is a MAP, not a list, because a header also says what ORDER the
    /// columns are in: a sheet that puts Section first is as valid as one
    /// that puts Name first, and only the header can tell us which.
    static let headingColumns: [String: Column] = [
        "name": .name,
        "host / ip": .address, "host/ip": .address,
        "host": .address, "ip": .address, "address": .address,
        "credential": .credential,
        "section": .section,
    ]

    /// What the alert offers when a header is refused.
    static let acceptedHeadingSummary =
        "Name, Host / IP, Credential, Section (any order; Host, IP or Address also mean Host / IP)"

    /// Is this row a HEADER at all? A data row always carries a TARGET, so a
    /// first line with no address anywhere in it is a header — right or
    /// wrong. A single field is the exception: one value per line is how a
    /// column of names is pasted, and "core-sw" on its own is data unless it
    /// happens to be one of the accepted headings.
    static func looksLikeHeader(_ row: [String]) -> Bool {
        let named = row.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !named.isEmpty else { return false }
        // A data row carries a target; a header row carries at least one of
        // OUR column names. Both are required — "no address" alone made a
        // column of section labels or credential names, or a `name ⇥ section`
        // block pasted before the addresses, into a "header" that was then
        // refused. A row with neither is data (positional), and a row with
        // one of our names beside a stranger ("Name,IP,Port") is the header
        // that `headerProblems` refuses.
        return !named.contains(where: looksLikeAddress)
            && named.contains { headingColumns[$0.lowercased()] != nil }
    }

    /// A row that is DATA but has a header's shape: several fields, no
    /// address, and not one name this app knows. `ชื่อ,ไอพี` is such a row —
    /// so is `sw1<TAB>Floor 1`, which is why this only warns and never
    /// decides: a Floor column is real data and losing it would be worse
    /// than a line of status text nobody needed.
    static func mightHaveBeenHeader(_ row: [String]) -> Bool {
        let named = row.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard named.count > 1, !named.contains(where: looksLikeAddress) else { return false }
        return !named.contains { headingColumns[$0.lowercased()] != nil }
    }

    /// The names in a header row this app will not take: anything that is not
    /// an accepted heading, plus any column named twice (two Name columns
    /// have no order between them). Empty in a header it accepts.
    static func headerProblems(_ row: [String]) -> [String] {
        var problems: [String] = []
        var seen = Set<Column>()
        for field in row {
            let name = field.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            guard let column = headingColumns[name.lowercased()] else {
                problems.append(name)
                continue
            }
            if !seen.insert(column).inserted { problems.append(name) }
        }
        return problems
    }

    /// True for a name this app accepts as a heading — the alert uses it to
    /// say "unknown" or "duplicate" about each refused name.
    static func isAcceptedHeading(_ name: String) -> Bool {
        headingColumns[name.trimmingCharacters(in: .whitespaces).lowercased()] != nil
    }

    /// Clipboard text → one array of trimmed fields per data line.
    ///
    /// Tab wins over comma wherever both appear: Excel, Numbers and Sheets all
    /// put TAB-separated text on the clipboard, and a name like
    /// "Core, floor 3" would otherwise split itself in half.
    /// Just the data rows, for callers that do not care how the columns were
    /// labelled (the spread's own positional path, and the tests).
    static func rows(from text: String) -> [[String]] {
        block(from: text).rows
    }

    static func block(from text: String) -> Block {
        // One leading BOM, dropped. Excel's "CSV UTF-8" export starts with
        // U+FEFF, which made the first field "\u{FEFF}Name": the header was
        // not recognised, and a host called "Name" pointing at "IP" landed.
        // Only at the very start — a BOM anywhere else is not a BOM.
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // `isNewline` covers CRLF as one Character (it is a single grapheme
        // cluster), so \r\n / \r / \n all arrive here as a line break — no
        // pre-pass that turns \r\n into two empty lines.
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // "#" is how a hand-kept list comments out a decommissioned
            // switch; blank lines are what a spreadsheet leaves behind.
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return Block(rows: [], columns: nil, header: nil) }

        let fields: [[String]]
        if lines.contains(where: { $0.contains("\t") }) {
            fields = lines.map { split($0, separator: "\t", quoted: false) }
        } else if lines.contains(where: { $0.contains(",") }) {
            // Quote-aware only here: a CSV file really does write
            // `"Core, floor 3",10.0.0.1`, and that is the one delimiter a
            // field is allowed to contain.
            fields = lines.map { split($0, separator: ",", quoted: true) }
        } else {
            // A list with no delimiter at all. Two shapes arrive here: one
            // value per line (a column copied out of a spreadsheet — Excel
            // puts NO tab on the clipboard for a single column), or
            // `name 10.0.0.1` pasted out of a text file. Splitting on
            // whitespace served the second and broke the first: a column of
            // section labels like "Floor 1" was cut into "Floor" and "1", and
            // then refused as a header. So the split happens only when every
            // line is genuinely `name target` — two or more words with an
            // address among them; otherwise each line is one value, spaces
            // and all.
            // Per LINE, not per list: `sw1 10.0.0.1` and `Floor 3` arrive in
            // the same paste all the time (a name column with a couple of
            // `name target` lines in it), and an all-or-nothing decision
            // either cut "Floor 3" in half or left the two real rows
            // unsplit. A line splits when it is genuinely `name target` —
            // two or more words with a target among them.
            fields = lines.map { line in
                let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
                return words.count >= 2 && words.contains(where: looksLikeTarget) ? words : [line]
            }
        }

        // A line of nothing but delimiters (",,") carries no value.
        var rows = fields.filter { row in row.contains { !$0.isEmpty } }
        var columns: [Column?]?
        var header: [String]?
        var mayBeHeader = false
        if let first = rows.first, looksLikeHeader(first) {
            let problems = headerProblems(first)
            // Refused, not guessed: nothing is placed, and the caller shows
            // the names it could not take.
            guard problems.isEmpty else {
                return Block(rows: [], columns: nil, header: first, rejectedHeader: problems)
            }
            columns = headerMap(first)
            header = first
            rows.removeFirst()
        } else if let first = rows.first {
            mayBeHeader = mightHaveBeenHeader(first)
        }
        return Block(rows: rows, columns: columns, header: header,
                     rejectedHeader: nil, firstRowMayBeHeader: mayBeHeader)
    }

    /// A parsed paste or file: the data rows, and — when the first line was a
    /// header — which column each field position belongs to. Without a header
    /// the positions mean `columnOrder`, left to right.
    struct Block {
        var rows: [[String]]
        var columns: [Column?]?
        /// The header row as it was written, when there was one — verbatim,
        /// because it is shown back to the user when it is refused.
        var header: [String]?
        /// The heading names this app would not take, when the first line was
        /// header-shaped and did not match. Non-nil means **nothing was
        /// parsed**: `rows` is empty on purpose and the caller must say so
        /// rather than place anything.
        var rejectedHeader: [String]?
        /// The first row was KEPT as data but looks like it might have been
        /// meant as a header: two or more fields, no address anywhere in it,
        /// and not one accepted column name — `ชื่อ,ไอพี` is the case this
        /// exists for. It is data, because a `Floor 1` column has exactly the
        /// same shape and must survive; the caller says so in its status line
        /// rather than deciding for the user.
        var firstRowMayBeHeader = false

        var isEmpty: Bool { rows.isEmpty }
    }

    /// Which column each position of an ACCEPTED header row names, or nil
    /// when the row is not a header this app takes. An empty field maps to
    /// nothing and is skipped (Excel writes a trailing comma constantly).
    static func headerMap(_ row: [String]) -> [Column?]? {
        guard looksLikeHeader(row), headerProblems(row).isEmpty else { return nil }
        return row.map { field in
            let name = field.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : headingColumns[name.lowercased()]
        }
    }

    private static func split(_ line: String, separator: Character, quoted: Bool) -> [String] {
        var out: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character? = iterator.next()
        while let character = pending {
            pending = iterator.next()
            if quoted, character == "\"" {
                // "" inside a quoted field is one literal quote (RFC 4180).
                if inQuotes, pending == "\"" {
                    field.append("\"")
                    pending = iterator.next()
                } else {
                    inQuotes.toggle()
                }
                continue
            }
            if character == separator, !inQuotes {
                out.append(field)
                field = ""
                continue
            }
            field.append(character)
        }
        out.append(field)
        return out.map { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // One layer of surrounding quotes — for the UNQUOTED paths only.
            // A TSV cell that Excel decided to quote still means its content;
            // but on the quote-aware path the quotes have already been read,
            // so stripping again turned `\"\"\"Core\"\"\"` (a CSV field whose
            // value really is `\"Core\"`) into a bare `Core`.
            guard !quoted, trimmed.count >= 2,
                  trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed }
            return String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The largest file Import CSV… will read. A host list is a few hundred
    /// lines; the sheet used to read and parse whatever was dropped on it,
    /// whole, on the main thread — a 64 MB file took ten seconds and 780 MB
    /// of RSS before the gate below even got to say no.
    static let maxImportBytes = 8 << 20

    static func importSizeAllowed(bytes: Int) -> Bool {
        bytes >= 0 && bytes <= maxImportBytes
    }

    /// How many rows a paste anchored at `anchor` may still place: the cap
    /// bounds the GRID, not each block, so a second 2,000-row paste cannot
    /// take the grid to 4,000 rows.
    static func rowBudget(anchor: Int, existing: Int, cap: Int) -> Int {
        max(0, cap - max(anchor, existing))
    }

    /// What to add to a paste's status line when the grid could not take the
    /// whole block. `placed` is what landed, `cap` the grid's limit.
    static func capNote(placed: Int, cap: Int) -> String {
        if placed == 0 { return " · grid is full (\(cap) rows)" }
        // "first 1 rows only" is the kind of sentence that makes the whole
        // dialog look machine-written.
        if placed == 1 { return " · first row only (grid cap \(cap))" }
        return " · first \(placed) rows only (grid cap \(cap))"
    }

    /// Does this file look like a list of HOSTS at all?
    ///
    /// Only the FILE path asks (Import CSV… and a dropped file): a clipboard
    /// paste lands in the grid where the user can see it and delete it, while
    /// a file is chosen blind and 800 rows of a README is not something to
    /// fill the sheet with.
    ///
    /// Counting `looksLikeAddress` per field was the first attempt and it
    /// refused real lists: a CSV of `core-sw-01` style hostnames has no dots
    /// and no colons anywhere. So the question is about the COLUMN that is
    /// supposed to hold targets — named by the header when there is one,
    /// position 1 when there is not — plus a cheap "is this even text" test.
    ///
    /// A file whose rows are single values is accepted: one value per line is
    /// how a column of names is exported, and `guessColumn` decides what it
    /// is. That is a deliberate choice — the grid shows it and nothing is
    /// written until Add.
    static func looksLikeHostList(_ block: Block, text: String) -> Bool {
        guard !block.rows.isEmpty else { return false }
        // Binary-ish: control characters other than tab/CR/LF. A PNG or a
        // .dat opened as Latin-1 decodes to "text" and parses into rows.
        let sample = text.unicodeScalars.prefix(4_000)
        let control = sample.filter { scalar in
            scalar.properties.generalCategory == .control
                && scalar != "\t" && scalar != "\n" && scalar != "\r"
        }.count
        if !sample.isEmpty, Double(control) / Double(sample.count) > 0.01 { return false }

        func usable(_ field: String?) -> Bool {
            guard let field else { return false }
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.contains(where: { $0.isWhitespace })
        }
        // A header told us which column holds the target.
        if let columns = block.columns, let at = columns.firstIndex(of: .address) {
            let good = block.rows.filter { usable($0.indices.contains(at) ? $0[at] : nil) }.count
            return good * 2 >= block.rows.count
        }
        // No header, and every row is ONE value: a column copied out of a
        // spreadsheet. Accepted only when the values look like things that
        // belong in a cell — a hostname, an address, or a short label like
        // "Floor 1" (that is a legitimate Section column) — which is what
        // separates them from PROSE. A README's lines are long and wordy; a
        // column's are short and few-worded.
        if block.rows.allSatisfy({ $0.count == 1 }) {
            let values = block.rows.compactMap(\.first)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !values.isEmpty else { return false }
            if guessColumn(forSingleColumn: values) == .address { return true }
            // A cell holds a NAME or a short label: at most two words, and
            // within the name cap. Three words was too generous — "Call the
            // vendor" and "Order the SFP" are a to-do list, not a column —
            // while "Floor 1" is exactly the Section column this accepts.
            let cellLike = values.filter { value in
                value.count <= ConfigurationHygiene.maxNameLength
                    && value.split(whereSeparator: \.isWhitespace).count <= 2
            }.count
            if cellLike * 2 >= values.count { return true }
            // …or a column of single words, whatever their length.
            let wordy = values.filter { !$0.contains(where: { $0.isWhitespace }) }.count
            return wordy * 2 >= values.count
        }
        let good = block.rows.filter { row in
            usable(row.indices.contains(1) ? row[1] : nil) || row.contains(where: looksLikeAddress)
        }.count
        return good * 2 >= block.rows.count
    }

    /// The STRICT target test, for deciding whether a whitespace-separated
    /// line is `name target` and may be split at all.
    ///
    /// `looksLikeAddress` is too generous here on purpose — it only has to
    /// pick a column and the user can see the result — and `1.5` passes it,
    /// so a pasted column of `Rack 3.2` / `MDF 2.1` / `Floor 10.5` was cut in
    /// half at the space. A real target carries a letter, or a second dot, or
    /// one of `: @ [`; `10.0.0.1`, `sw1.lab.example.com`, `admin@h` and
    /// `h:2222` all do, and a floor number does not.
    static func looksLikeTarget(_ s: String) -> Bool {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeAddress(text) else { return false }
        if text.contains(":") || text.contains("@") || text.contains("[") { return true }
        if text.contains(where: { $0.isLetter }) { return true }
        return text.filter { $0 == "." }.count >= 2
    }

    /// Is this text meant to be a target rather than a label? Deliberately
    /// loose — it only has to be right about which COLUMN a one-column paste
    /// belongs in, and the user can see and fix the result.
    static func looksLikeAddress(_ s: String) -> Bool {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return false }
        // A user@ can only be a login target.
        if text.contains("@") { return true }
        if text.hasPrefix("["), text.contains("]") { return true }
        if let colon = text.lastIndex(of: ":") {
            // `2001:db8::1` — asked FIRST, because host:port would read the
            // last group of an IPv6 address as a port.
            if text.filter({ $0 == ":" }).count > 1 {
                return ConnectParser.looksLikeIPv6(text)
            }
            // host:port. `looksLikeIPv6` alone is no use here: every hex word
            // ("face", "abc") passes it, which is exactly the name column.
            if !text[..<colon].isEmpty, Int(text[text.index(after: colon)...]) != nil { return true }
        }
        // A dot with something after it: 10.0.0.1, sw1.lab.example.com. The
        // char after the dot matters — "core-sw-01." is a typo in a name.
        var previousWasDot = false
        for character in text {
            if previousWasDot, character.isLetter || character.isNumber { return true }
            previousWasDot = character == "."
        }
        return false
    }

    /// Which column a paste of exactly one field per line belongs in. Most
    /// wins: one stray label in a list of 40 addresses is a typo in the
    /// sheet, not a change of meaning.
    static func guessColumn(forSingleColumn fields: [String]) -> Column {
        let values = fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return .name }
        let addresses = values.filter(looksLikeAddress).count
        return addresses * 2 > values.count ? .address : .name
    }

    /// The credential a pasted cell names: its NAME first, then its
    /// username — a spreadsheet column headed "user" holds logins, one headed
    /// "credential" holds the names we gave them, and both are normal.
    ///
    /// nil means "no saved credential says that", which is information, not a
    /// failure: the sheet keeps the text as a plain username for that row so
    /// the user can see it was not matched. Passwords are never involved —
    /// only the id travels.
    static func resolveCredential(_ text: String,
                                  in credentials: [(id: UUID, name: String, username: String)]) -> UUID? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        if let match = credentials.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return match.id
        }
        return credentials.first { $0.username.caseInsensitiveCompare(wanted) == .orderedSame }?.id
    }

    /// Which saved credential a table row actually uses. `rowCredential` and
    /// `defaultCredential` must already have been checked to still exist —
    /// this decides between them, it cannot look either one up.
    ///
    /// The middle case is the deliberate one. A Credential cell whose text
    /// matched no saved credential is kept as that row's `pastedUsername`,
    /// which means the row names a DIFFERENT login from the sheet's default —
    /// so it gets no credential at all and will ask for a password. Falling
    /// through to the default instead replaced the pasted username with the
    /// default credential's user AND saved the default's password reference
    /// beside it: a host the user had told to log in as `netops` quietly
    /// logging in as `admin` with admin's password. Same class of bug as the
    /// one `HostEditSheet.effectiveUsername` exists for. The user was shown
    /// the alternative (unmatched text → default credential) on 2026-09-12
    /// and chose to keep this rule.
    static func credentialChoice(rowCredential: UUID?,
                                 pastedUsername: String,
                                 addressUser: String = "",
                                 defaultCredential: UUID?,
                                 defaultUsername: String = "") -> UUID? {
        if let rowCredential { return rowCredential }
        guard pastedUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // A `user@` typed into the Host / IP cell is a login the user WROTE.
        // The sheet's default credential is a blanket answer for the rows
        // that said nothing, so it must not quietly overrule one: pasting
        // `netops@10.0.0.1` with a default of `admin` used to save the host
        // as admin, with admin's password reference. Same name = no conflict,
        // and the default applies (it carries a password; the address does
        // not). Case-sensitive: logins are.
        let user = addressUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty, user != defaultUsername { return nil }
        return defaultCredential
    }

    /// The `user@` a Host / IP cell carries, or "" — the same split
    /// `makeHost` performs, so the sheet can ask the question before it
    /// builds anything.
    static func addressUser(_ address: String) -> String {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.contains("@") else { return "" }
        return ConnectParser.parse(raw, requireHostShape: false)?.username ?? ""
    }

    /// The same batch with its own headings snapped together: each host's
    /// label is matched against the labels of the hosts BEFORE it, so
    /// `Floor 2` / `Floor  2` / `floor 2` in one import become one heading
    /// instead of three rows nobody can tell apart.
    ///
    /// `applyImport(.merge)` snaps each added host against the destination's
    /// existing headings; a NEW group has none, so this is what covers
    /// `.createNew` and the merge-to-new fallback.
    static func snappedHostsWithinBatch(_ hosts: [Host]) -> [Host] {
        var seen: [String] = []
        return hosts.map { host in
            guard let label = host.sectionName else { return host }
            var copy = host
            let snapped = HostStore.snappedHeading(label, existing: seen) ?? label
            copy.section = snapped
            if !seen.contains(snapped) { seen.append(snapped) }
            return copy
        }
    }

    /// The list with hosts that name the SAME connection collapsed to the
    /// first of them, in order.
    ///
    /// Run after hygiene, never before: two rows only BECOME the same
    /// connection once a stripped control character or a narrowed port has
    /// been applied, and a pair that collapsed before the count was taken was
    /// reported to the user as "already existed" — which it never was.
    /// `applyImport` runs this over its incoming rows for BOTH actions, so a
    /// `.sheepterm` file with a row copied twice is one host either way. The
    /// sheet runs it too, before it counts: it has to report "1 repeated"
    /// rather than let the store quietly drop a row the user typed.
    static func deduped(_ hosts: [Host]) -> [Host] {
        var seen = Set<String>()
        return hosts.filter { seen.insert($0.connectionKey).inserted }
    }

    /// The list with EXACT repeats collapsed: same target, same content, same
    /// id. Everything else is two entries.
    ///
    /// This is the import side, and it is deliberately narrower than
    /// `deduped`. The app itself can hold two hosts on one target — Edit Host
    /// changes an address onto another host's, a drag brings one in from
    /// another group, a merge lands one — and the sidebar shows both. Keying
    /// the import dedupe on the target alone meant exporting that group and
    /// importing it back **silently dropped one of them**, and a row carrying
    /// an existing host's id could be thrown away in favour of a plain add, so
    /// the Replace the user was owed was never offered.
    ///
    /// A file with a row genuinely written twice is still one host: that is
    /// what "same id" catches, since a `.sheepterm` file carries our ids.
    static func dedupedExactRepeats(_ hosts: [Host]) -> [Host] {
        var kept: [Host] = []
        kept.reserveCapacity(hosts.count)
        // Bucketed by id AND target, not by target alone: a repeat has to match
        // on both, so a file with 20,000 hosts on ONE address put all 20,000
        // in one bucket and compared against every earlier row in it —
        // measured at 9 s on the main thread, before the first dialog. With
        // the id in the bucket key the buckets are one row deep again.
        // (Identical output either way: `sameForImport` is only ever asked
        // about rows that already agree on id and target.)
        var buckets: [String: [Int]] = [:]
        for host in hosts {
            let bucket = "\(host.id.uuidString)\u{0}\(host.connectionKey)"
            let repeatOfEarlier = (buckets[bucket] ?? []).contains { position in
                HostStore.sameForImport(kept[position], host)
            }
            guard !repeatOfEarlier else { continue }
            buckets[bucket, default: []].append(kept.count)
            kept.append(host)
        }
        return kept
    }

    /// How many of these hosts actually land, and under how many headings —
    /// counted over the hosts that are NEW to the group they are going into,
    /// after hygiene. The sheet used to count its rows instead, so "12 hosts
    /// filed under 2 sections" was printed for a paste where eleven of them
    /// were already there and nothing was filed at all.
    static func filedSummary(hosts: [Host], existing: [Host]) -> (hosts: Int, sections: Int) {
        // Snapped the way the store will snap them — against the headings
        // already in the group, then against each other — or two spellings of
        // one heading were reported as "2 sections" and the number disagreed
        // with the sidebar the user was about to look at.
        let already = existing.compactMap(\.sectionName)
        let seeded = hosts.map { host -> Host in
            var copy = host
            copy.section = HostStore.normalizedHeading(host.section, existing: already)
            return copy
        }
        // By KEY, not by scanning `existing` per host: 2,000 rows against a
        // 2,000-host group was four million comparisons for a status line.
        let taken = Set(existing.map(\.connectionKey))
        var labels = Set<String>()
        var count = 0
        for host in snappedHostsWithinBatch(seeded) {
            guard !taken.contains(host.connectionKey), let label = host.sectionName else { continue }
            count += 1
            labels.insert(label)
        }
        return (count, labels.count)
    }

    /// One table row → one `Host`, or nil when the address is not a usable
    /// target (the sheet counts those and says so rather than landing a host
    /// that can never connect).
    ///
    /// `credentialID`/`credentialUsername` are the credential ALREADY chosen
    /// for this row — the row's own, or the sheet's default. Deciding WHICH
    /// needs the store; naming the login does not, and that is the half that
    /// was worth testing: a credential's username and its password are one
    /// login (the bug `HostEditSheet.effectiveUsername` exists for), so a
    /// chosen credential names the user and nothing else may override it.
    /// `pastedUsername` is text from a Credential cell that matched no saved
    /// credential; it is a username, never a password.
    ///
    /// `vendor`, `cipherMode` and `agentForward` are left nil on purpose:
    /// nobody ever said (see `HostCompleteness`).
    static func makeHost(name: String,
                         address: String,
                         credentialID: UUID?,
                         credentialUsername: String?,
                         pastedUsername: String,
                         section: String? = nil) -> Host? {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let host: String
        let port: Int
        let addressUser: String
        // Same test, same parser, as HostEditSheet's Host field: a pasted
        // `admin@10.0.0.1:2222` must come apart here instead of being handed
        // to libssh whole.
        if raw.contains(":") || raw.contains("[") || raw.contains("@") {
            guard let parsed = ConnectParser.parse(raw, requireHostShape: false) else { return nil }
            host = parsed.address
            port = parsed.port
            addressUser = parsed.username
        } else {
            guard !raw.contains(where: { $0.isWhitespace }) else { return nil }
            host = raw
            port = Host.defaultSSHPort
            addressUser = ""
        }

        let username: String
        if let credentialUsername, !credentialUsername.isEmpty {
            username = credentialUsername
        } else {
            let pasted = pastedUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            username = pasted.isEmpty ? addressUser : pasted
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = section?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Host(name: trimmedName.isEmpty ? host : trimmedName,
                    kind: .ssh,
                    address: host,
                    port: port,
                    username: username,
                    credentialID: credentialID,
                    section: (label?.isEmpty ?? true) ? nil : label)
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
    /// Per FILE, not one flag for both: with one flag a corrupt hosts.json
    /// held every recents.json write for the whole session although that file
    /// was fine, and a connect's recent never reached the disk.
    private var suppressHostsWrites = false
    private var suppressRecentsWrites = false
    /// A recent that `noteRecent` could not write (writes held) and that the
    /// next real save has to carry to disk — `noteRecent` is not a user
    /// mutation, so nothing else would.
    private var recentsPendingWrite = false

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
        if !warnings.isEmpty { dataLoadWarning = warnings.joined(separator: "\n") }
        suppressHostsWrites = groupsLoad.warning != nil
        suppressRecentsWrites = recentsLoad.warning != nil
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
            // Set aside, exactly as an undecodable file is: left in place,
            // the first user edit's `.bak` copy fails for the same reason the
            // read did, and the atomic write then replaces the only copy —
            // measured, the original was gone and the `.bak` was an older
            // version. A rename needs no read permission on the file.
            let corruptURL = url.appendingPathExtension("corrupt-\(corruptStamp())")
            let setAside = (try? FileManager.default.moveItem(at: url, to: corruptURL)) != nil
            let warning = setAside
                ? "\(url.lastPathComponent) could not be read (\(error.localizedDescription)); "
                    + "it was preserved as \(corruptURL.lastPathComponent) and the list starts empty."
                : "\(url.lastPathComponent) could not be read (\(error.localizedDescription)) and could not "
                    + "be set aside. SheepTerm started with an empty list and will not overwrite the file."
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
        suppressHostsWrites = groupsLoad.warning != nil
        suppressRecentsWrites = recentsLoad.warning != nil
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
        suppressHostsWrites = false
        suppressRecentsWrites = false
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
        // A user edit re-armed writes; recents that a connect could not write
        // while they were held go now, or a quit before the next recents
        // mutator would lose the session's connections.
        if recentsPendingWrite { saveRecents() }
    }

    private func saveRecents() {
        mergeRecentsFromDiskIfNeeded()
        if write(recents, to: Self.recentsURL) {
            knownRecentsMtime = Self.mtime(of: Self.recentsURL)
            recentsPendingWrite = false
        } else if suppressRecentsWrites {
            recentsPendingWrite = true
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
            let held = url == Self.recentsURL ? suppressRecentsWrites : suppressHostsWrites
            let warning = "\(url.lastPathComponent) was changed by something else, could not be read, "
                + "and could not be set aside either (\(error.localizedDescription)). "
                + (held ? "SheepTerm is holding its own save until you change something."
                        : "SheepTerm saved what it had, which replaced it.")
            dataLoadWarning = [dataLoadWarning, warning].compactMap { $0 }.joined(separator: "\n")
            return false
        }
        let held = url == Self.recentsURL ? suppressRecentsWrites : suppressHostsWrites
        let warning = "\(url.lastPathComponent) was changed by something else and could not be read. "
            + "It was preserved as \(corruptURL.lastPathComponent); "
            + (held ? "SheepTerm is holding its own save until you change something."
                    : "SheepTerm saved what it had.")
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
        let suppressed = url == Self.recentsURL ? suppressRecentsWrites : suppressHostsWrites
        guard !suppressed else {
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
                    // Refuse, do not proceed: a file that cannot be copied
                    // is most often one that cannot be READ, and writing over
                    // it would destroy the only copy of whatever it holds.
                    // The change stays in memory and is retried by the next
                    // save; losing a change is recoverable, losing the file
                    // is not.
                    NSLog("SheepTerm: could not back up %@ (%@) — not overwriting it",
                          url.lastPathComponent, error.localizedDescription)
                    return false
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
        // Hygiene here, not only on the import path: a group name becomes a
        // sidebar row, a menu item and part of a `.sheepterm` file name, and
        // this door was the one that took whatever was typed.
        let trimmed = Self.cleanGroupName(name)
        guard !trimmed.isEmpty, !groups.contains(where: { $0.name == trimmed }) else { return }
        // After the guard, like `renameGroup`: a rejected add is not a user
        // change and must not re-arm writes over a quarantined file.
        noteUserMutation()
        groups.append(HostGroup(name: trimmed, hosts: []))
        save()
    }

    /// The one pass a group NAME gets, wherever one arrives — typed into New
    /// Group, renamed, or read out of a `.sheepterm` file. `sanitizedName`
    /// strips control characters and caps the length but does NOT trim, and
    /// the four doors used to disagree about that: "  Lab  " typed into the
    /// prompt became "Lab", while the same string arriving as an import stayed
    /// padded and read as a different group from the one beside it.
    static func cleanGroupName(_ name: String) -> String {
        // `.whitespacesAndNewlines`, not `.whitespaces`: U+2028/U+2029 are
        // neither control characters (so `sanitizedName` keeps them) nor
        // spaces, and a name that still ends in a line separator reads as a
        // different group from the one beside it.
        ConfigurationHygiene.sanitizedName(name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same duplicate-name rule as addGroup — renaming into an existing
    /// name would make the two groups indistinguishable in pickers.
    /// Returns false (and changes nothing) when the name is taken.
    @discardableResult
    func renameGroup(_ group: HostGroup, to name: String) -> Bool {
        // Same pass as `addGroup`, for the same reason.
        let trimmed = Self.cleanGroupName(name)
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
        deleteGroups(withIDs: [group.id])
    }

    /// Deletes several groups with ONE write, and cleans up after their hosts
    /// the way `removeHosts` does.
    ///
    /// The loop this replaces wrote hosts.json once per group — three groups,
    /// three writes for one confirmed action — and left every deleted group's
    /// hosts in Recent, still clickable, pointing at entries that no longer
    /// exist anywhere.
    @discardableResult
    func deleteGroups(withIDs ids: Set<UUID>) -> Int {
        let victims = groups.filter { ids.contains($0.id) }
        guard !victims.isEmpty else { return 0 }
        noteUserMutation()
        var keys = Set<String>()
        for group in victims {
            deletedGroupIDs.insert(group.id)
            for host in group.hosts {
                deletedHostIDs.insert(host.id)
                keys.insert(host.connectionKey)
            }
        }
        groups.removeAll { ids.contains($0.id) }
        // Same rule as `removeHosts`: a target another group still holds
        // keeps its recent, and is not tombstoned.
        pruneRecents(forRemovedKeys: keys)
        save()
        return victims.count
    }

    /// The group an import would merge into — same id first, then same
    /// name — or nil when the import lands as a brand-new group (0.4 ก).
    func existingGroup(matching incoming: HostGroup) -> HostGroup? {
        // By the CLEANED name: every door that WRITES a group name puts the
        // cleaned form in the store (`cleanGroupName`), so a `.sheepterm`
        // group written as "  Lab  " has to match the "Lab" already here.
        // Comparing raw made the dialog and the merge disagree about which
        // group an import was about — and a second "Lab" nobody can tell
        // apart from the first.
        let wanted = Self.cleanGroupName(incoming.name)
        return groups.first { $0.id == incoming.id }
            ?? groups.first { Self.cleanGroupName($0.name) == wanted }
    }

    /// "Name 2", "Name 3", … — the first numbered variant not taken, so an
    /// import never creates an accidental duplicate group name (0.4 ค4).
    func uniqueGroupName(base: String) -> String {
        if !groups.contains(where: { $0.name == base }) { return base }
        var number = 2
        while groups.contains(where: { $0.name == "\(base) \(number)" }) { number += 1 }
        return "\(base) \(number)"
    }

    /// Which existing host each incoming row is ABOUT, in file order — the
    /// single definition of that question, used by the Replace/Keep dialog
    /// (`conflictingHosts`) and by `applyImport(.merge)` that applies its
    /// answers. nil = there is nothing here for that row; it is an add.
    ///
    /// The rule: the LOWEST existing position matching `id == inc.id ||
    /// sameConnection`, **not already claimed by an earlier incoming row**.
    /// Then it is claimed, so no two rows can be about one host.
    ///
    /// Both halves matter, and both were bugs:
    ///
    /// - Two implementations of "which host is this about" drifted. The
    ///   dialog walked the array with `firstIndex`; the merge used a
    ///   dictionary — and on a group holding two hosts on one target it
    ///   named one host and rewrote the other.
    /// - Without CLAIMING, a file that swaps two hosts' addresses resolved
    ///   both of its rows to the same slot: `sw1@.1, sw2@.2` re-addressed to
    ///   `sw1@.2, sw2@.1` ended as `sw2@.1, sw2@.2` — the first row's edit
    ///   overwritten, "2 replaced", one host silently gone. The mirror case
    ///   lost an ADD: a row re-addressing a host to `.9` followed by a new
    ///   host on the old address resolved to that same slot and was either
    ///   written over it or dropped with nothing said.
    ///
    /// Computed over the PRE-merge array and never updated while the merge
    /// runs: the answers the user gave were about what was on screen, and a
    /// key that moves mid-loop moves the target for every row after it.
    static func mergePairing(existing: [Host],
                             incoming: [Host]) -> [(incomingIndex: Int, existingIndex: Int?)] {
        // Candidate positions, ascending, for BOTH tests. Ids are supposed to
        // be unique inside a group, but hosts.json is a file on disk that
        // another copy of the app (or a hand edit) can leave with two of one
        // id — and then "the lowest UNCLAIMED position with this id" has to
        // mean what it says, exactly as it does for a key.
        var byKey: [String: [Int]] = [:]
        var byID: [UUID: [Int]] = [:]
        for (position, host) in existing.enumerated() {
            byKey[host.connectionKey, default: []].append(position)
            byID[host.id, default: []].append(position)
        }
        var claimed = [Bool](repeating: false, count: existing.count)
        // Where each scan left off — every position before it is claimed, so
        // a file with forty rows on one target does not rescan.
        var keyCursor: [String: Int] = [:]
        var idCursor: [UUID: Int] = [:]
        var pairs: [(incomingIndex: Int, existingIndex: Int?)] = []
        pairs.reserveCapacity(incoming.count)
        for (incomingIndex, inc) in incoming.enumerated() {
            var choice: Int?
            if let positions = byID[inc.id] {
                var scan = idCursor[inc.id] ?? 0
                while scan < positions.count, claimed[positions[scan]] { scan += 1 }
                idCursor[inc.id] = scan
                if scan < positions.count { choice = positions[scan] }
            }
            let key = inc.connectionKey
            if let positions = byKey[key] {
                var scan = keyCursor[key] ?? 0
                while scan < positions.count, claimed[positions[scan]] { scan += 1 }
                keyCursor[key] = scan
                if scan < positions.count {
                    // `sameConnection`, not address+port+username spelled out
                    // again: that copy was blind to `kind`, so a serial entry
                    // whose device path happened to equal an SSH host's
                    // address would be offered as a conflict with it. Same
                    // omission the quick-connect duplicate check had, and the
                    // same fix — there is one definition of "the same target"
                    // in this app.
                    choice = min(choice ?? positions[scan], positions[scan])
                }
            }
            if let choice { claimed[choice] = true }
            pairs.append((incomingIndex: incomingIndex, existingIndex: choice))
        }
        return pairs
    }

    /// Incoming hosts that collide with an existing host (same id, or same
    /// address+port+username) AND differ in content — the pairs the
    /// Replace/Keep dialog asks about (0.4 ข).
    ///
    /// The pairing itself is `mergePairing`, which `applyImport` walks too:
    /// the dialog must not be able to name a host the merge will not write.
    /// The `incomingIndex` is the caller's ANSWER KEY: `applyImport(replace:)`
    /// is keyed by it, not by the incoming host's id, because two rows in one
    /// file can carry the same id (a file written by hand, or one host copied
    /// and re-addressed) — and then one id-keyed answer decided both rows.
    func conflictingHosts(incoming: HostGroup,
                          existing: HostGroup) -> [(incomingIndex: Int, incoming: Host, existing: Host)] {
        // Deduped first, exactly as `applyImport` does it — the same function,
        // so the indices mean the same thing on both sides.
        let rows = Self.importRows(incoming.hosts)
        return Self.mergePairing(existing: existing.hosts, incoming: rows).compactMap { pair in
            guard let existingIndex = pair.existingIndex else { return nil }
            let current = existing.hosts[existingIndex]
            let inc = rows[pair.incomingIndex]
            guard !Self.sameForImport(current, inc) else { return nil }
            return (incomingIndex: pair.incomingIndex, incoming: inc, existing: current)
        }
    }

    /// The rows an import actually works through: EXACT repeats collapsed,
    /// nothing else. One function so the dialog's indices and the merge's
    /// indices cannot mean different rows.
    static func importRows(_ hosts: [Host]) -> [Host] {
        BulkHostParser.dedupedExactRepeats(hosts)
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
    func applyImport(_ rawIncoming: HostGroup, action: ImportGroupAction,
                     replace: [Int: Bool]) -> GroupImportStats {
        noteUserMutation()
        var stats = GroupImportStats()
        // ONE dedupe, for BOTH actions and before anything is paired or
        // written: a row written twice in the same file is one host whichever
        // way the import lands. EXACT repeats only (`importRows`) — the app
        // itself can hold two hosts on one target, and collapsing on the
        // target alone lost one of them on export→import.
        var incoming = rawIncoming
        incoming.hosts = Self.importRows(incoming.hosts)
        stats.repeatedRows = rawIncoming.hosts.count - incoming.hosts.count
        switch action {
        case .createNew:
            var group = incoming
            group.id = UUID()
            group.name = uniqueGroupName(base: Self.cleanGroupName(incoming.name))
            // A new group has no headings of its own, so the batch is snapped
            // against ITSELF: three spellings of one heading in a single
            // import must not open three rows.
            group.hosts = Self.freshIDs(BulkHostParser.snappedHostsWithinBatch(group.hosts))
            groups.append(group)
            stats.addedGroup = true
            stats.groupName = group.name
            stats.addedHosts = group.hosts.count
        case .merge:
            // The same test `existingGroup(matching:)` answers the dialog
            // with — the two must not disagree about the destination.
            let wanted = Self.cleanGroupName(incoming.name)
            guard let index = groups.firstIndex(where: { $0.id == incoming.id })
                ?? groups.firstIndex(where: { Self.cleanGroupName($0.name) == wanted }) else {
                // The match vanished between dialog and apply — land as a
                // new group instead of failing silently.
                var group = incoming
                group.id = UUID()
                group.name = uniqueGroupName(base: Self.cleanGroupName(incoming.name))
                // Same pass as `.createNew` — this IS a new group.
                group.hosts = Self.freshIDs(BulkHostParser.snappedHostsWithinBatch(group.hosts))
                groups.append(group)
                stats.addedGroup = true
                stats.groupName = group.name
                stats.addedHosts = group.hosts.count
                break
            }
            stats.groupName = groups[index].name
            // Hoisted out of the loop: `sections(in:)` walks the group's
            // hosts and the old conflict test walked them again, so 2,000 rows
            // into a 2,000-host group was 2,000 × 4,000 scans — measured at
            // 3.2 s. The heading list is maintained as labels are written, and
            // the pairing below is one pass with dictionaries.
            var headings = sections(in: groups[index].id)
            // ONE pairing, shared with the dialog (`conflictingHosts`), taken
            // over the PRE-merge array: which host each row is about was
            // decided when the user answered, and every row is about a
            // DIFFERENT host (see `mergePairing`'s claiming rule).
            let pairs = Self.mergePairing(existing: groups[index].hosts, incoming: incoming.hosts)
            // 0.4 (ค)2: never rename the existing group after the file.
            for pair in pairs {
                let inc = incoming.hosts[pair.incomingIndex]
                if let hostIndex = pair.existingIndex {
                    let current = groups[index].hosts[hostIndex]
                    guard !Self.sameForImport(current, inc) else { continue }
                    // No decision (aborted dialog) defaults to keep. Keyed by
                    // the ROW, not the host id: two rows sharing an id used to
                    // share one answer.
                    guard replace[pair.incomingIndex] == true else { continue }
                    // 0.4 (ค)1: a replaced host keeps OUR credential
                    // reference — the file carries none — and OUR id and
                    // heading, so open tabs and the sidebar keep pointing at
                    // it and it stays where it was filed. The heading is not
                    // part of `sameForImport` and not in the Replace/Keep
                    // diff either, so taking the file's nil would have
                    // unfiled the host with nothing on screen to say so.
                    var merged = inc.carryingLocalFiling(from: current)
                    merged.credentialID = current.credentialID
                    // In place: the slot is claimed by this row alone, so no
                    // later row can read or overwrite what was just written.
                    groups[index].hosts[hostIndex] = merged
                    if let label = merged.sectionName, !headings.contains(label) {
                        headings.append(label)
                    }
                    // As `updateHost` does: the recent keyed by the old
                    // target follows the edit instead of pointing at a
                    // connection that no longer exists.
                    updateRecents(from: current, to: merged)
                    stats.replacedHosts += 1
                } else {
                    var added = inc
                    added.id = UUID()
                    // A heading that reads like one the destination already
                    // has IS that heading. This is the ADD path; the other
                    // three writers do the same through the same normaliser —
                    // `setSection` (re-filing), `moveHosts` (a drop) and
                    // `snappedHostsWithinBatch` (a brand-new group).
                    added.section = Self.normalizedHeading(added.section, existing: headings)
                    if let label = added.sectionName, !headings.contains(label) {
                        headings.append(label)
                    }
                    groups[index].hosts.append(added)
                    stats.addedHosts += 1
                }
            }
        }
        save()
        return stats
    }

    /// One answer per incoming host ID rather than per row — for callers that
    /// have no row to point at (and for tests). Two rows carrying the same id
    /// get the same answer here, which is the best such a caller can mean;
    /// the dialog keys its answers by row and uses `applyImport` directly.
    @discardableResult
    func applyImport(_ incoming: HostGroup, action: ImportGroupAction,
                     replaceIDs: [UUID: Bool]) -> GroupImportStats {
        let rows = Self.importRows(incoming.hosts)
        var byRow: [Int: Bool] = [:]
        for (position, host) in rows.enumerated() {
            if let answer = replaceIDs[host.id] { byRow[position] = answer }
        }
        return applyImport(incoming, action: action, replace: byRow)
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
        // The pre-edit target no longer exists as a saved host; a newer
        // recents.json from another copy must not bring it back.
        if old.connectionKey != new.connectionKey { deletedRecentKeys.insert(old.connectionKey) }
        var seen = Set<String>()
        recents = recents.filter { seen.insert($0.connectionKey).inserted }
        if recents.count > Self.maxRecents {
            recents = Array(recents.prefix(Self.maxRecents))
        }
        saveRecents()
    }

    func removeHost(_ host: Host) {
        removeHosts(withIDs: [host.id])
    }

    /// Removes several hosts with ONE write. The per-host version was called
    /// in a loop by "Delete N Hosts", so thirteen hosts meant thirteen
    /// hosts.json writes (and up to thirteen recents.json writes) for one
    /// confirmed action — and a failure halfway left the list half deleted
    /// with no way to tell.
    ///
    /// Each host still gets exactly what the single version gave it: its id
    /// in `deletedHostIDs` and its connection in `deletedRecentKeys`, so a
    /// newer file from another copy cannot put it back.
    @discardableResult
    func removeHosts(withIDs ids: [UUID]) -> Int {
        let wanted = Set(ids)
        let victims = groups.flatMap(\.hosts).filter { wanted.contains($0.id) }
        guard !victims.isEmpty else { return 0 }
        noteUserMutation()
        for host in victims { deletedHostIDs.insert(host.id) }
        for index in groups.indices {
            groups[index].hosts.removeAll { wanted.contains($0.id) }
        }
        // A removed host must not linger in Recent — it can no longer be
        // connected to. But the same TARGET may be saved twice (two groups,
        // one switch), so the recent belongs to whatever is left: computing
        // the keys before the removal deleted the survivor's recent too, and
        // tombstoned a connection this Mac still holds.
        pruneRecents(forRemovedKeys: Set(victims.map(\.connectionKey)))
        save()
        return victims.count
    }

    /// Drops recents whose target NOTHING holds any more, and tombstones just
    /// those. Call after the hosts are out of `groups`.
    private func pruneRecents(forRemovedKeys removed: Set<String>) {
        let surviving = Set(groups.flatMap(\.hosts).map(\.connectionKey))
        let gone = removed.subtracting(surviving)
        guard !gone.isEmpty else { return }
        // …or a newer recents.json puts the connection back.
        deletedRecentKeys.formUnion(gone)
        let countBefore = recents.count
        recents.removeAll { gone.contains($0.connectionKey) }
        if recents.count != countBefore { saveRecents() }
    }

    // MARK: Credential references

    /// How many saved hosts reference a credential — shown in the delete
    /// confirmation before the credential is removed.
    /// Counts recents too: the delete dialog quoting a smaller number than
    /// the change actually affects is worse than no number.
    func hostCount(usingCredential id: UUID) -> Int {
        // Every connect writes a recent carrying the credential, so a recent
        // whose target is a saved host is that host again, not a second one
        // — counted twice, the delete dialog doubled its number.
        let saved = groups.flatMap(\.hosts)
        let savedKeys = Set(saved.map(\.connectionKey))
        return saved.filter { $0.credentialID == id }.count
            + recents.filter { $0.credentialID == id && !savedKeys.contains($0.connectionKey) }.count
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

    // MARK: Sections (sub-headings INSIDE a group)

    /// Every section label used inside one group, in the order its first host
    /// appears. Derived, never stored — a section exists exactly as long as a
    /// host carries its label, so there is no list to keep in step and no
    /// empty section to clean up.
    func sections(in groupID: UUID) -> [String] {
        guard let group = groups.first(where: { $0.id == groupID }) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for host in group.hosts {
            guard let name = host.sectionName, seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// Files the given hosts under `name` (nil = loose in their group).
    /// Returns how many hosts actually changed.
    ///
    /// Hosts keep their group: this only writes the label, so a selection
    /// spanning two groups files each host under that label in ITS OWN group.
    /// The label is not identity (`connectionKey` ignores it), so there is no
    /// recents work and no tombstone — the same reason `moveHosts` has none.
    @discardableResult
    func setSection(_ name: String?, forHostIDs ids: Set<UUID>) -> Int {
        // `normalizedHeading` per group below does the hygiene, the trim and
        // the snap; this only has to know whether a label was asked for.
        let asked = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (asked?.isEmpty ?? true) ? nil : asked
        // A label the user ASKED for that hygiene leaves empty ("\u{1}") is a
        // refusal, not "no section": treating it as nil unfiled every host in
        // the selection, which is the opposite of what was typed.
        if value != nil, Self.normalizedHeading(value, existing: []) == nil { return 0 }
        // Snapped to a heading the group already has that READS the same —
        // see the loop below: "Floor  2" typed into New Section… joins
        // "Floor 2" instead of opening a second row nobody can tell apart.
        // Worked out before anything is written: `noteUserMutation` re-arms
        // saving over a quarantined file, and a call that changes nothing must
        // not do that (same rule as `addGroup`/`renameGroup`).
        var targets: [(group: Int, host: Int, label: String?)] = []
        for groupIndex in groups.indices {
            // Snapped per GROUP: a selection spanning two groups files each
            // side under its own group's spelling of the heading.
            let snapped = Self.normalizedHeading(value, existing: sections(in: groups[groupIndex].id))
            for hostIndex in groups[groupIndex].hosts.indices
            where ids.contains(groups[groupIndex].hosts[hostIndex].id) {
                let host = groups[groupIndex].hosts[hostIndex]
                // The RAW field for the nil case: a stored "   " reads as
                // `sectionName == nil` already, so comparing the trimmed
                // value left the whitespace in the file forever.
                let changes = snapped == nil ? host.section != nil : host.sectionName != snapped
                if changes { targets.append((groupIndex, hostIndex, snapped)) }
            }
        }
        guard !targets.isEmpty else { return 0 }
        noteUserMutation()
        for target in targets { groups[target.group].hosts[target.host].section = target.label }
        save()
        return targets.count
    }

    /// Renames a section inside one group. Case-sensitive, like group names.
    /// Returns the number of hosts changed; **0 also means refused** — an
    /// empty new name, or a name that is already another section in that
    /// group (merging two headings silently is not this method's call to
    /// make, exactly as `renameGroup` refuses a duplicate). The caller asks
    /// `sections(in:)` to tell the two apart.
    @discardableResult
    func renameSection(in groupID: UUID, from old: String, to new: String) -> Int {
        // The SAME normaliser the write uses, so what the caller is told and
        // what lands in the file cannot differ (`normalizedHeading` is also
        // what the sidebar asks before it rekeys the fold state).
        let cleaned = ConfigurationHygiene.sanitizedName(new)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned
        guard !trimmed.isEmpty, trimmed != old,
              let groupIndex = groups.firstIndex(where: { $0.id == groupID }),
              // Inner whitespace included: "Floor 2" and "Floor  2" would be
              // two headings nobody can tell apart in the sidebar. The hosts
              // being RENAMED are not a collision with themselves, though —
              // without that exclusion `floor 2` → `Floor 2` and `Floor  2`
              // → `Floor 2` (tidying one heading's own spelling) were refused
              // as "already used".
              !groups[groupIndex].hosts.contains(where: {
                  guard $0.sectionName != old else { return false }
                  return $0.sectionName == trimmed || Self.sameHeading($0.sectionName, trimmed)
              }) else { return 0 }
        let indices = groups[groupIndex].hosts.indices.filter {
            groups[groupIndex].hosts[$0].sectionName == old
        }
        guard !indices.isEmpty else { return 0 }
        noteUserMutation()
        for index in indices { groups[groupIndex].hosts[index].section = trimmed }
        save()
        return indices.count
    }

    /// Takes a heading away: its hosts stay in the group, loose. Nothing is
    /// deleted — there is no such thing as deleting a section, only the label
    /// coming off the hosts that carried it.
    @discardableResult
    func removeSection(in groupID: UUID, _ name: String) -> Int {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return 0 }
        let indices = groups[groupIndex].hosts.indices.filter {
            groups[groupIndex].hosts[$0].sectionName == name
        }
        guard !indices.isEmpty else { return 0 }
        noteUserMutation()
        for index in indices { groups[groupIndex].hosts[index].section = nil }
        save()
        return indices.count
    }

    /// How many hosts those groups hold, counted over the REAL groups.
    ///
    /// Pure, and it takes the groups explicitly because that is the bug it
    /// exists for: a sidebar row built during a search carries a FILTERED
    /// copy of its group, and a delete confirmation that counted the row's
    /// own hosts promised "2 hosts go with them" and then deleted 35.
    static func hostCount(ofGroupIDs ids: Set<UUID>, in groups: [HostGroup]) -> Int {
        groups.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.hosts.count }
    }

    /// How many of these hosts are filed under one heading — for the same
    /// reason: a filtered row knows only the hosts that matched.
    static func hostCount(inSection label: String, hosts: [Host]) -> Int {
        hosts.filter { $0.sectionName == label }.count
    }

    /// The heading actually WRITTEN for a label the user typed: hygiene
    /// (control characters out, 64-character cap), trimmed, then snapped to
    /// the group's existing spelling. nil when nothing is left.
    ///
    /// One function because three callers used to do their own halves of it
    /// and a fourth (the sidebar's collapse-key rekey, and the "already used"
    /// message) guessed at the result: a rename to "Floor  2\u{0}" was
    /// stored as "Floor 2" while the fold state and the alert still talked
    /// about the raw string.
    static func normalizedHeading(_ label: String?, existing: [String]) -> String? {
        guard let label else { return nil }
        let cleaned = ConfigurationHygiene.sanitizedName(label)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return snappedHeading(cleaned, existing: existing)
    }

    /// The heading to actually write when the user asks for `label` in a
    /// group that already has one reading the same: "Floor  2" typed into
    /// New Section… (or an Add Hosts Section cell) becomes the existing
    /// "Floor 2" rather than a second row nobody can tell from the first.
    static func snappedHeading(_ label: String?, existing: [String]) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return existing.first { $0 == trimmed || sameHeading($0, trimmed) } ?? trimmed
    }

    /// Two heading names that read the same: case and every run of
    /// whitespace ignored. Used to REFUSE a rename, never to merge — the
    /// sidebar cannot show "Floor 2" and "Floor  2" as two different rows in
    /// any way a person can act on.
    static func sameHeading(_ a: String?, _ b: String?) -> Bool {
        func key(_ text: String?) -> String? {
            guard let text else { return nil }
            let parts = text.lowercased().split(whereSeparator: \.isWhitespace)
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        guard let left = key(a), let right = key(b) else { return false }
        return left == right
    }

    /// What the "Set Credential for Group" picker is showing. THREE states,
    /// because "nothing picked yet" and "None (ask when connecting)" are
    /// different answers: a mixed group opens on `.unset`, and reading that
    /// as `.none` is what let Return detach every credential in it.
    nonisolated enum GroupCredentialChoice: Hashable {
        case unset
        case none
        case credential(UUID)
    }

    /// The credential EVERY `.ssh` host in this list already shares, or nil
    /// when they differ, when none has one, or when there are no SSH hosts at
    /// all. Pure, because it decides what the "Set Credential for Group"
    /// sheet opens on — and opening on "None" over a group that all shares
    /// one credential meant Return detached every host in it.
    static func sharedCredential(in hosts: [Host]) -> UUID? {
        let ssh = hosts.filter { $0.kind == .ssh }
        guard let first = ssh.first?.credentialID else { return nil }
        return ssh.allSatisfy { $0.credentialID == first } ? first : nil
    }

    /// Whether "Set Credential for Group" may apply what the sheet is showing.
    ///
    /// The MIXED case is why this is a function and not a comparison: twelve
    /// hosts on credential X and one on none share nothing, so the sheet
    /// opens on "None" — and Return then detached X from all twelve. A group
    /// that does not agree with itself needs the user to PICK something
    /// before Apply means anything; a group that does agree needs the pick to
    /// be different from what it already has.
    static func groupCredentialApplyEnabled(hosts: [Host], choice: GroupCredentialChoice) -> Bool {
        let ssh = hosts.filter { $0.kind == .ssh }
        guard !ssh.isEmpty else { return false }
        switch choice {
        case .unset:
            // Nothing picked yet. Only a MIXED group opens here, and Return
            // over it used to detach the credential from every host that had
            // one because "nothing picked" and "None" were the same value.
            return false
        case .none:
            return !credentialIsUniform(in: hosts) || sharedCredential(in: hosts) != nil
        case .credential(let id):
            return !credentialIsUniform(in: hosts) || sharedCredential(in: hosts) != id
        }
    }

    /// True when every `.ssh` host in the list agrees about its credential —
    /// including all agreeing on having none. A group whose hosts DISAGREE
    /// has no current state to compare an Apply against.
    static func credentialIsUniform(in hosts: [Host]) -> Bool {
        let ssh = hosts.filter { $0.kind == .ssh }
        guard let first = ssh.first else { return false }
        return ssh.allSatisfy { $0.credentialID == first.credentialID }
    }

    /// The store index a drop BETWEEN display rows means, from the row BELOW
    /// the insertion line.
    ///
    /// Pure, and taken from the row below on purpose. The row above was the
    /// obvious choice and it is wrong whenever a heading is not contiguous:
    /// with the array `[A(sec1), B, C(sec1), X]` the sidebar shows
    /// `sec1[A, C] / B / X`, so the gap above B has the sec1 HEADING above
    /// it, and "just after the heading's last host" is index 3 — where X
    /// already was. The drop did nothing. The row below the line is the one
    /// the user is pointing at, and its own index is always the answer.
    ///
    /// `childFirstHostIDs` is, for each display child of the group (or of a
    /// heading), the id of its FIRST host: a loose row is its own host, a
    /// heading row is the first host under it.
    static func dropIndex(in hosts: [Host], childFirstHostIDs ids: [UUID], childIndex index: Int) -> Int {
        guard index >= 0, index < ids.count else { return hosts.count }
        return hosts.firstIndex { $0.id == ids[index] } ?? hosts.count
    }

    /// The hosts of one group, in array order — what the sidebar displays and
    /// what every drop index counts against.
    func hosts(inGroup groupID: UUID) -> [Host] {
        groups.first { $0.id == groupID }?.hosts ?? []
    }

    /// Which groups a multi-host "Move to Group" submenu should offer: every
    /// group EXCEPT one that already holds all of them. Moving a selection
    /// into the group it is already in is a no-op the user cannot tell from a
    /// mistake, and it used to unfile them on the way (see `moveHosts`'
    /// `keepHeadingWhenStaying`).
    func moveTargets(forHostIDs ids: Set<UUID>) -> [HostGroup] {
        groups.filter { group in
            let here = Set(group.hosts.map(\.id))
            return !ids.isEmpty && !ids.isSubset(of: here)
        }
    }

    /// How many of these hosts would lose a heading by moving into `groupID`:
    /// the ones that are filed AND are actually changing group. A heading
    /// belongs to the group it is in, so a host that crosses groups goes
    /// loose — fine for one host from the menu, worth asking about for a
    /// dozen, since nothing puts them back.
    func headingsLost(movingHostIDs ids: Set<UUID>, toGroupID groupID: UUID) -> Int {
        let staying = Set(groups.first { $0.id == groupID }?.hosts.map(\.id) ?? [])
        var count = 0
        for group in groups {
            for host in group.hosts where ids.contains(host.id) {
                if host.sectionName != nil, !staying.contains(host.id) { count += 1 }
            }
        }
        return count
    }

    /// The question asked before a MENU unfiles several hosts at once.
    ///
    /// One function because both menu paths ask it, and because the copy has
    /// a measured budget: past ~30 characters on the message line the alert
    /// stops using the compact layout and the icon leaves the centre (see
    /// `NSAlert.sheepStyled`). It counts HOSTS — twelve hosts under one
    /// heading is one heading, so "Remove 1 heading?" was the wrong number,
    /// and "Remove 12 headings?" was the wrong noun.
    /// The singular branch is unreachable through the menu — `confirmUnfiling`
    /// returns true without an alert at one host, because one is a small,
    /// obvious change the user can put back by hand. It is kept so the
    /// function is correct on its own terms (and tested), not because a "1"
    /// ever reaches an alert.
    static func unfileQuestion(count: Int) -> String {
        "Unfile \(count) host\(count == 1 ? "" : "s")?"
    }

    /// How many of these hosts are filed under a heading right now — what
    /// "No Section" on a selection would clear.
    func filedCount(ofHostIDs ids: Set<UUID>) -> Int {
        groups.reduce(0) { total, group in
            total + group.hosts.filter { ids.contains($0.id) && $0.sectionName != nil }.count
        }
    }

    /// Where a host sits in its group's own array, which is the only kind of
    /// index `moveHosts` understands. A child index taken off a SECTION row
    /// is a position among that section's hosts and means nothing here, so
    /// the sidebar converts through this.
    func hostIndex(of id: UUID, inGroup groupID: UUID) -> Int? {
        groups.first { $0.id == groupID }?.hosts.firstIndex { $0.id == id }
    }

    /// One credential for every SSH host in a group (right-click a group →
    /// Set Credential for Group…). Thirteen switches that all log in as
    /// `admin` were thirteen trips through Edit Host.
    ///
    /// `username` travels with a chosen credential because a credential's
    /// username and its password are ONE login — the rule
    /// `HostEditSheet.effectiveUsername` exists for, and leaving the old
    /// username beside a new credential is how a host comes to log in as one
    /// person with another's password. Choosing "None" (`id == nil`) only
    /// detaches the reference: there is no new login to name, and rewriting
    /// the usernames then would throw away the only thing left that says who
    /// these hosts log in as.
    ///
    /// Serial and local hosts are not touched (a console has no credential),
    /// and a host whose values are already these is not a change: the
    /// returned pairs are exactly what moved, so the caller can drop the
    /// session-cached password for each OLD identity.
    @discardableResult
    func setCredential(id: UUID?, username: String?, forGroupID groupID: UUID) -> [(old: Host, new: Host)] {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return [] }
        let login = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Worked out BEFORE anything is written: `noteUserMutation` re-arms
        // saving over a quarantined file, and a call that changes nothing
        // must not do that (same rule as `addGroup`/`renameGroup`).
        var changes: [(old: Host, new: Host)] = []
        for host in groups[groupIndex].hosts where host.kind == .ssh {
            var updated = host
            updated.credentialID = id
            if id != nil, !login.isEmpty { updated.username = login }
            guard updated != host else { continue }
            changes.append((old: host, new: updated))
        }
        guard !changes.isEmpty else { return [] }
        noteUserMutation()
        for change in changes {
            guard let hostIndex = groups[groupIndex].hosts.firstIndex(where: { $0.id == change.old.id }) else { continue }
            groups[groupIndex].hosts[hostIndex] = change.new
            // As `updateHost` does: a recent keyed by the old user@host:port
            // follows the change instead of pointing at a login that is no
            // longer configured anywhere.
            updateRecents(from: change.old, to: change.new)
        }
        // Once, not per host: thirteen hosts are one edit.
        save()
        return changes
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


    /// The one-id wrappers. Both DELEGATE to the plural versions: one
    /// implementation of "where does it land" is the whole point — a host
    /// dropped on its own used to take a different path from three dropped
    /// together (and kept its old heading on the way). The index convention
    /// is theirs: NSOutlineView reports a drop as "insert before child N",
    /// counted BEFORE the dragged row is taken out.
    ///
    /// Nothing in the app calls these any more; the sidebar and the menus all
    /// go through `moveHosts`/`moveGroups`. They are kept because the tests
    /// read better with them and because a one-row move is a case worth
    /// keeping spelled out.
    func moveHost(withID id: UUID, toGroupID groupID: UUID, atIndex index: Int) {
        moveHosts(withIDs: [id], toGroupID: groupID, atIndex: index, section: nil)
    }

    func moveGroup(withID id: UUID, toIndex index: Int) {
        moveGroups(withIDs: [id], toIndex: index)
    }

    /// The multi-selection twin of `moveHost`: every host in `ids` lands in
    /// the destination group, together, in the order the SIDEBAR shows them —
    /// not the order the pasteboard happened to list them.
    ///
    /// `index` is a position in the destination as it stands right now, which
    /// is what NSOutlineView reports, so hosts of the selection that sit above
    /// it are subtracted the way `moveHost` subtracts its one.
    ///
    /// Nothing about a host's identity changes (same address, port, username),
    /// so — exactly as in `moveHost` — recents are not touched and there is no
    /// tombstone to write. One `save()`, and none at all when the arrangement
    /// it would write is the one already in memory: a no-op must not re-arm
    /// writes over a quarantined file.
    @discardableResult
    func moveHosts(withIDs ids: [UUID], toGroupID groupID: UUID, atIndex index: Int,
                   section: String? = nil,
                   keepHeadingWhenStaying: Bool = false) -> Int {
        guard let destGroup = groups.firstIndex(where: { $0.id == groupID }) else { return 0 }
        let wanted = Set(ids)
        // Sidebar order = groups in order, hosts in order.
        // The heading travels through the same normaliser as every other
        // write: dropping hosts on "floor  2" in a group that already has
        // "Floor 2" files them under the existing one.
        let sectionValue = Self.normalizedHeading(section, existing: sections(in: groupID))
        let alreadyHere = Set(groups[destGroup].hosts.map(\.id))
        var moving = groups.flatMap(\.hosts).filter { wanted.contains($0.id) }
        // `keepHeadingWhenStaying` is the MENU's rule, not a drop's: "Move to
        // Group" on a selection that spans groups is about the hosts that
        // CHANGE group, and it used to unfile the ones already in the
        // destination as a side effect — no confirmation, no way back. They
        // are left out of the move entirely, position included: pulling d1 out
        // and re-appending it after d2 and d3 reordered a group the user never
        // dragged.
        if keepHeadingWhenStaying { moving.removeAll { alreadyHere.contains($0.id) } }
        guard !moving.isEmpty else { return 0 }
        let movingIDs = Set(moving.map(\.id))
        // The section the drop landed in travels with the move: dropping a
        // host on a group header takes it OUT of whatever section it was in
        // (nil), and dropping it on a section heading files it there.
        for index in moving.indices { moving[index].section = sectionValue }

        var updated = groups
        let clamped = max(0, min(index, updated[destGroup].hosts.count))
        let removedBefore = updated[destGroup].hosts.prefix(clamped).filter { movingIDs.contains($0.id) }.count
        for group in updated.indices {
            updated[group].hosts.removeAll { movingIDs.contains($0.id) }
        }
        let destination = max(0, min(clamped - removedBefore, updated[destGroup].hosts.count))
        updated[destGroup].hosts.insert(contentsOf: moving, at: destination)
        guard updated != groups else { return 0 }
        noteUserMutation()
        groups = updated
        save()
        return moving.count
    }

    /// The multi-selection twin of `moveGroup`: the selected groups move
    /// together to `index`, keeping their current relative order. Same
    /// pre-removal index convention, same no-op rule as `moveHosts`.
    @discardableResult
    func moveGroups(withIDs ids: Set<UUID>, toIndex index: Int) -> Int {
        let moving = groups.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return 0 }
        let movingIDs = Set(moving.map(\.id))
        var updated = groups
        let clamped = max(0, min(index, updated.count))
        let removedBefore = updated.prefix(clamped).filter { movingIDs.contains($0.id) }.count
        updated.removeAll { movingIDs.contains($0.id) }
        updated.insert(contentsOf: moving, at: max(0, min(clamped - removedBefore, updated.count)))
        guard updated != groups else { return 0 }
        noteUserMutation()
        groups = updated
        save()
        return moving.count
    }

    /// Moves a host into the group with this NAME, **creating it when there is
    /// no such name**. That last part makes it wrong for anything driven by
    /// the UI — a group renamed in another window between opening a menu and
    /// choosing from it would fork a second group under the old name — so the
    /// sidebar uses `moveHosts(withIDs:toGroupID:atIndex:section:)` instead.
    /// What is left here is the test harness, which uses the create-on-demand
    /// to seed groups. Do not call it from app code.
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
    /// The group's name as WRITTEN — hygiene and `uniqueGroupName` both
    /// happen inside `applyImport`, so a caller that reports "Added 3 hosts
    /// to “X”" has to be told which X it actually got.
    var groupName: String?
    /// True when the group was appended as a brand-new group.
    var addedGroup = false
    /// Hosts appended to an existing (or new) group.
    var addedHosts = 0
    /// Existing hosts overwritten by an incoming host with the same id
    /// or address+port+username.
    var replacedHosts = 0
    /// Rows the file repeated EXACTLY (same target, same content, same id)
    /// and that were therefore collapsed. Reported, because a count that
    /// silently shrinks between the dialog and the sidebar is the kind of
    /// difference someone finds a week later.
    var repeatedRows = 0
}

extension String {
    /// Sidebar / Quick Search matching: case- and diacritic-insensitive, so
    /// `cafe` finds `café-sw1`. Thai has neither, so it is unaffected.
    func matchesSearch(_ query: String) -> Bool {
        range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
    }
}
