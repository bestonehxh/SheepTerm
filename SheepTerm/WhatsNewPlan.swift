import Foundation

/// The What's New window: each page and tip carries the release a user could
/// first have had it in (the PUBLIC build that contained it), and on launch
/// after an update the window shows only what is newer than the release this
/// Mac last ran (the owner, 2026-11-17: "What's New ตามอัพเกรดจริง") — nothing
/// newer, no window. Help ▸ What's New… shows everything. Versions are
/// "<marketing>.<build>" ("6.1.57"), compared numerically
/// (`UpdateCore.compareDotted`).
///
/// Records (local only — not synced, not in Backup):
/// - `lastRunKey`: the newest release this Mac has launched, written at every
///   launch from 6.1 (64) on (6.2 (1) is the first public one), never
///   lowered (a downgrade leaves it).
/// - `seenKey`: the newest window key shown (written when SHOWN, never
///   lowered) — what 6.0 (13)–6.1 (63) wrote and read. Read here only when
///   `lastRunKey` is missing, to tell which public line the Mac came from.
nonisolated enum WhatsNewPlan {
    struct Item: Equatable {
        let id: String
        /// The public release it arrived in.
        let release: String
    }

    /// Newest first: Help ▸ What's New… opens on the latest; an upgrade sees
    /// the same order, filtered. The view's pages carry these ids.
    /// Public Mac builds: 6.0 (18), 6.1 (11)–(13), 6.1 (57); 6.2 (1) is the
    /// next one (the owner, 2026-11-18; 6.1 (58)–(64) never shipped).
    static let pages: [Item] = [
        Item(id: "banner", release: "6.2.1"),        // 6.1 (58)–(59)
        Item(id: "steadier", release: "6.2.1"),      // 6.1 (60)–(63)
        Item(id: "home", release: "6.1.11"),         // 6.0 (22)–(40)
        Item(id: "workspaces", release: "6.1.57"),   // 6.1 (16)
        Item(id: "badges", release: "6.1.11"),       // 6.0 (21)–(32)
        Item(id: "rightclick", release: "6.1.11"),   // 6.0 (20)–(26)
        Item(id: "import", release: "6.1.57"),       // 6.1 (17)
        Item(id: "jump", release: "6.1.57"),         // the page's news: four hops, 6.1 (34)
        Item(id: "groupicon", release: "6.1.11"),    // 6.0 (38)
        Item(id: "trash", release: "6.1.57"),        // 6.1 (28)
        Item(id: "savesplit", release: "6.1.57"),    // 6.1 (36)
        Item(id: "keys", release: "6.1.11"),         // 6.0 (27)–(46)
        Item(id: "optimize", release: "6.1.11"),     // 6.0 (22)
    ]
    /// In the Tips page's reading order (two per row, paired by length).
    static let tips: [Item] = [
        Item(id: "logs", release: "6.1.11"),         // 6.0 (44)
        Item(id: "rightclickall", release: "6.1.11"),
        Item(id: "homesearch", release: "6.1.11"),   // 6.0 (34)–(40)
        Item(id: "reopen", release: "6.1.57"),       // 6.1 (35)
        Item(id: "depth", release: "6.1.57"),        // 6.1 (15)
        Item(id: "zmodem", release: "6.1.57"),       // 6.1 (37)
        Item(id: "broadcast", release: "6.1.57"),    // 6.1 (46)
        Item(id: "topbar", release: "6.1.57"),       // 6.1 (29)
        Item(id: "stopwatch", release: "6.1.11"),    // 6.1 (8)–(9)
        Item(id: "optimize", release: "6.1.11"),     // Start Optimize's tip
    ]

    /// The newest release any page or tip names: the key `seenKey` records.
    static let release: String = (pages + tips).map(\.release)
        .max { UpdateCore.compareDotted($0, $1) == .orderedAscending } ?? "0"
    static let seenKey = "whatsNewSeen"
    static let lastRunKey = "whatsNewLastRun"
    /// The last public build before this one: where a Mac with data but no
    /// readable record is taken to come from.
    static let lastShipped = "6.1.57"
    /// What 6.1 (11)–(57) recorded when they showed their window ("6.1.1");
    /// a valid record older than it was written by 6.0 (≤ 6.0 (18) public).
    static let windowKey61 = "6.1.1"
    static let lastShipped60 = "6.0.18"
    /// 6.1 (58)–(64) never shipped; they were the development of 6.2 (1)
    /// and carry its pages. A record from one of them = 6.2 (1), so what that
    /// Mac already saw is not shown again (only the owner's test Macs).
    static let nextPublic = "6.2.1"
    static func fromDevelopment(_ release: String) -> String {
        UpdateCore.compareDotted(release, lastShipped) == .orderedDescending
            && UpdateCore.compareDotted(release, "6.2") == .orderedAscending ? nextPublic : release
    }

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

    /// "6.1.57", "6.0", "6": digits and dots only (anything else = unreadable).
    static func isRelease(_ s: String?) -> Bool {
        guard let s else { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.count <= 4
            && parts.allSatisfy { !$0.isEmpty && $0.count <= 6 && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// What this Mac had before this launch.
    enum Since: Equatable {
        /// A new Mac: nothing saved, no record.
        case freshInstall
        /// Older than every page (a build before 6.0 (13) showed it).
        case beforeAll
        case release(String)
    }

    static func since(lastRun: String?, seen: String?, usedBefore: Bool) -> Since {
        if isRelease(lastRun), let lastRun { return .release(fromDevelopment(lastRun)) }
        // No record of its own: an older build (or an unreadable record).
        guard let seen else { return usedBefore ? .beforeAll : .freshInstall }
        guard isRelease(seen) else { return .release(lastShipped) }
        // Past the last public build: a development build's key ("6.1.60"
        // from 6.1 (60)–(64)), or a later build's.
        if UpdateCore.compareDotted(seen, lastShipped) == .orderedDescending { return .release(fromDevelopment(seen)) }
        if UpdateCore.compareDotted(seen, windowKey61) != .orderedAscending { return .release(lastShipped) }
        return .release(lastShipped60)
    }

    struct Selection: Equatable {
        var pages: [String]
        var tips: [String]
        var isEmpty: Bool { pages.isEmpty && tips.isEmpty }
        /// The feature pages, then one Tips page when there are tips.
        var pageCount: Int { pages.count + (tips.isEmpty ? 0 : 1) }
        /// Start Optimize ends the window only when its tip is there.
        var endsWithOptimize: Bool { tips.contains("optimize") }
    }

    static let everything = Selection(pages: pages.map(\.id), tips: tips.map(\.id))

    /// THE rule: Help ▸ What's New… = everything; a launch = what is newer
    /// than `since` and not newer than the running build — none on a new Mac,
    /// on the same build again, or after a downgrade.
    static func selection(since: Since, running: String, fromHelp: Bool, enabled: Bool = showsOnLaunch) -> Selection {
        if fromHelp { return everything }
        guard enabled else { return Selection(pages: [], tips: []) }
        func newer(_ item: Item) -> Bool {
            guard UpdateCore.compareDotted(item.release, running) != .orderedDescending else { return false }
            switch since {
            case .freshInstall: return false
            case .beforeAll: return true
            case .release(let last): return UpdateCore.compareDotted(item.release, last) == .orderedDescending
            }
        }
        return Selection(pages: pages.filter(newer).map(\.id), tips: tips.filter(newer).map(\.id))
    }

    static func selection(lastRun: String?, seen: String?, running: String, usedBefore: Bool, fromHelp: Bool = false) -> Selection {
        selection(since: since(lastRun: lastRun, seen: seen, usedBefore: usedBefore), running: running, fromHelp: fromHelp)
    }

    /// `lastRunKey` after this launch: the running release, never lowered.
    static func lastRunAfterLaunch(_ lastRun: String?, running: String) -> String {
        guard isRelease(lastRun), let lastRun, UpdateCore.compareDotted(lastRun, running) == .orderedDescending else { return running }
        return lastRun
    }

    /// The record after the window has been shown: this release, never
    /// lowered (Help ▸ What's New… in an older build must not make a newer
    /// one's window come back in a build that still reads `seenKey`).
    static func seenAfterShowing(_ seen: String?) -> String {
        guard let seen, UpdateCore.compareDotted(seen, release) == .orderedDescending else { return release }
        return seen
    }
}
