import AppKit
import Combine
import Synchronization
import SwiftUI
import UniformTypeIdentifiers

/// Settings (⌘,). Highlight rules are fixed built-ins now, so the window has
/// only the one pane — the chrome, sidebar, connection, backup and library
/// sections.
struct SettingsView: View {
    var body: some View {
        GeneralSettingsView()
            .frame(width: 700, height: 500)
    }
}

/// General settings: appearance, terminal look, auto-reconnect, backup, libraries.
struct GeneralSettingsView: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage("showRecents") private var showRecents = true
    @AppStorage("recentsShown") private var recentsShown = 5
    @AppStorage(ChromeStyle.storageKey) private var chromeStyle = ChromeStyle.glass
    @AppStorage(SessionTerminalHost.clipboardWriteKey) private var allowClipboardWrite = false

    var body: some View {
        Form {
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
                    ForEach(Theme.availableMonospaceFamilies, id: \.self) { family in
                        Text(family).tag(family)
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
                Text("Applied to every open tab immediately; the grid re-measures, so columns and rows change with it. Also in View → Terminal Font, with ⌘+ / ⌘− for the size. On a display running a scaled resolution (the 13″ Air's stock 1470 × 956 is one) the whole screen is resampled before it reaches the eye, and a larger or heavier face survives that better than a thin one; Termius draws roughly 14 pt Semibold. Font smoothing is macOS's stroke thickening: on it makes light-on-dark text bolder with a soft grey edge, off (the default) draws thinner, cleaner stems — the same edge the Claude app's text has.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Sidebar") {
                Toggle("Show Recent", isOn: $showRecents)
                Stepper(value: $recentsShown, in: 1...HostStore.maxRecents) {
                    LabeledContent("Recent entries shown") {
                        Text("\(recentsShown)")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .disabled(!showRecents)
                Text("Hides the whole Recent section — header included. SheepTerm remembers at most \(HostStore.maxRecents) recent connections, so that is the ceiling here too.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                Toggle("Auto-reconnect dropped sessions", isOn: $model.autoReconnect)
                Text("When a session that had been working drops, reconnect automatically (3 tries: 2 s / 5 s / 10 s). Serial counts: a console cable on a rebooting switch drops exactly the way an SSH session does. SSH sessions also send a keepalive every 60 s to survive device idle-timeouts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                Toggle("Allow remote programs to set the clipboard (OSC 52)", isOn: $allowClipboardWrite)
                Text("Lets vim or tmux on a device copy into the Mac's clipboard. Off by default: a compromised device could plant a command for your next ⌘V. When on, pasting text a session set always asks first. Reading the clipboard is never allowed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
