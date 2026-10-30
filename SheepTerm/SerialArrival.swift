import Foundation

/// A USB serial cable plugged in while the app runs (5.0 (29)): since
/// 6.0 (14) the "Console cable" card (`SerialArrivalCard`, its lifecycle) for
/// `lifetime` seconds. In the app only, never a system notification. The
/// pure rules; `SerialWatcher` feeds the paths (IOKit notifications, no
/// polling) and `AppModel` drives the card.
nonisolated enum SerialArrival {
    static let lifetime: TimeInterval = 15
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

    /// The name on the card: `usbserial-1410`, not `/dev/cu.usbserial-1410`.
    static func shortName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("cu.") ? String(name.dropFirst(3)) : name
    }

    /// What the card opens by default: the saved serial host on that device, else a
    /// fresh console at the speed its USB device asks for (`ConsoleBaud`:
    /// an Aruba CX USB-C port 115200, every console cable 9600). Not the last
    /// recent's baud any more (5.0 (39)): one cable goes from a Cisco to an
    /// Aruba controller to a Huawei in a day, so the speed it had last time
    /// says nothing about the box it is plugged into now.
    static func host(for path: String, saved: [Host], usb: ConsoleBaud.USBDevice?) -> Host {
        let port = calloutPath(path)
        if let host = saved.first(where: { $0.kind == .serial && calloutPath($0.address) == port }) { return host }
        return Host(name: shortName(path), kind: .serial, address: path, port: ConsoleBaud.baud(for: usb))
    }

    /// What a serial tab's "port is open" status does to Recent (5.0 (39)/(40)). `noted` = the speed its
    /// recent was written at — carried over a Reconnect, so a speed picked while the tab was down moves
    /// the row too (the Windows port did this first). nil = leave Recent alone.
    enum RecentStep: Equatable { case note, move(from: Int) }
    static func recentStep(didNote: Bool, noted: Int?, baud: Int) -> RecentStep? {
        if let noted, noted != baud { return .move(from: noted) }
        return didNote ? nil : .note
    }

    /// A device re-enumerating on wake is not a cable just plugged in.
    static let wakeQuiet: TimeInterval = 5
}
