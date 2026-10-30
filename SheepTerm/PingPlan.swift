import Foundation

/// The Ping tab's rules (6.0 (2)): what a typed line expands to, how a row's
/// last 60 packets read as up / slow / down, and the up/down log lines.
/// Pure and Foundation-only — the harness compiles it (`PingTests`).
nonisolated enum PingPlan {
    /// Targets one tab pings at most (one /sbin/ping process each).
    static let maxTargets = 64
    /// Packets a row remembers (stats + sparkline).
    static let window = 60
    /// A reply slower than this (ms) makes the row amber.
    static let slowMilliseconds = 100.0
    /// Consecutive lost packets that make a row red.
    static let downAfter = 2
    /// Send intervals offered (s); the first launch uses `defaultInterval`.
    static let intervals: [Double] = [0.5, 1, 2, 5]
    static let defaultInterval = 1.0
    /// Reply deadline handed to ping (-W) and its watchdog.
    static let replyTimeout = 2.0
    /// Log lines kept per tab (in memory only).
    static let logCap = 1000
    /// Shortest CIDR prefix expanded (/24 = 254 hosts — the cap trims it).
    static let shortestPrefix = 24

    // MARK: Targets

    struct Expansion: Equatable {
        /// New targets, in the order typed, none already in the tab.
        var targets: [String] = []
        /// Words that are not an address, a name, a range or a /24…/32.
        var refused: [String] = []
        /// True when `maxTargets` cut the list short.
        var truncated = false
    }

    /// `10.0.0.1, core-sw 10.0.1.0/29 10.0.2.1-20` → one address per target.
    /// Commas, semicolons and spaces separate; `existing` (the tab's
    /// targets) is skipped case-insensitively, and the total stays ≤ `maxTargets`.
    static func expand(_ text: String, existing: [String] = []) -> Expansion {
        var result = Expansion()
        var seen = Set(existing.map { $0.lowercased() })
        var room = max(0, maxTargets - existing.count)
        for word in words(text) {
            guard let addresses = addresses(for: word) else {
                result.refused.append(word)
                continue
            }
            for address in addresses where !seen.contains(address.lowercased()) {
                guard room > 0 else { result.truncated = true; break }
                seen.insert(address.lowercased())
                result.targets.append(address)
                room -= 1
            }
        }
        return result
    }

    /// A typed line's words: commas, semicolons and spaces separate.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map(String.init)
    }

    /// Every address a line names, in the order typed, once each
    /// (case-insensitive) — existing targets included, refused words and
    /// the cap ignored. `arrange` lays the rows out by it.
    static func typedOrder(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in words(text) {
            for address in addresses(for: word) ?? [] where seen.insert(address.lowercased()).inserted {
                out.append(address)
            }
        }
        return out
    }

    /// The rows after a line is submitted (6.0 (14)): the targets the line
    /// names — rows already in the tab and new ones — sit in the order typed,
    /// as one block starting where the first named existing row was; rows the
    /// line does not name keep their order around it. A line naming no
    /// existing row appends its new targets at the end (as before).
    /// Case-insensitive like `expand`; an existing row keeps its own spelling;
    /// a target typed twice counts once (its first place).
    static func arrange(current: [String], typed: [String]) -> [String] {
        var spelling: [String: String] = [:]
        for address in current where spelling[address.lowercased()] == nil { spelling[address.lowercased()] = address }
        var seen = Set<String>()
        let block = typed.compactMap { address -> String? in
            let key = address.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return spelling[key] ?? address
        }
        guard let start = current.firstIndex(where: { seen.contains($0.lowercased()) }) else { return current + block }
        let before = current[..<start].filter { !seen.contains($0.lowercased()) }
        let after = current[start...].filter { !seen.contains($0.lowercased()) }
        return before + block + after
    }

    /// Drag to reorder (6.0 (14)): `moving` leaves `ids` (keeping its
    /// order) and lands before the item that was at `index` in `ids`
    /// (`ids.count` = the end). Ids not in `ids` are ignored.
    static func move<ID: Hashable>(_ ids: [ID], moving: Set<ID>, to index: Int) -> [ID] {
        let at = min(max(0, index), ids.count)
        let moved = ids.filter { moving.contains($0) }
        guard !moved.isEmpty else { return ids }
        var rest = ids.filter { !moving.contains($0) }
        let shift = ids[..<at].filter { moving.contains($0) }.count
        rest.insert(contentsOf: moved, at: at - shift)
        return rest
    }

    /// One word → its addresses; nil = not a target.
    static func addresses(for word: String) -> [String]? {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !w.hasPrefix("-") else { return nil }
        if let slash = w.firstIndex(of: "/") {
            guard let base = ipv4(String(w[..<slash])), let prefix = Int(w[w.index(after: slash)...]),
                  prefix >= shortestPrefix, prefix <= 32 else { return nil }
            let size = UInt32(1) << UInt32(32 - prefix)
            let network = base & ~(size &- 1)
            var hosts = (0..<size).map { network + $0 }
            // /31 and /32 have no network/broadcast address to skip.
            if prefix <= 30 { hosts = Array(hosts.dropFirst().dropLast()) }
            return hosts.map(dotted)
        }
        if let dash = w.firstIndex(of: "-"), let first = ipv4(String(w[..<dash])) {
            let tail = String(w[w.index(after: dash)...])
            let last: UInt32
            if let octet = UInt32(tail), octet <= 255 {
                last = (first & 0xFFFF_FF00) | octet
            } else if let full = ipv4(tail), full & 0xFFFF_FF00 == first & 0xFFFF_FF00 {
                last = full
            } else {
                return nil
            }
            guard last >= first else { return nil }
            return (first...last).map(dotted)
        }
        if ipv4(w) != nil { return [w] }
        if w.contains(":") { return looksLikeIPv6(w) ? [w] : nil }
        return isHostName(w) ? [w] : nil
    }

    static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            value = value << 8 | octet
        }
        return value
    }

    static func dotted(_ value: UInt32) -> String {
        "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    static func looksLikeIPv6(_ text: String) -> Bool {
        let parts = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let address = parts.first, address.filter({ $0 == ":" }).count >= 2,
              address.allSatisfy({ ($0.isASCII && $0.isHexDigit) || $0 == ":" || $0 == "." }) else { return false }
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        }
        return true
    }

    /// RFC 1123-ish: ASCII letters, digits, `-` `_` `.`, at least one letter
    /// (an all-digit word like `300` is a typo, not a host).
    static func isHostName(_ text: String) -> Bool {
        guard text.count <= 253, !text.hasPrefix("."), !text.hasSuffix("-"),
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }),
              text.contains(where: { $0.isLetter }) else { return false }
        return !text.contains("..")
    }

    /// The connect box: `ping 10.10.1.1` (or several) → the targets; nil
    /// for anything else, or when a word is not a target.
    static func connectBoxTargets(_ text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("ping ") else { return nil }
        let expansion = expand(String(trimmed.dropFirst(5)))
        guard expansion.refused.isEmpty, !expansion.targets.isEmpty else { return nil }
        return expansion.targets
    }

    /// Rename… (6.0 (14)): only a row whose target is an address literal
    /// (IPv4 / IPv6) takes a name — a row typed as a name already has one.
    static func canRename(_ address: String) -> Bool {
        // A link-local IPv6 with its zone (`fe80::1%en0`) is an address too.
        let parts = address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let ip = parts.first, isAddressLiteral(String(ip)) else { return false }
        return parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// Longest name Rename… keeps.
    static let maxRowName = 64

    /// What Rename… stores: trimmed, at most `maxRowName` characters; nil
    /// (empty) = no name of its own — the row shows the saved host's name or
    /// the address again (`hostCells`).
    static func rowName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && !($0.unicodeScalars.first.map(CharacterSet.controlCharacters.contains) ?? false) }
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxRowName))
    }

    /// The saved host's name for an address (case-insensitive), else nil.
    static func savedName(for address: String, in saved: [(name: String, address: String)]) -> String? {
        let key = address.lowercased()
        return saved.first { $0.address.lowercased() == key && !$0.name.isEmpty }?.name
    }

    // MARK: Status

    enum Status: Equatable {
        /// No packet settled yet (or the row was restarted).
        case waiting
        case up, slow, down
        /// Stopped by the user.
        case stopped
    }

    /// One row's last `window` packets: latency in ms, nil = lost.
    struct Stats: Equatable {
        private(set) var samples: [Double?] = []
        private(set) var consecutiveLosses = 0
        private(set) var status: Status = .waiting

        var lastLatency: Double? { samples.last ?? nil }
        var lossPercent: Double? {
            guard !samples.isEmpty else { return nil }
            return Double(samples.filter { $0 == nil }.count) / Double(samples.count) * 100
        }

        /// Records one packet; returns the new status when it changed.
        @discardableResult
        mutating func record(_ latency: Double?) -> Status? {
            samples.append(latency)
            if samples.count > PingPlan.window { samples.removeFirst(samples.count - PingPlan.window) }
            consecutiveLosses = latency == nil ? consecutiveLosses + 1 : 0
            let next: Status
            if consecutiveLosses >= PingPlan.downAfter {
                next = .down
            } else if latency == nil && status == .down {
                next = .down       // one more loss while down is still down
            } else if latency == nil && status == .waiting {
                next = .waiting    // a first lost packet says nothing yet
            } else if (latency ?? 0) > PingPlan.slowMilliseconds || samples.contains(where: { $0 == nil }) {
                next = .slow
            } else {
                next = .up
            }
            defer { status = next }
            return next == status ? nil : next
        }

        mutating func stop() { status = .stopped; consecutiveLosses = 0 }
        /// Resume keeps the samples; the status is re-earned by the next packet.
        mutating func resume() { status = .waiting; consecutiveLosses = 0 }
        mutating func reset() { self = Stats() }
    }

    // MARK: Log

    /// What the log records: the first reply, going down, coming back
    /// after `downFor` seconds, and the user's stop / remove (the log was
    /// empty while everything answered — the owner read that as broken).
    enum Event: Equatable {
        case first(latency: Double?)
        case down
        case up(downFor: TimeInterval?)
        case stopped
        case removed

        /// For the log's dot: green / red / grey.
        enum Tone { case good, bad, neutral }
        var tone: Tone {
            switch self {
            case .first, .up: return .good
            case .down: return .bad
            case .stopped, .removed: return .neutral
            }
        }
    }

    /// The event a status change makes, if any: the first answer, entering
    /// down, and leaving it for up/slow. Up ↔ slow is not logged.
    static func event(from old: Status, to new: Status, latency: Double? = nil, downSince: Date?, now: Date) -> Event? {
        if new == .down && old != .down { return .down }
        if old == .down && (new == .up || new == .slow) {
            return .up(downFor: downSince.map { now.timeIntervalSince($0) })
        }
        if old == .waiting && (new == .up || new == .slow) { return .first(latency: latency) }
        return nil
    }

    /// "09:41:02 edge-fw down" / "09:43:10 edge-fw up · down 2m 8s"
    static func logLine(_ event: Event, name: String, at date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let time = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "\(time) \(name) \(eventText(event))"
    }

    /// The event alone: "replying · 1.2 ms", "down", "up · down 2m 8s".
    static func eventText(_ event: Event) -> String {
        switch event {
        case .first(let ms): return ms.map { "replying · \(latencyText($0))" } ?? "replying"
        case .down: return "down"
        case .up(let downFor?): return "up · down \(duration(downFor))"
        case .up(nil): return "up"
        case .stopped: return "stopped"
        case .removed: return "removed"
        }
    }

    /// 45s · 2m 8s · 1h 3m
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    static func appendingLog(_ line: String, to log: [String]) -> [String] {
        var out = log
        out.append(line)
        if out.count > logCap { out.removeFirst(out.count - logCap) }
        return out
    }

    /// A host's log as CSV (SheepPing's format), quoting the message.
    static func csv(_ packets: [(Date, Double?, String)]) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["Timestamp,Status,Latency (ms),Message"]
        for (date, latency, message) in packets {
            let lat = latency.map { String(format: "%.1f", $0) } ?? ""
            // A leading = + - @ would be a formula in a spreadsheet, quoted
            // or not: an apostrophe keeps it text (review 6.0 (2)).
            let safe = message.first.map { "=+-@".contains($0) } == true ? "'" + message : message
            lines.append("\(f.string(from: date)),\(latency == nil ? "Fail" : "OK"),\(lat),\"\(safe.replacingOccurrences(of: "\"", with: "\"\""))\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The wait before starting a ping again. One that ran for at least an
    /// interval resets to the interval; one that died sooner doubles it, up
    /// to 30 s.
    static func respawnPause(previous: Double, interval: Double, lived: Double) -> Double {
        lived >= interval ? interval : min(30, max(interval, previous * 2))
    }

    /// The Hostname and IP columns. Hostname: a saved host's name, or the
    /// name typed; the address itself for a bare one. IP: what it resolved to, else
    /// the address typed when it is one, else "…" while resolving.
    static func hostCells(name: String, address: String, resolved: String) -> (hostname: String, ip: String) {
        let literal = isAddressLiteral(address)
        // No name: the address itself (the owner, 6.0 (2)), never a dash.
        let hostname = name.lowercased() != address.lowercased() ? name : address
        let ip = !resolved.isEmpty ? resolved : (literal ? address : "…")
        return (hostname, ip)
    }

    /// A dotted IPv4 or an IPv6 literal (not a name).
    static func isAddressLiteral(_ text: String) -> Bool {
        if text.contains(":") { return text.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" } }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in Int(p).map { (0...255).contains($0) && !p.isEmpty } ?? false }
    }

    // MARK: Columns

    /// The list's columns after the status dot (always shown).
    enum Column: CaseIterable, Hashable {
        case hostname, ip, status, latency, ok, failed, rate, graph
    }

    /// What a narrow pane (a split) gives up first: the graph, Rate, IP,
    /// then Status (the dot before the name says it too), then Latency.
    /// Hostname, OK and Failed always stay (the owner, 6.0 (2): a split hid
    /// Failed — the count that matters most).
    static let dropOrder: [Column] = [.graph, .rate, .ip, .status, .latency]
    static let alwaysShown: Set<Column> = [.hostname, .ok, .failed]
    /// Column gaps tried, widest first: a split closes them up before it
    /// gives up a column (other than the graph).
    static let gaps: [Double] = [32, 20, 12]

    /// The columns that fit in `width`: each one costs its width plus `gap`;
    /// `fixed` is what every row spends regardless (dot, padding).
    static func visibleColumns(width: Double, widths: [Column: Double], gap: Double, fixed: Double) -> Set<Column> {
        var shown = Set(Column.allCases)
        func need() -> Double { fixed + shown.reduce(0) { $0 + (widths[$1] ?? 0) + gap } }
        for column in dropOrder where need() > width { shown.remove(column) }
        return shown
    }

    /// The widest gap that keeps the most columns (`gaps`, `visibleColumns`).
    static func columnLayout(width: Double, widths: [Column: Double], fixed: Double) -> (shown: Set<Column>, gap: Double) {
        var best: (shown: Set<Column>, gap: Double)?
        for gap in gaps {
            let shown = visibleColumns(width: width, widths: widths, gap: gap, fixed: fixed)
            if best == nil || shown.subtracting([.graph]).count > best!.shown.subtracting([.graph]).count { best = (shown, gap) }
        }
        return best!
    }

    // MARK: Empty state

    /// The empty tab's only content (6.0 (14), the owner's design "E · chase
    /// across"): three dots running left → right across a track, each pass
    /// eased in and out, each dot a little behind the one before, faint at
    /// the ends (`chaseFloor`) and at most `chasePeak` in the middle.
    static let chaseTrack = 110.0
    static let chaseDot = 9.0
    static let chasePeriod = 2.1
    static let chaseStagger = 0.25
    static let chasePeak = 0.5
    /// Opacity at the track's ends (the owner, 6.0 (14): a dot leaving the
    /// track must still be seen — 0.15, not 0).
    static let chaseFloor = 0.15
    static let chaseDots = 3

    /// Dot `index` at `time` (s): its centre's distance along the track and
    /// its opacity. nil time = Reduce Motion: still dots, faint, near the middle.
    static func chase(index: Int, time: Double?) -> (x: Double, opacity: Double) {
        guard let time else {
            let e = 0.5 + Double(index - (chaseDots - 1) / 2) * 0.16
            return (e * chaseTrack, chasePeak * 0.7)
        }
        var p = (time - Double(index) * chaseStagger).truncatingRemainder(dividingBy: chasePeriod) / chasePeriod
        if p < 0 { p += 1 }
        let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
        return (e * chaseTrack, chaseFloor + (chasePeak - chaseFloor) * sin(Double.pi * e))
    }

    // MARK: Text

    /// The status bar: "3 up · 1 down" (slow counts as up — it answers);
    /// empty before anything answered or failed.
    static func summary(_ statuses: [Status]) -> String {
        let up = statuses.filter { $0 == .up || $0 == .slow }.count
        let down = statuses.filter { $0 == .down }.count
        var parts: [String] = []
        if up > 0 || down > 0 { parts.append("\(up) up") }
        if down > 0 { parts.append("\(down) down") }
        return parts.joined(separator: " · ")
    }

    static func latencyText(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
    }

    static func lossText(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return String(format: "%.0f%%", percent)
    }

    static func intervalLabel(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }

    /// The tab's interval: a saved value that is one of `intervals`, else the default.
    static func interval(saved: Double) -> Double {
        intervals.contains(saved) ? saved : defaultInterval
    }

    /// Whether a new tab shows the packet log: off until the user turns it on (field use, 6.0 (12) — the log card took the room
    /// the hosts need); the user's last choice after that.
    static func showsLog(saved: Bool?) -> Bool { saved ?? false }
}
