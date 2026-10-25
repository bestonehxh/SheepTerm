import Foundation

/// The What's New window (6.0): shown ONCE, on the first launch of 6.0 or
/// later on a Mac that has not closed it yet; closing it records the
/// release so it never comes back for that release.
nonisolated enum WhatsNewPlan {
    /// The release the window describes.
    static let release = "6.0"
    static let seenKey = "whatsNewSeen"
    /// Off since 6.0 (3) (the user): no update opens the window on its own,
    /// not even on a Mac that never closed it. The once-per-release rule
    /// stays for a release that turns it back on.
    static let showsOnLaunch = false

    static func shouldShow(seen: String?, running: String, enabled: Bool = showsOnLaunch) -> Bool {
        guard enabled else { return false }
        guard UpdateCore.compareDotted(running, release) != .orderedAscending else { return false }
        guard let seen else { return true }
        return UpdateCore.compareDotted(seen, release) == .orderedAscending
    }
}
