import Foundation

/// A USB serial cable plugged in while the app runs (5.0 (29), the user's
/// option 1): a dashed "shadow" tab at the end of the tab strip for
/// `lifetime` seconds — click = open that console. In the app only, never a
/// system notification. The pure rules; `SerialWatcher` feeds the paths
/// (IOKit notifications, no polling) and `AppModel` shows the shadow.
nonisolated enum SerialArrival {
    static let lifetime: TimeInterval = 15
    /// Baud when nothing better is known: network gear consoles ship 9600 8N1.
    static let defaultBaud = 9600

    /// A cable's callout device, not one of the Mac's own ports.
    static func isCable(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("cu.") else { return false }
        let lower = name.lowercased()
        return !["bluetooth", "debug-console", "wlan", "airpods"].contains { lower.contains($0) }
    }

    /// `/dev/tty.X` and `/dev/cu.X` are one port: compare by the callout path
    /// (a host typed as tty must still match the cable, review 5.0 (29)).
    static func calloutPath(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("tty.") else { return path }
        return ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("cu." + name.dropFirst(4))
    }

    /// The name on the shadow tab: `usbserial-1410`, not `/dev/cu.usbserial-1410`.
    static func shortName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("cu.") ? String(name.dropFirst(3)) : name
    }

    /// What the shadow opens: the saved serial host on that device, else the
    /// last recent on it (its baud), else a fresh console at 9600.
    static func host(for path: String, saved: [Host], recents: [Host]) -> Host {
        let port = calloutPath(path)
        if let host = saved.first(where: { $0.kind == .serial && calloutPath($0.address) == port }) { return host }
        let baud = recents.first(where: { $0.kind == .serial && calloutPath($0.address) == port })?.port ?? defaultBaud
        return Host(name: shortName(path), kind: .serial, address: path, port: baud)
    }

    /// The shadow tab now: one device at a time (the newest arrival), gone
    /// when it expires, when the cable is pulled, or when a tab already
    /// holds that device.
    struct Shadow: Equatable {
        let path: String
        let shownAt: Date

        var name: String { SerialArrival.shortName(path) }

        func isLive(now: Date) -> Bool { now.timeIntervalSince(shownAt) < SerialArrival.lifetime && now >= shownAt }
    }

    /// The shadow after a device event. `arrived`: a cable appeared (nil = a
    /// device went away, `gone`). `openPaths`: devices a tab already holds.
    static func next(current: Shadow?, arrived: String?, gone: String?, openPaths: Set<String>, now: Date) -> Shadow? {
        let open = Set(openPaths.map(calloutPath))
        if let arrived, isCable(arrived), !open.contains(calloutPath(arrived)) { return Shadow(path: arrived, shownAt: now) }
        if let current, let gone, calloutPath(current.path) == calloutPath(gone) { return nil }
        guard let current, current.isLive(now: now), !open.contains(calloutPath(current.path)) else { return nil }
        return current
    }

    /// A device re-enumerating on wake is not a cable just plugged in.
    static let wakeQuiet: TimeInterval = 5
}
