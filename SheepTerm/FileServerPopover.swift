import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The status-bar File Server button: a server glyph, green while any server
/// listens, that opens `FileServerPopover`.
struct FileServerStatusButton: View {
    @ObservedObject private var server = FileServerModel.shared

    var body: some View {
        Button {
            server.popoverShown.toggle()
        } label: {
            FileServerGlyph(running: server.isAnyRunning, busy: server.inFlight > 0)
                .frame(width: 14, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("File Server")
        .popover(isPresented: $server.popoverShown, arrowEdge: .top) {
            FileServerPopover()
                .environmentObject(AppModel.shared)
        }
    }
}

/// The File Server's own glyph (drawn, like the status-bar sheep — no SF
/// Symbol): one server unit and its status light. Off: a grey light; on: a
/// green one; it blinks only while a transfer moves. (The owner's pick,
/// 2026-10-25, "B" of three minimal drafts.)
struct FileServerGlyph: View {
    var running: Bool
    /// A transfer is moving: the light blinks like a disk LED (the popover
    /// has the percent; this says "something is happening" with it closed).
    var busy = false

    var body: some View {
        if busy {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate * 4) % 2 == 0
                shape(light: on ? Theme.ok : Theme.ok.opacity(0.25))
            }
        } else {
            shape(light: running ? Theme.ok : Theme.dimText)
        }
    }

    private func shape(light lightColor: Color) -> some View {
        Canvas { ctx, size in
            let unit = CGRect(x: 0.5, y: size.height * 0.2, width: size.width - 1, height: size.height * 0.6)
            ctx.stroke(Path(roundedRect: unit, cornerRadius: unit.height * 0.35), with: .color(Theme.dimText), lineWidth: 1)
            let d = unit.height * 0.32
            let light = CGRect(x: unit.maxX - unit.height * 0.5 - d / 2, y: unit.midY - d / 2, width: d, height: d)
            ctx.fill(Path(ellipseIn: light), with: .color(lightColor))
        }
        .accessibilityHidden(true)
    }
}

/// Where File ▸ File Server… anchors when the status bar is hidden: an
/// invisible strip at the bottom of the window.
struct FileServerHiddenAnchor: View {
    @ObservedObject private var server = FileServerModel.shared

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: 0)
            .popover(isPresented: $server.popoverShown, arrowEdge: .bottom) {
                FileServerPopover()
                    .environmentObject(AppModel.shared)
            }
    }
}

/// The File Server panel, minimal: server chips + this Mac's address, the
/// one file a device may pull, the command for the focused tab's device
/// family, writes. No titles, no dividers, icons with tooltips (clean-UI rule).
struct FileServerPopover: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var server = FileServerModel.shared
    @State private var macIP: String?
    @State private var dropTargeted = false
    @State private var fileHover = false
    @State private var editingLogin = false
    @State private var userDraft = ""
    @State private var passwordDraft = ""
    @State private var loginProblem: String?

    private var tab: SessionTab? { model.selectedTab }

    private var isDeviceTab: Bool {
        guard let tab else { return false }
        switch tab.content {
        case .ssh, .serial: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(FileServerPlan.Proto.allCases) { ServerChip(proto: $0) }
                Spacer(minLength: 8)
                Text(macIP ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dimText)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
                    .help("This Mac's address toward the device")
                Button {
                    server.popoverShown = false
                    model.showTransferLog = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Theme.dimText)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Transfer Log")
            }
            if server.running.keys.contains(where: \.needsLogin) { loginLine }
            if let error = server.startError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warn)
                    .lineLimit(2)
            }
            fileRow
            if let proto = server.commandProto { commands(for: proto) }
            writesRow
            ForEach(server.transfers) { TransferRow(transfer: $0) }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { server.revalidateServedFile() }
        .task(id: tab.flatMap { model.deviceAddress(of: $0) } ?? "") {
            #if DEBUG
            // Screenshots (What's New art): a sample address, not this Mac's.
            if let ip = ProcessInfo.processInfo.environment["SHEEPTERM_DEBUG_MAC_IP"] { macIP = ip; return }
            #endif
            let address = tab.flatMap { model.deviceAddress(of: $0) }
            let routed = await Task.detached { address.flatMap { FileServerPlan.ipv4(toReach: $0) } }.value
            macIP = routed ?? NetworkInfo.primaryIPv4()?.ip
        }
    }

    /// `sheepterm · ••••••••` — the password is copied, never shown. Click
    /// the line to set your own login (kept in the Keychain vault).
    @ViewBuilder private var loginLine: some View {
        if editingLogin {
            HStack(spacing: 6) {
                TextField("", text: $userDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                SecureField(String(localized: "new password"), text: $passwordDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveLogin)
                Button(action: saveLogin) { Image(systemName: "checkmark") }
                    .buttonStyle(.borderless).help("Save")
                if server.hasOwnPassword {
                    Button { server.forgetOwnPassword(); editingLogin = false } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).help("Back to a new random password every launch")
                }
            }
            .font(.system(size: 11))
            .noAutoFill()
            if let loginProblem {
                Text(loginProblem).font(.system(size: 11)).foregroundStyle(Theme.warn)
            }
        } else {
            HStack(spacing: 6) {
                Button {
                    userDraft = server.username
                    passwordDraft = ""
                    loginProblem = nil
                    editingLogin = true
                } label: {
                    Text("\(server.username) · \(String(repeating: "•", count: 8))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dimText)
                }
                .buttonStyle(.plain)
                .help(server.hasOwnPassword ? "Login for SCP / SFTP / FTP — click to change"
                      : "Login for SCP / SFTP / FTP — a new password every launch; click to set your own")
                CopyButton(text: server.password, help: "Copy password", secret: true)
                    .font(.system(size: 11))
                Spacer()
            }
            .onAppear { server.loadSavedLogin() }
        }
    }

    private func saveLogin() {
        loginProblem = server.setLogin(user: userDraft, password: passwordDraft)
        if loginProblem == nil { editingLogin = false; passwordDraft = "" }
    }

    private var fileRow: some View {
        Button { server.chooseFile() } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc").foregroundStyle(Theme.dimText)
                Text(server.servedFile?.lastPathComponent ?? String(localized: "Choose a file to serve"))
                    .foregroundStyle(server.servedFile == nil ? Theme.dimText : Theme.tabText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .help(server.servedFile?.path ?? String(localized: "Choose the file a device can pull — or drop one here"))
        .padding(.vertical, 2)
        .background { if fileHover { ControlFill(zone: .sidebar, cornerRadius: 6).padding(-4) } }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(dropTargeted ? Theme.accent : Color.clear, lineWidth: 1.5).padding(-4))
        .onHover { inside in
            guard inside != fileHover else { return }
            fileHover = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if fileHover { fileHover = false; NSCursor.pop() } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in FileServerModel.shared.setServedFile(url) }
            }
            return true
        }
    }

    private func port(for proto: FileServerPlan.Proto) -> UInt16 {
        let kind: FileServerModel.Server = proto == .tftp ? .tftp : proto == .ftp ? .ftp : .ssh
        return server.running[kind] ?? proto.defaultPort
    }

    @ViewBuilder private func commands(for proto: FileServerPlan.Proto) -> some View {
        if let ip = macIP {
            let file = server.servedFile?.lastPathComponent
            // The family: the device tab's own, else the one picked here
            // (any tab — a local shell, a web tab — can still get a command).
            let tabFamily = isDeviceTab ? tab?.highlightVendor : nil
            let family = tabFamily.flatMap { $0 == .auto ? nil : $0 } ?? server.pickedVendor
            let lines: [FileServerPlan.Command] = {
                guard let family else { return [] }
                return FileServerPlan.commands(vendor: family, proto: proto, ip: ip, port: port(for: proto),
                                               user: server.username, password: server.password,
                                               file: file, hostName: isDeviceTab ? (tab?.title ?? "") : "switch")
                    .filter { $0.kind == .pull || server.allowWrites }
            }()
            if lines.isEmpty {
                // No family yet: the address to copy, always (never an empty panel).
                CommandRow(command: .init(kind: .pull,
                                          text: FileServerPlan.url(proto: proto, ip: ip, port: port(for: proto),
                                                                   user: server.username, file: file),
                                          verified: false),
                           tabID: nil)
            } else {
                ForEach(lines, id: \.text) { CommandRow(command: $0, tabID: isDeviceTab ? tab?.id : nil) }
            }
            // The family picker unless the device tab already names one.
            if tabFamily == nil || tabFamily == .auto {
                FamilyPickerRow(current: server.pickedVendor) { picked in
                    if let tab, isDeviceTab {
                        model.setHighlightVendorForTabOnly(picked, tabID: tab.id)
                    } else {
                        server.pickedVendor = picked
                    }
                }
            }
        }
    }

    private var writesRow: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $server.allowWrites) {
                Text("Receive files").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .disabled(!server.isAnyRunning)
            .help("Let a device send a file here (a config backup) — into the folder, never over an existing file")
            Spacer()
            if server.allowWrites {
                Button { server.revealWriteFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help(server.writeFolder.path)
                    .contextMenu { Button("Choose Folder…") { server.chooseWriteFolder() } }
            }
        }
    }
}

/// A protocol chip: green while its server listens (SFTP and SCP share
/// the SSH server, so they light together); the one whose command is shown
/// is filled. The port shows only when it is not the standard one.
private struct ServerChip: View {
    let proto: FileServerPlan.Proto
    @ObservedObject private var server = FileServerModel.shared

    var body: some View {
        let kind = FileServerModel.server(for: proto)
        let on = server.isOn(kind)
        let shown = on && server.commandProto == proto
        Button { server.tapChip(proto) } label: {
            HStack(spacing: 3) {
                Text(proto.label)
                if let port = server.running[kind], port != kind.preferredPort {
                    // verbatim: a LocalizedStringKey formats the Int (":6,969").
                    Text(verbatim: ":\(port)").foregroundStyle(Theme.warn)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(on ? Theme.ok : Theme.dimText)
            // One line always: a fallback port (":6969") used to wrap the
            // chip into two rows (6.0 (1)); the address beside it gives way.
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(shown ? Theme.ok.opacity(0.22) : on ? Theme.ok.opacity(0.08) : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(shown ? Theme.ok.opacity(0.5) : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .opacity(server.starting.contains(kind) ? 0.5 : 1)
        .help(!on ? "Start \(proto.label) — turns itself off after 10 minutes without a transfer"
              : shown ? "Stop \(kind.label)" : "Show the \(proto.label) command")
    }
}

private struct CopyButton: View {
    let text: String
    var help: LocalizedStringKey = "Copy"
    /// Holds the login password: concealed and cleared after a minute.
    var secret = false
    /// A check for a moment after the copy, like the AI panel's Copy: the
    /// password is never shown, so the click had nothing to show for it.
    @State private var copied = false

    var body: some View {
        Button {
            if secret {
                SecretPasteboard.copy(text)
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        // The app's icon box: a soft rounded background under the pointer (the AI panel's Copy).
        .buttonStyle(ChromeIconButtonStyle(width: 22, height: 20))
        .help(help)
    }
}

/// One device command: the text (wrapping, so nothing hides in the middle),
/// and icon buttons to type it into the tab (no Return — the user runs it)
/// and to copy it.
/// The device family for the copy command — a row like the command rows
/// (same fill on the glass); a click pops the families as a plain NSMenu
/// (a SwiftUI Menu's hit area is smaller than its label).
struct FamilyPickerRow: View {
    let current: Vendor?
    let onPick: (Vendor) -> Void
    @State private var hover = false
    @State private var anchor = MenuAnchorBox()

    var body: some View {
        Button(action: pop) {
            // The command rows' own fill on the glass — no tint, no outline
            // (the user, 6.0: the blue dashed box did not belong on glass).
            HStack(spacing: 6) {
                // Label always; the choice (or "Choose") on the right.
                Text("Device Family").foregroundStyle(Theme.dimText)
                Spacer(minLength: 8)
                Text(current?.localizedLabel ?? String(localized: "Choose"))
                    .foregroundStyle(current == nil ? Theme.accent : Theme.tabText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.dimText)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background { ControlFill(zone: .sidebar, cornerRadius: 8) }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hover ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(box: anchor))
        .onHover { hover = $0 }
        .help("The device's copy command for this family")
    }

    private func pop() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        for family in Vendor.allCases where family != .auto {
            let item = MenuAction(title: family.localizedLabel) { onPick(family) }
            item.state = family == current ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }
}

struct CommandRow: View {
    let command: FileServerPlan.Command
    let tabID: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: command.kind == .pull ? "arrow.down.to.line" : "arrow.up.to.line")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dimText)
                .padding(.top, 2)
                .help(command.kind == .pull ? "Device pulls the file" : "Device sends its configuration")
            Text(command.shown)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if command.verified, let tabID {
                Button {
                    AppModel.shared.typeHistoryCommand(command.text, into: tabID)
                    FileServerModel.shared.popoverShown = false
                } label: {
                    Image(systemName: "return")
                }
                .buttonStyle(ChromeIconButtonStyle(width: 22, height: 20))
                .help("Type into the terminal (you press Return)")
            }
            CopyButton(text: command.text, help: command.carriesPassword ? "Copy (includes the password)" : "Copy",
                       secret: command.carriesPassword)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background { ControlFill(zone: .sidebar, cornerRadius: 8) }
    }
}

/// One transfer, minimal (the user, 5.0 (60)): a ring that fills green while
/// it runs (percent + size on hover), then ✓ Success or ✕ Failed — the
/// reason behind an ⓘ tooltip, never on the row.
struct TransferRow: View {
    let transfer: ServerTransfer
    /// Hover shows the numbers IN the row, in place of the status: a `.help`
    /// tooltip never appeared (the row redraws every progress tick and each
    /// redraw restarts it).
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            TransferRing(transfer: transfer)
            Text(transfer.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if hovering {
                Text(hoverText)
                    .foregroundStyle(transfer.state == .failed ? Theme.destructive : Theme.dimText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                switch transfer.state {
                case .active:
                    EmptyView()
                case .done:
                    Text("Success").foregroundStyle(Theme.ok)
                case .failed:
                    Text("Failed").foregroundStyle(Theme.destructive)
                }
            }
            if transfer.state != .active {
                // Point at the row (or here): the bytes moved / the reason.
                Image(systemName: "info.circle")
                    .foregroundStyle(hovering ? Theme.tabText : Theme.dimText)
            }
        }
        .font(.system(size: 11))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Running: "26% · 78.9 MB of 300 MB". Done: the exact bytes moved
    /// against the file's size, to check they match. Failed: the reason.
    private var hoverText: String { FileServerPlan.rowDetail(transfer) }

}

/// An arc that turns, for a transfer of unknown size.
private struct SpinningArc: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Circle().trim(from: 0, to: 0.25)
                .stroke(Theme.ok, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turn * 360 - 90))
        }
    }
}

/// 20 pt ring: a green arc fills as it runs (percent and size on hover);
/// full green ✓ / red ✕ after.
struct TransferRing: View {
    let transfer: ServerTransfer

    private var fraction: Double? {
        guard transfer.total > 0 else { return nil }
        return min(1, Double(transfer.done) / Double(transfer.total))
    }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.dimText.opacity(0.25), lineWidth: 2)
            switch transfer.state {
            case .active:
                if let fraction {
                    Circle().trim(from: 0, to: max(0.02, fraction))
                        .stroke(Theme.ok, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    // Size unknown (TFTP without tsize): a green arc spins.
                    SpinningArc()
                }
            case .done:
                Circle().stroke(Theme.ok, lineWidth: 2)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.ok)
            case .failed:
                Circle().stroke(Theme.destructive, lineWidth: 2)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.destructive)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityElement()
        .accessibilityLabel(transfer.state == .done ? "Success" : transfer.state == .failed ? "Failed"
                            : "\(Int((fraction ?? 0) * 100))%")
    }
}

/// The bottom bar while the File Server moves files (compact, the user's
/// pick): a thin green bar + "69%  734 KB/1.1 MB" — the name on hover; then
/// "Success" / "Failed ⓘ" for a few seconds.
struct TransferStatusStrip: View {
    @ObservedObject private var server = FileServerModel.shared
    /// The name shows IN the strip on hover — a `.help` tooltip never
    /// appears on a view that redraws every 0.2 s (review 6.0).
    @State private var hovering = false
    /// The bar's font is monospaced 11 pt: one character = one advance.
    static let advance = ("0" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]).width
    static let percentWidth = ceil(advance * 4)          // "100%"
    static let sizeWidth = ceil(advance * 17)            // "999.9 MB/999.9 MB"

    var body: some View {
        HStack(spacing: 8) {
            if let strip = FileServerPlan.strip(server.transfers) {
                // Fixed slots (the user, 5.0 (60)): the bar and the numbers
                // never shift as the digits change — percent right-aligned
                // in "100%", size left-aligned in "999.9 MB/999.9 MB".
                if hovering {
                    Text(strip.label).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .trailing)
                }
                TransferBar(fraction: strip.fraction).frame(width: 90)
                Text(strip.percent ?? "")
                    .frame(width: Self.percentWidth, alignment: .trailing)
                Text(strip.size)
                    .frame(width: Self.sizeWidth, alignment: .leading)
            } else if let outcome = server.stripOutcome {
                // Words only, no ✓ / ✕ (the user, 5.0 (60)).
                if outcome.state == .done {
                    Text("Success").foregroundStyle(Theme.ok)
                } else {
                    Text("Failed").foregroundStyle(Theme.destructive)
                    Image(systemName: "info.circle")
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(server.stripOutcome.map { _ in hoverText } ?? "")
    }

    private var hoverText: String {
        if let strip = FileServerPlan.strip(server.transfers) { return strip.label }
        guard let outcome = server.stripOutcome else { return "" }
        if outcome.state == .done { return "\(outcome.name) · \(outcome.peer)" }
        return "\(outcome.name) · \(outcome.detail.isEmpty ? String(localized: "failed") : outcome.detail)"
    }
}

/// A thin green bar (AppKit's progress bar ignores the tint); nil = a
/// green segment sliding along (size unknown).
struct TransferBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.dimText.opacity(0.25))
                if let fraction {
                    Capsule().fill(Theme.ok).frame(width: max(4, geo.size.width * fraction))
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule().fill(Theme.ok).frame(width: geo.size.width * 0.25)
                            .offset(x: (geo.size.width * 1.25) * t - geo.size.width * 0.25)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 4)
    }
}
