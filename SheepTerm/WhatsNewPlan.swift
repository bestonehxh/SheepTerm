import Foundation

/// The What's New window: opens ON ITS OWN exactly once per release that
/// carries one — on the first launch of a build at or past `release` on a
/// Mac whose record is older (a fresh install has none, so it sees it once).
/// The record is written when the window is SHOWN (not only when closed),
/// so a crash or force-quit never brings it back; Help ▸ What's New… opens
/// it any time. Versions are "<marketing>.<build>" ("6.0.13"), compared
/// numerically (`UpdateCore.compareDotted`); an older record ("6.0", what
/// 6.0 (1)–(12) wrote) is older than any 6.0 build's.
nonisolated enum WhatsNewPlan {
    /// The release the window describes: 6.0 (13).
    static let release = "6.0.13"
    static let seenKey = "whatsNewSeen"
    /// The DEBUG hook SHEEPTERM_DEBUG_WHATSNEW_PAGE: any number lands on a
    /// real page (an out-of-range index would trap in `pages[page]`).
    static func debugPage(_ requested: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(requested, 0), count - 1)
    }
    /// Back on in 6.0 (13) (the user), with the once-per-release rule.
    static let showsOnLaunch = true

    /// "6.0" + "13" → "6.0.13".
    static func running(marketing: String, build: String) -> String {
        build.isEmpty ? marketing : "\(marketing).\(build)"
    }

    static func shouldShow(seen: String?, running: String, enabled: Bool = showsOnLaunch) -> Bool {
        guard enabled else { return false }
        // An older build than the one that carries this window: not its news.
        guard UpdateCore.compareDotted(running, release) != .orderedAscending else { return false }
        guard let seen else { return true }
        return UpdateCore.compareDotted(seen, release) == .orderedAscending
    }

    /// The record after the window has been shown: this release, never
    /// lowered (Help ▸ What's New… in an older build must not make a newer
    /// one's window come back).
    static func seenAfterShowing(_ seen: String?) -> String {
        guard let seen, UpdateCore.compareDotted(seen, release) == .orderedDescending else { return release }
        return seen
    }
}
