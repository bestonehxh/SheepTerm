import Foundation

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

    /// The command that turns the device's pager off for this session, sent
    /// once after the shell is up when the host asks for it (Edit Host →
    /// "Disable paging on connect"). nil = nothing is sent: Auto cannot
    /// know, Linux has no pager of its own, and FortiOS's only switch
    /// (`config system console … set output standard`) is a CONFIG change
    /// that outlives the session — auto-page (View → Auto-page) covers it
    /// without touching the box.
    var disablePagingCommand: String? {
        switch self {
        case .auto, .linux, .fortios: return nil
        case .cisco: return "terminal length 0"
        case .arubaCX, .arubaOS: return "no page"
        case .huawei: return "screen-length 0 temporary"
        case .comware: return "screen-length disable"
        case .juniper: return "set cli screen-length 0"
        case .panos: return "set cli pager off"
        case .gaia: return "set clienv rows 0"
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

