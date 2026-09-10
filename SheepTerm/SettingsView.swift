import AppKit
import CLibSSH
import Combine
import Synchronization
import SwiftUI
import UniformTypeIdentifiers

/// Checks whether the libraries this app carries have newer versions. There
/// are two — libssh and the OpenSSL it links (`libcrypto`) — and they are the
/// only code here we did not write; the terminal emulator is ours
/// (`Packages/SheepVT`). OpenSSL is the bigger of the two by nine times and
/// is the one with the busier advisory feed, so leaving it out of this check
/// answered the easy half of the question. The same two are declared in
/// `.ship.conf` (BUNDLED_LIBS), which is what `Tools/deps.sh` and the release
/// script read — keep the two lists in step.
@MainActor
final class LibraryUpdateChecker: ObservableObject {
    @Published var libsshStatus: String?
    @Published var checking = false

    /// What is linked into THIS running app, not what Homebrew has: libssh
    /// answers for itself, and OpenSSL's version is read out of the dylib the
    /// app bundles (its own release line is in the binary).
    var libsshInstalled: String {
        ssh_version(0).map { String(cString: $0) } ?? "unknown"
    }

    /// Read once, not on every redraw: this is shown from a SwiftUI body, and
    /// the scan below walks a 4.8 MB dylib. The version cannot change while the
    /// app is running — it is the copy inside this bundle.
    let opensslInstalled: String = LibraryUpdateChecker.readBundledOpenSSLVersion()

    private static func readBundledOpenSSLVersion() -> String {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("libcrypto.3.dylib"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "unknown" }
        // The release line ("OpenSSL 3.6.3 9 Jun 2026") sits in the string
        // table; scan for it rather than link another header in. `memmem` does
        // the walk — comparing with a freshly built Array per byte allocated
        // millions of times for one label.
        let needle = Array("OpenSSL 3.".utf8)
        return data.withUnsafeBytes { raw -> String in
            guard let base = raw.baseAddress, raw.count > needle.count else { return "unknown" }
            let hit = needle.withUnsafeBytes { n in
                memmem(base, raw.count, n.baseAddress, n.count)
            }
            guard let hit else { return "unknown" }
            let start = raw.baseAddress!.distance(to: hit)
            let bytes = raw.bindMemory(to: UInt8.self)
            var end = start
            while end < bytes.count, bytes[end] != 0, end - start < 64 { end += 1 }
            let line = String(decoding: bytes[start ..< end], as: UTF8.self)
            return line.split(separator: " ").dropFirst().first.map(String.init) ?? "unknown"
        }
    }

    func check() {
        checking = true
        libsshStatus = "checking…"
        // The bundled versions are read HERE, on the main actor, and handed
        // to the check: the question this button answers is whether the
        // libraries THIS APP CARRIES are behind, and only those two strings
        // can answer it. The old check ran `brew outdated` and reported its
        // verdict verbatim, which is a statement about the Homebrew
        // installation — a different copy of the library that the app does
        // not load. "Both up to date" was true of Homebrew while the bundle
        // could be a year behind.
        let bundledLibssh = libsshInstalled
        let bundledOpenSSL = opensslInstalled
        Task.detached { [weak self] in
            // Strong for the task's few seconds: the nested MainActor.run
            // closure may not capture the weak var (Swift 6 error).
            guard let self else { return }
            let verdict = Self.compareWithHomebrew(bundledLibssh: bundledLibssh,
                                                   bundledOpenSSL: bundledOpenSSL)
            await MainActor.run {
                self.libsshStatus = verdict
                self.checking = false
            }
        }
    }

    /// One `brew` run: what it printed and how it ended. `nil` = brew is not
    /// installed here at all.
    private struct BrewRun {
        let status: Int32
        let output: String
        let error: String
        let killed: Bool

        /// How to describe this run when the caller decides it failed —
        /// brew's own stderr if it said anything, else the exit status.
        /// Whether a non-zero status IS a failure is the caller's call:
        /// `brew outdated` exits 1 precisely because a formula is outdated.
        nonisolated var failureReason: String {
            error.isEmpty ? "exit \(status)\(killed ? ", killed after 10 s" : "")" : error
        }
    }

    nonisolated private static func runBrew(_ arguments: [String]) -> BrewRun? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        process.arguments = arguments
        // Auto-update fetches every tap — minutes on a slow link, which the
        // 10 s watchdog below would kill, turning a fine check into an error.
        // The hints go to stderr, which is the text a failure is reported
        // with, so silence those too.
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        // Watchdog: a stuck brew (lock file, network) must never hang the
        // settings UI — kill it after 10 s.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        // Drain stderr concurrently so a full stderr buffer can't block the
        // child, then read stdout BEFORE waiting — reading after
        // waitUntilExit deadlocks once the pipe buffer fills.
        // Kept for the failure message: brew says WHY on stderr, and without
        // it a failed check can only report a number. Bounded — a broken brew
        // can be very talkative.
        let errorText = Mutex("")
        let stderrDrain = DispatchWorkItem {
            let text = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            errorText.withLock { $0 = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
        }
        DispatchQueue.global().async(execute: stderrDrain)
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        stderrDrain.wait()
        process.waitUntilExit()
        let killed = !watchdog.isCancelled && !process.isRunning && process.terminationReason == .uncaughtSignal
        watchdog.cancel()
        return BrewRun(status: process.terminationStatus,
                       output: output,
                       error: errorText.withLock { $0 },
                       killed: killed)
    }

    /// The version numbers in a string, e.g. "0.12.2" out of "libssh 0.12.2"
    /// and out of libssh's own "0.12.2/openssl/zlib". Compared as numbers
    /// because the two sides are printed by different programs: Homebrew says
    /// `libssh 0.12.2`, `ssh_version` names its crypto and compression
    /// backends after the number, and a string compare of those two is a
    /// mismatch every single time.
    nonisolated private static func versionNumbers(in text: String) -> [[Int]] {
        text.split(whereSeparator: { !$0.isNumber && $0 != "." })
            .map { $0.split(separator: ".").compactMap { Int($0) } }
            .filter { $0.count >= 2 }
    }

    /// The highest version in `text` — `brew list --versions` prints EVERY
    /// installed version of a formula on one line, and the one that matters
    /// is the newest.
    nonisolated private static func highestVersion(in text: String) -> [Int]? {
        versionNumbers(in: text).max { lhs, rhs in lhs.lexicographicallyPrecedes(rhs) }
    }

    nonisolated private static func describe(_ version: [Int]) -> String {
        version.map(String.init).joined(separator: ".")
    }

    /// The line `brew list --versions` printed for one formula.
    nonisolated private static func brewLine(_ formula: String, in listing: String) -> String? {
        listing.split(separator: "\n").first { $0.hasPrefix(formula + " ") }.map(String.init)
    }

    /// Compares the two dylibs INSIDE THIS BUNDLE with what Homebrew has, and
    /// only then asks Homebrew whether it is itself behind. Three different
    /// answers were being conflated before; each one now gets its own words.
    nonisolated private static func compareWithHomebrew(bundledLibssh: String,
                                                        bundledOpenSSL: String) -> String {
        guard let listing = runBrew(["list", "--versions", "libssh", "openssl@3"]) else {
            return "Homebrew not found on this Mac — the bundled versions above are what the app loads"
        }
        // `brew list --versions` exits non-zero when one of the formulae is
        // not installed, having printed the others — that is an answer, not a
        // failure. Only an empty result (or the watchdog) means the run itself
        // told us nothing.
        guard !listing.killed, listing.status == 0 || !listing.output.isEmpty else {
            return "⚠️ could not check: \(listing.failureReason)"
        }
        var behind: [String] = []
        var notes: [String] = []
        var compared = 0
        // Which SIDE could not be read matters: "the app cannot say what it
        // is carrying" and "Homebrew does not have this formula" are
        // different situations and only one of them is about this app.
        for (formula, bundled) in [("libssh", bundledLibssh), ("openssl@3", bundledOpenSSL)] {
            guard let bundledVersion = highestVersion(in: bundled) else {
                notes.append("\(formula): the bundled copy does not report a version — nothing to compare")
                continue
            }
            guard let line = brewLine(formula, in: listing.output),
                  let brewVersion = highestVersion(in: String(line.dropFirst(formula.count))) else {
                notes.append("\(formula): Homebrew does not have it installed — nothing to compare")
                continue
            }
            compared += 1
            if bundledVersion.lexicographicallyPrecedes(brewVersion) {
                behind.append("\(formula): bundled \(describe(bundledVersion)) < Homebrew \(describe(brewVersion))")
            }
        }
        // Homebrew's own state, asked separately and labelled as such — it is
        // about the installation in /opt/homebrew, not about this app.
        let outdated = runBrew(["outdated", "--verbose", "libssh", "openssl@3"])
        var brewNote = ""
        if let outdated {
            if !outdated.output.isEmpty {
                // `brew outdated` exits 1 precisely BECAUSE something is
                // outdated. Treating that as a failed run (the old code did)
                // made this branch unreachable: every real update available
                // was reported as "could not check: exit 1".
                brewNote = "\nHomebrew's own copy has an update pending: \(outdated.output) — `brew upgrade` before rebuilding."
            } else if outdated.status != 0 || outdated.killed {
                brewNote = "\nHomebrew's own update check failed: \(outdated.failureReason)"
            }
        }
        let asides = (notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n")) + brewNote
        if behind.isEmpty {
            // Never "up to date" on the strength of a comparison that did not
            // happen — the one thing this button must not do is say
            // everything is fine when it does not know.
            guard compared > 0 else {
                return "⚠️ could not compare the bundled libraries with Homebrew." + asides
            }
            return "✅ the \(compared == 2 ? "libraries" : "library") this app bundles"
                + " \(compared == 2 ? "are" : "is") no older than what Homebrew has installed"
                + " (vs the local brew index — run `brew update` to refresh)." + asides
        }
        return "⬆️ the app is carrying older libraries than Homebrew has:\n"
            + behind.joined(separator: "\n")
            + "\nRun ./Tools/deps.sh update, which upgrades, rebuilds and names the gates to run." + asides
    }

}

/// Settings (⌘,). Highlight rules are fixed built-ins now, so the window has
/// only the one pane — the chrome, sidebar, connection, backup and library
/// sections.
struct SettingsView: View {
    var body: some View {
        GeneralSettingsView()
            .frame(width: 700, height: 500)
    }
}

/// General settings: appearance, terminal look, auto-reconnect, library updates.
struct GeneralSettingsView: View {
    @ObservedObject private var model = AppModel.shared
    @StateObject private var updates = LibraryUpdateChecker()
    @AppStorage("showRecents") private var showRecents = true
    @AppStorage("recentsShown") private var recentsShown = 5
    @AppStorage(ChromeStyle.storageKey) private var chromeStyle = ChromeStyle.glass

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
                LabeledContent("libssh (bundled)") {
                    Text(updates.libsshInstalled)
                        .font(.system(size: 12, design: .monospaced))
                }
                LabeledContent("OpenSSL (bundled)") {
                    Text(updates.opensslInstalled)
                        .font(.system(size: 12, design: .monospaced))
                }
                if let status = updates.libsshStatus {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("SheepVT (terminal emulator)") {
                    Text("built in — Packages/SheepVT")
                        .foregroundStyle(.secondary)
                }
                Button {
                    updates.check()
                } label: {
                    if updates.checking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(updates.checking)
            }
        }
        .formStyle(.grouped)
        .padding(4)
    }
}
