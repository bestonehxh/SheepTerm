import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A Ping tab (6.0 (2), from SheepPing): one long-lived /sbin/ping per
/// target (`PingStream`), rows with status / latency / loss / sparkline,
/// and a per-host packet log (as SheepPing). Nothing pings until the user adds a target; `close`
/// stops every process.
@MainActor
final class PingTabController: ObservableObject {
    /// One target. Its own ObservableObject so a packet repaints its row only.
    @MainActor
    final class Row: ObservableObject, Identifiable {
        let id = UUID()
        let address: String
        let name: String
        @Published fileprivate(set) var stats = PingPlan.Stats()
        @Published fileprivate(set) var resolvedIP = ""
        /// Totals since added / restarted (SheepPing's Success / Failed).
        @Published fileprivate(set) var okCount = 0
        @Published fileprivate(set) var failCount = 0
        /// Every packet, oldest first, capped (SheepPing's per-host log).
        @Published fileprivate(set) var packets: [Packet] = []
        var rate: Double? { okCount + failCount == 0 ? nil : Double(okCount) / Double(okCount + failCount) * 100 }
        fileprivate var task: Task<Void, Never>?
        fileprivate var epoch = 0
        var isRunning: Bool { task != nil }

        init(address: String, name: String) {
            self.address = address
            self.name = name
        }
    }

    @Published private(set) var rows: [Row] = []
    /// One packet in a host's log.
    struct Packet: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let latency: Double?     // nil = no reply
        let message: String
    }
    static let packetCap = 500

    @Published var showLog = true
    @Published var selection = Set<Row.ID>()
    @Published private(set) var interval: Double
    /// Bumped on every row status change (the summary and Stop/Resume follow it).
    @Published private(set) var statusTick = 0
    /// Words the last Add could not read (shown in the field's tooltip/red tint).
    @Published var refused: [String] = []

    /// A saved host's name for an address (the device column), else nil.
    var savedName: ((String) -> String?)?
    var onTitleChange: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onOpenSSH: ((String) -> Void)?

    private static let intervalKey = "pingInterval"
    private var closed = false
    private var clickMonitor: Any?

    private(set) lazy var hosting: NSHostingView<AnyView> = {
        let view = NSHostingView(rootView: AnyView(PingTabView().environmentObject(self)))
        view.translatesAutoresizingMaskIntoConstraints = true
        return view
    }()

    init() {
        interval = PingPlan.interval(saved: UserDefaults.standard.double(forKey: Self.intervalKey))
    }

    static func title(count: Int) -> String {
        count == 0 ? String(localized: "Ping") : String(localized: "Ping · \(count)")
    }

    func start() {
        onTitleChange?(Self.title(count: 0))
        // Mouse-down anywhere in this pane → onFocus (as the Files tab does).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.hosting.window, event.window === window else { return event }
            let point = self.hosting.convert(event.locationInWindow, from: nil)
            if self.hosting.bounds.contains(point) { self.onFocus?() }
            return event
        }
    }

    // MARK: Targets

    var addresses: [String] { rows.map(\.address) }

    /// Adds what a line expands to (`PingPlan.expand`) and starts each.
    /// Returns false when nothing could be added.
    @discardableResult
    func add(_ text: String) -> Bool {
        guard !closed else { return false }
        let expansion = PingPlan.expand(text, existing: addresses)
        refused = expansion.refused
        if expansion.truncated { NSSound.beep() }
        add(targets: expansion.targets)
        return !expansion.targets.isEmpty
    }

    func add(targets: [String]) {
        guard !closed else { return }
        let room = PingPlan.maxTargets - rows.count
        var known = Set(addresses.map { $0.lowercased() })
        // `insert` here: a list naming one host twice must not start two pings.
        for address in targets.filter({ known.insert($0.lowercased()).inserted }).prefix(max(0, room)) {
            let row = Row(address: address, name: savedName?(address) ?? address)
            rows.append(row)
            start(row)
        }
        changed()
    }

    func remove(_ ids: Set<Row.ID>) {
        for row in rows where ids.contains(row.id) { halt(row) }
        rows.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        changed()
    }

    func stop(_ ids: Set<Row.ID>) {
        for row in rows where ids.contains(row.id) && row.isRunning {
            halt(row)
            row.stats.stop()
        }
        changed()
    }

    /// Clears the row's stats and starts it again.
    func restart(_ ids: Set<Row.ID>) {
        for row in rows where ids.contains(row.id) {
            halt(row)
            row.stats.reset()
            row.okCount = 0
            row.failCount = 0
            row.packets = []
            start(row)
        }
        changed()
    }

    func restartAll() { restart(Set(rows.map(\.id))) }

    var anyRunning: Bool { rows.contains { $0.isRunning } }

    /// Stop everything, or resume what is stopped (stats kept).
    func toggleAll() {
        if anyRunning {
            stop(Set(rows.map(\.id)))
        } else {
            for row in rows { row.stats.resume(); start(row) }
            changed()
        }
    }

    func setInterval(_ seconds: Double) {
        guard PingPlan.intervals.contains(seconds), seconds != interval else { return }
        interval = seconds
        UserDefaults.standard.set(seconds, forKey: Self.intervalKey)
        // Running rows pick it up; their samples stay.
        for row in rows where row.isRunning {
            halt(row)
            start(row)
        }
    }

    func selectedRows(_ ids: Set<Row.ID>) -> [Row] { rows.filter { ids.contains($0.id) } }

    func copyAddresses(_ ids: Set<Row.ID>) {
        let text = selectedRows(ids).map(\.address).joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openSSH(_ ids: Set<Row.ID>) {
        for row in selectedRows(ids) { onOpenSSH?(row.address) }
    }

    // MARK: Log

    func clearPackets(_ row: Row) { row.packets = [] }

    /// SheepPing's CSV: Timestamp,Status,Latency (ms),Message — oldest first.
    func packetsCSV(_ row: Row) -> String { PingPlan.csv(row.packets.map { ($0.date, $0.latency, $0.message) }) }

    func copyPackets(_ row: Row) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(packetsCSV(row), forType: .string)
    }

    func savePackets(_ row: Row) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "ping-\(row.address.replacingOccurrences(of: "/", with: "-")).csv"
        let text = packetsCSV(row)
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSSound.beep() }
        }
        if let window = hosting.window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }


    // MARK: Engine

    private func start(_ row: Row) {
        halt(row)
        row.epoch += 1
        let epoch = row.epoch
        let address = row.address
        let interval = self.interval
        // Detached: the stream is read off main; each packet hops back once.
        row.task = Task.detached(priority: .utility) { [weak self, weak row] in
            // One ping stays up while it runs; it ends only when the target
            // is unroutable/unresolvable or killed, so this loop respawns.
            var pause = interval
            while !Task.isCancelled {
                let began = ContinuousClock.now
                let stream = PingStream(address: address, interval: interval, timeout: PingPlan.replyTimeout)
                await withTaskCancellationHandler {
                    for await result in stream.results {
                        guard !Task.isCancelled else { break }
                        await MainActor.run {
                            guard let self, let row, row.epoch == epoch, !self.closed else { return }
                            self.record(result, on: row)
                        }
                    }
                } onCancel: {
                    stream.cancel()
                }
                guard !Task.isCancelled else { break }
                // A ping that died at once (a name that does not resolve: ~14 ms)
                // waits longer each time — 64 bad names at 0.5 s were 128
                // fork+exec+DNS a second (review 6.0 (2)). A run that lived
                // resets it.
                pause = PingPlan.respawnPause(previous: pause, interval: interval,
                                              lived: (ContinuousClock.now - began) / .seconds(1))
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    /// Ends the row's process; a late packet is dropped by the epoch.
    private func halt(_ row: Row) {
        row.epoch += 1
        row.task?.cancel()
        row.task = nil
    }

    private func record(_ result: PingResult, on row: Row) {
        if result.isSuccess { row.okCount += 1 } else { row.failCount += 1 }
        // Oldest first (an append, not an insert at 0 that moves 500 items
        // per packet); the log view shows it newest first.
        row.packets.append(Packet(date: Date(), latency: result.isSuccess ? result.latency : nil,
                                  message: TransferLogFile.clean(result.message)))
        if row.packets.count > Self.packetCap { row.packets.removeFirst(row.packets.count - Self.packetCap) }
        if result.isSuccess, !result.resolvedIP.isEmpty, result.resolvedIP != row.resolvedIP {
            row.resolvedIP = result.resolvedIP
        }
        guard row.stats.record(result.isSuccess ? result.latency ?? 0 : nil) != nil else { return }
        statusTick &+= 1
        onStatus?(summary)
    }

    var summary: String { PingPlan.summary(rows.map(\.stats.status)) }

    private func changed() {
        statusTick &+= 1
        onTitleChange?(Self.title(count: rows.count))
        onStatus?(summary)
    }

    #if DEBUG
    /// Screenshots only (website, What's New): rows with sample names,
    /// addresses and a minute of made-up packets — no process starts.
    func loadDemo() {
        let now = Date()
        func row(_ name: String, _ address: String, _ samples: [Double?]) {
            let r = Row(address: address, name: name)
            for (k, s) in samples.enumerated() {
                r.stats.record(s)
                if s == nil { r.failCount += 1 } else { r.okCount += 1 }
                let at = now.addingTimeInterval(Double(k - samples.count))
                r.packets.append(Packet(date: at, latency: s, message: s.map {
                    "64 bytes from \(address): icmp_seq=\(k) ttl=64 time=\(String(format: "%.3f", $0)) ms" } ?? "Request timeout for icmp_seq \(k)"))
            }
            rows.append(r)
        }
        func wave(_ base: Double, _ spread: Double, seed: Int) -> [Double?] {
            (0..<60).map { i in base + spread * (0.5 + 0.5 * sin(Double(i * 7 + seed) * 0.37)) }
        }
        // The story the promo tells: core-sw1 is rebooting onto a new image.
        row("core-sw1", "10.10.1.1", wave(1.1, 0.6, seed: 1).enumerated().map { $0.offset >= 44 ? nil : $0.element })
        row("dist-sw3", "10.10.1.3", wave(38, 30, seed: 4).enumerated().map { $0.offset % 13 == 5 ? nil : $0.element })
        row("edge-fw", "10.10.1.6", wave(2.4, 1.0, seed: 2))
        row("Google DNS", "8.8.8.8", wave(13, 4, seed: 7))
        changed()
    }
    #endif

    // MARK: Lifetime

    func close() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        closed = true
        for row in rows { halt(row) }
        // Break the hosting ↔ controller cycle and drop the packets: a
        // closed tab must not keep 64 × 500 of them (review 6.0 (2)).
        rows = []
        hosting.rootView = AnyView(EmptyView())
    }
}

extension PingTabController: PaneContent {
    var paneView: NSView { hosting }
    var keyView: NSView { hosting }
    var hasPrompt: Bool { false }
    var promptHasKeyboard: Bool { false }
    func focusPrompt() -> Bool { false }
    func paneDidHide() {}
    func setPointerNeedsFocus(_ needsFocus: Bool) {}
    func refreshFocusAppearance() {}
}
