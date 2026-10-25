import Combine
import SwiftUI

struct StatusBarView: View {
    static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // The status-bar clock is Gregorian as well — pinned explicitly so a
        // Buddhist-era system calendar can never reach it.
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    @EnvironmentObject var model: AppModel
    /// The status bar is switched off but a transfer is moving.
    var onlyTransfer = false
    // Empty until onAppear — getifaddrs isn't free, so don't run it in the
    // initializer that every re-render of the parent evaluates.
    @State private var localAddress = ""
    // Hoisted so the publisher isn't recreated on every re-render.
    /// `static`, not an instance `let`: an instance initializer runs on every
    /// struct init, so every AppModel publish built a fresh publisher and
    /// resubscribed — restarting the 15 s phase each time, which a chattier
    /// model would turn into an IP that never refreshes.
    private static let ipTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
          if onlyTransfer {
            // The bar is hidden but files are moving: only the strip + glyph.
            Spacer()
            TransferStatusStrip()
            FileServerStatusButton()
          } else {
            // The connection state (statusConnectionStyle) and the highlight
            // vendor control sit at the left edge for a remote tab, ahead of
            // the session/cipher/device-IP/user TEXT (statusShowSession), so
            // turning the text on never pushes them away from the edge.
            if let tab = model.selectedTab {
                SessionStatusText(tab: tab, showText: model.statusShowSession, indicator: model.statusConnectionStyle,
                                  onVendorChange: { model.setHighlightVendorCurrent($0) },
                                  onBaudChange: { model.setBaud($0, for: tab) },
                                  onOpenWeb: { url in if let web = Host.web(name: "", url: url) { model.open(host: web) } })
            } else if model.statusShowSession {
                Text("no session")
            }
            Spacer()
            if model.statusShowHints {
                // The break key only exists on a serial console; a hint for a
                // greyed-out item would just raise the question.
                Text(model.canSendBreak
                     ? String(localized: "⌘T tab · ⌘0 sidebar · ⌘1–9 switch · ⌃⌥B break")
                     : String(localized: "⌘T tab · ⌘0 sidebar · ⌘1–9 switch"))
                    .foregroundStyle(Theme.dimText.opacity(0.7))
            }
            Spacer()
            // Files moving: a compact bar beside the glyph (the user's pick,
            // 5.0 (60): "69%  734 KB/1.1 MB"; the other items stay).
            if model.fileTransferShown && model.statusShowTransfers {
                TransferStatusStrip()
            }
            if FileServerPlan.showsGlyph(switchOn: model.statusShowFileServer, running: model.fileServerActive,
                                         starting: false, popoverOpen: false) {
                FileServerStatusButton()
            }
            if model.statusShowClock {
                ClockText()
            }
            if model.statusShowIP {
                Text(localAddress)
            }
          }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Theme.dimText)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background { ChromeBackground(zone: .statusBar) }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.chromeLine)
                .frame(height: 1)
        }
        .onAppear {
            // Same guard as the tick below: no getifaddrs for a segment that
            // isn't shown (it starts hidden).
            guard model.statusShowIP else { return }
            localAddress = NetworkInfo.summary()
        }
        // Switching "This Mac IP" on used to show whatever was read at
        // onAppear — the ticks in between were skipped, so on a laptop that
        // had changed networks meanwhile the bar displayed the old address
        // until the next tick up to 15 s later.
        .onChange(of: model.statusShowIP) { _, shown in
            if shown { localAddress = NetworkInfo.summary() }
        }
        .onReceive(Self.ipTimer) { _ in
            // getifaddrs isn't free — skip while the IP segment is hidden or
            // nothing of the app is on screen to show it on.
            guard model.statusShowIP, MainWindowKeyMonitor.shared.isVisible else { return }
            localAddress = NetworkInfo.summary()
        }
        .onReceive(MainWindowKeyMonitor.shared.$isVisible) { visible in
            // Coming back on screen: refresh the address that went stale
            // while the ticks were skipped.
            guard visible, model.statusShowIP else { return }
            localAddress = NetworkInfo.summary()
        }
    }
}

/// The status-bar clock. It ticks once a second only while some part of the
/// app is actually on screen — while everything is occluded (minimized,
/// hidden, fully covered) the timeline is torn down, so the app stops waking
/// up 60 times a minute for a clock nobody can read. Re-appearing re-renders
/// with the current time immediately, so it can never show a stale one.
private struct ClockText: View {
    @ObservedObject private var window = MainWindowKeyMonitor.shared

    var body: some View {
        if window.isVisible {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(StatusBarView.clockFormatter.string(from: context.date))
            }
        } else {
            Text(StatusBarView.clockFormatter.string(from: Date()))
        }
    }
}

/// Tiny sheep pacing back and forth — the "connecting" indicator. (The
/// sheep picks connectionState: walking = connecting, napping = connected,
/// faded = closed.) Drawn by `SheepGlyphView`, the same sheep on every platform.
struct WalkingSheepView: View {
    @ObservedObject private var windowKey = MainWindowKeyMonitor.shared

    var body: some View {
        if !windowKey.isKey {
            // Static frame while the window isn't key — no TimelineView
            // ticking at 20 fps in the background.
            SheepGlyphView(pose: .walking(x: 0, bob: 0, mirrored: false), windowActive: false)
        } else {
            TimelineView(.animation(minimumInterval: 0.05)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let period = 3.2
                let phase = time.truncatingRemainder(dividingBy: period) / period
                let walkingRight = phase < 0.5
                let progress = walkingRight ? phase * 2 : (1 - phase) * 2
                let x = (progress - 0.5) * 18
                let bob = abs(sin(progress * .pi * 8)) * -1.2
                SheepGlyphView(pose: .walking(x: x, bob: bob, mirrored: walkingRight), time: time)
            }
        }
    }
}

/// Connected: the sheep naps, breathing, with its z's rising one by one.
struct SleepingSheepView: View {
    @ObservedObject private var windowKey = MainWindowKeyMonitor.shared

    var body: some View {
        if !windowKey.isKey {
            // Static frame while the window isn't key — no TimelineView
            // ticking in the background.
            SheepGlyphView(pose: .sleeping(zOpacity: 0.7, zOffsetY: 0), windowActive: false)
        } else {
            TimelineView(.animation(minimumInterval: 0.12)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let pulse = (sin(time * 2.2) + 1) / 2
                SheepGlyphView(pose: .sleeping(zOpacity: 0.35 + 0.65 * pulse, zOffsetY: 2 - 3 * pulse), time: time)
            }
        }
    }
}

/// `statusInfo` is a data channel — the app keys on its prefixes
/// ("disconnected", "ssh2 ·", "serial ·", "· LEGACY") — so it stays English
/// and only its words are translated here, where it is shown. Technical lines
/// (cipher, baud, address) pass through as they are.
enum StatusInfoDisplay {
    static func text(_ info: String?) -> String? {
        guard let info else { return nil }
        if info == "disconnected" { return String(localized: "disconnected") }
        if let rest = info.dropPrefix("disconnected — ") {
            return String(localized: "disconnected — \(reason(rest))")
        }
        if let rest = info.dropPrefix("failed — ") {
            return String(localized: "failed — \(reason(rest))")
        }
        if info == "new tab" { return String(localized: "new tab") }
        if info == "cancelled — certificate not trusted" { return String(localized: "cancelled — certificate not trusted") }
        if let server = info.dropPrefix("certificate — ") { return String(localized: "certificate — \(server)") }
        if info.hasSuffix("…"), let rest = info.dropPrefix("loading ") {
            return String(localized: "loading \(String(rest.dropLast()))…")
        }
        return info
    }

    private static func reason(_ reason: String) -> String {
        switch reason {
        case "cancelled": return String(localized: "cancelled")
        case "host key refused": return String(localized: "host key refused")
        case "session ended": return String(localized: "session ended")
        case "jump host missing": return String(localized: "jump host missing")
        case "auto-reconnect gave up": return String(localized: "auto-reconnect gave up")
        case "auto-reconnect limit reached": return String(localized: "auto-reconnect limit reached")
        case "not an http(s) address": return String(localized: "not an http(s) address")
        case "the page stopped; reload to try again": return String(localized: "the page stopped; reload to try again")
        default: return reason // e.g. a localizedDescription, already in the user's language
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

struct SessionStatusText: View {
    @ObservedObject var tab: SessionTab
    /// Whether the session/cipher/device-IP/username line is shown. The
    /// remote controls (state sheep + vendor picker) show regardless.
    var showText: Bool = true
    var indicator: ConnectionIndicator = .sheep
    var onVendorChange: (Vendor) -> Void = { _ in }
    var onBaudChange: (Int) -> Void = { _ in }
    /// A local forward's "Open in Web Tab".
    var onOpenWeb: (String) -> Void = { _ in }

    /// A connected SSH tab's port forwards (5.0 (50)–(53)) — the menu that
    /// makes them usable in a click: open, copy, stop/start, and how many
    /// connections each carries. The worker's own report, so it is empty
    /// once the session is over.
    private var forwardStates: [ForwardState] { tab.forwards }

    private func setForward(_ spec: PortForwardSpec, _ enabled: Bool) {
        if case .ssh(let controller) = tab.content { controller.setForward(spec, enabled: enabled) }
    }

    /// A serial tab's line speed (5.0 (39)): read from the controller's host,
    /// which `onBaudChanged` updates before the new status line arrives.
    private var serialBaud: Int? {
        if case .serial(let controller) = tab.content, !controller.isTelnet { return controller.host.port }
        return nil
    }

    private var text: String {
        switch tab.content {
        case .local:
            return String(localized: "local · \((LocalTerminalController.userShell() as NSString).lastPathComponent)")
        case .ssh(let controller):
            return StatusInfoDisplay.text(tab.statusInfo) ?? String(localized: "connecting to \(controller.host.address)…")
        case .serial(let controller):
            return StatusInfoDisplay.text(tab.statusInfo) ?? String(localized: "opening \(controller.host.address)…")
        case .web(let controller):
            return StatusInfoDisplay.text(tab.statusInfo) ?? String(localized: "loading \(WebAddress.displayHost(of: controller.host.address))…")
        case .files(let controller):
            return tab.statusInfo ?? controller.endpoint.host
        case .ping:
            return tab.statusInfo ?? String(localized: "Ping")
        }
    }

    private var isRemote: Bool {
        switch tab.content {
        case .ssh, .serial: return true
        case .local, .web, .files, .ping: return false
        }
    }

    // Contains, not hasSuffix: with agent forwarding on, SSHWorker appends
    // " · agent" AFTER " · LEGACY", and a suffix match silently un-warned a
    // legacy session that forwards its agent (found in the 4.1 bug sweep).
    private var isLegacy: Bool {
        tab.statusInfo?.contains("· LEGACY") == true
    }

    private enum ConnectionState {
        case connecting, connected, closed
    }

    private var connectionState: ConnectionState {
        guard let info = tab.statusInfo else { return .connecting }
        // Prefix, not equality: the auto-reconnect budget appends a reason
        // ("disconnected — auto-reconnect limit reached"), and an exact
        // compare put that dead session back on the napping/Connected sheep.
        return info.hasPrefix("disconnected") ? .closed : .connected
    }

    private var connectionStateText: String {
        switch connectionState {
        case .connecting: return String(localized: "Connecting…")
        case .connected: return String(localized: "Connected")
        case .closed: return String(localized: "Disconnected")
        }
    }

    private var indicatorPhase: ConnectionIndicator.Phase {
        switch connectionState {
        case .connecting: return .connecting
        case .connected: return .connected
        case .closed: return .closed
        }
    }

    /// Amber connecting, green up, red down — turned down as a whole by the
    /// view's opacity (`ConnectionIndicator.brightness`), so overlapping
    /// parts never show through each other.
    private var stateColor: Color {
        switch connectionState {
        case .connecting: return Theme.warn
        case .connected: return Theme.ok
        case .closed: return Theme.destructive
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if isRemote {
                switch indicator {
                case .sheep:
                    // A picture, not a button (the owner's call, 2026-10-22):
                    // ⇧⌘H and the menu toggle highlighting.
                    Group {
                        switch connectionState {
                        case .connecting:
                            WalkingSheepView()
                        case .connected:
                            SleepingSheepView()
                        case .closed:
                            SheepGlyphView(pose: .closed)
                        }
                    }
                    .frame(height: 16)          // as wide as SheepGlyph.slotWidth(pose): narrower asleep
                case .wool:
                    WoolIndicator(phase: indicatorPhase, color: stateColor)
                        .opacity(ConnectionIndicator.brightness(indicatorPhase))
                        .help(connectionStateText)
                case .packet:
                    PacketIndicator(phase: indicatorPhase, color: stateColor)
                        .opacity(ConnectionIndicator.brightness(indicatorPhase))
                        .help(connectionStateText)
                case .off:
                    EmptyView()
                }
            }
            if isRemote {
                // The pack this session colours with, and a one-click way to
                // correct it: a serial console does not announce its vendor,
                // so the first thing you learn about a box is often that it
                // is not the one you expected.
                Menu {
                    ForEach(Vendor.allCases) { family in
                        Toggle(family.localizedLabel, isOn: Binding(
                            get: { tab.highlightVendor == family },
                            set: { _ in onVendorChange(family) }
                        ))
                    }
                } label: {
                    Text(tab.highlightVendor.badge)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Theme.dimText)
                .opacity(tab.highlightEnabled ? 1 : 0.4)
            }
            if let baud = serialBaud {
                // The console's speed, changed in place: one cable meets a
                // 9600 Cisco and a 115200 Aruba CX in the same day, and a
                // console at the wrong speed shows only garbage.
                Menu {
                    ForEach(ConsoleBaud.rates.contains(baud) ? ConsoleBaud.rates : (ConsoleBaud.rates + [baud]).sorted(), id: \.self) { rate in
                        Toggle(String(rate), isOn: Binding(
                            get: { baud == rate },
                            set: { _ in onBaudChange(rate) }
                        ))
                    }
                } label: {
                    Text(String(baud))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Theme.dimText)
                .help("Baud rate")
            }
            if !forwardStates.isEmpty {
                Menu {
                    ForEach(forwardStates, id: \.self) { state in
                        let spec = state.spec
                        Section(state.title) {
                            if state.active, let address = spec.macAddress {
                                if let url = spec.webURL {
                                    Button("Open in Web Tab") { onOpenWeb(url) }
                                }
                                Button(spec.isSOCKS ? "Copy Proxy Address" : "Copy Address") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(address, forType: .string)
                                }
                            }
                            if state.active {
                                Button("Stop") { setForward(spec, false) }
                            } else {
                                Button("Start") { setForward(spec, true) }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.left.arrow.right")
                        Text(String(forwardStates.filter(\.active).count))
                    }
                    .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Theme.dimText)
                .help("Port forwards")
            }
            if showText {
                Text(text)
                    .foregroundStyle(isLegacy ? Theme.warn : Theme.dimText)
                    .lineLimit(1)
            }
        }
    }
}


// MARK: - Plain connection indicators (5.0 (60))

/// Animates only while connecting AND the window is key — the same rule the
/// walking sheep follows; otherwise one static frame, no timeline ticking.
private struct IndicatorClock<Content: View>: View {
    let animating: Bool
    @ViewBuilder var content: (Double) -> Content
    @ObservedObject private var windowKey = MainWindowKeyMonitor.shared

    var body: some View {
        if animating && windowKey.isKey {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                content(context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            content(0.15)
        }
    }
}

/// Three wool puffs; connecting, they hop one after another.
struct WoolIndicator: View {
    let phase: ConnectionIndicator.Phase
    let color: Color
    static let period = 1.1

    static func puff(_ c: CGPoint, _ r: CGFloat) -> Path {
        var p = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        for i in 0..<8 {
            let a = Double(i) / 8 * 2 * .pi
            let br = r * 0.36
            p = p.union(Path(ellipseIn: CGRect(x: c.x + r * 0.86 * cos(a) - br, y: c.y + r * 0.86 * sin(a) - br,
                                               width: 2 * br, height: 2 * br)))
        }
        return p
    }

    var body: some View {
        IndicatorClock(animating: phase == .connecting) { time in
            Canvas { ctx, size in
                let t = (time / Self.period).truncatingRemainder(dividingBy: 1)
                for i in 0..<3 {
                    var lift: CGFloat = 0
                    var alpha = 1.0
                    if phase == .connecting {
                        let ph = t - Double(i) * 0.18
                        let k = ph < 0 ? 0 : max(0, sin(min(ph, 0.5) * 2 * .pi))
                        lift = CGFloat(k) * 2.2
                        alpha = 0.45 + 0.55 * k
                    }
                    let puff = Self.puff(CGPoint(x: 4 + CGFloat(i) * 7, y: size.height / 2 - lift), 2.4)
                    ctx.fill(puff, with: .color(color.opacity(alpha)))
                }
            }
        }
        .frame(width: 22, height: 14)
        .accessibilityHidden(true)
    }
}

/// Two ends (this Mac, the device); connecting, a packet runs between them;
/// up, a line joins them; down, the line is broken.
struct PacketIndicator: View {
    let phase: ConnectionIndicator.Phase
    let color: Color
    static let period = 1.2

    var body: some View {
        IndicatorClock(animating: phase == .connecting) { time in
            Canvas { ctx, size in
                let y = size.height / 2
                let left = CGPoint(x: 3, y: y), right = CGPoint(x: 21, y: y)
                switch phase {
                case .connected:
                    var line = Path(); line.move(to: left); line.addLine(to: right)
                    ctx.stroke(line, with: .color(color), lineWidth: 1.2)
                case .closed:
                    for (a, b) in [(left.x, 9.0), (15.0, right.x)] {
                        var seg = Path(); seg.move(to: CGPoint(x: a, y: y)); seg.addLine(to: CGPoint(x: b, y: y))
                        ctx.stroke(seg, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    }
                case .connecting:
                    var dash = Path(); dash.move(to: left); dash.addLine(to: right)
                    ctx.stroke(dash, with: .color(Theme.dimText.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [1.5, 2]))
                    let t = (time / Self.period).truncatingRemainder(dividingBy: 1)
                    let x = left.x + (right.x - left.x) * (0.5 - 0.5 * cos(t * 2 * .pi))
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)), with: .color(color))
                }
                for p in [left, right] {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.6, y: y - 2.6, width: 5.2, height: 5.2)),
                             with: .color(phase == .closed ? Theme.dimText : color))
                }
            }
        }
        .frame(width: 24, height: 14)
        .accessibilityHidden(true)
    }
}
