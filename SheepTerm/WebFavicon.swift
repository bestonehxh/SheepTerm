import AppKit
import CryptoKit
import SheepWeb

/// Site icons for web tabs (5.0 (53), shared): the tab chip and the pane header show
/// the page's own icon instead of the globe once one is known.
///
/// The icon is drawn by the PAGE, never fetched by the app (`WebFaviconRules` in SheepWeb, shared
/// with the other Sheep apps): a script in the app's own content world loads the page's `<link rel=icon>` (same origin only) or `/favicon.ico` into a 64 px
/// canvas and hands back a PNG. So it goes through WebKit's own connection — the certificate the
/// user trusted for a switch or firewall applies, nothing new talks to the LAN, and a page can
/// never make the app itself call another host. Kept per site (`WebLoginKey.siteKey`) in memory
/// and under Application Support/SheepTerm/Favicons; View → Clear Website Data… empties it.
/// ARCHITECTURE.md §21.
@MainActor
enum WebFavicon {
    private static var memory: [String: NSImage] = [:]
    /// Sites with no file on disk (not looked for again this run).
    private static var missing: Set<String> = []
    /// When each site's page was last asked (once per 10 minutes, not on every page of it).
    private static var asked: [String: Date] = [:]
    /// Bumped by `clear()`: an icon still being drawn when the user cleared website data is dropped.
    private(set) static var generation = 0

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(for site: String) -> URL {
        let name = SHA256.hash(data: Data(site.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".png")
    }

    static func image(for site: String?) -> NSImage? {
        guard let site else { return nil }
        if let image = memory[site] { return image }
        if missing.contains(site) { return nil }
        if let data = try? Data(contentsOf: file(for: site)), let image = WebFaviconRules.decode(data) {
            memory[site] = image
            return image
        }
        missing.insert(site)
        return nil
    }

    /// True once per site per 10 minutes.
    static func shouldAsk(_ site: String, now: Date = Date()) -> Bool {
        if let last = asked[site], now.timeIntervalSince(last) < 600 { return false }
        asked[site] = now
        return true
    }

    /// The PNG the page drew: decoded (a PNG, small) before it is kept.
    @discardableResult
    static func store(site: String, png: Data, generation asked: Int) -> NSImage? {
        guard asked == generation, png.count <= WebFaviconRules.maxPNGBytes, let image = WebFaviconRules.decode(png) else { return nil }
        memory[site] = image
        missing.remove(site)
        try? png.write(to: file(for: site), options: .atomic)
        return image
    }

    static func clear() {
        generation &+= 1
        memory.removeAll()
        missing.removeAll()
        asked.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

}

