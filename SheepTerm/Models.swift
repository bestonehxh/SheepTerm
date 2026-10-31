import Combine
import Foundation

nonisolated enum ConnectionKind: String, Codable, Sendable {
    case ssh
    case serial
    case local
    /// A telnet session (RFC 854): `address` + TCP `port` (23 by default),
    /// driven like a serial console — `TelnetWorker` under the same
    /// `SerialTerminalController`. GNS3/EVE-NG consoles, reverse-telnet
    /// console servers, old gear without SSH. JSON value "telnet"; a build
    /// that predates it reads `.unsupported` and keeps the string.
    case telnet
    /// A web page (device web UI) opened in a WKWebView tab. `Host.address`
    /// holds the URL (see `WebAddress`, WebTabs.swift, and ARCHITECTURE.md
    /// "Web tabs"). JSON value "web" — SheepTerm for Windows reads it too.
    case web
    /// A kind this build does not know: written by a newer SheepTerm (or the
    /// Windows port). Never written as itself — `Host` keeps the raw string
    /// (`unknownKind`) and writes it back, so a hosts.json that holds one is
    /// neither quarantined nor silently turned into SSH. Such a host shows
    /// in the sidebar and opens nothing.
    case unsupported

    /// Tolerant: one unknown string must not throw the whole hosts.json into
    /// quarantine (the `Vendor` / `CipherMode` rule).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConnectionKind(rawValue: raw) ?? .unsupported
    }

    var badge: String {
        switch self {
        case .ssh: return "SSH"
        case .serial: return "SER"
        case .telnet: return "TEL"
        case .local: return "ZSH"
        case .web: return "WEB"
        case .unsupported: return "?"
        }
    }

    /// Kinds that are a terminal session on a device (highlight, snippets,
    /// broadcast, history, paging, logging).
    var isDeviceSession: Bool { self == .ssh || self == .serial || self == .telnet }
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
        case .auto: return String(localized: "Auto (recommended)")
        case .modern: return String(localized: "Modern only")
        case .legacy: return String(localized: "Legacy allowed")
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
    /// A subgroup PATH below the host's group ("Bldg 1/Floor 2") — in
    /// TRANSIT only (6.0 (12)). **In the store it is always nil**: since
    /// nested groups a host is filed by the group it sits in, and
    /// `GroupTree.fileLabels` turns a label into that group on the way in.
    /// Three things still carry one: a hosts.json from before nested groups
    /// (a label was a one-level section, read as ONE name), a `.sheepterm`
    /// export (`GroupTree.exportable` flattens a subtree into its top group),
    /// and an Add Hosts / CSV row (the Group column).
    ///
    /// Deliberately NOT part of `connectionKey`/`sameConnection`: it says
    /// where a host is FILED, not what it is, so re-filing a host must not
    /// make it a different target or a conflict on import.
    var section: String? = nil
    /// Set only on a connect-box target typed as `sftp://` / `scp://` /
    /// `ftp://` / `tftp://`: open it as a Files tab with this protocol
    /// (`RemoteEndpoint.Proto` raw value). NOT stored — no CodingKey, so it
    /// never reaches hosts.json, recents, Sync or a share.
    var filesProto: String? = nil
    /// Set only on a connect-box target typed as `ping 10.0.0.1 …`: open it
    /// in the Ping tab (`PingPlan.connectBoxTargets`). NOT stored, like `filesProto`.
    var pingTargets: [String]? = nil
    var cipherMode: CipherMode? = nil
    /// ForwardAgent for this host. Optional (not a defaulted Bool) so hosts
    /// written by an older build still decode — a missing key would throw.
    var agentForward: Bool? = nil
    /// Highlight rule pack. Optional for the same forward-compat reason as
    /// `agentForward`; a missing key means `.auto`, so hosts saved before
    /// this existed keep the union behaviour they were coloured with.
    var vendor: Vendor? = nil
    /// Send the family's pager-off command once the SSH shell is up (see
    /// `Vendor.disablePagingCommand`). Optional like the others: a file
    /// written before the field existed reads as nil = off. Travels in a
    /// `.sheepterm` — it is about the device, not about this Mac.
    var disablePaging: Bool? = nil
    /// Connect through this saved SSH host first (ProxyJump), by its id.
    /// nil = straight there. A dangling id (the bastion was deleted) is
    /// reported at connect time, never silently bypassed.
    var jumpHostID: UUID? = nil
    /// A bastion the user TYPED instead of picking a saved host (4.2 (9)):
    /// `user@host[:port]` or `user@[v6]:port`, read by `ConnectParser` with
    /// `requireHostShape: false`. `jumpHostID` wins when both are set and it
    /// resolves (see `JumpTarget.resolve`). Optional with a default so a
    /// hosts.json written before it decodes unchanged. Unlike the id it
    /// travels in a `.sheepterm`: it means the same thing on any Mac.
    var jumpSpec: String? = nil
    /// "Don't log this session": when true this host's sessions never create a
    /// log file, whatever File > Log Sessions to File says. JSON key `noLog`
    /// (same key on SheepTerm for Windows, so sync carries it). Optional like
    /// the other flags so every file written before it decodes unchanged and
    /// `false` is never written (nil = follow the global setting). Not a
    /// secret: it travels in a `.sheepterm` and in Sync.
    var noLog: Bool? = nil
    /// Web hosts only: lowercase hex SHA-256 of the leaf certificate the user
    /// chose "Trust & Connect" for (`WebTrust`). Local trust, like
    /// known_hosts: never travels in a `.sheepterm` / Share Link (ShareCodec
    /// strips it); Sync and Backup carry it (the user's own Macs).
    var webTrustedCertSHA256: String? = nil
    /// SSH port forwards opened with the session (5.0 (49)), in ssh's own
    /// spelling: `8443:10.0.0.1:443` (-L) or a bare `1080` (-D, SOCKS) —
    /// see `PortForwardSpec`. Listeners are on 127.0.0.1 only. This Mac's
    /// choice, like `agentForward`: a `.sheepterm` neither carries nor sets
    /// it (ShareCodec strips both ways); Sync and Backup carry it.
    var forwards: [String]? = nil
    /// The raw `kind` string of a host whose kind this build does not know
    /// (`kind == .unsupported`); written back as-is. Not a JSON key.
    var unknownKind: String? = nil

    /// Whether this host opts out of session logging, nil = no.
    var skipsLog: Bool { noLog ?? false }

    /// Something under the host forms' Advanced row is not at its default
    /// (cipher, agent, jump host, forwards) — the form then opens with
    /// Advanced shown, so a setting is never hidden AND in force.
    /// The host a second session to the same device opens with (⌘D split,
    /// Duplicate): its port forwards stay with the first one — a second set
    /// could only fail ("port in use") and leave rules nobody can start
    /// (review 5.0 (58)).
    var forSecondSession: Host {
        var copy = self
        copy.forwards = nil
        return copy
    }

    var hasAdvancedSettings: Bool {
        (cipherMode ?? .auto) != .auto || (agentForward ?? false) || jumpHostID != nil || jumpSpecValue != nil
            || !(forwards ?? []).isEmpty
    }

    /// The one decision "does this session get a log file": a host that opts
    /// out never does; every other one follows the global setting.
    /// `override` is the Quick Connect serial choice (nil = none).
    static func shouldLogSession(host: Host, global: Bool, override: Bool? = nil) -> Bool {
        if host.skipsLog { return false }
        return override ?? global
    }

    /// The typed bastion as a VALUE: nil, "" and "   " all mean "none".
    var jumpSpecValue: String? {
        guard let jumpSpec else { return nil }
        let trimmed = jumpSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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
        if filled.disablePaging == nil { filled.disablePaging = match.disablePaging }
        if filled.noLog == nil { filled.noLog = match.noLog }
        if filled.forwards == nil { filled.forwards = match.forwards }
        // The path is one answer: a target that names a bastion either way
        // keeps it, and only one that names none takes the saved host's.
        if filled.jumpHostID == nil && filled.jumpSpecValue == nil {
            filled.jumpHostID = match.jumpHostID
            filled.jumpSpec = match.jumpSpec
        }
        return filled
    }
}

/// Hand-written Codable (5.0 web tabs) for ONE reason: an unknown `kind`
/// must survive a load/save round trip (`unknownKind`). Written in an
/// extension so the memberwise init stays. Keeps the synthesized contract
/// exactly: id/name/kind/address/port/username required, every optional
/// read with decodeIfPresent and written only when non-nil. A new field must
/// be added to `CodingKeys`, `init(from:)` and `encode(to:)`.
extension Host {
    enum CodingKeys: String, CodingKey {
        case id, name, kind, address, port, username, credentialID, section, cipherMode, agentForward,
             vendor, disablePaging, jumpHostID, jumpSpec, noLog, webTrustedCertSHA256, forwards
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let rawKind = try c.decode(String.self, forKey: .kind)
        if let known = ConnectionKind(rawValue: rawKind), known != .unsupported {
            kind = known
            unknownKind = nil
        } else {
            kind = .unsupported
            unknownKind = rawKind
        }
        address = try c.decode(String.self, forKey: .address)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        credentialID = try c.decodeIfPresent(UUID.self, forKey: .credentialID)
        section = try c.decodeIfPresent(String.self, forKey: .section)
        cipherMode = try c.decodeIfPresent(CipherMode.self, forKey: .cipherMode)
        agentForward = try c.decodeIfPresent(Bool.self, forKey: .agentForward)
        vendor = try c.decodeIfPresent(Vendor.self, forKey: .vendor)
        disablePaging = try c.decodeIfPresent(Bool.self, forKey: .disablePaging)
        jumpHostID = try c.decodeIfPresent(UUID.self, forKey: .jumpHostID)
        jumpSpec = try c.decodeIfPresent(String.self, forKey: .jumpSpec)
        noLog = try c.decodeIfPresent(Bool.self, forKey: .noLog)
        webTrustedCertSHA256 = try c.decodeIfPresent(String.self, forKey: .webTrustedCertSHA256)
        // Tolerant: a value of the wrong shape (another build, a hand edit)
        // is dropped, not a reason to quarantine the whole hosts.json.
        forwards = (try? c.decodeIfPresent([String].self, forKey: .forwards)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind == .unsupported ? (unknownKind ?? ConnectionKind.unsupported.rawValue) : kind.rawValue,
                     forKey: .kind)
        try c.encode(address, forKey: .address)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encodeIfPresent(credentialID, forKey: .credentialID)
        try c.encodeIfPresent(section, forKey: .section)
        try c.encodeIfPresent(cipherMode, forKey: .cipherMode)
        try c.encodeIfPresent(agentForward, forKey: .agentForward)
        try c.encodeIfPresent(vendor, forKey: .vendor)
        try c.encodeIfPresent(disablePaging, forKey: .disablePaging)
        try c.encodeIfPresent(jumpHostID, forKey: .jumpHostID)
        try c.encodeIfPresent(jumpSpec, forKey: .jumpSpec)
        try c.encodeIfPresent(noLog, forKey: .noLog)
        try c.encodeIfPresent(webTrustedCertSHA256, forKey: .webTrustedCertSHA256)
        try c.encodeIfPresent(forwards, forKey: .forwards)
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
    /// The group this one is filed under; nil = a top-level group (6.0 (12)).
    ///
    /// Groups stay ONE flat list (`HostStore.groups`) — Sync's records, the
    /// merge-on-save union and every host lookup keep working on it — and the
    /// tree is this pointer plus the list's order: siblings are ordered as
    /// they appear in the list. Every reader of the shape goes through
    /// `GroupTree`, which also repairs it (a cycle, a missing parent, too
    /// deep) wherever a list arrives.
    ///
    /// Always WRITTEN, `null` included: a group without the key was written
    /// by a build that predates nesting (or SheepTerm for Windows before it
    /// caught up), and `HostStore` then keeps the parent it knew instead of
    /// reading the gap as "moved to the top" (`GroupTree.parentlessIDs`).
    var parentID: UUID? = nil
    /// Subgroup PATHS below this group to create even with no host in them —
    /// in TRANSIT only, like `Host.section`; **in the store it is always
    /// empty**. Carried by a hosts.json from before nested groups (its
    /// one-level section list, empty sections included) and by a `.sheepterm`
    /// export (`GroupTree.exportable`).
    var sections: [String] = []

    enum CodingKeys: String, CodingKey { case id, name, hosts, parentID, sections }

    /// Written by hand: a synthesized `init(from:)` throws `keyNotFound` for
    /// a missing key even when the property has a default value (measured —
    /// see ARCHITECTURE §11), and neither `sections` (before 4.1 (2)) nor
    /// `parentID` (before 6.0 (12)) is in every file. A throw there does not
    /// mean "no headings", it means the whole file is unreadable — which
    /// quarantines it and starts the user's host list empty.
    ///
    /// `id`, `name` and `hosts` stay REQUIRED. A group without an id is a file
    /// we do not understand, and inventing one would quietly split the user's
    /// data on the next merge; quarantining the file (as a host without an id
    /// already does) leaves it for them to look at. The other two are the
    /// opposite: a wrong-shaped `sections` is a list the hosts' labels rebuild,
    /// and a wrong-shaped `parentID` is a group put at the top level — both
    /// `try?`, never "unreadable file".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hosts = try container.decode([Host].self, forKey: .hosts)
        parentID = (try? container.decodeIfPresent(UUID.self, forKey: .parentID)) ?? nil
        sections = (try? container.decodeIfPresent([String].self, forKey: .sections)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(hosts, forKey: .hosts)
        if let parentID {
            try container.encode(parentID, forKey: .parentID)
        } else {
            try container.encodeNil(forKey: .parentID)
        }
        if !sections.isEmpty { try container.encode(sections, forKey: .sections) }
    }

    init(id: UUID = UUID(), name: String, hosts: [Host], parentID: UUID? = nil, sections: [String] = []) {
        self.id = id
        self.name = name
        self.hosts = hosts
        self.parentID = parentID
        self.sections = sections
    }
}

extension HostGroup {
    /// **The one source of truth for "which headings does this group show, in
    /// what order".** The declared list first, then every host label that is
    /// not in it, in first-appearance order.
    ///
    /// Everything reads this: the sidebar tree, the host `Section ▸` menu, the
    /// Add Hosts chevron, ⌘K, `HostStore.sections(in:)`, the snapping. Two
    /// implementations of this question is how "Floor 2" came to be offered in
    /// one place and missing in another.
    ///
    /// The second half is not a migration step, it is the invariant: a label
    /// on a host is a heading whether or not the list has caught up (an old
    /// file, a file from another machine, a group written by an older build).
    /// Hygiene folds those into the list on the next pass.
    var displayedSections: [String] {
        // By KEY (`HostStore.headingKey`), never by scanning the list per
        // entry: this runs on every sidebar rebuild and every drag-over, and
        // `contains(where: sameHeading)` inside the loop made it quadratic
        // (measured: ~2 s for 800 headings over 2,000 hosts).
        var out: [String] = []
        var seen = Set<String>()
        for name in sections {
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = HostStore.headingKey(label), seen.insert(key).inserted else { continue }
            out.append(label)
        }
        for host in hosts {
            guard let label = host.sectionName, let key = HostStore.headingKey(label),
                  seen.insert(key).inserted else { continue }
            out.append(label)
        }
        return out
    }

    /// Puts `label` in the declared list unless a heading already there reads
    /// the same. Returns true when the list actually changed, so a caller can
    /// keep the "a no-op must not re-arm writes" rule.
    ///
    /// Every write that gives a host a label goes through this: after any
    /// write, a label on a host is also in its group's list.
    @discardableResult
    mutating func declareHeading(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = HostStore.headingKey(trimmed) else { return false }
        // By key rather than by `sameHeading` per entry: the fold is a
        // lowercase and a split, so asking it inside the scan is the expensive
        // half. The scan itself stays — this is one heading against a list,
        // and callers that declare MANY assign `displayedSections` once
        // instead of calling this in a loop (see `setSection`).
        guard !sections.contains(where: { HostStore.headingKey($0) == key }) else { return false }
        sections.append(trimmed)
        return true
    }
}

/// The SHAPE of the group list (6.0 (12), nested groups) — pure, so the
/// harness pins every rule without a store or a window.
///
/// The list stays flat: a group points at its parent (`HostGroup.parentID`)
/// and siblings are ordered as they appear in the list. The top level is
/// depth 1. A list that has not been through `repair` yet (straight off a
/// disk, a sync, a backup) may hold a cycle or a dangling parent; every
/// reader here stops at either instead of looping, and treats a group whose
/// parent is missing as top level.
enum GroupTree {
    /// What the DATA may hold: Site › Building › Floor › Room. `repair`
    /// files anything deeper at this level, so a list written by another
    /// build, a sync or a backup with four levels loads as it is — never
    /// flattened.
    static let maxDepth = 4
    /// What the USER may make (6.0 (12), design G): Add Subgroup…, a move, an
    /// Add Hosts path, a `.sheepterm` / Share Link import build at most three
    /// levels — one bar colour each (`levelColor`). A fourth level that
    /// already exists stays, may move UP, and is never pushed deeper
    /// (`canMove`).
    static let userDepth = 3

    /// Design G's bar in front of a group row, by level (1 = top level):
    /// blue, teal, purple; a level-4 group (old data, a sync) takes level 3's.
    /// One palette for both platforms' sidebars (dark only).
    static let levelColors: [UInt32] = [0x4F9CF7, 0x3FB6A8, 0xA78BFA]
    static func levelColor(depth: Int) -> UInt32 {
        levelColors[max(0, min(depth, levelColors.count) - 1)]
    }

    /// The bars are DIM while the user is not working in the sidebar and in
    /// full colour while they are (the user, 6.0 (12)): the pointer over it,
    /// its list or search field focused, or a drag over it. No timers.
    static func barsActive(pointerInside: Bool, focused: Bool, dragging: Bool) -> Bool {
        pointerInside || focused || dragging
    }
    static let idleBarOpacity = 0.35
    /// View → Group Colors / Settings → Sidebar (on unless set). Off = no bar
    /// at all; the rows keep their places (the bar sits in the gutter).
    static let groupColorsKey = "sidebarGroupColors"
    static let groupColorsDefault = true
    static func groupColorsShown(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: groupColorsKey) as? Bool ?? groupColorsDefault
    }
    /// A bar's opacity; level 0 (a row that is not a group) has none, and
    /// none at all while Group Colors is off.
    static func barOpacity(active: Bool, depth: Int, shown: Bool = true) -> Double {
        !shown || depth < 1 ? 0 : active ? 1 : idleBarOpacity
    }
    /// The fade between the two, in seconds; none under Reduce Motion.
    static func barFade(reduceMotion: Bool) -> Double { reduceMotion ? 0 : 0.18 }
    /// Between the names of a path as TYPED — the Add Hosts Group column, a
    /// `.sheepterm` label: "Bldg 1/Floor 2".
    static let separator: Character = "/"
    /// Between the names of a path as SHOWN — menus, ⌘K, summaries.
    static let shownSeparator = " › "

    // MARK: Reading

    /// Each id's FIRST position: a list can carry an id twice (imports,
    /// shares and restores copy ids) and the merge keeps the first.
    static func positions(_ groups: [HostGroup]) -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        for (at, group) in groups.enumerated() where out[group.id] == nil { out[group.id] = at }
        return out
    }

    private static func childIDs(_ groups: [HostGroup]) -> [UUID: [UUID]] {
        var out: [UUID: [UUID]] = [:]
        for group in groups {
            if let parent = group.parentID, parent != group.id { out[parent, default: []].append(group.id) }
        }
        return out
    }

    /// The children of `parent` in list order; nil = the top level, which
    /// also takes every group whose parent is not in the list.
    static func children(of parent: UUID?, in groups: [HostGroup]) -> [HostGroup] {
        guard let parent else {
            let ids = Set(groups.map(\.id))
            return groups.filter { group in group.parentID.map { !ids.contains($0) || $0 == group.id } ?? true }
        }
        return groups.filter { $0.parentID == parent && $0.id != parent }
    }

    /// The chain above `id`, top level first, `id` itself not included.
    static func ancestors(of id: UUID, in groups: [HostGroup]) -> [HostGroup] {
        ancestors(of: id, in: groups, positions: positions(groups))
    }

    private static func ancestors(of id: UUID, in groups: [HostGroup], positions: [UUID: Int]) -> [HostGroup] {
        var chain: [HostGroup] = []
        var seen: Set<UUID> = [id]
        var next = positions[id].flatMap { groups[$0].parentID }
        while let parent = next, seen.insert(parent).inserted, let at = positions[parent] {
            chain.append(groups[at])
            next = groups[at].parentID
        }
        return chain.reversed()
    }

    /// 1 = top level.
    static func depth(of id: UUID, in groups: [HostGroup]) -> Int {
        ancestors(of: id, in: groups).count + 1
    }

    /// `id` and everything below it, in tree order (each group before its
    /// children, siblings in list order).
    static func subtreeIDs(of id: UUID, in groups: [HostGroup]) -> [UUID] {
        let kids = childIDs(groups)
        var out: [UUID] = []
        var seen = Set<UUID>()
        func walk(_ group: UUID) {
            guard seen.insert(group).inserted else { return }
            out.append(group)
            for child in kids[group] ?? [] { walk(child) }
        }
        walk(id)
        return out
    }

    /// The levels from `id` down to its deepest descendant, itself included
    /// (a group with no subgroup is 1) — what a move must fit under the cap.
    static func height(of id: UUID, in groups: [HostGroup]) -> Int {
        let kids = childIDs(groups)
        var seen = Set<UUID>()
        func levels(_ group: UUID) -> Int {
            guard seen.insert(group).inserted else { return 0 }
            return 1 + ((kids[group] ?? []).map(levels).max() ?? 0)
        }
        return levels(id)
    }

    /// The whole tree in sidebar order, each group with its depth.
    static func preorder(_ groups: [HostGroup]) -> [(group: HostGroup, depth: Int)] {
        let kids = childIDs(groups)
        let at = positions(groups)
        var out: [(group: HostGroup, depth: Int)] = []
        var seen = Set<UUID>()
        func walk(_ id: UUID, _ depth: Int) {
            guard let index = at[id], seen.insert(id).inserted else { return }
            out.append((groups[index], depth))
            for child in kids[id] ?? [] { walk(child, depth + 1) }
        }
        for root in children(of: nil, in: groups) { walk(root.id, 1) }
        return out
    }

    /// The names from the top level down to `id`, itself included.
    static func path(of id: UUID, in groups: [HostGroup]) -> [String] {
        guard let at = positions(groups)[id] else { return [] }
        return ancestors(of: id, in: groups).map(\.name) + [groups[at].name]
    }

    /// "Site A › Bldg 1 › Floor 2".
    static func shownPath(of id: UUID, in groups: [HostGroup]) -> String {
        path(of: id, in: groups).joined(separator: shownSeparator)
    }

    /// The path of `id` below `root` as typed ("Bldg 1/Floor 2"): "" for
    /// `root` itself, nil when `id` is not under it.
    static func relativePath(of id: UUID, below root: UUID, in groups: [HostGroup]) -> String? {
        if id == root { return "" }
        let chain = ancestors(of: id, in: groups)
        guard let top = chain.firstIndex(where: { $0.id == root }),
              let at = positions(groups)[id] else { return nil }
        return (chain[(top + 1)...].map(\.name) + [groups[at].name]).joined(separator: String(separator))
    }

    /// Every subgroup below `root` as a typed path, in tree order — what the
    /// Add Hosts Group column offers.
    static func relativePaths(below root: UUID, in groups: [HostGroup]) -> [String] {
        subtreeIDs(of: root, in: groups).dropFirst().compactMap { relativePath(of: $0, below: root, in: groups) }
    }

    /// Whether every group in `ids` may move under `parent` (nil = the top
    /// level): never into itself or its own subtree, and its deepest
    /// subgroup within `userDepth` once there — or, for a branch that
    /// already reaches deeper (a fourth level from old data), no deeper than
    /// it reaches now: such a branch can move up or sideways, never down.
    static func canMove(_ ids: Set<UUID>, under parent: UUID?, in groups: [HostGroup]) -> Bool {
        guard !ids.isEmpty else { return false }
        var base = 0
        if let parent {
            guard positions(groups)[parent] != nil, !ids.contains(parent),
                  !ancestors(of: parent, in: groups).contains(where: { ids.contains($0.id) }) else { return false }
            base = depth(of: parent, in: groups)
        }
        return ids.allSatisfy { id in
            let levels = height(of: id, in: groups)
            let bottom = base + levels
            let bottomNow = depth(of: id, in: groups) + levels - 1
            return bottom <= maxDepth && (bottom <= userDepth || bottom <= bottomNow)
        }
    }

    /// Whether the user may make a NEW subgroup under `parent`: not below
    /// level `userDepth`.
    static func canAddChild(to parent: UUID, in groups: [HostGroup]) -> Bool {
        positions(groups)[parent] != nil && depth(of: parent, in: groups) < userDepth
    }

    /// A typed path as its names: split on `/`, each cleaned the way a group
    /// name is, empty ones dropped ("Bldg 1//Floor 2 " → ["Bldg 1", "Floor 2"]).
    static func components(_ path: String) -> [String] {
        path.split(separator: separator).map { HostStore.cleanGroupName(String($0)) }.filter { !$0.isEmpty }
    }

    // MARK: Repairing

    /// Puts right whatever shape a list arrived in — every load, merge,
    /// import and restore runs it — and says whether anything moved. Nothing
    /// is ever dropped:
    /// - a parent that is the group itself, or is not in the list → top level;
    /// - a CYCLE (two Macs moved A under B and B under A before they synced)
    ///   → broken at the member with the smallest id, which goes to the top
    ///   level — the same member on every Mac, so they agree without talking;
    /// - deeper than `maxDepth` → filed under its ancestor at `maxDepth − 1`,
    ///   i.e. at the deepest level allowed (its own subgroups follow on the
    ///   next pass).
    @discardableResult
    static func repair(_ groups: inout [HostGroup]) -> Bool {
        var changed = false
        let ids = Set(groups.map(\.id))
        for index in groups.indices {
            if let parent = groups[index].parentID, parent == groups[index].id || !ids.contains(parent) {
                groups[index].parentID = nil
                changed = true
            }
        }
        while let victim = cycleMember(groups) {
            groups[positions(groups)[victim]!].parentID = nil
            changed = true
        }
        while true {
            let at = positions(groups)
            var moved = false
            for index in groups.indices where at[groups[index].id] == index {
                let chain = ancestors(of: groups[index].id, in: groups, positions: at)
                guard chain.count >= maxDepth else { continue }
                groups[index].parentID = chain[maxDepth - 2].id
                moved = true
            }
            guard moved else { break }
            changed = true
        }
        return changed
    }

    /// The smallest id on some cycle, or nil when there is none.
    private static func cycleMember(_ groups: [HostGroup]) -> UUID? {
        let at = positions(groups)
        var reachesTop = Set<UUID>()
        for start in groups {
            var chain: [UUID] = []
            var onChain = Set<UUID>()
            var current: UUID? = start.id
            while let id = current, !reachesTop.contains(id) {
                guard onChain.insert(id).inserted else {
                    let loop = chain[chain.firstIndex(of: id)!...]
                    return loop.min { $0.uuidString < $1.uuidString }
                }
                chain.append(id)
                current = at[id].flatMap { groups[$0].parentID }
            }
            reachesTop.formUnion(chain)
        }
        return nil
    }

    /// The ids of the groups whose record in a hosts.json has NO `parentID`
    /// key at all — written by a build that predates nested groups. A
    /// `"parentID": null` is a top-level group and is not in here.
    static func parentlessIDs(in data: Data) -> Set<UUID> {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { record in
            record["parentID"] == nil ? (record["id"] as? String).flatMap(UUID.init(uuidString:)) : nil
        })
    }

    // MARK: Labels → subgroups

    /// A STABLE id for the subgroup a label names below `parent`: two Macs
    /// migrating the same old hosts.json — or one re-reading it at every
    /// launch until the next save — meet in ONE subgroup, never two.
    /// FNV-1a over two lanes: not cryptography, an id that must agree.
    static func subgroupID(parent: UUID, key: String) -> UUID {
        let text = Array("\(parent.uuidString)/\(key)".utf8)
        func lane(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in text {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return hash
        }
        let low = lane(0xCBF2_9CE4_8422_2325), high = lane(0x8422_2325_CBF2_9CE4)
        var b = [UInt8](repeating: 0, count: 16)
        for k in 0..<8 {
            b[k] = UInt8(truncatingIfNeeded: low >> (8 * UInt64(k)))
            b[8 + k] = UInt8(truncatingIfNeeded: high >> (8 * UInt64(k)))
        }
        b[6] = (b[6] & 0x0F) | 0x80    // version 8: vendor-defined
        b[8] = (b[8] & 0x3F) | 0x80    // RFC 4122 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Turns the TRANSIT labels into subgroups, on every group that carries
    /// any (`HostGroup.sections`, `Host.section`): each label names a
    /// subgroup, every host with a label moves to the END of its subgroup in
    /// its own order, and nothing carries a label afterwards. Declared labels
    /// come first, so an EMPTY one still becomes a subgroup and the old
    /// section order is the new sibling order.
    ///
    /// A step of a label takes the child that READS the same
    /// (`HostStore.headingKey`: case and spacing folded), then the group with
    /// that step's stable id wherever it sits now (a migrated subgroup the
    /// user has since moved), and only then makes one — appended, so it is the
    /// last of its siblings. A step is only MADE down to level `makeUpTo`
    /// (`userDepth` for whatever the user brings in — a `.sheepterm`, Add
    /// Hosts, a Share Link; `maxDepth` for the load-time pass); an existing
    /// subgroup is still followed down to `maxDepth` (what exists is kept).
    /// A path deeper than that files into the deepest group reached.
    ///
    /// `splitPaths`: a label is a PATH ("Bldg 1/Floor 2") — a `.sheepterm`
    /// and an Add Hosts row. false: it is ONE name — a hosts.json written
    /// before nested groups, whose one-level sections could contain a "/".
    ///
    /// Linear: lookups go through maps kept up to date as groups are made. A
    /// hostile file with 20,000 declared sections runs this at LOAD, and a
    /// scan per label was quadratic in it.
    @discardableResult
    static func fileLabels(_ groups: inout [HostGroup], splitPaths: Bool, makeUpTo limit: Int) -> Bool {
        let owners = groups.filter { group in
            !group.sections.isEmpty || group.hosts.contains { $0.section != nil }
        }.map(\.id)
        guard !owners.isEmpty else { return false }
        var at = positions(groups)
        var childByKey: [UUID: [String: UUID]] = [:]
        for group in groups {
            guard let parent = group.parentID, parent != group.id, let key = HostStore.headingKey(group.name),
                  childByKey[parent]?[key] == nil else { continue }
            childByKey[parent, default: [:]][key] = group.id
        }
        var depthOf: [UUID: Int] = [:]
        func depth(_ id: UUID) -> Int {
            if let known = depthOf[id] { return known }
            var chain: [UUID] = []
            var seen = Set<UUID>()
            var current: UUID? = id
            var base = 0
            while let node = current, seen.insert(node).inserted {
                if let known = depthOf[node] { base = known; break }
                chain.append(node)
                current = at[node].flatMap { groups[$0].parentID }
            }
            for (offset, node) in chain.reversed().enumerated() { depthOf[node] = base + offset + 1 }
            return depthOf[id] ?? 1
        }
        func resolve(_ names: [String], below root: UUID) -> UUID {
            var current = root
            for name in names {
                guard depth(current) < maxDepth else { break }
                guard let key = HostStore.headingKey(name) else { continue }
                if let child = childByKey[current]?[key] {
                    current = child
                    continue
                }
                guard depth(current) < min(limit, maxDepth) else { break }
                let id = subgroupID(parent: current, key: key)
                if at[id] == nil {
                    groups.append(HostGroup(id: id, name: name, hosts: [], parentID: current))
                    at[id] = groups.count - 1
                    childByKey[current, default: [:]][key] = id
                    depthOf[id] = depth(current) + 1
                }
                current = id
            }
            return current
        }
        for owner in owners {
            guard let home = at[owner] else { continue }
            let labels = groups[home].displayedSections
            groups[home].sections = []
            var target: [String: UUID] = [:]
            for label in labels {
                guard let key = HostStore.headingKey(label), target[key] == nil else { continue }
                let names = splitPaths ? components(label) : [HostStore.cleanGroupName(label)].filter { !$0.isEmpty }
                guard !names.isEmpty else { continue }
                target[key] = resolve(names, below: owner)
            }
            var staying: [Host] = []
            var moving: [(to: UUID, host: Host)] = []
            for var host in groups[home].hosts {
                let key = HostStore.headingKey(host.sectionName)
                host.section = nil
                if let key, let to = target[key], to != owner {
                    moving.append((to, host))
                } else {
                    staying.append(host)
                }
            }
            groups[home].hosts = staying
            for move in moving {
                if let to = at[move.to] { groups[to].hosts.append(move.host) }
            }
        }
        return true
    }

    /// A subtree as ONE group, for a `.sheepterm`: the top group's own hosts,
    /// then each subgroup's in tree order labelled with its path below the
    /// top, and every subgroup's path in `sections` so an empty one travels
    /// too. This build rebuilds the subtree from it (`fileLabels(splitPaths:
    /// true)`); an older one shows the paths as one-level sections. A name
    /// with a "/" in it comes back split — the one thing the format loses.
    static func exportable(_ id: UUID, in groups: [HostGroup]) -> HostGroup? {
        let at = positions(groups)
        guard let top = at[id] else { return nil }
        var out = HostGroup(id: id, name: groups[top].name,
                            hosts: groups[top].hosts.map { host in var copy = host; copy.section = nil; return copy })
        for sub in subtreeIDs(of: id, in: groups).dropFirst() {
            guard let index = at[sub], let path = relativePath(of: sub, below: id, in: groups) else { continue }
            out.sections.append(path)
            out.hosts += groups[index].hosts.map { host in var copy = host; copy.section = path; return copy }
        }
        return out
    }
}


/// `port` is a plain `Int` on disk and it means two different things: a TCP
/// port for `.ssh` and the BAUD RATE for `.serial`. Nothing on the way in
/// narrowed it — `HostEditSheet` range-checks `.ssh` only, `ShareCodec` does
/// not look, and a backup's `validate` only asks whether the bytes decode —
/// so the value that reaches a worker is whatever some file said. These are
/// the ranges the workers can actually represent.
extension Host {
    /// the SSH connect needs a TCP port; `SSHWorker.connect` refuses
    /// anything outside this politely instead of trapping on the conversion.
    nonisolated static let sshPortRange = 1...65_535
    nonisolated static let defaultSSHPort = 22
    nonisolated static let defaultTelnetPort = 23

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
        case .ssh, .telnet: return Host.sshPortRange.contains(port)
        case .serial: return Host.serialBaudRange.contains(port)
        case .local, .web, .unsupported: return true
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
        /// Section names that had nothing usable in them and were dropped —
        /// a group's DECLARED headings, and (since round 10) host labels that
        /// clean to nothing, which leave their host loose. Its own counter
        /// because "shortened" reads as "your row is still there, just
        /// shorter", and this one is a heading that is gone.
        var droppedHeadings = 0
        /// `.ssh` hosts whose port was not a port.
        var narrowedPorts = 0
        /// `.serial` hosts whose baud rate was not a baud rate.
        var narrowedBauds = 0
        /// Addresses or usernames that carried control characters (a newline
        /// in an address reaches the SSH layer and the sidebar detail line as is).
        var cleanedFields = 0

        var isEmpty: Bool {
            shortenedNames == 0 && replacedNames == 0 && narrowedPorts == 0 && narrowedBauds == 0
                && cleanedFields == 0 && droppedHeadings == 0
        }

        static func + (lhs: Report, rhs: Report) -> Report {
            Report(shortenedNames: lhs.shortenedNames + rhs.shortenedNames,
                   replacedNames: lhs.replacedNames + rhs.replacedNames,
                   droppedHeadings: lhs.droppedHeadings + rhs.droppedHeadings,
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
                lines.append("• " + String(localized: "\(shortenedNames) name(s) or section label(s) were shortened to \(ConfigurationHygiene.maxNameLength) characters or had control characters removed."))
            }
            if replacedNames > 0 {
                lines.append("• " + String(localized: "\(replacedNames) entr(ies) had no usable name left and were named after their address."))
            }
            if droppedHeadings > 0 {
                lines.append("• " + String(localized: "\(droppedHeadings) empty section name(s) were dropped."))
            }
            if cleanedFields > 0 {
                lines.append("• " + String(localized: "\(cleanedFields) address(es) or username(s) had control characters removed."))
            }
            if narrowedPorts > 0 {
                lines.append("• " + String(localized: "\(narrowedPorts) SSH host(s) had a port outside \(String(Host.sshPortRange.lowerBound))–\(String(Host.sshPortRange.upperBound)) and were set to \(String(Host.defaultSSHPort))."))
            }
            if narrowedBauds > 0 {
                lines.append("• " + String(localized: "\(narrowedBauds) serial host(s) had a baud rate SheepTerm cannot use and were set to \(String(Host.defaultSerialBaud))."))
            }
            // Not "every one of them was kept": a dropped section name is a
            // row that is gone, and the bullet below says so. Short, because
            // the alert has to stay in the compact centred-icon layout.
            return String(localized: "Some entries were corrected on the way in:") + "\n"
                + lines.joined(separator: "\n")
        }
    }

    /// A file inside a payload that does not hold what its name says.
    enum HygieneError: LocalizedError {
        case undecodable(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .undecodable(let name, let reason):
                return String(localized: "the \(name) it carries could not be read (\(reason)).")
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

    /// U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR. Neither is a
    /// control character (Zl/Zp, not Cc/C1), so `controlOnly` leaves them —
    /// and a single-line `NSTextField` **draws them as a line break**: probed,
    /// the field reports a two-line intrinsic height and inks only the first
    /// line, so "Floor⟨U+2028⟩2" and "Floor⟨U+2028⟩3" are two headings that
    /// both read as "Floor" on screen. ⌘V of a soft line break (Shift-Return
    /// in TextEdit, Notes, Mail) puts one in.
    static let lineSeparators = CharacterSet(charactersIn: "\u{2028}\u{2029}")

    /// C0 and C1 CONTROL characters — including "\n" and "\t" — are stripped,
    /// as they always were. U+2028/U+2029 are FOLDED to a space instead,
    /// because they are not controls and a single-line field draws them as a
    /// line break: the reader sees two words on two lines, and folding keeps
    /// them as two words on one. That is also what `HostStore.headingKey`
    /// folds them to (so the store thought it had ONE clean heading while the
    /// file had two).
    ///
    /// Before the cap, so the fold cannot push a name over it.
    static func sanitizedName(_ text: String) -> String {
        String(uncappedName(text).prefix(maxNameLength))
    }

    /// `sanitizedName` BEFORE the cap — controls stripped, line separators
    /// folded. Separate so a caller can ask whether the cap is what changed
    /// a name (see `sanitize(_ hosts:)`).
    static func uncappedName(_ text: String) -> String {
        let noControls = text.components(separatedBy: controlOnly).joined()
        return noControls.components(separatedBy: lineSeparators).joined(separator: " ")
    }

    /// `sanitizedName` then trimmed — the name a person SEES and the store
    /// keeps: control characters out, line separators folded, capped, and no
    /// surrounding whitespace or newline. One helper, because the pair was
    /// written out by hand at a dozen call sites and two of them (Edit Host,
    /// Quick Connect) had only the trim: a pasted U+2028 still landed in a host
    /// name and the sidebar row drew its first line only.
    static func cleanedName(_ text: String) -> String {
        sanitizedName(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `countSections: false` is for the GROUP pass, which counts headings
    /// itself — once per heading per group, see `sanitize(_:emptyGroupName:)`.
    static func sanitize(_ hosts: inout [Host], countSections: Bool = true) -> Report {
        var report = Report()
        for index in hosts.indices {
            var cleaned = sanitizedName(hosts[index].name)
            // When the CAP cut the name, the cut can land on a space: stored,
            // that trailing space was trimmed again in memory at the next
            // load — a name that changed between one launch and the next. Only
            // then, and only the trailing end, so no other count moves.
            if uncappedName(hosts[index].name).count > maxNameLength {
                while cleaned.last?.isWhitespace == true { cleaned.removeLast() }
            }
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
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    // The label is GONE, and the host is loose. Counted as
                    // dropped, on its own line — "shortened … every one of
                    // them was kept" was the wrong thing to tell someone
                    // whose host had just left its heading. Only when there
                    // WAS a heading to lose: a whitespace-only label already
                    // read as no section (`sectionName`), so tidying it away
                    // is not a change the user needs to hear about.
                    if countSections, hosts[index].sectionName != nil { report.droppedHeadings += 1 }
                } else if countSections, cleaned != section {
                    report.shortenedNames += 1
                }
                hosts[index].section = trimmed.isEmpty ? nil : trimmed
            }
            // Control characters only — no length cap here: an address is
            // handed to the SSH layer / the serial open, and a username to the login,
            // where a newline is a different (wrong) value, not a long one.
            for keyPath in [\Host.address, \Host.username] {
                let value = hosts[index][keyPath: keyPath]
                let cleaned = value.components(separatedBy: controlOnly).joined()
                if cleaned != value {
                    hosts[index][keyPath: keyPath] = cleaned
                    report.cleanedFields += 1
                }
            }
            // A web host's address never keeps `user:pass@` (a file, a
            // backup, Sync, a share): hosts.json is plaintext and the sidebar
            // shows the address.
            if hosts[index].kind == .web {
                let stripped = WebAddress.strippingUserInfo(hosts[index].address)
                if stripped != hosts[index].address {
                    hosts[index].address = stripped
                    report.cleanedFields += 1
                }
            }
            if hosts[index].name.isEmpty {
                // A nameless host is unreadable in the sidebar and unusable
                // as a log file name. The address is what the user would have
                // called it anyway; "Untitled Host" only when there is not
                // even one of those.
                let address = sanitizedName(hosts[index].address)
                hosts[index].name = address.isEmpty ? String(localized: "Untitled Host") : address
                report.replacedNames += 1
            }
            if !hosts[index].hasUsablePort {
                switch hosts[index].kind {
                case .serial:
                    hosts[index].port = Host.defaultSerialBaud
                    report.narrowedBauds += 1
                case .telnet:
                    hosts[index].port = Host.defaultTelnetPort
                    report.narrowedPorts += 1
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
            // The load pass's collision rule (`HostStore.cleanGroupNames`), so a
            // restore cannot make two groups with one exact name (which
            // addGroup/renameGroup refuse): a backup from a pre-round-10 build
            // can hold "Lab A" AND "Lab⟨U+2028⟩A", or "  Lab  " AND "Lab".
            //
            // Checked against EVERY other group's CURRENT name — earlier ones
            // as already cleaned by this loop, later ones as stored — not the
            // earlier ones alone: with only the earlier ones, the order
            // ["Lab⟨U+2028⟩A", "Lab A"] cleaned the first to "Lab A" beside a
            // second that already WAS "Lab A". This way every order ends with
            // distinct names, and an already-clean group keeps its name. A
            // kept-raw name is not counted: nothing about it changed.
            let taken = groups.indices.contains {
                $0 != index && groups[$0].parentID == groups[index].parentID && groups[$0].name == cleaned
            }
            if cleaned != groups[index].name, !taken {
                groups[index].name = cleaned
                report.shortenedNames += 1
            }
            if groups[index].name.isEmpty {
                groups[index].name = emptyGroupName
                report.replacedNames += 1
            }
            // HEADINGS are counted here, once per heading per group, before
            // either pass touches them. A heading that was dirty on BOTH sides —
            // in the declared list and on a host's label — is one correction,
            // and the two passes below used to report it twice.
            report = report + headingCorrections(in: groups[index])
            report = report + sanitize(&groups[index].hosts, countSections: false)
            // The group's own heading list, AFTER the hosts (their labels have
            // just been cleaned, and the list has to agree with them).
            report = report + sanitizeHeadings(&groups[index], count: false)
        }
        return report
    }

    /// The heading corrections one group needs, counted **once per distinct
    /// raw heading spelling per group**: the same label on 30 hosts is one
    /// correction, the same heading dirty in the declared list and on a label
    /// is one, and two DIFFERENT raw spellings are two — even when they clean
    /// to the same heading (identical for 64 characters and different after,
    /// or two control-character spellings of one name). Keyed by the RAW
    /// fold, `headingKey(raw) ?? raw`, for exactly that reason: keying by the
    /// cleaned heading counted two different corrections as one.
    ///
    /// The rules for WHAT counts are the two passes' own: a declared name
    /// that cleans to nothing is dropped; a host label that does so is
    /// dropped only if it read as a heading at all (a whitespace-only label
    /// never did); anything that changed on the strip is shortened.
    static func headingCorrections(in group: HostGroup) -> Report {
        var shortened = Set<String>()
        var dropped = Set<String>()
        func note(_ raw: String, countsWhenEmpty: Bool) {
            let stripped = sanitizedName(raw)
            let rawKey = HostStore.headingKey(raw) ?? raw
            if HostStore.headingKey(stripped.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                if stripped != raw { shortened.insert(rawKey) }
            } else if countsWhenEmpty {
                dropped.insert(rawKey)
            }
        }
        for name in group.sections { note(name, countsWhenEmpty: true) }
        for host in group.hosts {
            guard let raw = host.section else { continue }
            note(raw, countsWhenEmpty: host.sectionName != nil)
        }
        var report = Report()
        report.shortenedNames = shortened.count
        report.droppedHeadings = dropped.count
        return report
    }

    /// The declared heading list, cleaned the way every other name is, then
    /// reconciled with the hosts:
    ///
    /// - each declared name stripped, capped and trimmed; empties dropped;
    /// - duplicates that READ the same collapsed, keeping the first spelling
    ///   (the sidebar cannot show "Floor 2" and "Floor  2" as two rows);
    /// - every host label snapped to the spelling in the list, and any label
    ///   the list does not have appended in first-appearance order.
    ///
    /// The last two are what make an old file — labels on hosts, no list at
    /// all — come out of a restore showing exactly the headings it shows
    /// today, in the same order. This is the only migration there is.
    static func sanitizeHeadings(_ group: inout HostGroup, count: Bool = true) -> Report {
        var report = Report()
        var list: [String] = []
        // Keyed, like every other pass over a heading list: this one runs on
        // every LOAD, and a hand-written 10,000-name list took 49 s to get
        // through when each entry scanned the ones before it.
        var byKey: [String: String] = [:]
        for name in group.sections {
            // Counted on the STRIP, not the trim, exactly as the host pass in
            // `sanitize(_ hosts:)` does it: "shortened or had control
            // characters removed" is not what happened to a name that only
            // had a space on the end, and reporting it made a tidy-up read as
            // a correction to the user's data.
            let stripped = sanitizedName(name)
            let cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = HostStore.headingKey(cleaned) else {
                // A heading that cleans to nothing is not a heading. Counted
                // on its own line: "shortened" is the wrong word for a row
                // that is gone, and the user is owed the difference.
                if count { report.droppedHeadings += 1 }
                continue
            }
            if count, stripped != name { report.shortenedNames += 1 }
            guard byKey[key] == nil else { continue }
            byKey[key] = cleaned
            list.append(cleaned)
        }
        for index in group.hosts.indices {
            guard let raw = group.hosts[index].section else { continue }
            // The SAME pass the declared names get. This function is also
            // called on its own — from `applyImport(.createNew)` and from
            // load-time materialisation — where `sanitize(&hosts)` has NOT
            // run, so a 70-character label (the Add Hosts Section cell had no
            // cap) was DECLARED raw. The next load capped the declared copy,
            // the host's raw label then folded to a different key, and the
            // group grew a phantom empty heading: three rows where the user
            // made two.
            let stripped = sanitizedName(raw)
            let cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = HostStore.headingKey(cleaned) else {
                // Nothing usable left: the host is loose, and the raw value
                // does not stay in the file to read as a heading later.
                // Counted exactly as `sanitize(_ hosts:)` counts it, so the
                // two passes cannot report the same file differently — and
                // only when there was a heading to lose.
                if count, group.hosts[index].sectionName != nil { report.droppedHeadings += 1 }
                if group.hosts[index].section != nil { group.hosts[index].section = nil }
                continue
            }
            if count, stripped != raw { report.shortenedNames += 1 }
            if let existing = byKey[key] {
                // Joining the list's spelling is bookkeeping, not a correction.
                group.hosts[index].section = existing
            } else {
                byKey[key] = cleaned
                list.append(cleaned)
                group.hosts[index].section = cleaned
            }
        }
        if list != group.sections { group.sections = list }
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
                report = report + sanitize(&groups, emptyGroupName: String(localized: "Untitled Group"))
                // A backup from before nested groups: its sections become
                // subgroups (one name each, as the load pass reads them), and
                // whatever shape the file had is repaired before it lands.
                GroupTree.fileLabels(&groups, splitPaths: false, makeUpTo: GroupTree.maxDepth)
                GroupTree.repair(&groups)
                files["hosts.json"] = try encoder.encode(groups)
            } catch {
                throw HygieneError.undecodable(name: "hosts.json", reason: error.localizedDescription)
            }
        }
        if let data = files["recents.json"] {
            do {
                var recents = try JSONDecoder().decode([Host].self, from: data)
                // No headings on a RESTORED recent: the file this writes is the
                // one the next launch reads, and a label in it is a heading ⌘K
                // can find that no group has (see `HostStore.cleanedRecents`).
                // Cleared BEFORE the hygiene pass, so it is genuinely not
                // counted — run after it, a recent's dirty label was reported
                // in the restore alert as "shortened" or "dropped", although
                // it was never the user's filing and is thrown away anyway.
                for index in recents.indices { recents[index].section = nil }
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
    /// handed to the SSH layer whole as a hostname.
    /// Hex groups and colons, an optional embedded IPv4 tail, an optional
    /// `%zone` — nothing else. Not a validator (`:::::` passes), only the
    /// spelling test that keeps a name with two colons in it from being
    /// taken for an address.
    nonisolated static func looksLikeIPv6(_ text: String) -> Bool {
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

    /// The sidebar connect box and Quick Search (⌘K): an `http(s)://` URL is
    /// a web target, anything else goes through `parse`. Forms keep calling
    /// `parse` — a URL in an SSH Host field is not a host name.
    static func parseConnectBox(_ text: String) -> Host? {
        if WebAddress.hasWebScheme(text) {
            return Host.web(name: "", url: text)
        }
        if let telnet = parseTelnet(text) { return telnet }
        if let files = parseFilesURL(text) { return files }
        if let ping = parsePing(text) { return ping }
        return parse(text)
    }

    /// A link another app opened us with (5.0 (53)): `telnet://host[:port]`
    /// — what GNS3 / EVE-NG hand out for a console, e.g. a GNS3 console
    /// command `open -a SheepTerm telnet://%h:%p` — or
    /// `ssh://[user@]host[:port]` (RFC draft spelling; `;fingerprint=…`
    /// parameters are dropped — the host key is still checked as always).
    /// Opens a tab and types nothing; nil = not a link we take.
    static func externalLink(_ text: String) -> Host? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("telnet://") { return parseTelnet(trimmed) }
        guard lower.hasPrefix("ssh://") else { return nil }
        var rest = String(trimmed.dropFirst("ssh://".count))
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        // `user;fingerprint=…@host`: parameters ride on the user part.
        if let at = rest.lastIndex(of: "@"), let semi = rest[..<at].firstIndex(of: ";") {
            rest = String(rest[..<semi]) + String(rest[at...])
        }
        guard let user = rest.removingPercentEncoding, var host = parse(user, requireHostShape: false) else { return nil }
        host.name = host.address
        return host
    }

    /// `telnet://host[:port]`, or what everyone types at a CLI —
    /// `telnet host [port]` — is a telnet target (port 23 unless one is
    /// given). A user@ has no meaning for telnet and is refused rather than
    /// silently dropped. nil = not a telnet target.
    static func parseTelnet(_ text: String) -> Host? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: String
        if trimmed.lowercased().hasPrefix("telnet://") {
            target = String(trimmed.dropFirst("telnet://".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            let words = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard words.count == 2 || words.count == 3, words[0].lowercased() == "telnet" else { return nil }
            if words.count == 3 {
                guard let port = Int(words[2]) else { return nil }
                target = String(words[1]).contains(":") && !String(words[1]).hasPrefix("[")
                    ? "[\(words[1])]:\(port)" : "\(words[1]):\(port)"
            } else {
                target = String(words[1])
            }
        }
        guard !target.contains("@"), var host = parse(target, requireHostShape: false) else { return nil }
        // `parse` fills in 22 when no port was typed; a bare IPv6 address
        // has no port at all (`2001:db8::22` ends in ":22" and is not one).
        let explicitPort = target.hasPrefix("[") ? target.contains("]:") : target.filter { $0 == ":" }.count == 1
        host.kind = .telnet
        if !explicitPort { host.port = Host.defaultTelnetPort }
        host.name = host.address
        return host
    }

    /// `ping 10.0.0.1 [more…]` → a Ping-tab target (`Host.pingTargets`).
    static func parsePing(_ text: String) -> Host? {
        guard let targets = PingPlan.connectBoxTargets(text) else { return nil }
        var host = Host(name: "ping " + targets.joined(separator: ", "), kind: .ssh, address: targets[0])
        host.pingTargets = targets
        return host
    }

    /// `sftp://[user@]host[:port][/path]`, `scp://…`, `ftp://…`, `tftp://…`
    /// → a Files-tab target (`Host.filesProto`). A password in the URL is
    /// dropped (it would be asked). Nil for anything else.
    static func parseFilesURL(_ text: String) -> Host? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { return nil }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        guard ["sftp", "scp", "ftp", "tftp"].contains(scheme) else { return nil }
        var rest = String(trimmed[schemeEnd.upperBound...])
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        // user:password@ — the password is never kept.
        if let at = rest.lastIndex(of: "@") {
            let userInfo = rest[..<at]
            let user = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            rest = (user.isEmpty ? "" : user + "@") + rest[rest.index(after: at)...]
        }
        // The scheme already says "a device": a one-label name (`switch-lab`)
        // is a host here, not a typo (review 6.0).
        guard var host = parse(rest, requireHostShape: false) else { return nil }
        // An explicit port: `host:21` or `[v6]:21` (a bare IPv6 has several colons).
        let explicitPort = rest.range(of: #"(^[^:]*|\])(:[0-9]+)$"#, options: .regularExpression) != nil
        if !explicitPort {
            host.port = ["ftp": 21, "tftp": 69][scheme] ?? 22
        }
        host.filesProto = scheme
        host.name = "\(scheme)://\(host.username.isEmpty ? "" : host.username + "@")\(host.address)"
        return host
    }

    static func parse(_ text: String, requireHostShape: Bool = true) -> Host? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // No whitespace may survive anywhere in the target — a pasted
        // newline/tab/inner space would otherwise reach the SSH layer raw.
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

        // the SSH connect needs a TCP port — reject values it can't
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

/// Which bastion a host connects through — the one rule `AppModel.open`
/// follows, here so it can be tested without a window (4.2 (9)).
///
/// Precedence: a `jumpHostID` that names a saved SSH host which is not itself
/// behind a jump host (one hop only) → `.saved`; else a `jumpSpec` that parses
/// → `.spec`; else anything named at all (a dangling or multi-hop id, a spec
/// that does not parse) → `.invalid`, which the tab reports instead of
/// silently connecting direct; else `.none`. An id naming the host itself is
/// treated as unset, as before.
enum JumpTarget: Equatable {
    case none
    case saved(Host)
    case spec(Host)
    case invalid

    /// A typed bastion → an SSH endpoint. nil = not a target. An empty
    /// username is allowed (the worker asks for one).
    static func parse(_ spec: String) -> Host? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("@") else { return nil }
        guard let parsed = ConnectParser.parse(trimmed, requireHostShape: false) else { return nil }
        // The host half must be a host: `a@b@c` is a UPN user, but a "[" or
        // "]" left in the address is a mistyped IPv6 literal.
        guard !parsed.address.contains("["), !parsed.address.contains("]") else { return nil }
        return parsed
    }

    /// Whether `host` may be a bastion: SSH, and not itself behind a jump
    /// host by either route (one hop only).
    static func canBeBastion(_ host: Host) -> Bool {
        host.kind == .ssh && host.jumpHostID == nil && host.jumpSpecValue == nil
    }

    static func resolve(host: Host, saved: [Host]) -> JumpTarget {
        let jumpID = host.jumpHostID.flatMap { $0 == host.id ? nil : $0 }
        if let jumpID, let bastion = saved.first(where: { $0.id == jumpID }), canBeBastion(bastion) {
            return .saved(bastion)
        }
        if let spec = host.jumpSpecValue {
            guard let parsed = parse(spec) else { return .invalid }
            return .spec(parsed)
        }
        return jumpID == nil ? .none : .invalid
    }

    /// The red line under the "Via jump host" row, or nil. A saved
    /// reference is checked against the store — `candidates` are the hosts
    /// the form offers, `saved` every saved host; typed text (used only when
    /// no id is set) against `parse`. The form refuses to save only for typed
    /// text (`blocksSave`): a stale reference was always saveable, and the
    /// tab names it at connect time.
    static func fieldError(text: String, jumpHostID: UUID?, candidates: [Host], saved: [Host]) -> String? {
        if let jumpHostID {
            if candidates.contains(where: { $0.id == jumpHostID }) { return nil }
            if saved.contains(where: { $0.id == jumpHostID }) {
                return String(localized: "That host is behind a jump host itself — one hop only")
            }
            return String(localized: "Saved jump host no longer exists — pick another or None")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(where: { $0.isWhitespace }) { return String(localized: "Jump host must not contain spaces") }
        return parse(trimmed) == nil ? String(localized: "Jump host must be user@host[:port]") : nil
    }

    /// Typed text that does not parse keeps Connect/Save disabled.
    static func blocksSave(text: String, jumpHostID: UUID?) -> Bool {
        guard jumpHostID == nil else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && parse(trimmed) == nil
    }

    /// The typed half of the field as it is stored: nil when a saved host is
    /// referenced or the field is empty.
    static func storedSpec(text: String, jumpHostID: UUID?) -> String? {
        guard jumpHostID == nil else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// How a saved bastion reads in the "Via jump host" field:
    /// `user@address`, `:port` only when it is not 22, an IPv6 literal in
    /// brackets only when a port follows it. `username` is the login the
    /// host connects with (its credential's, when it names one). `parse`
    /// reads the result back to the same endpoint.
    static func text(address: String, port: Int, username: String) -> String {
        let user = username.isEmpty ? "" : "\(username)@"
        guard port != 22 else { return user + address }
        let hostPart = address.contains(":") ? "[\(address)]" : address
        return "\(user)\(hostPart):\(port)"
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
        /// The GROUP column (6.0 (12); "Section" before nested groups): a
        /// subgroup path below the group the rows are added to, "Bldg 1/Floor
        /// 2", carried as `Host.section` until `applyImport` files it. Per
        /// ROW: two hosts of one paste can go into two subgroups.
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
        // A BLANK row (every field empty) is a row of blank cells across the
        // block's FULL width — Excel's meaning of a blank row in an in-cell
        // paste (decision 3). It used to blank only its first column:
        // "sw1⇥10.0.0.1 / (blank) / sw3⇥10.0.0.3" cleared row 2's Name and
        // left its address.
        func isBlank(_ fields: [String]) -> Bool {
            fields.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        if let columns {
            // Header-mapped: a blank row blanks every MAPPED column — never
            // the anchor's own column, which the header does not name.
            let mapped = columns.compactMap { $0 }
            for (rowOffset, fields) in block.enumerated() {
                if isBlank(fields) {
                    for column in mapped { cells.append((row: rowOffset, column: column, value: "")) }
                    continue
                }
                for (fieldIndex, value) in fields.enumerated() {
                    guard fieldIndex < columns.count, let column = columns[fieldIndex] else { continue }
                    cells.append((row: rowOffset, column: column, value: value))
                }
            }
            return cells
        }
        guard let start = columnOrder.firstIndex(of: anchor) else { return [] }
        // Positional: the width is the widest row of the block.
        let width = block.map(\.count).max() ?? 1
        for (rowOffset, fields) in block.enumerated() {
            let values = isBlank(fields) ? Array(repeating: "", count: width) : fields
            for (fieldIndex, value) in values.enumerated() {
                let columnIndex = start + fieldIndex
                guard columnIndex < columnOrder.count else { break }
                cells.append((row: rowOffset, column: columnOrder[columnIndex], value: value))
            }
        }
        return cells
    }

    /// True when text did not arrive in a single-line field by plain typing:
    /// Tab moves focus and Return submits. A paste carries them — and so does
    /// any separator keystroke (⌥Return, ⌥Enter, ⌥Tab, ⌃O, ⌃⌥Return, a
    /// ⌃Q-quoted Tab/Return), which this cannot tell from a paste; `cellPaste`
    /// does, and ignores such a keystroke, keeping the cell's text exactly.
    ///
    /// `isNewline`, not `== "\n" || == "\r"`: **CRLF is ONE Swift Character**,
    /// and it equals neither of those, so a Windows-origin paste with no tab
    /// in it (a single column, or comma-separated) was not a block at all —
    /// `spreadIfPasted` returned early and left the whole thing sitting in one
    /// cell, and over 64 characters `sectionCellEdit` then capped it, filing
    /// "Floor 1Floor 2…Floor 9F" as a heading (the round-7 data loss, by
    /// another door). `block(from:)` and `singleValue(ifPlain:)` already split
    /// on `isNewline`; this gate was the one place that disagreed with them.
    /// It also admits U+2028/U+0085, which those two already treat as lines.
    static func carriesBlockSeparators(_ text: String) -> Bool {
        text.contains { $0 == "\t" || $0.isNewline }
    }

    /// What an edit of an Add Hosts cell WAS, out of the field's whole new
    /// value — the one decision `AddHostsSheet.spreadIfPasted` acts on.
    ///
    /// ⌘V into a non-empty cell inserts the pasted text at the caret (or over
    /// the selection) and the field hands `onChange` its whole value.
    ///
    /// - `.block(text)` — a BLOCK, spread from the anchor with the anchor
    ///   REPLACED by its first value, like a spreadsheet range paste. Only the
    ///   pasted text: spreading the field's whole value made the text after
    ///   the caret one more row, which silently overwrote the cell below the
    ///   block ("Flo|or 9" + "Floor 1\nFloor 2\n" filed "or 9" on row 3).
    /// - `.single(cell)` — ONE value (`singleValue(ifPlain:)`: a spreadsheet
    ///   cell or an editor's line copy, closed by one newline). It keeps
    ///   INSERTION semantics, like typing it, and `cell` is the cell's final
    ///   text: "admin@" + "10.0.0.1\n" is "admin@10.0.0.1". Replacing the cell
    ///   for that closing newline lost "admin@" while the same text without
    ///   the newline was inserted.
    /// - `.unchanged(previous)` — not a paste. A separator CAN be typed into a
    ///   single-line field: ⌥Return, ⌥Enter, ⌥Tab, ⌃O, ⌃⌥Return and a
    ///   ⌃Q-quoted Tab/Return all insert one (⌥Return/⌥Tab are AppKit's
    ///   insertNewlineIgnoringFieldEditor: / insertTabIgnoringFieldEditor:).
    ///   Read as a paste, "\n" is a blank row and cleared the cell ("sw1" +
    ///   ⌥Tab cleared Name AND Host). An inserted text made only of separators
    ///   that the clipboard does not account for is such a keystroke, and the
    ///   payload is `previous` EXACTLY — not trimmed or cleaned: the view
    ///   assigns it raw, because "core " + ⌥Return written back through
    ///   `write` lost its space and the next "sw" made "coresw". (⌘V of a
    ///   copied EMPTY cell — "\n" on the clipboard — is matched by the
    ///   clipboard and still clears, as decided.)
    ///
    /// What was inserted (`insertion`) is found in Unicode SCALARS, not
    /// Characters: a pasted combining mark (or a regional indicator) fuses
    /// with the character before the caret into one Character, and then the
    /// clipboard is not a Character substring of the field and a Character
    /// diff keeps the fused letter in the block.
    enum CellPaste: Equatable {
        case single(String)
        case block(String)
        case unchanged(String)
    }

    static func cellPaste(previous: String, typed: String, clipboard: String?) -> CellPaste {
        let edit = insertion(previous: previous, typed: typed, clipboard: clipboard)
        if !edit.fromClipboard, edit.pasted.allSatisfy({ $0 == "\t" || $0.isNewline }) { return .unchanged(previous) }
        if singleValue(ifPlain: edit.pasted) != nil {
            // The value AS PASTED, less the BOM and the one closing newline
            // `singleValue` drops — untrimmed, since it lands between other
            // text the way typing it would. `write` trims the cell's ends.
            var value = edit.pasted
            if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
            if value.last?.isNewline == true { value.removeLast() }
            return .single(edit.prefix + edit.lead + value + edit.trail + edit.suffix)
        }
        return .block(edit.pasted)
    }

    /// The text the field inserted, and what it sits between.
    private struct Insertion {
        var prefix = "", lead = "", pasted: String, trail = "", suffix = ""
        /// True when the clipboard accounts for `pasted` — a real ⌘V.
        var fromClipboard = false
    }

    /// 1. The CLIPBOARD, when it carries a separator and sits in `typed`
    ///    between a prefix and a suffix of `previous` that do not overlap (an
    ///    insertion, or a replacement of the selection between them). It is
    ///    the only thing that can tell "Floor 9" with the caret at the start
    ///    from "Floor " + "1\nFloor 2\nFloor " — the same field text. Tried
    ///    bare, then with the one space NeXT smart paste adds on either side
    ///    or both: a copy made by double-click-drag in a Cocoa text view or
    ///    WebKit carries that flavour, the field editor (smart insert on)
    ///    inserts clip + " ", and the bare clipboard then missed and the diff
    ///    below ate into the block ("Floor 1\nFloor 2 Floor 9" → "1" /
    ///    "Floor 2 Floor"). The padding is kept apart from the pasted text.
    /// 2. Otherwise (a drag, or a clipboard that changed) a DIFF: the longest
    ///    common prefix, then the longest common suffix that does not overlap
    ///    it; what lies between in `typed` was inserted. When that is a pure
    ///    insertion that could equally sit further left (its edges repeat the
    ///    text beside it), the placement that ENDS with a line break is taken
    ///    — the shape of a spreadsheet clipboard — and otherwise the caret is
    ///    taken to be after the common prefix. Limits, both needing the
    ///    clipboard to resolve: a field text two different pastes produce
    ///    ("A" + "\nBA", or "A\nB" + "A"); and a replaced selection whose ends
    ///    match the pasted text's ends ("cd" of "abcdef" replaced by
    ///    "cX\nYd" reads as "X\nY" inserted between "abc" and "def" — the
    ///    smaller edit).
    /// 3. An empty `previous` falls out of step 2 as the whole value.
    private static func insertion(previous: String, typed: String, clipboard: String?) -> Insertion {
        let old = Array(previous.unicodeScalars), new = Array(typed.unicodeScalars)
        func text(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            return String(view)
        }
        // Common prefix / suffix lengths, unbounded — both steps use them.
        var lcp = 0
        while lcp < old.count, lcp < new.count, old[lcp] == new[lcp] { lcp += 1 }
        var lcs = 0
        while lcs < old.count, lcs < new.count, old[old.count - 1 - lcs] == new[new.count - 1 - lcs] { lcs += 1 }

        // 1. With `prefix = new[..<i]` and the suffix after the candidate,
        //    "prefix of previous" is i <= lcp and "suffix of previous" is
        //    (new.count - candidate.count - i) <= lcs; the two must not
        //    overlap inside `previous`. Only those i are compared, so this
        //    stays cheap even for a 2,000-row block.
        if let clipboard, carriesBlockSeparators(clipboard) {
            let clip = Array(clipboard.unicodeScalars)
            for (lead, trail) in [("", ""), (" ", ""), ("", " "), (" ", " ")] {
                let candidate = Array(lead.unicodeScalars) + clip + Array(trail.unicodeScalars)
                let outside = new.count - candidate.count
                guard outside >= 0, outside <= old.count else { continue }
                let first = max(0, outside - lcs), last = min(lcp, outside)
                guard first <= last else { continue }
                for i in first...last where new[i..<(i + candidate.count)].elementsEqual(candidate) {
                    return Insertion(prefix: text(new[..<i]), lead: lead, pasted: clipboard, trail: trail,
                                     suffix: text(new[(i + candidate.count)...]), fromClipboard: true)
                }
            }
        }

        // 2. The diff. The suffix is bounded so it never overlaps the prefix.
        let p = lcp
        let s = min(lcs, min(old.count, new.count) - p)
        var start = p, end = new.count - s
        guard start < end else { return Insertion(pasted: typed) }
        func endsWithLineBreak(_ index: Int) -> Bool { Character(new[index - 1]).isNewline }
        if p + s == old.count, !endsWithLineBreak(end) {
            // A pure insertion may slide left while the character before it
            // equals its own last character; take the first placement that
            // ends with a line break, if any does.
            var shift = 1
            while shift <= p, new[p - shift] == new[end - shift] {
                if endsWithLineBreak(end - shift) { start = p - shift; end -= shift; break }
                shift += 1
            }
        }
        let inserted = text(new[start..<end])
        // No separator in what was inserted: `previous` itself carried one,
        // and the whole value is all there is to go on.
        guard carriesBlockSeparators(inserted) else { return Insertion(pasted: typed) }
        return Insertion(prefix: text(new[..<start]), pasted: inserted, suffix: text(new[end...]))
    }

    /// The hygiene report for the rows that will actually be WRITTEN.
    ///
    /// `AddHostsSheet.add()` cleans every row, dedupes, and then merges — and a
    /// merge never overwrites, so a row whose target is already in the group
    /// is not written at all. Reporting "3 names were shortened" for a paste
    /// where those three rows already existed described corrections that
    /// never reached the user's data. This mirrors `add()` exactly — clean,
    /// first row wins per target, skip what the group already has — and then
    /// reports on the RAW forms of the rows that are left.
    static func hygieneReport(forRows raw: [Host], landingIn existing: [Host]) -> ConfigurationHygiene.Report {
        var cleaned = raw
        _ = ConfigurationHygiene.sanitize(&cleaned)
        let taken = Set(existing.map(\.connectionKey))
        var seen = Set<String>()
        var landing: [Host] = []
        for (index, host) in cleaned.enumerated() {
            let key = host.connectionKey
            guard !taken.contains(key), seen.insert(key).inserted else { continue }
            landing.append(raw[index])
        }
        return ConfigurationHygiene.sanitize(&landing)
    }

    /// A file's bytes as text, for Import CSV… and a dropped file.
    ///
    /// UTF-16 FIRST, by its BOM. Excel's "UTF-16 Unicode Text" and Numbers'
    /// UTF-16 CSV both start with FF FE (or FE FF), and the old order — UTF-8,
    /// then Latin-1 — "succeeded" on them through Latin-1, which accepts any
    /// byte: every other character came out as NUL and the file was refused as
    /// "doesn't look like a host list", while ⌘V of the very same text worked.
    ///
    /// Then UTF-8 (a UTF-8 BOM decodes fine and `block(from:)` drops the
    /// leading U+FEFF), then Latin-1 as the last resort for old Windows
    /// exports. nil only when nothing decodes, which Latin-1 makes rare.
    static func decodeImport(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(2))
        if bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF] {
            // `.utf16` reads the BOM itself and picks the byte order from it;
            // naming the endianness here would make Foundation keep the BOM
            // as a character instead.
            if let text = String(data: data, encoding: .utf16) {
                return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// What the Add Hosts **Section cell** should do with a value that has
    /// just been typed or pasted into it.
    ///
    /// `.spread` — it carries a separator, so it is a BLOCK and belongs to the
    /// spread path, whole. Capping first was a data-losing bug: a ten-row
    /// paste of "Floor 1\nFloor 2\n…\nFloor 10\n" is 81 characters, so the
    /// cap cut it at 64 and the spread then ran over the truncated string —
    /// rows 9 and 10 gone, and the fragment left on line 8 filed as a
    /// heading. Every value the spread LANDS is capped by
    /// `AddHostsSheet.write(_:into:column:)`, which is the right place for it.
    ///
    /// `.cap(cleaned)` — one long value: shortened in place so the cell cannot
    /// show one spelling and file another (that mismatch is what made phantom
    /// headings). Through `ConfigurationHygiene.sanitizedName`, which strips
    /// control characters and THEN caps — `prefix(64)` on the raw string capped
    /// first and stripped afterwards, so a >64-character heading with a
    /// control character in it left 63 characters in the cell against the
    /// store's 64: two `headingKey`s, two sidebar rows, one heading.
    ///
    /// `.keep` — nothing to do. Note the scope: a value **at or under** the
    /// cap that carries a control character is kept AS TYPED, and the store's
    /// own pass strips it at `add()` — the cleaned label then snaps onto the
    /// existing heading (`normalizedHeading`/`sanitizeHeadings`), so there is
    /// no phantom row and nothing to show the user. The "cell must not show
    /// one spelling and file another" rule is about the OVER-CAP case, where
    /// the difference is a visible 63 against 64.
    ///
    /// Pure so the harness can hold it to all three; the view only switches.
    enum SectionCellEdit: Equatable {
        case spread
        case cap(String)
        case keep
    }

    static func sectionCellEdit(_ typed: String) -> SectionCellEdit {
        if carriesBlockSeparators(typed) { return .spread }
        guard typed.count > ConfigurationHygiene.maxNameLength else { return .keep }
        // Trimmed after the cap, so the cell holds EXACTLY what the store
        // would keep: the cap can land on a space, and a cell ending in one
        // is a spelling the store trims away.
        return .cap(ConfigurationHygiene.cleanedName(typed))
    }

    /// The pasted text as ONE value, when that is all it is — or nil when it
    /// is a block and belongs to `spread`.
    ///
    /// ⌘V of a single cell out of Excel carries a trailing newline, so
    /// `carriesBlockSeparators` says "block" for it; a name like
    /// `Core, floor 3` was then split at the comma into two columns. One line
    /// with no tab in it is a value, and the comma inside it is part of the
    /// name.
    ///
    /// Exactly ONE terminal newline is the clipboard closing the row. Anything
    /// more — a second newline, a leading one, a tab anywhere, even at the
    /// edges — describes more cells, and it goes to the spread: in a grid a
    /// blank row is a cell with coordinates, like Excel's (see
    /// `block(from:preservingEmptyRows:)`).
    ///
    /// `skippingBlankLines` is the SHEET-level paste (no cell focused), which
    /// has no coordinates to keep: whitespace-only lines are dropped, and what
    /// is left is one value if it is exactly one line with no tab. Excel gives
    /// "Core, floor 3\n\n" for two cells of a column where the second is
    /// blank; without this the text went to the import path, which dropped
    /// the blank line and split the one remaining comma line as CSV — a host
    /// called "Core" pointing at "floor 3".
    static func singleValue(ifPlain raw: String, skippingBlankLines: Bool = false) -> String? {
        // One leading BOM dropped, the way `block(from:)` drops it — it is not
        // part of the value.
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if skippingBlankLines {
            // The sheet-level paste keeps exactly the lines an IMPORT keeps
            // (`importLines`): blank lines and "#" comments go ("Core, floor
            // 3\n# note\n" is one value) — but a "#"-titled header stays, and
            // a header-shaped line (even a lone one, below) goes to the block,
            // which accepts or refuses it exactly as Import does. The tab test is on the RAW line: an edge tab is a cell
            // boundary here too ("\tcore-sw-01" is two cells, as on import).
            let lines = importLines(text.split(whereSeparator: \.isNewline).map(String.init))
            guard lines.count == 1, !lines[0].contains("\t") else { return nil }
            let value = lines[0].trimmingCharacters(in: .whitespaces)
            // A LONE header-shaped line is a header, the way Import reads it —
            // plain ("Name,Host") or "#"-titled — so the block path accepts it
            // as a header or refuses it with the Alert. It landed as one value
            // (a host called "Name,Host"). A one-line value like
            // "Core, floor 3" names no column and stays one value.
            let fields = value.contains(",") ? split(value, separator: ",", quoted: true) : [value]
            guard !looksLikeHeader(fields) else { return nil }
            return value.isEmpty ? nil : value
        }
        // One terminal newline closes the clipboard row; any other newline
        // or TAB describes a cell boundary, even at the edges of the text.
        var value = text
        if value.last?.isNewline == true { value.removeLast() }
        guard !value.contains(where: { $0.isNewline || $0 == "\t" }) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
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
        // "Section" is what this column was called before nested groups: a
        // sheet saved then still imports. "Subgroup" is what the grid's own
        // column header says now — a paste copied out of the sheet must be
        // readable back in, refused under the name the user just saw.
        "group": .section, "section": .section, "subgroup": .section,
    ]

    /// What the alert offers when a header is refused.
    static let acceptedHeadingSummary =
        "Name, Host / IP, Credential, Group (any order; Host, IP or Address also mean Host / IP; Section or Subgroup also means Group)"

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

    /// Clipboard text → one array of trimmed fields per data line — just the
    /// data rows, for callers that do not care how the columns were labelled
    /// (the spread's own positional path, and the tests).
    ///
    /// The delimiter (`block(from:)`): a tab INSIDE a line means TSV; a tab
    /// only at a line's edge means TSV only when every non-blank line has a
    /// tab (a real spreadsheet copy with an empty edge column); otherwise a
    /// comma, then whitespace per line. Excel, Numbers and Sheets put
    /// TAB-separated text on the clipboard, so a name like "Core, floor 3"
    /// in a TSV row is never split at its comma.
    static func rows(from text: String) -> [[String]] {
        block(from: text).rows
    }

    static func block(from text: String, preservingEmptyRows: Bool = false) -> Block {
        // One leading BOM, dropped. Excel's "CSV UTF-8" export starts with
        // U+FEFF, which made the first field "\u{FEFF}Name": the header was
        // not recognised, and a host called "Name" pointing at "IP" landed.
        // Only at the very start — a BOM anywhere else is not a BOM.
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // `isNewline` covers CRLF as one Character (it is a single grapheme
        // cluster), so \r\n / \r / \n all arrive here as a line break — no
        // pre-pass that turns \r\n into two empty lines.
        // Never trim a whole TSV line: leading/trailing TABs are empty cells.
        // An IN-CELL paste (`preservingEmptyRows`) follows Excel: a blank row
        // is a real cell with coordinates, and a "#" line is an ordinary value
        // — so Section and Credential values stay aligned with the hosts
        // already in the grid. An import and the sheet-level paste still skip
        // both (below).
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        if text.last?.isNewline == true { lines.removeLast() }
        if !preservingEmptyRows {
            // An IMPORT skips blank lines and "#" comments: "#" is how a
            // hand-kept list comments out a decommissioned switch, and blank
            // lines are what a spreadsheet leaves behind. The one kept "#" line
            // is a header-shaped one in the header position (`importLines`).
            // The line itself is kept whole, so a leading TAB still means an
            // empty first cell.
            lines = importLines(lines)
        }
        guard !lines.isEmpty else { return Block(rows: [], columns: nil, header: nil) }

        // The delimiter, decided on TRIMMED lines:
        // - a tab INSIDE a line (after trimming its ends) means TSV;
        // - a tab only at a line's EDGE means TSV only when EVERY non-blank
        //   line has a tab — always true of a real Excel / Numbers / HTML-table
        //   copy (an empty first or last column is a tab on every row), never
        //   of a stray tab. One stray tab on one line of a one-column list
        //   used to send the whole list down the TSV path: IPs landed in Name,
        //   a names file was refused, "Floor 2" landed in Host / IP;
        // - otherwise a comma means CSV, and then whitespace per line.
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let innerTab = trimmedLines.contains { $0.contains("\t") }
        let everyLineTabbed = lines.allSatisfy { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty || line.contains("\t")
        }
        let edgeTab = lines.contains { $0.contains("\t") }
        let comma = trimmedLines.contains { $0.contains(",") }
        let nonBlank = trimmedLines.filter { !$0.isEmpty }.count

        let fields: [[String]]
        if innerTab || (edgeTab && everyLineTabbed) {
            // UNtrimmed: a leading tab is an empty first cell.
            fields = lines.map { split($0, separator: "\t", quoted: false) }
        } else if preservingEmptyRows, nonBlank == 1 {
            // An in-cell paste of ONE value between blank rows: the blank rows
            // keep their coordinates (Excel), and the value lands WHOLE. It
            // used to take the comma branch, because the blank line counted
            // as the "second line" that makes a comma a delimiter —
            // "Core, floor 3\n\n" became "Core" and "floor 3". The same holds
            // for the whitespace `name target` split, deliberately:
            // "\nsw1 10.0.0.1\n" lands "sw1 10.0.0.1" whole in one cell, as one
            // value always does — the same answer the single-value paste
            // gives when there are no blank rows around it.
            fields = trimmedLines.map { [$0] }
        } else if comma {
            // Quote-aware only here: a CSV file really does write
            // `"Core, floor 3",10.0.0.1`, and that is the one delimiter a
            // field is allowed to contain.
            fields = trimmedLines.map { split($0, separator: ",", quoted: true) }
        } else {
            // A list with no delimiter at all. Two shapes arrive here: one
            // value per line (a column copied out of a spreadsheet — Excel
            // puts NO tab on the clipboard for a single column), or
            // `name 10.0.0.1` pasted out of a text file. Splitting on
            // whitespace served the second and broke the first: a column of
            // section labels like "Floor 1" was cut into "Floor" and "1", and
            // then refused as a header. So a line splits only when it is
            // genuinely `name target` — two or more words with a target among
            // them — and PER LINE, not per list: `sw1 10.0.0.1` and `Floor 3`
            // arrive in the same paste all the time, and an all-or-nothing
            // decision either cut "Floor 3" in half or left the real rows
            // unsplit.
            fields = trimmedLines.map { line in
                isNameTargetLine(line) ? line.split(whereSeparator: \.isWhitespace).map(String.init) : [line]
            }
        }

        // Empty rows can be skipped when importing new records, but are real
        // coordinates when overwriting cells in an existing grid.
        var rows = preservingEmptyRows ? fields : fields.filter { row in row.contains { !$0.isEmpty } }
        var columns: [Column?]?
        var header: [String]?
        var mayBeHeader = false
        // The header candidate is the first row that HAS A VALUE. In an
        // in-cell paste the first row can be a blank cell (Excel), and testing
        // only `rows.first` let "Name" land as a host — and an unknown header
        // ("Name, IP, Port") through unrefused, "Port" and then "22" landing
        // in Credential. A "#" row does not hide a header either: in-cell it
        // is an ordinary value cell, but it is never the header. (An import
        // has dropped both kinds of row already, so this is index 0 there.)
        let candidate = rows.firstIndex { row in
            let values = row.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let first = values.first else { return false }
            // A "#" row is skipped as a NOTE unless it is a header titled
            // EXACTLY "#" in its first column (the same test as
            // `isHeaderShapedCommentLine`). Such a sheet ("#⇥Name⇥Host") IS a
            // header, and an unknown one: it must reach `headerProblems` and be
            // refused, not land as data shifted one column. "# name" is a
            // commented-out header, and stays a note.
            return !first.hasPrefix("#") || (first == "#" && looksLikeHeader(row))
        }
        if let index = candidate, looksLikeHeader(rows[index]) {
            let first = rows[index]
            let problems = headerProblems(first)
            // Refused, not guessed: nothing is placed, and the caller shows
            // the names it could not take.
            guard problems.isEmpty else {
                return Block(rows: [], columns: nil, header: first, rejectedHeader: problems)
            }
            columns = headerMap(first)
            header = first
            // THAT row goes; the blank rows before it keep their coordinates.
            rows.remove(at: index)
        } else if let index = candidate {
            mayBeHeader = mightHaveBeenHeader(rows[index])
        }
        return Block(rows: rows, columns: columns, header: header,
                     rejectedHeader: nil, firstRowMayBeHeader: mayBeHeader)
    }

    /// What an in-cell spread does to the grid, worked out before it writes.
    struct SpreadOutcome: Equatable {
        /// Indices into `cells` that are actually written.
        var writes: [Int]
        /// Rows that received at least one non-empty value.
        var filled: Int
        /// CELLS that held text and were emptied by an empty value — counted
        /// per cell, so a row that got a name while its old address was
        /// cleared reports both.
        var cleared: Int
        /// Whether a block cell writes the anchor cell itself (with any
        /// value, empty included). A block that does not name the anchor's
        /// column — header-mapped, refused, header-only — leaves it alone.
        var anchorWritten: Bool
    }

    /// Decided BEFORE anything is written, from the grid as it is:
    /// - an EMPTY value aimed at a row the grid does not have yet is not
    ///   written at all — trailing blank lines past the bottom of the grid
    ///   used to append empty rows just to hold nothing ("sw1\n\n\n" into the
    ///   last of four rows grew the grid to six);
    /// - a row is FILLED when it gets any non-empty value, judged by what
    ///   `write` will actually store (`storedCellValue`);
    /// - a cell is CLEARED only when an empty value replaced text that was
    ///   there; an empty value over an empty cell is neither.
    ///
    /// The anchor's text is `anchorPrevious` — the cell's value from before
    /// the paste — and it counts only when a block cell actually writes the
    /// anchor. The anchor is NOT cleared just because a paste started there:
    /// a header-mapped block that does not name its column, a refused header
    /// and a header-only paste all leave it as it was.
    static func spreadOutcome(cells: [(row: Int, column: Column, value: String)], anchor: Int,
                              anchorColumn: Column? = nil, anchorPrevious: String = "",
                              rowCount: Int, oldValue: (Int, Column) -> String) -> SpreadOutcome {
        var writes: [Int] = []
        var filledRows = Set<Int>()
        var cleared = 0
        var anchorWritten = false
        func before(_ row: Int, _ column: Column) -> String {
            if row == anchor, column == anchorColumn { return anchorPrevious }
            return oldValue(row, column)
        }
        for (index, cell) in cells.enumerated() {
            let target = anchor + cell.row
            // Judged by what `write` will actually STORE: a Section value of
            // nothing but control characters lands empty, and is not "filled".
            let stored = storedCellValue(cell.value, column: cell.column)
            if stored.isEmpty {
                guard target < rowCount else { continue }
                if !before(target, cell.column).isEmpty { cleared += 1 }
            } else {
                filledRows.insert(target)
            }
            if target == anchor, cell.column == anchorColumn { anchorWritten = true }
            writes.append(index)
        }
        return SpreadOutcome(writes: writes, filled: filledRows.count, cleared: cleared,
                             anchorWritten: anchorWritten)
    }

    /// The value `AddHostsSheet.write(_:into:column:)` stores for a cell:
    /// separators folded to a space and trimmed, and — for Section — the
    /// store's name pass on top. One function, so the grid and the status line
    /// agree about what "empty" means.
    ///
    /// The separators are everything `carriesBlockSeparators` calls one, as a
    /// CharacterSet — `.newlines` rather than "\r\n" by hand, so the line
    /// separators `isNewline` admits (U+2028, U+0085, …) cannot survive inside
    /// a cell either. The invariant this keeps: **a value in a cell never
    /// carries a separator**, so a cell the user touches again is never
    /// mistaken for a fresh block paste.
    static func storedCellValue(_ value: String, column: Column) -> String {
        let trimmed = value
            .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "\t")))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return column == .section ? ConfigurationHygiene.cleanedName(trimmed) : trimmed
    }

    /// A "#" line that is a HEADER, not a comment: a sheet whose first column
    /// is titled "#". Exactly that — the FIRST field is "#" and the row looks
    /// like a header — and nothing looser: "any field is a column name" made a
    /// commented-out header ("# name,host,credential") into an unknown heading
    /// that refused the whole file, and a later "# name, host" line into a
    /// host called "# name".
    static func isHeaderShapedCommentLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let separator: Character = trimmed.contains("\t") ? "\t" : ","
        guard trimmed.contains(separator) else { return false }
        let fields = split(trimmed, separator: separator, quoted: separator == ",")
        return fields.first == "#" && looksLikeHeader(fields)
    }

    /// The lines an IMPORT (and the sheet-level paste) keeps: blank lines and
    /// "#" comments go — except a header-shaped "#" line in the HEADER
    /// position, i.e. the first line kept. A "#"-titled header anywhere else
    /// is a comment like any other.
    static func importLines(_ lines: [String]) -> [String] {
        var seenKept = false
        return lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            if trimmed.hasPrefix("#") {
                guard !seenKept, isHeaderShapedCommentLine(trimmed) else { return false }
            }
            seenKept = true
            return true
        }
    }

    /// A line that is genuinely `name target`: two or more words with a
    /// target among them. The one test both the delimiter choice and the
    /// whitespace split use.
    private static func isNameTargetLine(_ line: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.count >= 2 && words.contains(where: looksLikeTarget)
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

    /// How many rows a paste may still place. The cap bounds the GRID, not
    /// each block — a second 2,000-row paste cannot take it to 4,000 — and the
    /// two kinds of paste use it differently:
    /// - an in-cell ⌘V (`anchor` given) OVERWRITES from the anchor down, so
    ///   the rows already there cost nothing: `cap - anchor`;
    /// - an import (no anchor) ADDS rows, filling blank ones first
    ///   (`place(_:)`) and then appending, so the budget is the free space
    ///   plus the blank rows it can reuse.
    static func rowBudget(anchor: Int? = nil, existing: Int, blankRows: Int = 0, cap: Int) -> Int {
        if let anchor { return max(0, cap - max(0, anchor)) }
        return max(0, cap - existing) + min(max(0, blankRows), min(existing, cap))
    }

    /// What to add to a paste's status line when the grid could not take the
    /// whole block. `placed` is what landed, `cap` the grid's limit.
    static func capNote(placed: Int, cap: Int) -> String {
        if placed == 0 { return " · " + String(localized: "grid is full (\(String(cap)) rows)") }
        // "first 1 rows only" is the kind of sentence that makes the whole
        // dialog look machine-written.
        if placed == 1 { return " · " + String(localized: "first row only (grid cap \(String(cap)))") }
        return " · " + String(localized: "first \(placed) rows only (grid cap \(String(cap)))")
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
        if WebAddress.hasWebScheme(text) { return true }
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
        // The CLEANED name, like the pick branch below: a legacy credential
        // named "core⟨U+2028⟩lab" or "core\tlab" resolved when PICKED (the
        // pick writes the cleaned name) but not when the same text was typed,
        // imported or block-pasted — the host then saved as username
        // "core lab" with no credential. First in array order wins when a
        // clean name and a legacy one clean to the same text.
        if let match = credentials.first(where: {
            ConfigurationHygiene.cleanedName($0.name).caseInsensitiveCompare(wanted) == .orderedSame
        }) {
            return match.id
        }
        // Usernames are LOGINS and are never cleaned: a username that differs
        // by a character is a different login.
        return credentials.first { $0.username.caseInsensitiveCompare(wanted) == .orderedSame }?.id
    }

    /// The credential a row's Credential cell names, when the row may also
    /// carry an explicit PICK from the cell's menu.
    ///
    /// Credential NAMES are not unique (`CredentialStore.add` appends without
    /// checking, and a blank name falls back to the username), so the menu's
    /// "core (netops)" wrote "core" into the cell and the name rule then took
    /// the FIRST "core" — the host was saved with admin's credential. The pick
    /// is an id and it wins, but only while it still describes the cell:
    ///
    /// - empty text → nil, whatever was picked: an empty cell means the
    ///   Default, and a stale pick must not outlive the text it came with;
    /// - a pick whose credential still exists AND whose (cleaned) name the
    ///   cell holds → that id. The view clears a pick in ONE case only: a
    ///   BLOCK paste (a tab or a second line) that writes the Credential
    ///   column. Otherwise this rule alone governs it — clearing on each edit
    ///   lost it through intermediate text ("core" → "corex" → "core", ⌘X ⌘V,
    ///   ⌘Z) and the host saved with the other "core". A kept pick cannot
    ///   describe different text: this check is the guard;
    /// - otherwise the existing text rule, `resolveCredential(_:in:)`: a saved
    ///   name or username is that credential, anything else is the host's
    ///   username and NEVER the Default (the user's decision).
    static func resolveCredential(_ text: String, picked: UUID?,
                                  in credentials: [(id: UUID, name: String, username: String)]) -> UUID? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        // The CLEANED name: the pick writes the cleaned form into the cell,
        // so a name from an old credentials.json that still carries a tab or
        // a newline is compared as the cell shows it.
        if let picked, let match = credentials.first(where: { $0.id == picked }),
           ConfigurationHygiene.cleanedName(match.name) == wanted {
            return picked
        }
        return resolveCredential(wanted, in: credentials)
    }

    /// The Credential menu's entries, one per credential, BY ID, labelled
    /// "name (username)" — with " — 2", " — 3" … on the second and later of
    /// an identical pair. Two "admin (admin)" entries used to share one
    /// `ForEach` id, and the second could never be chosen. The CELL still
    /// holds the name; the suffix only tells the menu rows apart.
    static func credentialMenuLabels(
        _ credentials: [(id: UUID, name: String, username: String)]
    ) -> [(id: UUID, label: String)] {
        var seen: [String: Int] = [:]
        return credentials.map { credential in
            let base = "\(credential.name) (\(credential.username))"
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            return (credential.id, count == 1 ? base : "\(base) — \(count)")
        }
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
        // Keyed, like every other pass over a heading list: `snappedHeading`
        // scans what it is given, so a 2,000-row batch with 2,000 distinct
        // headings was four million comparisons — measured at 1.7 s inside a
        // paste (and `filedSummary` runs it a second time for the status line).
        var seen: [String: String] = [:]
        return hosts.map { host in
            guard let label = host.sectionName, let key = HostStore.headingKey(label) else {
                return host
            }
            var copy = host
            if let first = seen[key] {
                copy.section = first
            } else {
                seen[key] = label
                copy.section = label
            }
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
    static func filedSummary(hosts: [Host], existing: [Host],
                             declared: [String] = []) -> (hosts: Int, sections: Int) {
        // Snapped the way the store will snap them — against the headings
        // already in the group, then against each other — or two spellings of
        // one heading were reported as "2 sections" and the number disagreed
        // with the sidebar the user was about to look at.
        //
        // `declared` is the group's own heading list (`displayedSections`
        // minus what the hosts say), so a row typed as "floor  2" into a group
        // whose EMPTY "Floor 2" heading exists joins it here too — the same
        // answer the store will write.
        // Keyed once, not scanned per row: a 2,000-row paste into a group
        // with 2,000 headings was four million comparisons for a status line.
        var byKey: [String: String] = [:]
        for name in declared + existing.compactMap(\.sectionName) {
            guard let key = HostStore.headingKey(name), byKey[key] == nil else { continue }
            byKey[key] = name
        }
        let seeded = hosts.map { host -> Host in
            var copy = host
            guard let asked = host.section,
                  let key = HostStore.headingKey(ConfigurationHygiene.sanitizedName(asked)) else {
                copy.section = nil
                return copy
            }
            copy.section = byKey[key]
                ?? ConfigurationHygiene.cleanedName(asked)
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

    /// The Add Hosts answer, filed the way the STORE will file it. The label
    /// count above cannot see `GroupTree.fileLabels`' depth rule: a labeled
    /// row into a group already at the user's cap (`GroupTree.userDepth`) stays loose in that group, and the
    /// status line claimed it was filed. So the new rows are filed over a
    /// copy of the real tree (`splitPaths: true`, exactly `applyImport`'s
    /// door) and only the hosts that actually moved into a subgroup — and
    /// the subgroups that received one — are counted.
    static func filedSummary(hosts: [Host], existing: [Host], declared: [String] = [],
                             groups tree: [HostGroup], root: UUID?) -> (hosts: Int, sections: Int) {
        var byKey: [String: String] = [:]
        for name in declared + existing.compactMap(\.sectionName) {
            guard let key = HostStore.headingKey(name), byKey[key] == nil else { continue }
            byKey[key] = name
        }
        let seeded = hosts.map { host -> Host in
            var copy = host
            guard let asked = host.section,
                  let key = HostStore.headingKey(ConfigurationHygiene.sanitizedName(asked)) else {
                copy.section = nil
                return copy
            }
            copy.section = byKey[key] ?? ConfigurationHygiene.cleanedName(asked)
            return copy
        }
        let taken = Set(existing.map(\.connectionKey))
        let rows = snappedHostsWithinBatch(seeded).filter { !taken.contains($0.connectionKey) }
        var sim = tree
        let home: UUID
        if let root, let index = sim.firstIndex(where: { $0.id == root }) {
            sim[index].sections = declared
            sim[index].hosts.append(contentsOf: rows)
            home = root
        } else {
            // ".new": the sheet makes a fresh top-level group, so the paths
            // start from depth 1 and never hit the cap first.
            let fresh = HostGroup(name: "landing", hosts: rows, sections: declared)
            home = fresh.id
            sim.append(fresh)
        }
        GroupTree.fileLabels(&sim, splitPaths: true, makeUpTo: GroupTree.userDepth)
        let stayed = Set((sim.first { $0.id == home }?.hosts ?? []).map(\.id))
        let movedIDs = Set(rows.map(\.id)).subtracting(stayed)
        var subgroups = Set<UUID>()
        for group in sim where group.id != home {
            if group.hosts.contains(where: { movedIDs.contains($0.id) }) {
                subgroups.insert(group.id)
            }
        }
        return (movedIDs.count, subgroups.count)
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
                         section: String? = nil,
                         noLog: Bool = false) -> Host? {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        // An http(s):// URL in the Host / IP cell is a WEB host (5.0 web
        // tabs): the URL is its address, the credential works as for SSH.
        if WebAddress.hasWebScheme(raw) {
            let pasted = pastedUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            let user = (credentialUsername?.isEmpty == false ? credentialUsername : nil) ?? pasted
            guard var web = Host.web(name: name, url: raw, username: user, credentialID: credentialID) else { return nil }
            let label = section?.trimmingCharacters(in: .whitespacesAndNewlines)
            web.section = (label?.isEmpty ?? true) ? nil : label
            return web
        }

        let host: String
        let port: Int
        let addressUser: String
        // Same test, same parser, as HostEditSheet's Host field: a pasted
        // `admin@10.0.0.1:2222` must come apart here instead of being handed
        // to the SSH layer whole.
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
                    section: (label?.isEmpty ?? true) ? nil : label,
                    noLog: noLog ? true : nil)
    }
}

@MainActor
final class HostStore: ObservableObject {
    @Published var groups: [HostGroup] { didSet { revision &+= 1; hasUnsavedGroups = true } }
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
    /// Sync (5.0 (7)): hosts.json failed to load at launch (or the last
    /// reload). Unlike `suppressHostsWrites` this does NOT clear on the user's
    /// next edit — a near-empty list after a quarantine must not be uploaded
    /// over every Mac's hosts. Cleared by the next clean reload (a restore,
    /// or Sync bringing the cloud copy down).
    private(set) var hostsQuarantined = false
    /// Sync: `groups` changed in memory and has not reached hosts.json yet
    /// (a refused write keeps it in memory "for the next save"). Sync then
    /// neither uploads the stale file nor writes over the change. Set by
    /// the assignment itself, cleared by a write that landed or a load — so
    /// a mutator that touches only recents cannot leave it stuck.
    private(set) var hasUnsavedGroups = false
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
        var loadedGroups = groupsLoad.value
        // The same old-build gap `reloadFromDisk` guards: a record with NO
        // `parentID` key is "I don't know", not "top level". At launch there
        // is no in-memory list to keep, but the rolling `.bak` this copy last
        // wrote still holds the tree, so the parents come from there. Best
        // effort: a group the `.bak` never saw stays top level, and one moved
        // since its save gets the older parent — both still beat the first
        // edit writing `parentID: null` and flattening the subtree on every
        // Mac. The recovered list then differs from disk, which keeps
        // `syncSnapshot` from re-uploading the parentless file.
        if let data = try? Data(contentsOf: Self.fileURL) {
            let parentless = GroupTree.parentlessIDs(in: data)
            if !parentless.isEmpty, groupsLoad.warning == nil,
               let bakData = try? Data(contentsOf: Self.fileURL.appendingPathExtension("bak")),
               let known = try? JSONDecoder().decode([HostGroup].self, from: bakData), !known.isEmpty {
                Self.keepKnownParents(&loadedGroups, parentless: parentless, known: known)
            }
        }
        Self.materialise(&loadedGroups)
        groups = loadedGroups
        let recentsLoad = Self.loadList([Host].self, from: Self.recentsURL)
        recents = Self.cleanedRecents(recentsLoad.value)
        let warnings = [groupsLoad.warning, recentsLoad.warning].compactMap { $0 }
        if !warnings.isEmpty { dataLoadWarning = warnings.joined(separator: "\n") }
        suppressHostsWrites = groupsLoad.warning != nil
        suppressRecentsWrites = recentsLoad.warning != nil
        hostsQuarantined = groupsLoad.warning != nil
        hasUnsavedGroups = false
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
                ? String(localized: "\(url.lastPathComponent) could not be read (\(error.localizedDescription)); it was preserved as \(corruptURL.lastPathComponent) and the list starts empty.")
                : String(localized: "\(url.lastPathComponent) could not be read (\(error.localizedDescription)) and could not be set aside. SheepTerm started with an empty list and will not overwrite the file.")
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
            let warning = String(localized: "\(url.lastPathComponent) was unreadable; the original was preserved as \(corruptURL.lastPathComponent) and the list starts empty.")
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
        var loadedGroups = groupsLoad.value
        // A group whose record has NO `parentID` key was written by a build
        // that predates nested groups — another Mac on an older build, or
        // SheepTerm for Windows, through Sync. That is "I don't know", not
        // "top level": keep the parent this copy knew, or one edit there
        // would flatten the subtree on every Mac.
        if let data = try? Data(contentsOf: Self.fileURL) {
            Self.keepKnownParents(&loadedGroups, parentless: GroupTree.parentlessIDs(in: data), known: groups)
        }
        Self.materialise(&loadedGroups)
        groups = loadedGroups
        recents = Self.cleanedRecents(recentsLoad.value)
        let warnings = [groupsLoad.warning, recentsLoad.warning].compactMap { $0 }
        dataLoadWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        suppressHostsWrites = groupsLoad.warning != nil
        suppressRecentsWrites = recentsLoad.warning != nil
        hostsQuarantined = groupsLoad.warning != nil
        hasUnsavedGroups = false
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

    /// The load-time pass, in memory, on every load: the transit labels of a
    /// hosts.json from before nested groups become subgroups (one-level
    /// sections, so a label is ONE name — `GroupTree.fileLabels`), names are
    /// cleaned, and the tree is repaired (`GroupTree.repair`).
    ///
    /// No `save()` and no `noteUserMutation()`: reading a file is not the
    /// user's change, and a file that was quarantined stays write-suppressed
    /// until they make one. The new shape reaches disk with their next edit;
    /// until then every launch derives the same subgroups with the same ids
    /// (`GroupTree.subgroupID`), so nothing forks in between.
    private static func materialise(_ groups: inout [HostGroup]) {
        for index in groups.indices {
            // Cleans and folds the labels first, so two spellings of one old
            // section become one subgroup.
            _ = ConfigurationHygiene.sanitizeHeadings(&groups[index])
            cleanHostNames(&groups[index].hosts)
        }
        GroupTree.fileLabels(&groups, splitPaths: false, makeUpTo: GroupTree.maxDepth)
        cleanGroupNames(&groups)
        GroupTree.repair(&groups)
    }

    /// See `reloadFromDisk`: `parentless` groups take the parent `known` gave
    /// them, while that parent is still in the list.
    static func keepKnownParents(_ groups: inout [HostGroup], parentless: Set<UUID>, known: [HostGroup]) {
        guard !parentless.isEmpty else { return }
        let ids = Set(groups.map(\.id))
        var parentOf: [UUID: UUID] = [:]
        for group in known { if let parent = group.parentID, parentOf[group.id] == nil { parentOf[group.id] = parent } }
        for index in groups.indices where parentless.contains(groups[index].id) {
            if let parent = parentOf[groups[index].id], ids.contains(parent) { groups[index].parentID = parent }
        }
    }

    /// Host NAMES saved before rounds 10–11 can carry U+2028/U+2029 (Edit
    /// Host and Quick Connect only trimmed), and a single-line sidebar row
    /// draws such a name as its first line only. Headings are fixed on load by
    /// `sanitizeHeadings`; this is the same step for names, under the same
    /// rules: in memory only, no `save()`, no `noteUserMutation()` — the file
    /// catches up with the user's next edit, and a quarantined file stays
    /// write-suppressed.
    ///
    /// A name that would clean to NOTHING keeps its raw form: "Untitled Host"
    /// or the address is a restore's decision to make and to report, not
    /// something a launch should do silently. Nothing keys on a host's name
    /// (ids, connection keys and recents' keys are all address-based), so
    /// changing it in memory moves nothing else.
    private static func cleanHostNames(_ hosts: inout [Host]) {
        for index in hosts.indices { cleanHostName(&hosts[index]) }
    }

    /// THE per-host rule every load-time path shares — hosts in groups,
    /// recents, and hosts adopted from another copy's file: the store's name
    /// pass, the raw name kept if the pass would empty it, and nothing written
    /// unless the name actually changes.
    private static func cleanHostName(_ host: inout Host) {
        let cleaned = ConfigurationHygiene.cleanedName(host.name)
        if !cleaned.isEmpty, cleaned != host.name { host.name = cleaned }
    }

    /// Group NAMES get the same load-time pass: a group named before round 10
    /// ("Lab⟨U+2028⟩A") drew as "Lab" in the sidebar header and the Add Hosts
    /// picker, while `existingGroup(matching:)` and `applyImport(.merge)`
    /// already compared the cleaned "Lab A" — the store and the screen named
    /// the group differently.
    ///
    /// `cleanGroupName`, and ONLY when the result is non-empty, differs, and
    /// no SIBLING already has that exact name: the uniqueness rule
    /// `addGroup`/`renameGroup` enforce. On a collision the raw name stays —
    /// renaming one group onto another's name at launch would make them
    /// indistinguishable in every picker, which is worse than a name that
    /// draws on one line too few. In memory only, like the rest of this pass.
    private static func cleanGroupNames(_ groups: inout [HostGroup]) {
        for index in groups.indices {
            let cleaned = cleanGroupName(groups[index].name)
            guard !cleaned.isEmpty, cleaned != groups[index].name,
                  !groups.indices.contains(where: {
                      $0 != index && groups[$0].parentID == groups[index].parentID && groups[$0].name == cleaned
                  })
            else { continue }
            groups[index].name = cleaned
        }
    }

    /// Every recents list that comes off DISK, made fit to show: no heading,
    /// and a cleaned name.
    ///
    /// The heading: `noteRecent` has cleared `section` since 4.1 (2) — a
    /// recent is a connection, not a filing, and nothing keeps that copy in
    /// step with its group's list. But every recents.json written by 4.1 (1) or
    /// earlier carries labels on up to twenty entries, and ⌘K searches recents
    /// FIRST and matches `sectionName`: a heading that no longer exists
    /// anywhere was still findable through a recent.
    ///
    /// The name: Quick Connect sessions ALWAYS land in recents, and before
    /// round 11 Quick Connect only trimmed the name — so a pre-round-11
    /// recents.json holds raw session names, and a Recent row with a U+2028 in
    /// it drew its first line only. `cleanHostName`, the same rule the groups'
    /// hosts get. A name is not part of `connectionKey`, so dedupe and the
    /// recents tombstones are untouched by it.
    private static func cleanedRecents(_ hosts: [Host]) -> [Host] {
        hosts.map { host in
            var copy = host
            copy.section = nil
            cleanHostName(&copy)
            return copy
        }
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
            hasUnsavedGroups = false
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
            let warning = String(localized: "\(url.lastPathComponent) was changed by something else, could not be read, and could not be set aside either (\(error.localizedDescription)).") + " "
                + (held ? String(localized: "SheepTerm is holding its own save until you change something.")
                        : String(localized: "SheepTerm saved what it had, which replaced it."))
            dataLoadWarning = [dataLoadWarning, warning].compactMap { $0 }.joined(separator: "\n")
            return false
        }
        let held = url == Self.recentsURL ? suppressRecentsWrites : suppressHostsWrites
        let warning = String(localized: "\(url.lastPathComponent) was changed by something else and could not be read. It was preserved as \(corruptURL.lastPathComponent);") + " "
            + (held ? String(localized: "SheepTerm is holding its own save until you change something.")
                    : String(localized: "SheepTerm saved what it had."))
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
            // puts two rows with one identity into the outline. A host that
            // arrives with a LABEL (the other copy is a build from before
            // nested groups) keeps it here and is filed by the pass below.
            let hostsOnlyOnDisk = diskGroup.hosts.filter { seenHostIDs.insert($0.id).inserted }
                .map { host -> Host in
                    var copy = host
                    // The NAME too, with the load pass's own rule — an adopted
                    // host was otherwise kept raw in memory AND written raw.
                    Self.cleanHostName(&copy)
                    return copy
                }
            if !hostsOnlyOnDisk.isEmpty {
                merged[i].hosts.append(contentsOf: hostsOnlyOnDisk)
                changed = true
            }
            // An old build's heading list (its empty sections) comes along so
            // the pass below can make subgroups of it. Our own `parentID`
            // wins, like every other attribute of a group both sides hold.
            if !diskGroup.sections.isEmpty {
                merged[i].sections = diskGroup.sections
                changed = true
            }
        }

        // Deduped by id, not just filtered: a file can carry the SAME group
        // id twice (imports, LAN shares and restores all copy ids), and
        // appending both would put two groups with one id into `groups` —
        // colliding SwiftUI row identities, the same class of bug that made
        // recents get a fresh id per entry. Its `parentID` comes with it; a
        // parent this copy deleted leaves it at the top level (`repair`).
        var seenGroupIDs = knownIDs.union(deletedGroupIDs)
        let groupsOnlyOnDisk = diskGroups.filter { seenGroupIDs.insert($0.id).inserted }
            .map { group -> HostGroup in
                // A group new to us can still carry hosts we already hold
                // elsewhere or have deleted — same rule as above.
                var g = group
                g.hosts = g.hosts.filter { seenHostIDs.insert($0.id).inserted }
                Self.cleanHostNames(&g.hosts)
                return g
            }
        if !groupsOnlyOnDisk.isEmpty {
            merged.append(contentsOf: groupsOnlyOnDisk)
            changed = true
        }

        if changed {
            // The load pass over the result: labels an old build left become
            // subgroups, names are cleaned (a name kept raw at load for a
            // collision that has since gone away is cleaned HERE — one launch
            // early — and written with this save; harmless, a group's
            // identity is its id everywhere), and the tree is repaired — the
            // other copy may have moved a group under one this copy moved
            // under it.
            Self.materialise(&merged)
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
        for host in Self.cleanedRecents(diskRecents) {
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
        // And NO heading. A recent is a connection, not a filing: nothing
        // keeps this copy in step with the group's list, so a heading renamed
        // or removed afterwards lived on in Recent — and ⌘K, which matches a
        // host's heading, went on finding a section that is not there any
        // more. The saved host keeps its own label; this copy has no business
        // with it.
        entry.section = nil
        // Connecting to it again is the user asking for it back.
        deletedRecentKeys.remove(entry.connectionKey)
        recents.removeAll { $0.sameConnection(as: entry) }
        recents.insert(entry, at: 0)
        if recents.count > Self.maxRecents {
            recents = Array(recents.prefix(Self.maxRecents))
        }
        saveRecents()
    }

    /// A serial session changed speed in the tab (5.0 (39)): its recent moves
    /// to the new speed instead of keeping a second row at the old one.
    func noteRecent(_ host: Host, replacingPort oldPort: Int) {
        var old = host
        old.port = oldPort
        recents.removeAll { $0.sameConnection(as: old) }
        // Like `updateRecents`: a recents.json merged in later must not bring
        // the old speed back. Not a user mutation (see `noteRecent`).
        if old.connectionKey != host.connectionKey { deletedRecentKeys.insert(old.connectionKey) }
        noteRecent(host)
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

    /// A new group at the END of `parent`'s subgroups (nil = the top level).
    /// Returns its id, or nil when refused: an empty name, a name a SIBLING
    /// already has (two "Floor 2" under different buildings are fine — one
    /// building with two is not), a parent that is gone, or one already at
    /// `GroupTree.userDepth` (the user's cap; data may hold `maxDepth`).
    @discardableResult
    func addGroup(named name: String, parent: UUID? = nil) -> UUID? {
        // Hygiene here, not only on the import path: a group name becomes a
        // sidebar row, a menu item and part of a `.sheepterm` file name, and
        // this door was the one that took whatever was typed.
        let trimmed = Self.cleanGroupName(name)
        guard !trimmed.isEmpty, !nameTaken(trimmed, under: parent, except: nil) else { return nil }
        if let parent, !GroupTree.canAddChild(to: parent, in: groups) { return nil }
        // After the guard, like `renameGroup`: a rejected add is not a user
        // change and must not re-arm writes over a quarantined file.
        noteUserMutation()
        let group = HostGroup(name: trimmed, hosts: [], parentID: parent)
        groups.append(group)
        save()
        return group.id
    }

    /// Whether a sibling under `parent` (other than `except`) has exactly
    /// this name — the one uniqueness rule for group names.
    func nameTaken(_ name: String, under parent: UUID?, except: UUID?) -> Bool {
        GroupTree.children(of: parent, in: groups).contains { $0.id != except && $0.name == name }
    }

    /// What a group picker lists (Quick Connect, Add Host, Web Host): every
    /// group as its path, in sidebar order. `quickConnectGroupIndex` reads
    /// the choice back.
    var groupChoiceLabels: [String] {
        GroupTree.preorder(groups).map { GroupTree.shownPath(of: $0.group.id, in: groups) }
    }

    /// The group a Quick Connect "Save to group → New group…" names. It was
    /// the one group-creating path that skipped `cleanGroupName`: the sheet
    /// only trimmed, and `AppModel.saveSession` looked the name up raw and
    /// appended it raw — so "Branch⟨U+2028⟩BKK" made a raw group, and after a
    /// relaunch (whose load pass cleans it to "Branch BKK") the same text made
    /// a SECOND one. Blank is the sheet's own fallback, "Quick Connect".
    static func quickConnectGroupName(_ raw: String) -> String {
        let cleaned = cleanGroupName(raw)
        return cleaned.isEmpty ? "Quick Connect" : cleaned
    }

    /// Where a Quick Connect save lands: the group with EXACTLY that name
    /// first (a group picked from the sheet's list, even a legacy one kept raw
    /// for a collision), then the one with the cleaned name — the name a new
    /// group would be created under. nil = create it. The lookup and the
    /// stored name agree because both go through `quickConnectGroupName`.
    func quickConnectGroupIndex(for raw: String) -> Int? {
        // A PATH first ("Site A › Bldg 1", what the pickers list since nested
        // groups — two subgroups may share a name), then a bare name.
        if let path = GroupTree.preorder(groups).first(where: {
            GroupTree.shownPath(of: $0.group.id, in: groups) == raw
        }), let at = groups.firstIndex(where: { $0.id == path.group.id }) { return at }
        if let exact = groups.firstIndex(where: { $0.name == raw }) { return exact }
        let name = Self.quickConnectGroupName(raw)
        return groups.firstIndex { $0.name == name }
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
        ConfigurationHygiene.cleanedName(name)
    }

    /// Same duplicate-name rule as addGroup — renaming into an existing
    /// name would make the two groups indistinguishable in pickers.
    /// Returns false (and changes nothing) when the name is taken.
    @discardableResult
    func renameGroup(_ group: HostGroup, to name: String) -> Bool {
        // Same pass as `addGroup`, for the same reason.
        let trimmed = Self.cleanGroupName(name)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == group.id }) else { return false }
        guard !nameTaken(trimmed, under: groups[index].parentID, except: group.id) else { return false }
        // Its own name again is not a change: no write, no re-armed saving.
        guard groups[index].name != trimmed else { return true }
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
    /// the way `removeHosts` does. A group goes with its whole SUBTREE —
    /// what the confirmation counts (`hostCount(ofGroupIDs:)`,
    /// `subgroupCount(ofGroupIDs:)`), and the returned number is the groups
    /// the user picked, not the subgroups that went with them.
    ///
    /// The loop this replaces wrote hosts.json once per group — three groups,
    /// three writes for one confirmed action — and left every deleted group's
    /// hosts in Recent, still clickable, pointing at entries that no longer
    /// exist anywhere.
    @discardableResult
    func deleteGroups(withIDs ids: Set<UUID>) -> Int {
        let picked = groups.filter { ids.contains($0.id) }.count
        guard picked > 0 else { return 0 }
        let doomed = Set(ids.flatMap { GroupTree.subtreeIDs(of: $0, in: groups) })
        let victims = groups.filter { doomed.contains($0.id) }
        noteUserMutation()
        var keys = Set<String>()
        for group in victims {
            deletedGroupIDs.insert(group.id)
            for host in group.hosts {
                deletedHostIDs.insert(host.id)
                keys.insert(host.connectionKey)
            }
        }
        groups.removeAll { doomed.contains($0.id) }
        // Same rule as `removeHosts`: a target another group still holds
        // keeps its recent, and is not tombstoned.
        pruneRecents(forRemovedKeys: keys)
        save()
        return picked
    }

    /// The group an import would merge into — same id first, then same
    /// name at the TOP LEVEL (an import lands there) — or nil when it lands
    /// as a brand-new group (0.4 ก).
    func existingGroup(matching incoming: HostGroup) -> HostGroup? {
        // By the CLEANED name: every door that WRITES a group name puts the
        // cleaned form in the store (`cleanGroupName`), so a `.sheepterm`
        // group written as "  Lab  " has to match the "Lab" already here.
        // Comparing raw made the dialog and the merge disagree about which
        // group an import was about — and a second "Lab" nobody can tell
        // apart from the first.
        let wanted = Self.cleanGroupName(incoming.name)
        return groups.first { $0.id == incoming.id }
            ?? GroupTree.children(of: nil, in: groups).first { Self.cleanGroupName($0.name) == wanted }
    }

    /// "Name 2", "Name 3", … — the first numbered variant no SIBLING has, so
    /// an import never creates an accidental duplicate group name (0.4 ค4).
    func uniqueGroupName(base: String, parent: UUID? = nil) -> String {
        if !nameTaken(base, under: parent, except: nil) { return base }
        var number = 2
        while nameTaken("\(base) \(number)", under: parent, except: nil) { number += 1 }
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
        // so the indices mean the same thing on both sides. Against the
        // matched group's WHOLE subtree, as the merge pairs it: a re-import of
        // your own export finds the hosts that sit in its subgroups.
        let rows = Self.importRows(incoming.hosts)
        let held = subtreeHosts(of: existing.id).map(\.host)
        return Self.mergePairing(existing: held, incoming: rows).compactMap { pair in
            guard let existingIndex = pair.existingIndex else { return nil }
            let current = held[existingIndex]
            let inc = rows[pair.incomingIndex]
            guard !Self.sameForImport(current, inc) else { return nil }
            return (incomingIndex: pair.incomingIndex, incoming: inc, existing: current)
        }
    }

    /// Every host of `groupID` and its subgroups in tree order, with where it
    /// sits — the one list an import pairs against.
    func subtreeHosts(of groupID: UUID) -> [(group: Int, index: Int, host: Host)] {
        let at = GroupTree.positions(groups)
        var out: [(group: Int, index: Int, host: Host)] = []
        for id in GroupTree.subtreeIDs(of: groupID, in: groups) {
            guard let g = at[id] else { continue }
            for (h, host) in groups[g].hosts.enumerated() { out.append((g, h, host)) }
        }
        return out
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
        // NAMES compared as the store would write them, on BOTH sides. An
        // import cleans the incoming name (since round 10 that folds U+2028),
        // but a name stored before that fix still carries the raw character —
        // so re-importing your own export raised a Replace/Keep conflict
        // whose diff read "name: sw 1 → sw 1".
        ConfigurationHygiene.cleanedName(a.name) == ConfigurationHygiene.cleanedName(b.name)
            && a.kind == b.kind && a.address == b.address
            && a.port == b.port && a.username == b.username
            // cipherMode and agentForward are NOT compared (4.1 (37)): a
            // .sheepterm cannot carry them any more (ShareCodec resets both
            // on import) and a Replace keeps ours — so a difference there is
            // never something the import would apply, and re-importing your
            // own export must not raise a conflict over it.
            // The device family travels in the file and decides which
            // highlight pack a session gets. Leaving it out of this test made
            // a file that changed ONLY the family (Cisco → Aruba CX) look
            // identical: no conflict was raised, and the merge below skipped
            // the host on the same test, so even answering Replace kept the
            // old family.
            && a.highlightVendor == b.highlightVendor
            // Same reasoning: a file that changes only this must raise the
            // conflict, or Replace would silently keep the old answer.
            && (a.disablePaging ?? false) == (b.disablePaging ?? false)
            && a.skipsLog == b.skipsLog
        // jumpHostID and jumpSpec are NOT compared: ShareCodec strips both
        // ways, so a file can never carry either and a Replace keeps ours
        // (like cipherMode).
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
        // The file's labels are PATHS below the group it names (a subtree
        // flattened by `GroupTree.exportable`, or an Add Hosts Group column),
        // and `fileLabels(splitPaths: true)` makes the subgroups — the
        // declared ones too, so an empty subgroup travels. A step that reads
        // like an existing subgroup IS that subgroup.
        var updated = groups
        let wanted = Self.cleanGroupName(incoming.name)
        let match: Int? = action == .createNew ? nil
            : updated.firstIndex(where: { $0.id == incoming.id })
                ?? GroupTree.children(of: nil, in: updated).first { Self.cleanGroupName($0.name) == wanted }
                    .flatMap { top in updated.firstIndex { $0.id == top.id } }
        if let index = match {
            // `.merge`. 0.4 (ค)2: never rename the existing group after the file.
            stats.groupName = updated[index].name
            let rootID = updated[index].id
            // ONE pairing, shared with the dialog (`conflictingHosts`), taken
            // over the PRE-merge subtree: which host each row is about was
            // decided when the user answered, and every row is about a
            // DIFFERENT host (see `mergePairing`'s claiming rule).
            let held = subtreeHosts(of: rootID)
            let pairs = Self.mergePairing(existing: held.map(\.host), incoming: incoming.hosts)
            var added: [Host] = []
            for pair in pairs {
                let inc = incoming.hosts[pair.incomingIndex]
                guard let slot = pair.existingIndex.map({ held[$0] }) else {
                    var row = inc
                    row.id = UUID()
                    added.append(row)
                    continue
                }
                let current = slot.host
                guard !Self.sameForImport(current, inc) else { continue }
                // No decision (aborted dialog) defaults to keep. Keyed by the
                // ROW, not the host id: two rows sharing an id used to share
                // one answer.
                guard replace[pair.incomingIndex] == true else { continue }
                // 0.4 (ค)1: a replaced host keeps OUR credential reference —
                // the file carries none — and OUR id, and it stays in the
                // subgroup it is in: open tabs and the sidebar keep pointing
                // at it, and where you file a host is not the file's to say.
                var merged = inc.carryingLocalFiling(from: current)
                merged.credentialID = current.credentialID
                // Same for what this Mac hands the server: the file's
                // values were reset on import (ShareCodec.stripForImport),
                // so taking them would silently switch OUR agent
                // forwarding off and our cipher policy back to auto.
                merged.agentForward = current.agentForward
                merged.cipherMode = current.cipherMode
                // Both jump fields are ours: a file never carries a path
                // (ShareCodec strips it), so Replace keeps what we had.
                merged.jumpHostID = current.jumpHostID
                merged.jumpSpec = current.jumpSpec
                // So are the port forwards (the file carries none).
                merged.forwards = current.forwards
                // A web host's trusted certificate is ours too (the file
                // never carries one) — kept while the URL is the same.
                merged.webTrustedCertSHA256 = merged.address == current.address
                    ? current.webTrustedCertSHA256 : nil
                // In place: the slot is claimed by this row alone, so no
                // later row can read or overwrite what was just written.
                updated[slot.group].hosts[slot.index] = merged
                // As `updateHost` does: the recent keyed by the old target
                // follows the edit instead of pointing at a connection that
                // no longer exists.
                updateRecents(from: current, to: merged)
                stats.replacedHosts += 1
            }
            updated[index].hosts.append(contentsOf: added)
            updated[index].sections = incoming.sections
            stats.addedHosts = added.count
        } else {
            // `.createNew` — or a `.merge` whose match vanished between the
            // dialog and now: land as a new top-level group rather than fail
            // silently.
            let group = HostGroup(id: UUID(), name: uniqueGroupName(base: wanted),
                                  hosts: Self.freshIDs(incoming.hosts), sections: incoming.sections)
            updated.append(group)
            stats.addedGroup = true
            stats.groupName = group.name
            stats.addedHosts = group.hosts.count
        }
        GroupTree.fileLabels(&updated, splitPaths: true, makeUpTo: GroupTree.userDepth)
        groups = updated
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
        for groupIndex in groups.indices {
            if let hostIndex = groups[groupIndex].hosts.firstIndex(where: { $0.id == host.id }) {
                let old = groups[groupIndex].hosts[hostIndex]
                // AFTER the lookup, like every other mutator here: an update
                // for a host that is no longer anywhere changes nothing, and
                // `noteUserMutation` re-arms writing over a file that was
                // quarantined at launch. This was the one door that re-armed
                // them for a no-op.
                noteUserMutation()
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
            recents[index].disablePaging = new.disablePaging
            recents[index].noLog = new.noLog
            recents[index].jumpHostID = new.jumpHostID
            recents[index].jumpSpec = new.jumpSpec
            recents[index].forwards = new.forwards
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

    // MARK: Group tree (6.0 (12))

    /// How many hosts those groups hold, counted over the REAL groups.
    ///
    /// Pure, and it takes the groups explicitly because that is the bug it
    /// exists for: a sidebar row built during a search carries a FILTERED
    /// copy of its group, and a delete confirmation that counted the row's
    /// own hosts promised "2 hosts go with them" and then deleted 35.
    /// Every subgroup of those groups counts too: deleting a group deletes
    /// its subtree, and the confirmation has to say how much goes with it.
    static func hostCount(ofGroupIDs ids: Set<UUID>, in groups: [HostGroup]) -> Int {
        let doomed = Set(ids.flatMap { GroupTree.subtreeIDs(of: $0, in: groups) })
        return groups.filter { doomed.contains($0.id) }.reduce(0) { $0 + $1.hosts.count }
    }

    /// How many SUBGROUPS (at any depth) go with those groups — the other
    /// half of the delete confirmation.
    static func subgroupCount(ofGroupIDs ids: Set<UUID>, in groups: [HostGroup]) -> Int {
        Set(ids.flatMap { GroupTree.subtreeIDs(of: $0, in: groups) }).subtracting(ids).count
    }

    /// Two heading names that read the same: case and every run of
    /// whitespace ignored. Used to REFUSE a rename, never to merge — the
    /// sidebar cannot show "Floor 2" and "Floor  2" as two different rows in
    /// any way a person can act on.
    static func sameHeading(_ a: String?, _ b: String?) -> Bool {
        guard let left = headingKey(a), let right = headingKey(b) else { return false }
        return left == right
    }

    /// The FOLDED form of a heading — lowercased, every run of whitespace
    /// squeezed to one space — or nil when nothing is left. Two headings read
    /// the same exactly when their keys are equal, and `sameHeading` is
    /// defined as that, so there is one rule and not two.
    ///
    /// Exposed because every list operation needs the key, not the comparison:
    /// folding a string costs a lowercase and a split, and asking
    /// `sameHeading` inside a loop over the headings made `displayedSections`,
    /// `SidebarLayout.rows`, `declareHeading` and `sanitizeHeadings` all
    /// quadratic — 800 headings over 2,000 hosts measured at ~2 s per sidebar
    /// rebuild (and every drag-over does one), and a hand-written 10,000-name
    /// list took 49 s to open. With a `Set` of keys they are linear.
    static func headingKey(_ text: String?) -> String? {
        guard let text else { return nil }
        let parts = text.lowercased().split(whereSeparator: \.isWhitespace)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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
    /// the insertion line. `childFirstHostIDs` is one entry per display
    /// child, nil for a subgroup row (`SidebarLayout.childFirstHostIDs`): nil
    /// means "no host to point at", and that is the end of the group's hosts.
    static func dropIndex(in hosts: [Host], childFirstHostIDs ids: [UUID?], childIndex index: Int) -> Int {
        // The end of the group for every case that names no host: past the
        // last child, or a child that is a heading. Under the loose rows IS
        // the end of the loose rows, which is where the headings start.
        guard index >= 0, index < ids.count, let id = ids[index] else { return hosts.count }
        return hosts.firstIndex { $0.id == id } ?? hosts.count
    }

    /// The hosts of one group, in array order — what the sidebar displays and
    /// what every drop index counts against.
    func hosts(inGroup groupID: UUID) -> [Host] {
        groups.first { $0.id == groupID }?.hosts ?? []
    }

    /// Which groups a "Move to Group" submenu should offer, in tree order
    /// with each one's depth (the menu indents by it): every group EXCEPT one
    /// that already holds all of them. Moving a selection into the group it
    /// is already in is a no-op the user cannot tell from a mistake.
    func moveTargets(forHostIDs ids: Set<UUID>) -> [(group: HostGroup, depth: Int)] {
        GroupTree.preorder(groups).filter { entry in
            !ids.isEmpty && !ids.isSubset(of: Set(entry.group.hosts.map(\.id)))
        }
    }

    /// Where a "Move to ▸" on GROUPS may put them, in tree order with depth:
    /// every group they fit under (`GroupTree.canMove`) except the one they
    /// are already all in. The top level is the menu's own first item.
    func groupMoveTargets(forGroupIDs ids: Set<UUID>) -> [(group: HostGroup, depth: Int)] {
        let parents = Set(groups.filter { ids.contains($0.id) }.map(\.parentID))
        return GroupTree.preorder(groups).filter { entry in
            !(parents.count == 1 && parents.first == entry.group.id)
                && GroupTree.canMove(ids, under: entry.group.id, in: groups)
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
        guard groups.contains(where: { $0.id == groupID }) else { return [] }
        let login = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Worked out BEFORE anything is written: `noteUserMutation` re-arms
        // saving over a quarantined file, and a call that changes nothing
        // must not do that (same rule as `addGroup`/`renameGroup`). The whole
        // SUBTREE: the group's subgroups are part of what was right-clicked.
        var changes: [(old: Host, new: Host)] = []
        var slots: [(group: Int, index: Int)] = []
        for slot in subtreeHosts(of: groupID) where slot.host.kind == .ssh {
            var updated = slot.host
            updated.credentialID = id
            if id != nil, !login.isEmpty { updated.username = login }
            guard updated != slot.host else { continue }
            changes.append((old: slot.host, new: updated))
            slots.append((slot.group, slot.index))
        }
        guard !changes.isEmpty else { return [] }
        noteUserMutation()
        var updated = groups
        for (change, slot) in zip(changes, slots) {
            updated[slot.group].hosts[slot.index] = change.new
        }
        groups = updated
        for change in changes {
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
        moveHosts(withIDs: [id], toGroupID: groupID, atIndex: index)
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
                   skippingHostsAlreadyThere: Bool = false) -> Int {
        guard let destGroup = groups.firstIndex(where: { $0.id == groupID }) else { return 0 }
        let wanted = Set(ids)
        // The moved hosts keep their ARRAY order — `groups.flatMap(\.hosts)`,
        // i.e. list order then each group's own order — which is the order a
        // multi-row drag that stays inside one group shows them in.
        let alreadyHere = Set(groups[destGroup].hosts.map(\.id))
        var moving = groups.flatMap(\.hosts).filter { wanted.contains($0.id) }
        // The MENU's rule, not a drop's: "Move to Group" on a selection that
        // spans groups is about the hosts that CHANGE group. The ones already
        // in the destination are left out entirely, position included:
        // pulling d1 out and re-appending it after d2 and d3 reordered a group
        // the user never dragged.
        if skippingHostsAlreadyThere { moving.removeAll { alreadyHere.contains($0.id) } }
        guard !moving.isEmpty else { return 0 }
        let movingIDs = Set(moving.map(\.id))

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

    /// The top-level twin of `moveGroups(withIDs:toParent:atIndex:)`, which
    /// is where the rules are.
    @discardableResult
    func moveGroups(withIDs ids: Set<UUID>, toIndex index: Int) -> Int {
        moveGroups(withIDs: ids, toParent: nil, atIndex: index)
    }

    /// The selected groups move together under `parent` (nil = the top
    /// level), to `index` among its subgroups, keeping their current relative
    /// order and taking their subtrees with them. `index` is a position among
    /// those subgroups as they stand right now — what NSOutlineView reports —
    /// so selected ones above it are subtracted, as in `moveHosts`.
    ///
    /// A group whose ancestor is also selected travels with that ancestor and
    /// is not moved on its own. Refused (0, nothing written) when the move
    /// would put a group inside itself or past the user's cap
    /// (`GroupTree.canMove`: `userDepth`, or no deeper for a branch already
    /// past it), and when
    /// it changes nothing — a no-op must not re-arm writes over a quarantined
    /// file. A parent that already has a subgroup of the same name keeps
    /// both: two rows the user can rename, never a silent merge.
    @discardableResult
    func moveGroups(withIDs ids: Set<UUID>, toParent parent: UUID?, atIndex index: Int) -> Int {
        let selected = ids.filter { id in groups.contains { $0.id == id } }
        let tops = Set(selected.filter { id in
            !GroupTree.ancestors(of: id, in: groups).contains { selected.contains($0.id) }
        })
        guard !tops.isEmpty, GroupTree.canMove(tops, under: parent, in: groups) else { return 0 }
        let moving = groups.filter { tops.contains($0.id) }.map { group -> HostGroup in
            var copy = group
            copy.parentID = parent
            return copy
        }
        // Siblings as they stand, for the pre-removal index.
        let siblings = GroupTree.children(of: parent, in: groups)
        let clamped = max(0, min(index, siblings.count))
        let removedBefore = siblings.prefix(clamped).filter { tops.contains($0.id) }.count
        var updated = groups.filter { !tops.contains($0.id) }
        // The siblings that stay, from the list AS IT STANDS. (Not
        // `children(of:in: updated)`: a moved group's own subgroups are still
        // in `updated` with their parent gone, so the top level counted them
        // as siblings and a top-level reorder of a group with subgroups
        // landed one slot off — found porting to Windows, 2026-10-28.)
        let remaining = siblings.filter { !tops.contains($0.id) }
        let slot = max(0, min(clamped - removedBefore, remaining.count))
        // Siblings are ordered by list position: in front of the sibling now
        // at `slot`, or after the last one (or after the parent itself when
        // there is none — anywhere would do, this keeps the file readable).
        let insertAt: Int
        if slot < remaining.count, let at = updated.firstIndex(where: { $0.id == remaining[slot].id }) {
            insertAt = at
        } else if let last = remaining.last, let at = updated.firstIndex(where: { $0.id == last.id }) {
            insertAt = at + 1
        } else if let parent, let at = updated.firstIndex(where: { $0.id == parent }) {
            insertAt = at + 1
        } else {
            insertAt = updated.count
        }
        updated.insert(contentsOf: moving, at: insertAt)
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
    /// sidebar uses `moveHosts(withIDs:toGroupID:atIndex:)` instead.
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
        // A host arriving WITH a label is filed below that group.
        if host.section != nil { GroupTree.fileLabels(&groups, splitPaths: true, makeUpTo: GroupTree.userDepth) }
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

/// The sidebar's row order INSIDE one group, worked out away from AppKit so
/// it can be tested. `SidebarOutline` walks this and builds rows from it; it
/// decides nothing about order itself.
///
/// **The rule** (6.0 (12)): the group's own hosts first, in array order, then
/// its subgroups in list order (`GroupTree.children`). Hosts first is the
/// order the old sections had (loose hosts above the headings), so a
/// migrated group looks the way it did.
enum SidebarLayout {
    enum Row: Equatable {
        case host(Host)
        case group(HostGroup)
    }

    static func rows(for group: HostGroup, in groups: [HostGroup]) -> [Row] {
        rows(for: group, subgroups: GroupTree.children(of: group.id, in: groups))
    }

    /// The same, with the subgroups already looked up — the sidebar builds
    /// one parent → children map per rebuild instead of a scan per group.
    static func rows(for group: HostGroup, subgroups: [HostGroup]) -> [Row] {
        group.hosts.map(Row.host) + subgroups.map(Row.group)
    }

    /// parent id → its subgroups in list order, in one pass.
    static func childMap(_ groups: [HostGroup]) -> [UUID: [HostGroup]] {
        var out: [UUID: [HostGroup]] = [:]
        for group in groups {
            if let parent = group.parentID, parent != group.id { out[parent, default: []].append(group) }
        }
        return out
    }

    /// What `HostStore.dropIndex` needs for a drop between a group's
    /// children: one entry per display row, nil for a subgroup row. A drop
    /// below the last host — among the subgroups — is the END of the hosts.
    static func childFirstHostIDs(for group: HostGroup, in groups: [HostGroup]) -> [UUID?] {
        group.hosts.map { Optional($0.id) }
            + Array(repeating: nil, count: GroupTree.children(of: group.id, in: groups).count)
    }

    /// The INVERSE of `HostStore.dropIndex`: which child row the insertion
    /// line belongs above for a store index. Hosts are the first rows in
    /// array order, so it is the index itself, at most the host count.
    static func childRow(forStoreIndex index: Int, in group: HostGroup) -> Int {
        min(max(0, index), group.hosts.count)
    }

    /// Where a dragged GROUP lands among `parent`'s subgroups for a drop at
    /// `childIndex` among its display rows: the hosts come first, so a point
    /// among them is the first subgroup slot. The insertion line is drawn at
    /// `hostCount + slot` — never among the hosts, where a group cannot go.
    static func subgroupSlot(childIndex: Int, hostCount: Int, subgroupCount: Int) -> (slot: Int, lineChildIndex: Int) {
        let slot = min(max(0, childIndex - hostCount), subgroupCount)
        return (slot, hostCount + slot)
    }

    /// Which group a ROOT-level drop line belongs to — the gap between two
    /// groups, above the first, or under the last. The last group ABOVE the
    /// line owns it (`aboveEveryGroup == false`); when the line is above every
    /// group, the FIRST group owns it and the drop goes to its TOP.
    /// `groupOrdinal` counts groups only.
    static func rootGapOwner(rootIsGroup: [Bool], index: Int) -> (groupOrdinal: Int, aboveEveryGroup: Bool)? {
        let groupPositions = rootIsGroup.indices.filter { rootIsGroup[$0] }
        guard !groupPositions.isEmpty else { return nil }
        let stop = min(max(index, 0), rootIsGroup.count)
        if let above = groupPositions.lastIndex(where: { $0 < stop }) { return (above, false) }
        return (0, true)
    }

    /// One row under a top-level header, for the drop rules: a host (in its
    /// own group), or a subgroup's folder row (under its parent). An OPEN
    /// folder's rows follow it at the same level, so a header's rows mix
    /// several groups — these two say whose each row is.
    enum FlatRow: Equatable {
        case host(UUID, group: UUID)
        case folder(UUID, parent: UUID)
    }

    /// A HOST dropped on the line above row `index` of a header's rows
    /// (`index == rows.count` = under the last one):
    /// - above a host → just before it, in that host's group;
    /// - right under a host (the line above a folder, or under the last row)
    ///   → just after that host, in ITS group: the line ending an open folder
    ///   puts a host last in that folder, not back at the top of the header;
    /// - above a folder with no host over it → the END of the hosts of the
    ///   group the folder sits in (a group's hosts come before its folders);
    /// - under a last row that is a folder → the end of the header's hosts.
    static func hostLanding(rows: [FlatRow], at index: Int, header: UUID,
                            groups: [HostGroup]) -> (group: UUID, index: Int) {
        func hostCount(_ id: UUID) -> Int { groups.first { $0.id == id }?.hosts.count ?? 0 }
        func position(of id: UUID, in group: UUID) -> Int? { groups.first { $0.id == group }?.hosts.firstIndex { $0.id == id } }
        guard index >= 0 else { return (header, hostCount(header)) }
        if index < rows.count, case .host(let id, let group) = rows[index] {
            return (group, position(of: id, in: group) ?? hostCount(group))
        }
        if index > 0, index <= rows.count, case .host(let id, let group) = rows[index - 1] {
            return (group, position(of: id, in: group).map { $0 + 1 } ?? hostCount(group))
        }
        if index < rows.count, case .folder(_, let parent) = rows[index] { return (parent, hostCount(parent)) }
        return (header, hostCount(header))
    }

    /// Where a line among a header's rows puts dragged GROUPS.
    enum GroupLanding: Equatable {
        /// The top level, in the gap above / below this header.
        case aboveHeader, belowHeader
        /// Under `parent` at `slot` among its subgroups, the line at row `line`.
        case inside(parent: UUID, slot: Int, line: Int)
    }

    /// GROUPS dropped on the line above row `index`. The pointer's distance
    /// from the edge plays no part: the user aims at a row, and a rule that
    /// read it made every line between two open groups nest the group.
    /// - above a folder → beside it, just before it, in the same parent;
    /// - above a host, top-level groups → the top level, in the gap nearest
    ///   the line (a host row is no place for a group, and the user is
    ///   reordering: going INTO a group is a drop ON its row);
    /// - above a host, subgroups → the FIRST subgroup of that host's group
    ///   (groups come after hosts, so this is the nearest place to the line);
    /// - under the last row → the gap below the header, so a subgroup comes
    ///   out to the top level there; but while the pointer is still ON that
    ///   last row (`pastLastRow` false), subgroups whose own parent ends at
    ///   this line stay in it, last: dragging a subgroup under its last
    ///   sibling is a reorder, and one row further down is the way out.
    static func groupLanding(rows: [FlatRow], at index: Int, header: UUID, groups: [HostGroup],
                             dragging: Set<UUID>, pastLastRow: Bool = false) -> GroupLanding {
        let parents = Set(groups.filter { dragging.contains($0.id) }.map(\.parentID))
        guard index >= 0, index < rows.count else {
            let last = rows.last.map(owner(of:)) ?? header
            let ending = GroupTree.ancestors(of: last, in: groups).map(\.id) + [last]
            if !pastLastRow, parents.count == 1, let home = parents.first ?? nil, ending.contains(home) {
                return .inside(parent: home, slot: GroupTree.children(of: home, in: groups).count, line: rows.count)
            }
            return .belowHeader
        }
        switch rows[index] {
        case .folder(let id, let parent):
            let slot = GroupTree.children(of: parent, in: groups).firstIndex { $0.id == id } ?? 0
            return .inside(parent: parent, slot: slot, line: index)
        case .host(_, let group):
            if parents == [nil] { return index * 2 < rows.count ? .aboveHeader : .belowHeader }
            let line = rows.firstIndex { $0 == .folder(id(of: $0), parent: group) }
                ?? rows.lastIndex { owner(of: $0) == group }.map { $0 + 1 } ?? index
            return .inside(parent: group, slot: 0, line: line)
        }
    }

    /// The group a row belongs to: a host's own, a folder's parent.
    private static func owner(of row: FlatRow) -> UUID {
        switch row {
        case .host(_, let group): group
        case .folder(_, let parent): parent
        }
    }

    private static func id(of row: FlatRow) -> UUID {
        switch row {
        case .host(let id, _), .folder(let id, _): id
        }
    }

    /// Whether the line under the section at root row `section` is the gap
    /// above the first group: the same line as the root gap there, which
    /// AppKit offers as the section's last child unless the pointer is at
    /// the very edge.
    static func sectionEndsAboveGroups(rootIsGroup: [Bool], section: Int) -> Bool {
        rootIsGroup.indices.contains(section + 1) && rootIsGroup[section + 1]
    }

    /// Whether a drag the outline thinks is running can still hold a rebuild
    /// back: AppKit tracks a drag only while a button is down.
    static func dragHoldsRebuild(mouseButtons: Int) -> Bool { mouseButtons != 0 }

    /// The open subgroups after a click on `id`: subgroups start SHUT, and
    /// each one opens and shuts on its own (the user tried "one open per
    /// level" and turned it down — open freely). What is open inside a
    /// subgroup keeps its state while that subgroup is shut.
    static func toggledOpen(_ id: UUID, in open: Set<UUID>, groups: [HostGroup]) -> Set<UUID> {
        var out = open
        if out.remove(id) == nil { out.insert(id) }
        return out
    }

    /// A dragged group dropped in a ROOT gap: its slot among the top-level
    /// groups (the groups above the line).
    static func rootGroupSlot(rootIsGroup: [Bool], index: Int) -> Int {
        let stop = min(max(index, 0), rootIsGroup.count)
        return rootIsGroup.prefix(stop).filter { $0 }.count
    }
}

extension String {
    /// Sidebar / Quick Search matching: case- and diacritic-insensitive, so
    /// `cafe` finds `café-sw1`. Thai has neither, so it is unaffected.
    func matchesSearch(_ query: String) -> Bool {
        range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
    }
}

/// A saved login (credentials.json). The password is never here — it lives
/// in the Keychain vault, keyed by `id` (`CredentialStore`).
struct Credential: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var username: String
    /// The web sites this login belongs to (5.0 (24), Safari's): origins as
    /// `WebLoginKey.siteKey` writes them ("https://192.168.225.39:443"). The
    /// login key lists these first on such a page and fills them only there.
    /// Optional so every credentials.json written before decodes unchanged;
    /// nil and [] mean the same.
    var websites: [String]? = nil
}
