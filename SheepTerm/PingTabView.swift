import AppKit
import SwiftUI

/// The Ping tab (macOS 27 look, the owner's call): a capsule field (Return
/// adds) with the interval and three icon buttons; rounded rows — dot, name
/// (+ address when they differ), a filled sparkline, latency, loss — with a
/// soft hover and a light selection (click, ⌘-click, ⇧-click; Delete removes);
/// the log as a card under them. Icons with tooltips, no captions.
struct PingTabView: View {
    @EnvironmentObject private var ping: PingTabController
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Theme.chrome.ignoresSafeArea()
            VStack(spacing: 10) {
                topRow
                if ping.rows.isEmpty {
                    PingEmptyState()
                } else {
                    PingList()
                }
                if ping.showLog && !ping.rows.isEmpty { PingLogView() }
            }
            .padding(12)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.tabText)
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    private var topRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.dimText)
                TextField("IP, name, 10.10.1.0/29, …", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($fieldFocused)
                    .onSubmit {
                        if ping.add(text) && ping.refused.isEmpty { text = "" }
                    }
                    .onChange(of: text) { if !ping.refused.isEmpty { ping.refused = [] } }
                    .foregroundStyle(ping.refused.isEmpty ? Theme.tabText : Theme.destructive)
                    .help(ping.refused.isEmpty ? "" : String(localized: "Not a target: \(ping.refused.joined(separator: ", "))"))
                    .noAutoFill()
                Menu {
                    ForEach(PingPlan.intervals, id: \.self) { seconds in
                        Button {
                            ping.setInterval(seconds)
                        } label: {
                            if seconds == ping.interval {
                                Label(PingPlan.intervalLabel(seconds), systemImage: "checkmark")
                            } else {
                                Text(PingPlan.intervalLabel(seconds))
                            }
                        }
                    }
                } label: {
                    Text(PingPlan.intervalLabel(ping.interval))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.dimText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .help("Interval")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background { ControlFill(zone: .sidebar, cornerRadius: 10) }
            Button { ping.restartAll() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 13)) }
                .buttonStyle(ChromeIconButtonStyle(width: 30, height: 30))
                .disabled(ping.rows.isEmpty)
                .help("Restart All")
            Button { ping.toggleAll() } label: { Image(systemName: ping.anyRunning ? "pause.fill" : "play.fill").font(.system(size: 12)) }
                .buttonStyle(ChromeIconButtonStyle(width: 30, height: 30))
                .disabled(ping.rows.isEmpty)
                .help(ping.anyRunning ? String(localized: "Stop All") : String(localized: "Resume All"))
            Button { ping.showLog.toggle() } label: { Image(systemName: "list.bullet.rectangle").font(.system(size: 13)) }
                .buttonStyle(ChromeIconButtonStyle(tint: ping.showLog ? Theme.accent : nil, width: 30, height: 30))
                .help("Log")
        }
    }
}

private struct PingEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.dimText.opacity(0.6))
            Text("Type an address above")
                .foregroundStyle(Theme.dimText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - List

/// Every column a fixed width sized for its widest value in the row font
/// (monospaced 12 pt), so nothing moves as numbers grow (the owner: room
/// for 9999 in OK and Failed, and for Latency): IP for an IPv4 / short
/// IPv6, Latency "9999 ms", OK / Failed five digits, Rate "100%".
private enum PingColumns {
    static let digit = ("0" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width
    static func chars(_ n: Int) -> CGFloat { ceil(digit * CGFloat(n)) + 4 }
    /// IP sits closer to the name (the owner, 6.0 (2)); what Hostname gives
    /// up goes to IP, so Status and everything after it stay put.
    static let ipShift: CGFloat = 70
    static let hostname: CGFloat = 260 - ipShift
    /// IP's own width; the shift is only spent when the graph is shown (a wide pane).
    static let ipBase: CGFloat = max(130, chars(15))
    static let ip: CGFloat = ipBase + ipShift
    static let spark: CGFloat = 130
    static let sparkGap: CGFloat = 16
    /// Between columns (the owner, 6.0 (2): "further apart"); header and rows share it.
    static let gap: CGFloat = 32
    /// Status, Latency, OK, Failed, Rate: ONE width (the widest value,
    /// "9999 ms"), so the columns step at one even pitch (the owner, 6.0 (2):
    /// "the gaps are not equal").
    static let number: CGFloat = max(72, chars(8))
    static let status = number
    static let latency = number
    static let ok = number
    static let failed = number
    static let rate = number
    static func ipWidth(_ shown: Set<PingPlan.Column>) -> CGFloat { shown.contains(.graph) ? ip : ipBase }
    /// Hostname may shrink to this before columns are dropped.
    static let hostnameMin: CGFloat = 110

    /// The columns a list `width` wide shows (`PingPlan.visibleColumns`);
    /// the dot and the row padding are spent first.
    static func visible(in width: CGFloat) -> (shown: Set<PingPlan.Column>, gap: Double) {
        let widths: [PingPlan.Column: Double] = [
            .hostname: hostnameMin, .ip: ipBase, .status: status, .latency: latency,
            .ok: ok, .failed: failed, .rate: rate, .graph: spark + sparkGap + ipShift,   // IP takes its shift only beside the graph
        ]
        return PingPlan.columnLayout(width: width, widths: widths, fixed: 16 + 28)
    }
}

private struct PingList: View {
    @EnvironmentObject private var ping: PingTabController
    @State private var anchor: PingTabController.Row.ID?
    @FocusState private var focused: Bool

    var body: some View {
        // A split pane is narrower than every column: drop the least needed
        // (PingPlan.dropOrder) instead of overflowing both edges.
        GeometryReader { geo in
            let fit = PingColumns.visible(in: geo.size.width)
            list(fit.shown, gap: CGFloat(fit.gap))
        }
    }

    private func list(_ shown: Set<PingPlan.Column>, gap: CGFloat) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: gap) {
                Color.clear.frame(width: 16, height: 1)
                Text("Hostname").frame(minWidth: PingColumns.hostnameMin, maxWidth: PingColumns.hostname, alignment: .leading)
                    .layoutPriority(1)
                if shown.contains(.ip) { Text("IP").frame(width: PingColumns.ipWidth(shown), alignment: .leading) }
                if shown.contains(.status) { Text("Status").frame(width: PingColumns.status, alignment: .leading) }
                if shown.contains(.latency) { Text("Latency").frame(width: PingColumns.latency, alignment: .trailing) }
                if shown.contains(.ok) { Text("OK").frame(width: PingColumns.ok, alignment: .trailing) }
                if shown.contains(.failed) { Text("Failed").frame(width: PingColumns.failed, alignment: .trailing) }
                if shown.contains(.rate) { Text("Rate").frame(width: PingColumns.rate, alignment: .trailing) }
                // The graph last, taking whatever width is left (the owner, 6.0 (2)).
                if shown.contains(.graph) {
                    Text("Last minute").frame(minWidth: PingColumns.spark, maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, PingColumns.sparkGap)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.dimText)
            .padding(.horizontal, 14)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ping.rows) { row in
                        PingRowView(row: row, selected: ping.selection.contains(row.id), shown: shown, gap: gap)
                            .contentShape(Rectangle())
                            .onTapGesture { click(row.id) }
                            .contextMenu { menu(for: row.id) }
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollContentBackground(.hidden)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard !ping.selection.isEmpty else { return .ignored }
            ping.remove(ping.selection)
            return .handled
        }
    }

    /// Click = this row; ⌘ = toggle it; ⇧ = the range from the last click.
    private func click(_ id: PingTabController.Row.ID) {
        focused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if ping.selection.contains(id) { ping.selection.remove(id) } else { ping.selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor,
                  let a = ping.rows.firstIndex(where: { $0.id == anchor }),
                  let b = ping.rows.firstIndex(where: { $0.id == id }) {
            ping.selection = Set(ping.rows[min(a, b)...max(a, b)].map(\.id))
        } else {
            ping.selection = ping.selection == [id] ? [] : [id]
            anchor = id
        }
    }

    /// The selection when the row is in it, else just this row.
    @ViewBuilder private func menu(for id: PingTabController.Row.ID) -> some View {
        let ids = ping.selection.contains(id) ? ping.selection : [id]
        Button("Stop") { ping.stop(ids) }
        Button("Restart") { ping.restart(ids) }
        Button("Remove") { ping.remove(ids) }
        Divider()
        Button("Copy Address") { ping.copyAddresses(ids) }
        Button("Open SSH") { ping.openSSH(ids) }
    }
}

private struct PingRowView: View {
    @ObservedObject var row: PingTabController.Row
    let selected: Bool
    let shown: Set<PingPlan.Column>
    let gap: CGFloat
    @State private var hovering = false

    var body: some View {
        HStack(spacing: gap) {
            PingStatusDot(row: row)
            // Hostname | IP, two columns (the owner, 6.0 (2)).
            let cells = PingPlan.hostCells(name: row.name, address: row.address, resolved: row.resolvedIP)
            // The header row uses the same widths and spacing, so every
            // title sits over its column.
            Text(cells.hostname)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.tabText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: PingColumns.hostnameMin, maxWidth: PingColumns.hostname, alignment: .leading)
                // Width goes to the name before the graph / spacer beside it
                // (a long name was cut while slack sat to its right).
                .layoutPriority(1)
                .help(row.resolvedIP.isEmpty ? row.address : "\(row.address) → \(row.resolvedIP)")
            if shown.contains(.ip) {
                Text(cells.ip)
                    .foregroundStyle(Theme.dimText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: PingColumns.ipWidth(shown), alignment: .leading)
            }
            if shown.contains(.status) {
                PingStatusBadge(status: row.stats.status)
                    .frame(width: PingColumns.status, alignment: .leading)
            }
            if shown.contains(.latency) {
                Text(row.stats.status == .down ? "—" : PingPlan.latencyText(row.stats.lastLatency))
                    .foregroundStyle(latencyColor)
                    .frame(width: PingColumns.latency, alignment: .trailing)
            }
            if shown.contains(.ok) {
                Text("\(row.okCount)")
                    .foregroundStyle(Theme.ok)
                    .frame(width: PingColumns.ok, alignment: .trailing)
            }
            if shown.contains(.failed) {
                Text("\(row.failCount)")
                    .foregroundStyle(row.failCount > 0 ? Theme.destructive : Theme.dimText)
                    .frame(width: PingColumns.failed, alignment: .trailing)
            }
            if shown.contains(.rate) {
                Text(row.rate.map { String(format: "%.0f%%", $0) } ?? "—")
                    .foregroundStyle(rateColor)
                    .frame(width: PingColumns.rate, alignment: .trailing)
            }
            if shown.contains(.graph) {
                PingSparkline(samples: row.stats.samples)
                    .frame(minWidth: PingColumns.spark, maxWidth: .infinity)
                    .frame(height: 18)
                    .padding(.leading, PingColumns.sparkGap)
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 12, design: .monospaced).monospacedDigit())
        .padding(.horizontal, 14)
        .frame(height: 32)
        // The Sidebar's own selection: white 14 %, hover 6 %, no outline.
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.14 : hovering ? 0.06 : 0))
        )
        .opacity(row.stats.status == .stopped ? 0.55 : 1)
        .onHover { hovering = $0 }
    }

    /// The address under the name when the name is a saved host's, or the
    /// resolved address when a name was typed.

    private var latencyColor: Color {
        guard let ms = row.stats.lastLatency, row.stats.status != .down else { return Theme.dimText }
        return ms < 30 ? Theme.ok : ms < 120 ? Theme.warn : Theme.destructive
    }

    private var rateColor: Color {
        guard let r = row.rate else { return Theme.dimText }
        return r >= 95 ? Theme.ok : r >= 75 ? Theme.warn : Theme.destructive
    }
}

/// SheepPing's badge: OK / Slow / Fail / … / Stopped in a tinted capsule.
private struct PingStatusBadge: View {
    let status: PingPlan.Status

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var label: String {
        switch status {
        case .up: return String(localized: "OK")
        case .slow: return String(localized: "Slow")
        case .down: return String(localized: "Fail")
        case .waiting: return "…"
        case .stopped: return String(localized: "Stopped")
        }
    }

    private var color: Color {
        switch status {
        case .up: return Theme.ok
        case .slow: return Theme.warn
        case .down: return Theme.destructive
        case .waiting, .stopped: return Theme.dimText
        }
    }
}

private struct PingStatusDot: View {
    @ObservedObject var row: PingTabController.Row

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18)).frame(width: 16, height: 16)
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
    }

    private var color: Color {
        switch row.stats.status {
        case .up: return Theme.ok
        case .slow: return Theme.warn
        case .down: return Theme.destructive
        case .waiting, .stopped: return Theme.dimText
        }
    }
}

/// The last 60 packets: a line of latencies scaled to the window's slowest;
/// a run of lost packets is a red dashed line along the bottom.
struct PingSparkline: View {
    let samples: [Double?]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let step = size.width / CGFloat(PingPlan.window - 1)
            // Right-aligned: the newest packet sits at the right edge.
            // From the left edge, under the column's title; the newest packet
            // is the right end of the line (the owner: the graph sat off to
            // the right while the minute filled).
            let x0: CGFloat = 0
            let top = max(samples.compactMap { $0 }.max() ?? 1, 1)
            func point(_ i: Int, _ ms: Double) -> CGPoint {
                CGPoint(x: x0 + CGFloat(i) * step, y: size.height - 1 - CGFloat(ms / top) * (size.height - 3))
            }
            var line = Path()
            var lost = Path()
            var penDown = false
            var i = 0
            while i < samples.count {
                if let ms = samples[i] {
                    let p = point(i, ms)
                    if penDown { line.addLine(to: p) } else { line.move(to: p); penDown = true }
                    i += 1
                } else {
                    var j = i
                    while j < samples.count, samples[j] == nil { j += 1 }
                    let start = x0 + CGFloat(i) * step
                    let end = max(x0 + CGFloat(j - 1) * step, start + 2)
                    lost.move(to: CGPoint(x: start, y: size.height - 1))
                    lost.addLine(to: CGPoint(x: end, y: size.height - 1))
                    penDown = false
                    i = j
                }
            }
            let slow = (samples.last ?? nil).map { $0 > PingPlan.slowMilliseconds } ?? false
            let tint = slow ? Theme.warn : Theme.ok
            // A soft area under the line (each answered run down to the base).
            var area = Path()
            var run: [CGPoint] = []
            func closeRun() {
                guard let first = run.first, let last = run.last, run.count > 1 else { run = []; return }
                area.move(to: CGPoint(x: first.x, y: size.height))
                for p in run { area.addLine(to: p) }
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.closeSubpath()
                run = []
            }
            for (k, ms) in samples.enumerated() {
                if let ms { run.append(point(k, ms)) } else { closeRun() }
            }
            closeRun()
            context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.28), tint.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            context.stroke(lost, with: .color(Theme.destructive), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        }
    }
}

// MARK: - Log

/// SheepPing's log: the selected host's packets, newest first — time,
/// latency or "timeout", the line ping printed. Copy, Save (CSV), Clear.
private struct PingLogView: View {
    @EnvironmentObject private var ping: PingTabController

    var body: some View {
        let selected = ping.rows.filter { ping.selection.contains($0.id) }
        Group {
            if selected.count == 1 {
                PingHostLog(row: selected[0])
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft").font(.system(size: 18)).foregroundStyle(Theme.dimText.opacity(0.6))
                    Text(selected.isEmpty ? "Select a host to see its log" : "Select one host to see its log")
                        .foregroundStyle(Theme.dimText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 210)
        .background { ControlFill(zone: .sidebar, cornerRadius: 10) }
    }
}

private struct PingHostLog: View {
    @EnvironmentObject private var ping: PingTabController
    @ObservedObject var row: PingTabController.Row

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PingStatusBadge(status: row.stats.status)
                Text(row.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if row.name != row.address || !row.resolvedIP.isEmpty {
                    Text(row.resolvedIP.isEmpty ? row.address : row.resolvedIP)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dimText)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(row.packets.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.dimText)
                Button { ping.copyPackets(row) } label: { Image(systemName: "doc.on.doc").font(.system(size: 12)) }
                    .buttonStyle(ChromeIconButtonStyle(width: 26, height: 22))
                    .disabled(row.packets.isEmpty)
                    .help("Copy Log")
                Button { ping.savePackets(row) } label: { Image(systemName: "square.and.arrow.down").font(.system(size: 12)) }
                    .buttonStyle(ChromeIconButtonStyle(width: 26, height: 22))
                    .disabled(row.packets.isEmpty)
                    .help("Save Log…")
                Button { ping.clearPackets(row) } label: { Image(systemName: "trash").font(.system(size: 12)) }
                    .buttonStyle(ChromeIconButtonStyle(width: 26, height: 22))
                    .disabled(row.packets.isEmpty)
                    .help("Clear Log")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(row.packets.reversed()) { p in
                        HStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(p.latency == nil ? Theme.destructive : Theme.ok)
                                .frame(width: 3, height: 13)
                                .padding(.trailing, 8)
                            Text(Self.time.string(from: p.date))
                                .foregroundStyle(Theme.dimText)
                                .frame(width: 64, alignment: .leading)
                            Group {
                                if let ms = p.latency {
                                    Text(String(format: "%6.1f ms", ms))
                                        .foregroundStyle(ms < 30 ? Theme.ok : ms < 120 ? Theme.warn : Theme.destructive)
                                } else {
                                    Text("timeout").foregroundStyle(Theme.destructive)
                                }
                            }
                            .frame(width: 72, alignment: .trailing)
                            Text(p.message)
                                .foregroundStyle(Theme.dimText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.leading, 12)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}
