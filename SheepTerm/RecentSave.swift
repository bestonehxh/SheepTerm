import Foundation

/// Recent → Save as Host… (5.0 (25)): which Add Host form a recent opens
/// and what it starts with. A recent is an ad-hoc connection, so nothing is
/// written until the form's Add; the form gets the recent's own values
/// (address, port, user, credential, options) under the recent's name.
enum RecentSave: Equatable {
    case web(name: String, url: String)
    case ssh(Host)
    case telnet(Host)
    /// Serial and local recents: the Add Host form has no such kind.
    case unsupported
    /// The recent IS a saved host (same connection): no second copy.
    case alreadySaved

    /// The recent is one of `saved`: same kind, address and port, and the
    /// users agree — either side empty counts as agreement (a saved host with
    /// no user, asked after KEX, leaves recents carrying the typed one; the
    /// rule `Host.completed(from:when:)` uses). One rule for the menu and the plan.
    static func isSaved(_ recent: Host, in saved: [Host]) -> Bool {
        saved.contains {
            $0.kind == recent.kind && $0.address == recent.address && $0.port == recent.port
                && ($0.username.isEmpty || recent.username.isEmpty || $0.username == recent.username)
        }
    }

    /// `credentialExists`: a credential id that no longer resolves starts
    /// the form on "enter manually" (as Edit Host does) instead of a blank picker.
    /// `saved`: every host in every group — a recent of one of them is not offered.
    static func plan(for recent: Host, saved: [Host], credentialExists: (UUID) -> Bool) -> RecentSave {
        if isSaved(recent, in: saved) { return .alreadySaved }
        switch recent.kind {
        case .web:
            return .web(name: recent.name, url: recent.address)
        case .ssh:
            var host = recent
            if let id = host.credentialID, !credentialExists(id) { host.credentialID = nil }
            return .ssh(host)
        case .telnet:
            return .telnet(recent)
        default:
            return .unsupported
        }
    }
}
