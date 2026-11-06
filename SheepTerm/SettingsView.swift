import AppKit
import Combine
import Synchronization
import SwiftUI
import UniformTypeIdentifiers

/// Settings (⌘,). Highlight rules are fixed built-ins now, so the window has
/// only the one pane — the chrome, sidebar, connection, backup and library
/// sections.
struct SettingsView: View {
    private enum Tab: Hashable { case general, optimization, ai }
    /// Set right before Settings opens to land on Optimization once.
    static var openOnOptimization = false
    /// Posted with it, for a Settings window already open (Fable round 4:
    /// `onAppear` does not run again, so it stayed on General).
    static let showOptimization = Notification.Name("SheepTerm.showOptimization")
    /// Always opens on General (the window keeps its view between openings).
    @State private var tab = Tab.general
    @State private var shown = false
    @ObservedObject private var aiChrome = AIPanelChrome.shared

    var body: some View {
        TabView(selection: $tab) {
            // General is exactly the pane it was before the tabs: 700 × 500.
            GeneralSettingsView()
                .frame(width: 700, height: 500)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            // 6.1: every switch that shapes the app, with role presets.
            OptimizationSettingsView()
                .frame(width: 700, height: 500)
                .tabItem { Label("Optimization", systemImage: "slider.horizontal.3") }
                .tag(Tab.optimization)
            // AI sizes to its content. Gone with View ▸ AI Assistant off.
            if aiChrome.enabled {
                AISettingsView()
                    .frame(width: 700)
                    .fixedSize(horizontal: false, vertical: true)
                    .tabItem { Label("AI", systemImage: "sparkles") }
                    .tag(Tab.ai)
            }
        }
        // What's New ▸ Start Optimize opens straight on Optimization (6.0 (48)).
        // Either may run first on a fresh window (Fable round 5): neither
        // ever sends it back to General; the flag is cleared once the window
        // is up, so it never carries over to a later opening.
        .onAppear {
            shown = true
            if Self.openOnOptimization { tab = .optimization; Self.openOnOptimization = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.showOptimization)) { _ in
            tab = .optimization
            if shown { Self.openOnOptimization = false }
        }
        .onDisappear { tab = .general; shown = false }
    }
}

/// General settings: appearance, terminal look, auto-reconnect, backup, libraries.
struct GeneralSettingsView: View {
    @State private var appLanguage = AppLanguage.current()
    private let originalLanguage = AppLanguage.launchLanguage
    @ObservedObject private var model = AppModel.shared
    @AppStorage(ChromeStyle.storageKey) private var chromeStyle = ChromeStyle.glass
    @AppStorage(SessionTerminalHost.clipboardWriteKey) private var allowClipboardWrite = false
    @AppStorage(UpdateCore.autoCheckKey) private var checkForUpdatesAutomatically = true
    @AppStorage(ShellIntegration.defaultsKey) private var realNetworkInfo = true

    var body: some View {
        Form {
            Section("Language") {
                Picker("App Language", selection: $appLanguage) {
                    Text("System Default").tag(AppLanguage.system)
                    ForEach(AppLanguage.allCases.filter { $0 != .system }) { language in
                        Text(verbatim: language.nativeName ?? language.rawValue).tag(language)
                    }
                }
                .onChange(of: appLanguage) { _, language in
                    language.apply()
                }
                if appLanguage != originalLanguage {
                    Text("Restart SheepTerm to apply the language. Active sessions stay open until you quit.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Appearance") {
                Picker("Chrome", selection: $chromeStyle) {
                    ForEach(ChromeStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Text("How the sidebar and tab bar are painted. Liquid Glass picks up the desktop behind the window (macOS 26); Solid Color keeps the flat chrome tile. The layout is the same either way — the terminal itself is never translucent.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Terminal") {
                Picker("Font", selection: $model.terminalFontFamily) {
                    Text(Theme.fontFamilyLabel(Theme.systemFontFamily)).tag(Theme.systemFontFamily)
                    Divider()
                    ForEach(Theme.terminalFontSections.platform, id: \.self) { family in
                        Text(family).tag(family)
                    }
                    if !Theme.terminalFontSections.bundled.isEmpty {
                        Divider()
                        ForEach(Theme.terminalFontSections.bundled, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    if !Theme.terminalFontSections.other.isEmpty {
                        Divider()
                        ForEach(Theme.terminalFontSections.other, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                }
                Stepper(value: $model.terminalFontSize, in: Theme.fontSizeRange, step: 1) {
                    LabeledContent("Size") {
                        Text("\(Int(model.terminalFontSize)) pt")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                Picker("Weight", selection: $model.terminalFontWeight) {
                    ForEach(Theme.TerminalFontWeight.allCases) { weight in
                        Text(weight.label).tag(weight)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Font smoothing", isOn: $model.terminalFontSmoothing)
                if ShellIntegration.isNeeded {
                    Toggle("Real MAC and ARP in local tabs", isOn: $realNetworkInfo)
                        .help("macOS 27 hides MAC addresses and the ARP table from commands in a local tab. On: ifconfig, arp, ndp, netstat and networksetup run through launchd and show the real values. Applies to new local tabs.")
                }
                Text("Applied to every open tab immediately; the grid re-measures, so columns and rows change with it. Also in View → Terminal Font, with ⌘+ / ⌘− for the size. On a display running a scaled resolution (the 13″ Air's stock 1470 × 956 is one) the whole screen is resampled before it reaches the eye, and a larger or heavier face survives that better than a thin one; Termius draws roughly 14 pt Semibold. Font smoothing is macOS's stroke thickening: on it makes light-on-dark text bolder with a soft grey edge, off (the default) draws thinner, cleaner stems — the same edge the Claude app's text has.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                Toggle("Allow remote programs to set the clipboard (OSC 52)", isOn: $allowClipboardWrite)
                Text("Lets vim or tmux on a device copy into the Mac's clipboard. Off by default: a compromised device could plant a command for your next ⌘V. When on, pasting text a session set always asks first. Reading the clipboard is never allowed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checkForUpdatesAutomatically)
                    .help("Checks GitHub a few seconds after every launch and once a day while SheepTerm is open. Nothing is installed until you press Install & Relaunch, and only a download whose signature matches is installed.")
                Button("Check Now") { AppUpdater.shared.checkNow() }
                    .help("Same as SheepTerm → Check for Updates…")
            }

            Section("Backup") {
                HStack(spacing: 10) {
                    Button {
                        BackupManager.backUp()
                    } label: {
                        Label("Back Up Configuration…", systemImage: "arrow.down.doc")
                    }
                    Button {
                        BackupManager.restore()
                    } label: {
                        Label("Restore…", systemImage: "arrow.up.doc")
                    }
                }
                Text("One file with every group and host, the Recent list, credential names and all app settings. Passwords are never included — they stay in this Mac's Keychain. Restoring replaces the current configuration and copies it aside first.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            SyncSettingsSection()

            Section("Libraries") {
                // No third-party code left to track: both halves of a session
                // are ours, and the only crypto underneath is Apple's.
                LabeledContent("SSH") {
                    Text("built in — Packages/SheepSSH")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("SheepVT (terminal emulator)") {
                    Text("built in — Packages/SheepVT")
                        .foregroundStyle(.secondary)
                }
                Text("Cryptography comes from macOS itself (CryptoKit, CommonCrypto, Security) and is updated with the system.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(4)
    }
}
