import Combine
import SwiftUI

/// Handles opened .sheepterm files at the APPLICATION level.
///
/// SwiftUI's `.onOpenURL` inside a WindowGroup made macOS treat the file as
/// a document and open a second window for it — and SheepTerm is
/// single-window on purpose (two windows share AppModel.shared and the same
/// TerminalView instances, so terminals blank and reparent between them).
/// An app delegate that implements `application(_:open:)` consumes the
/// event before that happens.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // Hop to the next runloop turn before doing anything: the import
        // asks for confirmation with NSAlert.runModal(), and a modal started
        // INSIDE this Apple Event callback does not run at all when the app
        // is already up — runModal returns the default button immediately,
        // so the file was imported with no dialog ever shown. Nothing may be
        // imported without an explicit accept (spec 0.4).
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp?.activate(ignoringOtherApps: true)
                for url in urls {
                    // sheepterm://share#v1.… = a share link; anything else is a .sheepterm file.
                    if url.scheme?.lowercased() == "sheepterm" {
                        ShareLinks.shared.handle(url: url)
                    } else if ["telnet", "ssh"].contains(url.scheme?.lowercased() ?? "") {
                        // A console link from GNS3 / EVE-NG / a browser: a tab,
                        // nothing typed (see ConnectParser.externalLink).
                        if let host = ConnectParser.externalLink(url.absoluteString) {
                            AppModel.shared.open(host: host)
                        }
                    } else {
                        AppModel.shared.importFile(at: url)
                    }
                }
            }
        }
    }

    /// Clicking the Dock icon with the window closed reopens it rather than
    /// creating a second one.
    /// The in-app updater (SheepTermUpdate.swift): first automatic check a
    /// few seconds after launch, then daily while the app stays open.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pre-5.0 (14) per-credential Keychain items → the one-item vault,
        // before Sync reads anything (PasswordVault.swift). A no-op once moved.
        PasswordVault.shared.migrate(AppModel.shared.credentialStore.credentials.map(\.id.uuidString)
                                     + ["sheepsync.session"])   // SyncEngine.sessionAccount
        AppUpdater.shared.start()
        SheepTermSync.shared.start()
        ShareLinks.shared.startExpiryWatch()
        // What's New, once per release that has one (WhatsNewPlan). Not in a
        // scripted debug run (screenshots / hooks), unless it is the subject.
        var scripted = false
        #if DEBUG
        let debugEnv = ProcessInfo.processInfo.environment
        scripted = debugEnv.keys.contains { $0.hasPrefix("SHEEPTERM_DEBUG_") } && debugEnv["SHEEPTERM_DEBUG_SHEET"] != "whatsnew"
        #endif
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if !scripted, WhatsNewPlan.shouldShow(seen: UserDefaults.standard.string(forKey: WhatsNewPlan.seenKey), running: marketing) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { AppModel.shared.showWhatsNew = true }
        }
#if DEBUG
        // Memory-keychain scratch runs: every credential gets a demo password so the screens have something to share.
        if PasswordVault.usesMemoryKeychain {
            for credential in AppModel.shared.credentialStore.credentials where Keychain.passwordWithoutPrompt(for: credential.id) == nil {
                _ = Keychain.setPasswordWithoutPrompt("demo-password-\(credential.name)", for: credential.id)
            }
        }
        // Debug builds only: SHEEPTERM_DEBUG_SHARE_GROUP=<group name> opens that group's Share Link sheet at launch (screenshots, scripted live check).
        let env = ProcessInfo.processInfo.environment
        if let link = env["SHEEPTERM_DEBUG_IMPORT_LINK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AppModel.shared.closeCurrentWorkspace()
                AppModel.shared.showImportLink(link)
            }
        }
        // SHEEPTERM_DEBUG_PING="10.0.0.1, core.lab" types `ping …` in the connect box;
        // SHEEPTERM_DEBUG_PING_LOG=1 opens the tab's log (live check, screenshots).
        // SHEEPTERM_DEBUG_PING_PROMO=<file>: the local tab cats that file
        // (sample device output) and a demo Ping tab opens beside it.
        if let file = env["SHEEPTERM_DEBUG_PING_PROMO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let tab = AppModel.shared.selectedTab {
                    // Typed and run (a trailing newline = Return as its own CR).
                    _ = AppModel.shared.terminalHost(ofSession: tab.id)?.sendCommand("clear; PS1='core-sw1# '; cat '\(file)'\n")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppModel.shared.debugPingDemoBeside() }
            }
        }
        // SHEEPTERM_DEBUG_PING_PNG=<path>: a demo Ping tab drawn off screen.
        if let path = env["SHEEPTERM_DEBUG_PING_PNG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let ping = PingTabController()
                ping.loadDemo()
                if let first = ping.rows.first { ping.selection = [first.id] }
                let host = ping.hosting
                host.appearance = NSAppearance(named: .darkAqua)
                // SHEEPTERM_DEBUG_PING_PNG_WIDTH: a narrower pane (a split).
                let width = env["SHEEPTERM_DEBUG_PING_PNG_WIDTH"].flatMap(Double.init) ?? 1100
                host.frame = NSRect(x: 0, y: 0, width: width, height: 640)
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: 640),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    window.orderOut(nil)
                    ping.close()
                }
            }
        }
        if env["SHEEPTERM_DEBUG_PING_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AppModel.shared.openPing(inNewTab: true)
                if case .ping(let ping)? = AppModel.shared.selectedTab?.content {
                    ping.loadDemo()
                    if ping.rows.count > 1 { ping.selection = [ping.rows[1].id] }
                }
            }
        }
        if let targets = env["SHEEPTERM_DEBUG_PING"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let host = ConnectParser.parseConnectBox("ping " + targets) else { return }
                AppModel.shared.open(host: host)
                if env["SHEEPTERM_DEBUG_PING_LOG"] == "1", case .ping(let ping)? = AppModel.shared.selectedTab?.content {
                    ping.showLog = true
                }
            }
        }
        if env["SHEEPTERM_DEBUG_NETWORK_INFO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AppModel.shared.closeCurrentWorkspace()
                AppModel.shared.showNetworkInfo = true
            }
        }
        if env["SHEEPTERM_DEBUG_SHARED_LINKS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AppModel.shared.closeCurrentWorkspace()
                AppModel.shared.showSharedLinks = true
            }
        }
        // SHEEPTERM_DEBUG_SHEET=addhost-ssh|addhost-web|addhost-telnet opens Add Host on that kind (addhost-newssh|addhost-newtelnet: the connect form)
        // (edithost:<uuid> is SidebarView's); SHEEPTERM_DEBUG_OPEN_URLS="u1 u2" opens
        // each like ⌘K would; SHEEPTERM_DEBUG_SIDEBAR=1 shows the sidebar. Scratch runs only.
        if env["SHEEPTERM_DEBUG_SIDEBAR"] == "1" || (env["SHEEPTERM_DEBUG_SHEET"] ?? "").hasPrefix("edithost:") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { AppModel.shared.sidebarShown = true }
        }
        // SHEEPTERM_DEBUG_TOGGLE_SIDEBAR=n: the sidebar toggled every n seconds (frame captures of the toggle).
        if let every = env["SHEEPTERM_DEBUG_TOGGLE_SIDEBAR"].flatMap(Double.init), every > 0 {
            Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in
                MainActor.assumeIsolated { AppModel.shared.toggleSidebar() }
            }
        }
        // SHEEPTERM_DEBUG_SPLIT=right|down (or several, "right down right"): split the
        // focused pane 3 s in, then once a second (pane margin shots, nested splits).
        if let split = env["SHEEPTERM_DEBUG_SPLIT"] {
            for (i, word) in split.split(separator: " ").enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(i)) {
                    AppModel.shared.splitFocusedPane(word == "down" ? .down : .right)
                    let m = AppModel.shared
                    NSLog("debug split %@ → panes %d, tabs %d, focused %@", String(word), m.selectedWorkspace?.paneCount ?? -1,
                          m.tabs.count, m.selectedTab?.title ?? "nil")
                }
            }
        }
        if let urls = env["SHEEPTERM_DEBUG_OPEN_URLS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                for text in urls.split(separator: " ") {
                    if let host = ConnectParser.parseConnectBox(String(text)) { AppModel.shared.open(host: host) }
                }
                if env["SHEEPTERM_DEBUG_SIDEBAR"] == "1" { AppModel.shared.sidebarShown = true }
            }
        }
        // SHEEPTERM_DEBUG_OPEN_FILES=n: Open Files on the selected SSH tab after n seconds
        // (screenshots of a Files tab riding that tab's connection).
        if let after = env["SHEEPTERM_DEBUG_OPEN_FILES"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { AppModel.shared.openFilesForSelectedTab() }
        }
        // SHEEPTERM_DEBUG_INDICATORS_PNG=<path>: the bottom bar's Wool and Packet
        // indicators, every phase, drawn by the real views (screenshots).
        if let path = env["SHEEPTERM_DEBUG_INDICATORS_PNG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let phases: [(ConnectionIndicator.Phase, Color)] = [
                    (.connecting, Theme.warn), (.connected, Theme.ok), (.closed, Theme.destructive)]
                @MainActor func row(_ v: some View, _ name: String) -> some View {
                    HStack(spacing: 10) { v; Text(name); Spacer(); Text("Sun 2026-10-25 04:10:00") }
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dimText)
                        .padding(.horizontal, 12).frame(width: 440, height: 24).background(Theme.chrome)
                }
                let view = VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in row(WoolIndicator(phase: phases[i].0, color: phases[i].1).opacity(ConnectionIndicator.brightness(phases[i].0)), "Wool") }
                    ForEach(0..<3, id: \.self) { i in row(PacketIndicator(phase: phases[i].0, color: phases[i].1).opacity(ConnectionIndicator.brightness(phases[i].0)), "Packet") }
                }.padding(12).background(Theme.tabActive)
                let host = NSHostingView(rootView: view)
                host.frame.size = host.fittingSize
                host.appearance = NSAppearance(named: .darkAqua)
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: host.frame.width, height: host.frame.height),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                window.orderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    window.orderOut(nil)
                }
            }
        }
        // SHEEPTERM_DEBUG_FILESERVER="tftp ssh ftp" starts those servers and
        // opens the File Server popover (scratch runs / screenshots only).
        if let servers = env["SHEEPTERM_DEBUG_FILESERVER"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                // SHEEPTERM_DEBUG_SERVE_FILE=<path>: the file a device may pull.
                if let file = env["SHEEPTERM_DEBUG_SERVE_FILE"] { FileServerModel.shared.setServedFile(URL(fileURLWithPath: file)) }
                if let v = env["SHEEPTERM_DEBUG_PICKED_VENDOR"].flatMap(Vendor.init(rawValue:)) { FileServerModel.shared.pickedVendor = v }
                for name in servers.split(separator: " ") {
                    if let kind = FileServerModel.Server(rawValue: String(name)) { FileServerModel.shared.start(kind) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    // …or, with SHEEPTERM_DEBUG_FILESERVER_PNG=<path>, renders the
                    // popover to that file instead (no screen capture needed).
                    if let path = env["SHEEPTERM_DEBUG_FILESERVER_PNG"] {
                        if let tab = AppModel.shared.selectedTab, let vendor = env["SHEEPTERM_DEBUG_VENDOR"].flatMap(Vendor.init(rawValue:)) {
                            AppModel.shared.setHighlightVendorForTabOnly(vendor, tabID: tab.id)
                        }
                        let host = NSHostingView(rootView: FileServerPopover().environmentObject(AppModel.shared)
                            .background(Theme.chrome).environment(\.colorScheme, .dark))
                        host.appearance = NSAppearance(named: .darkAqua)
                        let size = host.fittingSize
                        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                                              styleMask: .borderless, backing: .buffered, defer: false)
                        window.appearance = NSAppearance(named: .darkAqua)
                        window.backgroundColor = NSColor(Theme.chrome)
                        window.contentView = host
                        window.orderFront(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            host.frame.size = host.fittingSize
                            window.setContentSize(host.fittingSize)
                            host.layoutSubtreeIfNeeded()
                            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                                host.cacheDisplay(in: host.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                            }
                            window.orderOut(nil)
                        }
                    } else {
                        FileServerModel.shared.popoverShown = true
                    }
                }
            }
        }
        // SHEEPTERM_DEBUG_PREVIEW_PNG=<path>: 5.0 (60)'s visual changes in one
        // picture (Open File sheet, New SSH toggles, transfer rows, glyphs).
        if let path = env["SHEEPTERM_DEBUG_PREVIEW_PNG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let rows = [
                    ServerTransfer(token: "a", peer: "192.168.222.254", name: "running-config.cfg", isUpload: true, done: 734_003, total: 1_048_576),
                    ServerTransfer(token: "b", peer: "192.168.222.254", name: "startup-config.cfg", isUpload: true, done: 18_220, total: 18_220, state: .done),
                    ServerTransfer(token: "c", peer: "192.168.222.1", name: "fortios.out", isUpload: false, done: 0, total: 0, state: .failed, detail: "file not found"),
                    ServerTransfer(token: "d", peer: "192.168.222.1", name: "fgt-backup.conf", isUpload: true, done: 40_000, total: 0),
                ]
                let view = HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        QuickConnectSheet(kind: .ssh, addOnly: false)
                        FileTransferSheet()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { TransferRow(transfer: $0) }
                        HStack(spacing: 14) {
                            FileServerGlyph(running: false).frame(width: 14, height: 12)
                            FileServerGlyph(running: true).frame(width: 14, height: 12)
                            FileServerGlyph(running: false).frame(width: 16, height: 13)
                            Text("off · on · Files tab header").foregroundStyle(Theme.dimText)
                        }
                    }
                    .font(.system(size: 11))
                    .frame(width: 330).padding(14).background(Theme.tabActive)
                }
                .padding(16).environmentObject(AppModel.shared).background(Theme.chrome).environment(\.colorScheme, .dark)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: .darkAqua)
                host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: host.frame.width, height: host.frame.height),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    host.frame.size = host.fittingSize
                    window.setContentSize(host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    NSLog("preview png: %@", NSStringFromRect(host.bounds))
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    window.orderOut(nil)
                }
            }
        }
        // SHEEPTERM_DEBUG_STRIP_PNG=<path>: bottom-bar transfer strip drafts.
        if let path = env["SHEEPTERM_DEBUG_STRIP_PNG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let strip = FileServerPlan.Strip(label: "running-config.cfg", fraction: 0.69, percent: "69%", size: "734 KB/1.1 MB")
                @MainActor func bar(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        HStack(spacing: 12) { content() }
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dimText)
                            .padding(.horizontal, 12).frame(width: 760, height: 24)
                            .background(Theme.chrome)
                            .overlay(alignment: .top) { Rectangle().fill(Theme.chromeLine).frame(height: 1) }
                    }
                }
                let glyph = FileServerGlyph(running: true, busy: false).frame(width: 14, height: 12)
                let view = VStack(alignment: .leading, spacing: 18) {
                    bar("A  name · bar · percent and size") {
                        Text(strip.label).foregroundStyle(Theme.tabText)
                        TransferBar(fraction: 0.69).frame(maxWidth: 220)
                        Text(strip.detail); Spacer(); glyph
                    }
                    bar("B  bar across the whole bar, text on the right") {
                        Text(strip.label).foregroundStyle(Theme.tabText)
                        TransferBar(fraction: 0.69)
                        Text(strip.detail); glyph
                    }
                    bar("C  compact, right side beside the glyph (other items stay)") {
                        Text("zsh — This Mac").foregroundStyle(Theme.dimText); Spacer()
                        Text(strip.label).foregroundStyle(Theme.tabText)
                        TransferBar(fraction: 0.69).frame(width: 90)
                        Text("69%  734 KB/1.1 MB"); glyph
                    }
                    bar("Done (4 s, then the bar comes back)") {
                        Image(systemName: "checkmark").foregroundStyle(Theme.ok)
                        Text("running-config.cfg").foregroundStyle(Theme.tabText)
                        Text("Success").foregroundStyle(Theme.ok); Spacer(); glyph
                    }
                    bar("Failed (4 s; ⓘ = reason on hover)") {
                        Image(systemName: "xmark").foregroundStyle(Theme.destructive)
                        Text("fortios.out").foregroundStyle(Theme.tabText)
                        Text("Failed").foregroundStyle(Theme.destructive)
                        Image(systemName: "info.circle"); Spacer(); glyph
                    }
                }
                .padding(16).background(Theme.tabActive).environment(\.colorScheme, .dark)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: .darkAqua)
                host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: host.frame.width, height: host.frame.height),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    window.orderOut(nil)
                }
            }
        }
        if env["SHEEPTERM_DEBUG_SHEET"] == "transferlog" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppModel.shared.showTransferLog = true }
        }
        // SHEEPTERM_DEBUG_WHATSNEW_ART=<dir>: the What's New pictures, drawn
        // by the real views with sample data (start with SHEEPTERM_DEBUG_FILESERVER
        // + _SERVE_FILE + _MAC_IP + _VENDOR so the popover has a server, a
        // file and a command). Writes open-file.png and serve-file.png.
        if let dir = env["SHEEPTERM_DEBUG_WHATSNEW_ART"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                if let tab = AppModel.shared.selectedTab, let vendor = env["SHEEPTERM_DEBUG_VENDOR"].flatMap(Vendor.init(rawValue:)) {
                    AppModel.shared.setHighlightVendorForTabOnly(vendor, tabID: tab.id)
                }
                @MainActor func menuItem(_ title: String, on: Bool = false) -> some View {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(on ? Color.white : Theme.tabText)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .frame(width: 210, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.accent : Color.clear))
                }
                @MainActor func line() -> some View { Rectangle().fill(Theme.chromeLine).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 10) }
                let plusMenu = VStack(alignment: .leading, spacing: 0) {
                    HStack { Spacer(); Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.tabText) }
                        .padding(.bottom, 8).padding(.trailing, 6)
                    VStack(alignment: .leading, spacing: 0) {
                        menuItem("New Terminal Tab"); line()
                        menuItem("New SSH Connection…"); menuItem("New Telnet Session…"); menuItem("New Serial Console…"); menuItem("New Web Tab"); line()
                        menuItem("New Ping Tab"); line()
                        menuItem("Open File…", on: true); menuItem("Serve File…"); line()
                        menuItem("Passwords…")
                    }
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.controlFill))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.chromeLine))
                }
                let openFile = HStack(alignment: .top, spacing: 28) {
                    plusMenu.frame(width: 230)
                    Image(systemName: "arrow.right").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.dimText).padding(.top, 120)
                    FileTransferSheet(sample: "10.10.1.1", username: "admin").frame(width: SheetLayout.width)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.controlFill))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.chromeLine))
                }
                .padding(28)
                let bottomBar = HStack(spacing: 12) {
                    Text("ssh · admin@10.10.1.1"); Spacer()
                    TransferBar(fraction: 0.69).frame(width: 90)
                    Text("69%  734 KB/1.1 MB")
                    FileServerGlyph(running: true).frame(width: 14, height: 12)
                    Text("Sun 2026-10-25 09:41:00")
                }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dimText)
                .padding(.horizontal, 12).frame(height: 24).background(Theme.chrome)
                .overlay(alignment: .top) { Rectangle().fill(Theme.chromeLine).frame(height: 1) }
                let serveFile = VStack(spacing: 18) {
                    FileServerPopover()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.controlFill))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.chromeLine))
                    bottomBar.frame(width: 640)
                }
                .padding(28)
                @MainActor func write(_ v: some View, _ name: String) {
                    let host = NSHostingView(rootView: v.environmentObject(AppModel.shared).background(Theme.tabActive).environment(\.colorScheme, .dark))
                    host.appearance = NSAppearance(named: .darkAqua)
                    host.frame.size = host.fittingSize
                    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: host.frame.width, height: host.frame.height),
                                          styleMask: .borderless, backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: .darkAqua)
                    window.contentView = host
                    window.orderFront(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        host.frame.size = host.fittingSize
                        window.setContentSize(host.fittingSize)
                        host.layoutSubtreeIfNeeded()
                        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                            host.cacheDisplay(in: host.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                        }
                        window.orderOut(nil)
                    }
                }
                // Watching transfers: numbered callouts match the page's steps.
                @MainActor func badge(_ n: Int) -> some View {
                    Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.tabActive)
                        .frame(width: 18, height: 18).background(Circle().fill(Theme.ok))
                }
                let rows = [
                    ServerTransfer(token: "a", peer: "10.10.1.1", name: "AOS-CX_10.13.swi", isUpload: false, done: 734_003, total: 1_100_000),
                    ServerTransfer(token: "b", peer: "10.10.1.1", name: "running-config.cfg", isUpload: true, done: 18_220, total: 18_220, state: .done),
                    ServerTransfer(token: "c", peer: "10.10.1.2", name: "backup.cfg", isUpload: false, done: 0, total: 0, state: .failed, detail: "file not found"),
                ]
                let tooltip = Text("67% · 734 KB of 1.1 MB · 10.10.1.1")
                    .font(.system(size: 11)).foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.93)))
                    .shadow(radius: 2, y: 1)
                let panel = VStack(alignment: .leading, spacing: 10) {
                    TransferRow(transfer: rows[0])
                        .overlay(alignment: .topLeading) {
                            Image(systemName: "cursorarrow").font(.system(size: 14)).foregroundStyle(.white)
                                .shadow(radius: 1).offset(x: 12, y: 10)
                        }
                    tooltip.padding(.leading, 22).padding(.top, 2)
                    TransferRow(transfer: rows[1])
                    TransferRow(transfer: rows[2])
                }
                .frame(width: 300)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.controlFill))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.chromeLine))
                .overlay(alignment: .topTrailing) { badge(3).offset(x: 8, y: -8) }
                @MainActor func logLine(_ time: String, _ name: String, _ ok: Bool) -> some View {
                    HStack(spacing: 10) {
                        Text(time).monospacedDigit().foregroundStyle(Theme.dimText)
                        Text(name).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(ok ? "Success" : "Failed").foregroundStyle(ok ? Theme.ok : Theme.destructive)
                    }
                    .font(.system(size: 11))
                }
                let logCard = VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.dimText)
                        Text("Transfer Log").font(.system(size: 12, weight: .semibold))
                    }
                    logLine("09:41:02", "running-config.cfg", true)
                    logLine("09:38:15", "backup.cfg", false)
                    logLine("09:30:47", "AOS-CX_10.12.swi", true)
                }
                .frame(width: 270)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.controlFill))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.chromeLine))
                .overlay(alignment: .topTrailing) { badge(4).offset(x: 8, y: -8) }
                let bar = HStack(spacing: 12) {
                    Text("ssh · admin@10.10.1.1"); Spacer()
                    TransferBar(fraction: 0.67).frame(width: 90)
                        .overlay(alignment: .top) { badge(2).offset(y: -24) }
                    Text("67%  734 KB/1.1 MB")
                    FileServerGlyph(running: true).frame(width: 14, height: 12)
                        .overlay(alignment: .top) { badge(1).offset(y: -24) }
                    Text("Sun 2026-10-25 09:41:00")
                }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dimText)
                .padding(.horizontal, 12).frame(height: 24).background(Theme.chrome)
                .overlay(alignment: .top) { Rectangle().fill(Theme.chromeLine).frame(height: 1) }
                let transfers = VStack(spacing: 34) {
                    HStack(alignment: .top, spacing: 22) { panel; logCard }
                    bar.frame(width: 660)
                }
                .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 20)
                write(openFile, "open-file.png")
                write(serveFile, "serve-file.png")
                write(transfers, "transfers.png")
                write(TransferLogView(), "log.png")
            }
        }
        // SHEEPTERM_DEBUG_FAMILY_PNG=<path>: the File Server's no-family rows.
        if let path = env["SHEEPTERM_DEBUG_FAMILY_PNG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let view = VStack(alignment: .leading, spacing: 10) {
                    CommandRow(command: .init(kind: .pull, text: "tftp://10.10.1.10/AOS-CX_10.13.swi", verified: false), tabID: nil)
                    FamilyPickerRow(current: nil) { _ in }
                }
                .padding(14).frame(width: 360).background(Theme.controlFill).environment(\.colorScheme, .dark)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: .darkAqua)
                host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: host.frame.width, height: host.frame.height),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                window.orderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    window.orderOut(nil)
                }
            }
        }
        if env["SHEEPTERM_DEBUG_SHEET"] == "whatsnew" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppModel.shared.showWhatsNew = true }
        }
        if env["SHEEPTERM_DEBUG_SHEET"] == "passwords" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppModel.shared.showCredentials = true }
        }
        if env["SHEEPTERM_DEBUG_SHEET"] == "newwebtab" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppModel.shared.newWebTab() }
        }
        if let sheet = env["SHEEPTERM_DEBUG_SHEET"], sheet.hasPrefix("addhost-") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AppModel.shared.closeCurrentWorkspace()
                let kind: ConnectionKind = sheet == "addhost-web" ? .web : sheet.hasSuffix("telnet") ? .telnet : .ssh
                AppModel.shared.quickConnect = QuickConnectRequest(kind: kind,
                                                                   addOnly: sheet != "addhost-newssh" && sheet != "addhost-newtelnet")
            }
        }
        if let name = ProcessInfo.processInfo.environment["SHEEPTERM_DEBUG_SHARE_GROUP"], !name.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AppModel.shared.closeCurrentWorkspace()   // no local-shell prompt behind the sheet in screenshots
                if let group = AppModel.shared.store.groups.first(where: { $0.name == name }) {
                    AppModel.shared.showShareLink(groupID: group.id)
                }
            }
        }
#endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    /// Closing the window has to reach the same guard ⌘Q does.
    ///
    /// A SwiftUI WindowGroup does NOT terminate the app when its last window
    /// closes — measured on this macOS: the process stayed alive with zero
    /// windows and applicationShouldTerminate was never called. So the red
    /// button used to take the window away while every SSH/serial session kept
    /// running invisibly, no question asked, and every open log kept its
    /// unflushed tail.
    ///
    /// Returning true routes that close through applicationShouldTerminate —
    /// but the question then arrives AFTER the window has gone, and cancelling
    /// left the app windowless, which SwiftUI answered by putting a window back
    /// and closing it again: the alert came back in a loop with Quit as the
    /// only way out. So the question is asked in `MainWindowCloseGuard` BEFORE
    /// the window closes, and by the time AppKit gets here the answer is
    /// already known. This still matters for the ordinary case: with no live
    /// session there is nothing to ask, the window closes, and the app should
    /// go with it rather than linger invisibly.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// ⌘Q (and closing the last window, which terminates the app) must not
    /// silently drop live sessions — a half-finished configuration on a
    /// console port is exactly the thing you cannot get back. Local shells
    /// don't count: those are cheap to reopen and Terminal.app doesn't ask
    /// about them either.
    /// Set by `MainWindowCloseGuard` when the user has already answered this
    /// question at the close button. Asking twice for one gesture is what an
    /// app does when nobody joined its two exits up.
    static var quitAlreadyConfirmed = false

    enum QuitAnswer { case nothingToAsk, quit, cancel }

    /// The one place the "sessions are still open" question is asked.
    ///
    /// This one DOES block a logout or a restart, and should: it is a question
    /// whose answer changes what happens, macOS supports an app stopping a
    /// logout for exactly that reason, and a restart that silently kills a
    /// half-finished `configure terminal` is the outcome the question exists to
    /// prevent. `AppModel.reportUnflushedLogs` is the opposite case — it
    /// reports, decides nothing, and is suppressed during a logout. Do not make
    /// these two consistent with each other; the difference is the point.
    static func askAboutLiveSessions() -> QuitAnswer {
        // A device pulling from (or pushing to) the File Server counts too:
        // quitting cuts that transfer just the same.
        var titles = AppModel.shared.liveRemoteSessions.map(\.title)
        if FileServerModel.shared.inFlight > 0 { titles.append(String(localized: "File Server transfer")) }
        let live = titles
        guard !live.isEmpty else { return .nothingToAsk }
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit SheepTerm? \(live.count) sessions are still open.")
        let names = live.prefix(8).map { "• \($0)" }.joined(separator: "\n")
        let more = live.count > 8 ? "\n• " + String(localized: "and \(live.count - 8) more") : ""
        alert.informativeText = (live.count == 1 ? String(localized: "Quitting closes it right away.")
                                                 : String(localized: "Quitting closes them right away."))
            + "\n\n\(names)\(more)"
        let quit = alert.addButton(withTitle: String(localized: "Quit"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        // Cancel is the default: Return must never be the key that drops a
        // live session, and Escape maps to it as well.
        quit.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        // Red, as a button that drops live sessions should look (SheepAlert
        // paints `hasDestructiveAction`); it is still not the default.
        quit.hasDestructiveAction = true
        return alert.sheepStyled().runModal() == .alertFirstButtonReturn ? .quit : .cancel
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quitAlreadyConfirmed {
            Self.quitAlreadyConfirmed = false
            AppModel.shared.shutdownSessionsForQuit()
            return .terminateNow
        }
        switch Self.askAboutLiveSessions() {
        case .cancel:
            return .terminateCancel
        case .nothingToAsk, .quit:
            // Stop and flush BEFORE terminating: the async log close that a tab
            // close uses never ran when the process simply exited, so the tail
            // of every open log was lost.
            AppModel.shared.shutdownSessionsForQuit()
            return .terminateNow
        }
    }

}

@main
struct SheepTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        AppLanguage.applySystemFallback()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1100, height: 680)
        .windowStyle(.hiddenTitleBar)
        // The app delegate handles opened .sheepterm files; without this the
        // WindowGroup ALSO answers the open request by spawning a second
        // window for the "document" — and SheepTerm is single-window on
        // purpose. An empty match set means this scene handles no external
        // events, so no extra window is ever created for one.
        .handlesExternalEvents(matching: [])
        .commands {
            SheepTermCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Tracks whether the app's main window (fullSizeContentView) is key, and
/// whether anything of the app is on screen at all.
/// Asks about live sessions BEFORE the window is taken away.
///
/// `applicationShouldTerminateAfterLastWindowClosed` gets the question only
/// after AppKit has already closed the window, and answering Cancel then left
/// the app with no window at all — which SwiftUI answered by putting one back
/// and closing it again, so the alert returned in a loop whose only exit was
/// Quit. Refusing the close is what Cancel should mean: nothing happened, the
/// window is still there, the session is still up.
///
/// SwiftUI owns the window's delegate, so this one stands in front of it and
/// forwards every message it does not implement — `windowShouldClose` is the
/// only one it answers itself.
@MainActor
final class MainWindowCloseGuard: NSObject, NSWindowDelegate {
    static let shared = MainWindowCloseGuard()

    /// SwiftUI's delegate. `nonisolated(unsafe)` because the two forwarding
    /// overrides below cannot be main-actor (they override nonisolated
    /// NSObject methods); AppKit only ever sends them on the main thread.
    private nonisolated(unsafe) var forwardTo: (any NSWindowDelegate)?
    private weak var guarded: NSWindow?

    func attach(to window: NSWindow) {
        guard isMainTerminalWindow(window), window.delegate !== self else { return }
        forwardTo = window.delegate
        guarded = window
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === guarded else { return true }
        switch AppDelegate.askAboutLiveSessions() {
        case .nothingToAsk:
            return true             // nothing to lose; the app quits with the window
        case .cancel:
            return false            // the window stays exactly as it was
        case .quit:
            // Already answered — do not ask again on the way through
            // applicationShouldTerminate.
            AppDelegate.quitAlreadyConfirmed = true
            NSApp.terminate(nil)
            return false
        }
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forwardTo?.responds(to: aSelector) ?? false
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        forwardTo
    }
}

/// Window-scoped commands (Close Tab) disable themselves while Settings or
/// a panel is key, the status-bar sheep pause their animation while the
/// window isn't key, and the clock stops ticking while nothing is visible.
@MainActor
final class MainWindowKeyMonitor: NSObject, ObservableObject {
    static let shared = MainWindowKeyMonitor()
    @Published private(set) var isKey = true
    /// False while every window is occluded (hidden, minimized, fully
    /// covered). Unlike `isKey` this stays true for a visible-but-inactive
    /// window — a clock the user can still see must keep the right time;
    /// one nobody can see must not wake the app once a second.
    @Published private(set) var isVisible = true

    private override init() {
        super.init()
        isVisible = NSApp?.occlusionState.contains(.visible) ?? true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationOcclusionDidChange(_:)),
            name: NSApplication.didChangeOcclusionStateNotification,
            object: nil
        )
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowKeyStateDidChange(_:)),
                name: name,
                object: nil
            )
        }
    }

    /// AppKit posts application/window lifecycle notifications on the main
    /// thread. Selector observation keeps the Objective-C boundary at the
    /// framework edge instead of transferring a non-Sendable Notification
    /// through a @Sendable closure.
    @objc private func applicationOcclusionDidChange(_ note: Notification) {
        isVisible = NSApp?.occlusionState.contains(.visible) ?? true
    }

    @objc private func windowKeyStateDidChange(_ note: Notification) {
        // fullSizeContentView alone is NOT the main window: a SwiftUI sheet
        // carries it too, and so does the AuthPrompt panel. Both used to
        // report themselves key, which left File → Close Tab (⇧⌘W) enabled
        // while a sheet was up — pressing it closed a tab behind the sheet,
        // the exact thing the disabled() guard exists to prevent. Use the same
        // predicate syncFullscreen does.
        guard let window = note.object as? NSWindow,
              isMainTerminalWindow(window) else { return }
        isKey = note.name == NSWindow.didBecomeKeyNotification
    }
}

/// All menu commands live here so checkmarks (logging, device family,
/// terminal theme, …) update live — the struct observes AppModel.
struct SheepTermCommands: Commands {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var mainWindowKey = MainWindowKeyMonitor.shared
    @ObservedObject private var aiPanel = AIPanelChrome.shared

    /// Highlighting only means something for a remote session. On a local
    /// shell the Device Family menu still opened and still moved its
    /// checkmark, while nothing whatsoever happened — the status bar has
    /// always hidden the same control for a local tab. Toggle Highlighting
    /// (and its ⌘⇧H) was live in the same two dead cases: a local tab, and no
    /// tab at all, where `toggleHighlightCurrent` returns without doing
    /// anything.
    private var isRemoteSessionSelected: Bool {
        switch model.selectedTab?.content {
        case .ssh, .serial: return true
        case .local, .web, .files, .ping, nil: return false
        }
    }

    private var isWebSelected: Bool {
        if case .web? = model.selectedTab?.content { return true }
        return false
    }

    /// View → Terminal Font: one checkable item per family.
    private func fontToggles(_ families: [String]) -> some View {
        ForEach(families, id: \.self) { family in
            Toggle(family, isOn: Binding(
                get: { model.terminalFontFamily == family },
                set: { _ in model.terminalFontFamily = family }
            ))
        }
    }

    var body: some Commands {
        // One window only: a second window would share AppModel.shared and
        // the same TerminalView instances, blanking/reparenting views
        // between windows. Remove the default File → New Window (⌘N).
        CommandGroup(replacing: .newItem) { }

        // SheepTerm menu, under About. No shortcut: nothing obvious is free
        // and an update check is not an every-day keystroke.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { AppUpdater.shared.checkNow() }
        }

        CommandGroup(after: .newItem) {
            Button("Quick Connect…") { model.showQuickSearch = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("New Terminal Tab") { model.newLocalTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New SSH Connection…") { model.openQuickConnect(.ssh) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Telnet Session…") { model.openQuickConnect(.telnet) }
            Button("New Serial Console…") { model.openQuickConnect(.serial) }
            // No shortcut: ⌘T is New Terminal Tab, and ⌘N would read as a
            // new window to anyone coming from a browser.
            Button("New Web Tab") { model.newWebTab() }
            Divider()
            Button("New Ping Tab") { model.openPing(inNewTab: true) }
            // Main window only — while Settings is key, ⌘⇧W must not close
            // a terminal tab in the background.
            Button("Close Tab") { model.closeCurrentWorkspace() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!mainWindowKey.isKey)
            Divider()
            Button("Passwords…") { model.showCredentials = true }
            Button("Known Hosts…") { model.openKnownHosts() }
            Divider()
            Toggle("Log Sessions to File", isOn: $model.sessionLogging)
            Button("Open Logs Folder") {
                NSWorkspace.shared.open(SessionLogger.logsDirectory)
            }
            Button("Search Logs…") { model.showLogSearch = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            // Two items, short names (the owner, 5.0 (60)): files ON a device
            // (Open File… — starts on the focused SSH tab's device and rides
            // its connection), files FOR devices (Serve File… → the popover,
            // which also holds the Transfer Log).
            Button("Open File…") { model.showFileTransfer = true }
            Button("Serve File…") { FileServerModel.shared.popoverShown = true }
            Divider()
            Button("Import Group…") { model.importGroupViaPanel() }
            Button("Import from Link…") { model.showImportLink() }
            Button("Shared Links…") { model.showSharedLinks = true }
            Divider()
            Button("Back Up Configuration…") { BackupManager.backUp() }
            Button("Restore Configuration…") { BackupManager.restore() }
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy All Output") { model.copyAllOutput() }
                .disabled(!model.canCopyAllOutput)
            Toggle("Safe Multi-line Paste", isOn: $model.safePasteEnabled)
            Toggle("Confirm Dangerous Commands", isOn: $model.confirmDangerousCommands)
            // A break condition on a serial console (a boot loader's "press
            // Break now"). Greyed out everywhere else: SSH and a local shell
            // have no line to put one on.
            Button("Send Break") { model.sendBreak() }
                .keyboardShortcut("b", modifiers: [.control, .option])
                .disabled(!model.canSendBreak)
            Button("Send File via XMODEM…") { model.sendFileViaXModem() }
                .disabled(!model.canSendFileViaXModem)
            Divider()
            // Search in the scrollback. SheepVT owns the engine and the
            // find bar itself — these items only forward the standard
            // NSTextFinder actions to the active terminal view (see
            // AppModel.sendFinderAction).
            Button("Find…") { model.showFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.selectedTab == nil)
            Button("Find Next") { model.findNextMatch() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model.selectedTab == nil)
            Button("Find Previous") { model.findPreviousMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.selectedTab == nil)
            Button("Use Selection for Find") { model.useSelectionForFind() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.selectedTab == nil)
        }

        CommandGroup(after: .sidebar) {
            Button {
                model.toggleSidebar()
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.leading")
            }
            .keyboardShortcut("0", modifiers: .command)
            // AI Assistant off: no panel item and no ⌥⌘A at all.
            if aiPanel.enabled {
                Toggle(isOn: Binding(get: { aiPanel.shown }, set: { _ in aiPanel.toggle() })) {
                    Label("Show AI Panel", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
            }
            Toggle(isOn: $aiPanel.enabled) {
                Label("AI Assistant", systemImage: "sparkles")
            }
            Button {
                model.showReorderGroups = true
            } label: {
                Label("Reorder Groups…", systemImage: "arrow.up.arrow.down")
            }
            Button {
                model.showAddHosts()
            } label: {
                Label("Add Hosts…", systemImage: "tablecells")
            }
            Button {
                model.toggleHighlightCurrent()
            } label: {
                Label("Toggle Highlighting", systemImage: "highlighter")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(!isRemoteSessionSelected)
            // Answers `--More--` with a space on every SSH/serial tab. Global:
            // it does what the user would do next, so there is nothing to
            // decide per host.
            Toggle(isOn: $model.autoPage) {
                Label("Auto-page (--More--)", systemImage: "arrow.down.to.line")
            }
            Menu {
                ForEach(Vendor.allCases) { family in
                    Toggle(family.localizedLabel, isOn: Binding(
                        get: { model.selectedTab?.highlightVendor == family },
                        set: { _ in model.setHighlightVendorCurrent(family) }
                    ))
                }
            } label: {
                Label("Device Family", systemImage: "cpu")
            }
            .disabled(!isRemoteSessionSelected)
            // ⌘K already belongs to Quick Connect here, so this takes ⌘L.
            // Only the history above the screen goes — the visible screen and
            // the remote session are untouched. On a web tab the same key is
            // the browser's: the URL field (one item, so one owner of ⌘L).
            Button {
                model.commandL()
            } label: {
                if isWebSelected {
                    Label("Open Location", systemImage: "link")
                } else {
                    Label("Clear Scrollback", systemImage: "eraser")
                }
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(model.selectedTab == nil)
            // Web tabs only (greyed elsewhere): ⌘R / ⌘[ / ⌘] are free in a
            // terminal app and mean the browser's thing here.
            Button {
                model.reloadWebPage()
            } label: {
                Label("Reload Page", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!isWebSelected)
            Button {
                model.webGoBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!isWebSelected)
            Button {
                model.webGoForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!isWebSelected)
            Button {
                model.clearWebsiteData()
            } label: {
                Label("Clear Website Data…", systemImage: "trash")
            }
            // macOS 27 hides link addresses and the ARP table from a local
            // tab's commands; the app reads them itself (NetworkTables).
            Button {
                model.showNetworkInfo = true
            } label: {
                Label("Network Info…", systemImage: "network")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Toggle(isOn: $model.showStatusBar) {
                Label("Show Bottom Bar", systemImage: "rectangle.bottomthird.inset.filled")
            }
            Menu {
                Picker("Connection Status", selection: $model.statusConnectionStyle) {
                    Text("Wool").tag(ConnectionIndicator.wool)
                    Text("Packet").tag(ConnectionIndicator.packet)
                    Text("Sheep").tag(ConnectionIndicator.sheep)
                    Divider()
                    Text("Off").tag(ConnectionIndicator.off)
                }
                Toggle("Session Info", isOn: $model.statusShowSession)
                Toggle("Shortcut Hints", isOn: $model.statusShowHints)
                Toggle("This Mac IP", isOn: $model.statusShowIP)
                Toggle("Clock", isOn: $model.statusShowClock)
                Toggle("File Server", isOn: $model.statusShowFileServer)
                Toggle("Transfer Progress", isOn: $model.statusShowTransfers)
            } label: {
                Label("Bottom Bar Items", systemImage: "checklist")
            }
            Divider()
            Menu {
                ForEach(Theme.terminalThemes) { theme in
                    Toggle(theme.name, isOn: Binding(
                        get: { model.terminalTheme == theme.id },
                        set: { _ in model.terminalTheme = theme.id }
                    ))
                }
            } label: {
                Label("Terminal Theme", systemImage: "paintpalette")
            }
            Menu {
                Button("Bigger") { model.stepSize(1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Smaller") { model.stepSize(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                // On a web tab these three zoom the page (Safari's), so the last one says so.
                Button(model.selectedWebController != nil ? String(localized: "Actual Size") : String(localized: "Default Size (\(Int(Theme.defaultFontSize)) pt)")) {
                    model.stepSize(0)
                }
                Divider()
                Toggle(Theme.fontFamilyLabel(Theme.systemFontFamily), isOn: Binding(
                    get: { model.terminalFontFamily == Theme.systemFontFamily },
                    set: { _ in model.terminalFontFamily = Theme.systemFontFamily }
                ))
                // Same grouping as the Settings picker: system | platform | bundled | other.
                Divider()
                fontToggles(Theme.terminalFontSections.platform)
                if !Theme.terminalFontSections.bundled.isEmpty {
                    Divider()
                    fontToggles(Theme.terminalFontSections.bundled)
                }
                if !Theme.terminalFontSections.other.isEmpty {
                    Divider()
                    Menu("Other Installed") { fontToggles(Theme.terminalFontSections.other) }
                }
                Divider()
                ForEach(Theme.TerminalFontWeight.allCases) { weight in
                    Toggle(weight.label, isOn: Binding(
                        get: { model.terminalFontWeight == weight },
                        set: { _ in model.terminalFontWeight = weight }
                    ))
                }
                Divider()
                Toggle("Font Smoothing", isOn: Binding(
                    get: { model.terminalFontSmoothing },
                    set: { model.terminalFontSmoothing = $0 }
                ))
            } label: {
                Label("Terminal Font", systemImage: "textformat.size")
            }
        }

        // Saved commands (4.2 (4)). The list is the store's, in its order;
        // ⌘⇧B opens the broadcast form.
        CommandMenu("Snippets") {
            if model.snippetStore.snippets.isEmpty {
                Text("No snippets yet")
            } else {
                ForEach(model.snippetStore.snippets) { snippet in
                    Button(snippet.name) { model.sendSnippet(snippet) }
                        .disabled(model.selectedTab == nil || isWebSelected)
                }
            }
            Divider()
            Button("Edit Snippets…") { model.showSnippets = true }
            Divider()
            Button("Broadcast to Tabs…") { model.showBroadcast = true }
                .keyboardShortcut("b", modifiers: [.command, .shift])
        }

        // Per-host command history (5.0 (1)). ⌘Y: ⌃ chords belong to the
        // remote shell (⌃R reverse search, line editing), and ⇧⌘H is
        // Toggle Highlighting.
        CommandMenu("History") {
            Button("Command History…") { model.openCommandHistory() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(!model.canUseCommandHistory)
            Button("Clear History for This Host…") { model.clearCommandHistoryForCurrentHost() }
                .disabled(!model.canUseCommandHistory)
        }

        CommandMenu("Tabs") {
            // Split panes (4.2 (7)). ⌘W (the key monitor) closes the focused
            // pane, or the tab when it is the last one; ⌘⇧W closes the tab.
            // Main window only, like Close Tab: ⌘D behind Settings or Search
            // Logs must not start a second login to the focused device.
            Button("Split Right") { model.splitFocusedPane(.right) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!model.canSplitFocusedPane(.right) || !mainWindowKey.isKey)
            Button("Split Down") { model.splitFocusedPane(.down) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!model.canSplitFocusedPane(.down) || !mainWindowKey.isKey)
            Button("Close Pane") { model.closeCurrentTab() }
                .disabled(model.selectedTab == nil)
            // Also by dragging the pane's header onto the empty tab strip.
            Button("Unsplit") { model.moveFocusedPaneToNewTab() }
                .disabled((model.selectedWorkspace?.paneCount ?? 1) < 2)
            Menu("Focus Pane") {
                Button("Left") { model.focusPane(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Right") { model.focusPane(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Up") { model.focusPane(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Down") { model.focusPane(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
            .disabled((model.selectedWorkspace?.paneCount ?? 1) < 2)
            Button("Zoom Pane") { model.toggleZoomFocusedPane() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled((model.selectedWorkspace?.paneCount ?? 1) < 2)
            Button("Even Out Panes") { model.evenOutCurrentPanes() }
                .disabled((model.selectedWorkspace?.paneCount ?? 1) < 2)
            Divider()
            Button("Next Tab") { model.selectAdjacentTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { model.selectAdjacentTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            // ⌃⌘ arrows, not ⇧⌘: ⇧⌘←/→ is select-to-line-edge in every text
            // field (sidebar search, Quick Connect) and the menu would win.
            Button("Move Tab Left") { model.moveSelectedTab(right: false) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
            Button("Move Tab Right") { model.moveSelectedTab(right: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
            Divider()
            ForEach(1..<10, id: \.self) { number in
                Button("Tab \(number)") { model.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
        }
    }
}

/// The app's spelling of a device family, from the string catalog.
///
/// `Vendor.label` lives in the shared Windows source (root `Package.swift`),
/// where there is no catalog and the value is used in log lines and in the AI
/// prompt as a plain English identifier — so the localization lives here, at
/// the point the user reads it.
extension Vendor {
    var localizedLabel: String {
        switch self {
        case .auto: return String(localized: "Auto (all vendors)")
        case .cisco: return String(localized: "Cisco IOS / IOS-XE / NX-OS")
        case .arubaCX: return String(localized: "Aruba CX")
        case .arubaOS: return String(localized: "ArubaOS (Controller / MM)")
        case .huawei: return String(localized: "Huawei VRP")
        case .comware: return String(localized: "H3C / HPE Comware")
        case .juniper: return String(localized: "Juniper Junos")
        case .panos: return String(localized: "Palo Alto PAN-OS")
        case .fortios: return String(localized: "Fortinet FortiOS")
        case .gaia: return String(localized: "Check Point Gaia")
        case .linux: return String(localized: "Linux / server")
        }
    }
}
