import AppKit
import Combine
import SheepVTRender
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SessionTab: ObservableObject, Identifiable {
    enum Content {
        case local(LocalTerminalController)
        case ssh(SSHTerminalController)
        case serial(SerialTerminalController)
    }

    let id = UUID()
    let content: Content
    @Published var title: String
    @Published var statusInfo: String?
    @Published var highlightEnabled = false {
        didSet {
            switch content {
            case .ssh(let controller): controller.setHighlightEnabled(highlightEnabled)
            case .serial(let controller): controller.setHighlightEnabled(highlightEnabled)
            case .local: return
            }
            // The default for the NEXT tab follows whichever toggle was used
            // last — ⇧⌘H, the status-bar sheep, or the tab's context menu.
            // Two of the three used to write it and the third did not.
            UserDefaults.standard.set(highlightEnabled, forKey: "highlightDefault")
        }
    }
    /// Highlight rule pack for this tab. Starts from the host and can be
    /// switched live (View menu, status bar) for a console you turn out to be
    /// on a different box than you thought — a serial cable does not announce
    /// its vendor, and neither does a jump host.
    @Published var highlightVendor: Vendor = .auto {
        didSet {
            switch content {
            case .ssh(let controller): controller.adoptVendor(highlightVendor)
            case .serial(let controller): controller.adoptVendor(highlightVendor)
            case .local: break
            }
        }
    }
    /// True once the family is the user's own pick (menu / status bar) or a
    /// saved host's explicit `vendor`. Passive stream detection is disabled
    /// while this is set — even for an explicit `.auto` — so a deliberate
    /// choice is never silently overridden. The auto-detect path leaves it
    /// false, so a later manual pick still wins.
    var vendorManuallyChosen = false
    var wasConnected = false
    var autoReconnectAttempts = 0
    /// Guards the recent-host entry to exactly one write per connect:
    /// password auth notes it via rememberSessionPassword, key-only SSH
    /// and serial note it on the first success status.
    var didNoteRecent = false

    init(content: Content, title: String) {
        self.content = content
        self.title = title
    }
}

struct QuickConnectRequest: Identifiable {
    let id = UUID()
    let kind: ConnectionKind
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}


/// Read once. `ProcessInfo.environment` builds a fresh dictionary on every
/// access, and a tracer that is off should cost a boolean.
private let uiTraceEnabled = ProcessInfo.processInfo.environment["SHEEPTERM_CLICKLOG"] == "1"

/// Shared UI tracer, off unless `SHEEPTERM_CLICKLOG=1`. Added after two wrong
/// guesses about a click-timing bug: measuring beats reasoning about AppKit.
@MainActor
func uiTrace(_ what: @autoclosure () -> String) {
    guard uiTraceEnabled else { return }
    FileHandle.standardError.write("[ui \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] \(what())\n".data(using: .utf8)!)
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var tabs: [SessionTab] = []
    @Published var selectedID: UUID?
    // Launch clean like Terminal.app — the sidebar opens with ⌘0 or the
    // toolbar button when needed.
    @Published var sidebarShown = false
    // Persisted by the resize handle's drag .onEnded — writing UserDefaults
    // in a didSet here would hit disk on every drag frame.
    @Published var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "sidebarWidth")
        return saved == 0 ? 232 : min(max(saved, 200), 320)
    }()
    @Published var quickConnect: QuickConnectRequest?
    @Published var showCredentials = false
    @Published var showReorderGroups = false
    @Published var sessionLogging: Bool {
        didSet {
            UserDefaults.standard.set(sessionLogging, forKey: "logSessions")
        }
    }
    @Published var autoReconnect = true {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }
    @Published var safePasteEnabled = true {
        didSet {
            UserDefaults.standard.set(safePasteEnabled, forKey: "safePasteEnabled")
            guard !safePasteEnabled else { return }
            for tab in tabs {
                switch tab.content {
                case .ssh(let controller):
                    controller.terminalHost.cancelSafePaste(reason: .stopped)
                case .serial(let controller):
                    controller.terminalHost.cancelSafePaste(reason: .stopped)
                case .local:
                    break
                }
            }
        }
    }
    @Published var appearanceMode: AppearanceMode = .system {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
            NSApp.appearance = appearanceMode.appearance
        }
    }
    @Published var showStatusBar = true {
        didSet { UserDefaults.standard.set(showStatusBar, forKey: "showStatusBar") }
    }
    @Published var statusShowSession = true {
        didSet { UserDefaults.standard.set(statusShowSession, forKey: "statusShowSession") }
    }
    @Published var statusShowHints = true {
        didSet { UserDefaults.standard.set(statusShowHints, forKey: "statusShowHints") }
    }
    @Published var statusShowIP = true {
        didSet { UserDefaults.standard.set(statusShowIP, forKey: "statusShowIP") }
    }
    @Published var statusShowClock = true {
        didSet { UserDefaults.standard.set(statusShowClock, forKey: "statusShowClock") }
    }
    @Published var terminalTheme = "sheepterm" {
        didSet {
            UserDefaults.standard.set(terminalTheme, forKey: "terminalTheme")
            reapplyTerminalTheme()
        }
    }

    // Terminal font — see Theme.swift for why these exist. Each setter writes
    // the default Theme.terminalFont reads and pushes the result to every tab.
    @Published var terminalFontFamily: String = Theme.systemFontFamily {
        didSet {
            UserDefaults.standard.set(terminalFontFamily, forKey: Theme.fontFamilyKey)
            reapplyTerminalTheme()
        }
    }
    @Published var terminalFontSize: Double = Theme.defaultFontSize {
        didSet {
            let clamped = Theme.clampFontSize(terminalFontSize)
            if clamped != terminalFontSize { terminalFontSize = clamped; return }
            UserDefaults.standard.set(terminalFontSize, forKey: Theme.fontSizeKey)
            reapplyTerminalTheme()
        }
    }
    @Published var terminalFontWeight: Theme.TerminalFontWeight = Theme.defaultFontWeight {
        didSet {
            UserDefaults.standard.set(terminalFontWeight.rawValue, forKey: Theme.fontWeightKey)
            reapplyTerminalTheme()
        }
    }
    @Published var terminalFontSmoothing: Bool = Theme.defaultFontSmoothing {
        didSet {
            UserDefaults.standard.set(terminalFontSmoothing, forKey: Theme.fontSmoothingKey)
            reapplyTerminalTheme()
        }
    }

    /// View → Terminal Font → Bigger / Smaller (⌘+ / ⌘−), like Terminal.app.
    func stepTerminalFontSize(_ delta: Double) {
        terminalFontSize = Theme.clampFontSize(terminalFontSize + delta)
    }

    /// Pushes the current theme AND font (Settings → Terminal) onto every
    /// open terminal. A font change makes the view re-measure its cells and
    /// resize the grid, which reaches the remote end through the existing
    /// sizeChanged path — nothing else to do here.
    func reapplyTerminalTheme() {
        for tab in tabs {
            switch tab.content {
            case .local(let controller): Theme.apply(to: controller.terminalView)
            case .ssh(let controller): Theme.apply(to: controller.terminalView)
            case .serial(let controller): Theme.apply(to: controller.terminalView)
            }
        }
    }

    let store = HostStore()
    let credentialStore = CredentialStore()
    private var dataWarningSubscriptions = Set<AnyCancellable>()
    /// Session-lifetime memory of passwords that worked (keyed
    /// user@host:port) so reconnects don't ask again. Never written to disk.
    private var passwordCache: [String: String] = [:]

    private init() {
        // Our tab strip replaces native window tabbing entirely.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Suppress the macOS input-source switch panel for this app: the
        // terminal view can't anchor the small caret badge, so the system
        // would show the big centered language panel on every switch. The
        // menu-bar input icon still shows the current language.
        UserDefaults.standard.set(false, forKey: "TSMLanguageIndicatorEnabled")
        sessionLogging = UserDefaults.standard.object(forKey: "logSessions") as? Bool ?? true
        autoReconnect = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true
        safePasteEnabled = UserDefaults.standard.object(forKey: "safePasteEnabled") as? Bool ?? true
        appearanceMode = AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? ""
        ) ?? .system
        NSApp.appearance = appearanceMode.appearance
        terminalTheme = UserDefaults.standard.string(forKey: "terminalTheme") ?? "sheepterm"
        terminalFontFamily = Theme.terminalFontFamily
        terminalFontSize = Double(Theme.terminalFontSize)
        terminalFontWeight = Theme.terminalFontWeight
        terminalFontSmoothing = Theme.terminalFontSmoothing
        showStatusBar = UserDefaults.standard.object(forKey: "showStatusBar") as? Bool ?? true
        // Session text (device IP + username), shortcut hints and This-Mac IP
        // start HIDDEN — the bar shows just the connection dot, the highlight
        // sheep/vendor control and the clock until the user opts them back in
        // (View → Bottom Bar Items).
        statusShowSession = UserDefaults.standard.object(forKey: "statusShowSession") as? Bool ?? false
        statusShowHints = UserDefaults.standard.object(forKey: "statusShowHints") as? Bool ?? false
        statusShowIP = UserDefaults.standard.object(forKey: "statusShowIP") as? Bool ?? false
        statusShowClock = UserDefaults.standard.object(forKey: "statusShowClock") as? Bool ?? true
        // Launched from Finder the cwd is "/"; start shells at home like Terminal.app.
        FileManager.default.changeCurrentDirectoryPath(NSHomeDirectory())
        // hosts.json / recents.json unreadable at launch: the file is kept as
        // .corrupt-<timestamp> and writes are held until the next edit — and
        // for two releases nothing SAID so (`dataLoadWarning` had no reader;
        // ARCHITECTURE claimed it was shown). Every group vanishing with no
        // dialog is indistinguishable from data loss. Deferred off `init` for
        // the reason `CredentialStore` defers its own.
        // Observed, not read once: the warning is also set at SAVE time, when
        // a merge finds the file changed underneath us and unreadable
        // (`quarantineUnreadable`), and after a restore's `reloadFromDisk`.
        // A one-shot read at launch left those two with no audience.
        store.$dataLoadWarning
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { warning in
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Saved hosts could not be read"
                alert.informativeText = warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            .store(in: &dataWarningSubscriptions)
        purgeTeamShareLeftovers()
        // The highlight rules and their colours are fixed built-in constants
        // now. Compile the per-vendor packs once, here — there is no Settings
        // UI left to recompile them, so nothing ever calls this again.
        Highlighter.installDefaults()
        newLocalTab()
        installKeyMonitor()
    }

    /// Pulls every setting and every store back in after BackupManager has
    /// written a restored configuration over the live files. The window
    /// stays put and open sessions keep running — only the configuration
    /// changes underneath them.
    func reloadAfterRestore() {
        let defaults = UserDefaults.standard
        sessionLogging = defaults.object(forKey: "logSessions") as? Bool ?? true
        autoReconnect = defaults.object(forKey: "autoReconnect") as? Bool ?? true
        safePasteEnabled = defaults.object(forKey: "safePasteEnabled") as? Bool ?? true
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        terminalTheme = defaults.string(forKey: "terminalTheme") ?? "sheepterm"
        terminalFontFamily = Theme.terminalFontFamily
        terminalFontSize = Double(Theme.terminalFontSize)
        terminalFontWeight = Theme.terminalFontWeight
        terminalFontSmoothing = Theme.terminalFontSmoothing
        showStatusBar = defaults.object(forKey: "showStatusBar") as? Bool ?? true
        statusShowSession = defaults.object(forKey: "statusShowSession") as? Bool ?? false
        statusShowHints = defaults.object(forKey: "statusShowHints") as? Bool ?? false
        statusShowIP = defaults.object(forKey: "statusShowIP") as? Bool ?? false
        statusShowClock = defaults.object(forKey: "statusShowClock") as? Bool ?? true
        let width = defaults.double(forKey: "sidebarWidth")
        sidebarWidth = width == 0 ? 232 : min(max(width, 200), 320)
        store.reloadFromDisk()
        credentialStore.reloadFromDisk()
    }

    /// Team Share (LAN sharing + vault + team passphrase) was removed after
    /// the round-3 review; purge its leftovers so old installs don't carry
    /// them forever: the vault path/skip defaults, the plaintext-passphrase
    /// and KDF-salt defaults orphaned by earlier builds, and the Keychain
    /// team-passphrase item. Host passwords (same Keychain service, UUID
    /// accounts) are NOT touched.
    private func purgeTeamShareLeftovers() {
        for key in ["teamVaultPath", "teamVaultSkippedFiles", "teamPassphrase", "teamKeySalt"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Bestchaan.SheepTerm",
            kSecAttrAccount as String: "team-passphrase",
        ] as CFDictionary)
    }

    func exportGroup(_ group: HostGroup) {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: "sheepterm") {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "\(group.name).sheepterm"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ShareCodec.encode(group, sender: ShareCodec.deviceName)
            try data.write(to: url, options: .atomic)
        } catch {
            // `try?` here meant a full disk or a read-only folder produced no
            // file and no word — the panel closed as if it had worked.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The group could not be exported"
            alert.informativeText = "\(url.lastPathComponent): \(error.localizedDescription)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Opening a .sheepterm file (Finder double-click, `open`, drag onto the
    /// Dock icon). Routed through the app delegate rather than SwiftUI's
    /// `.onOpenURL`, because WindowGroup answers an opened document by
    /// spawning a SECOND window — and two windows share AppModel.shared and
    /// the very same TerminalView instances, so the terminal blanks and
    /// reparents between them.
    func importFile(at url: URL) {
        // Case-insensitively: the Import menu goes through UTType, which does
        // not care, and a file called `.SHEEPTERM` used to open silently.
        guard url.pathExtension.lowercased() == "sheepterm" else { return }
        guard let payload = decodeImport(at: url) else { return }
        // Never import silently — same confirmation as the menu path.
        confirmImport(payload)
    }

    func importGroupViaPanel() {
        let panel = NSOpenPanel()
        if let type = UTType(filenameExtension: "sheepterm") {
            panel.allowedContentTypes = [type, .json]
        }
        guard panel.runModal() == .OK, let url = panel.url,
              let payload = decodeImport(at: url) else { return }
        confirmImport(payload)
    }

    /// A file that cannot be read or decoded used to do NOTHING — no dialog,
    /// no log — which for a double-clicked .sheepterm looks like the app
    /// ignored the click. Say what went wrong instead.
    private func decodeImport(at url: URL) -> SharePayload? {
        do {
            return try ShareCodec.decode(try Data(contentsOf: url))
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not import \(url.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }
    }

    /// Forgets the session-cached password for one connection. The cache is
    /// keyed user@address:port and lived until quit, so a credential the
    /// user DELETED, or a host whose identity was edited, kept authenticating
    /// with the old password for the rest of the session.
    func forgetCachedPassword(for host: Host) {
        passwordCache.removeValue(forKey: "\(host.username)@\(host.address):\(host.port)")
    }

    func forgetCachedPasswords(forCredential id: UUID) {
        for host in store.groups.flatMap(\.hosts) where host.credentialID == id {
            forgetCachedPassword(for: host)
        }
    }

    /// Quit: every SSH/serial worker stopped and every log closed and
    /// flushed before the process exits. Synchronous by design — there is
    /// no "later" after applicationShouldTerminate returns.
    ///
    /// Two phases, and the split is the whole reason this is not a one-liner.
    /// Phase 1 starts every tab's shutdown without waiting for any of it, so
    /// the fifteenth tab's log close is queued microseconds after the first
    /// one's. Phase 2 then waits for all of them against ONE pair of absolute
    /// deadlines. The old shape did both per tab, in a loop, so a bound that
    /// was honest for one tab was paid once per tab by the user who had more.
    /// Measured against ten tabs on a volume that never completes a write:
    /// 35.0 s unbounded, 17.1 s bounded per tab (2 s × tabs in the worst
    /// case), 2.0 s this way. Ten healthy tabs: 0.002 s.
    func shutdownSessionsForQuit() {
        // Phase 1 — nothing here waits. See `beginShutdownForQuit`.
        var flushes: [QuitLogFlush] = []
        for tab in tabs {
            switch tab.content {
            case .ssh(let controller): flushes.append(controller.beginShutdownForQuit())
            case .serial(let controller): flushes.append(controller.beginShutdownForQuit())
            case .local: break          // no worker, no log
            }
        }
        guard !flushes.isEmpty else { return }

        // Phase 2 — one budget for the whole quit, taken once, in
        // `QuitLogFlush.waitForAll` (there rather than here so that
        // Tests/backpressure can run the real thing against real loggers).
        let unflushed = QuitLogFlush.waitForAll(flushes)
        guard !unflushed.isEmpty else { return }
        reportUnflushedLogs(unflushed)
    }

    /// A log whose tail could not be written is evidence that is quietly
    /// missing — the one failure in this whole path the user cannot see for
    /// themselves, and would otherwise meet weeks later as a file that stops
    /// mid-sentence. Said once, at the end of the quit, naming the sessions:
    /// an NSAlert because it is the last moment anything of ours is on
    /// screen, and the same idiom `askAboutLiveSessions` already uses for the
    /// other question ⌘Q has to ask. It only ever appears when a volume
    /// stopped accepting writes.
    private func reportUnflushedLogs(_ unflushed: [QuitLogFlush]) {
        let names = unflushed.map(\.session)
        // Per log, which of the three things happened, because they point at
        // different parts of the file: the volume refused a write at some
        // point (the hole is wherever that was — an hour ago, with the tail
        // landed fine; the session was told at the time), the shutdown threw
        // away output the session had already received (an amount, at the
        // end), or the last writes never landed (too slow). The first used
        // to be reported with the third's words, sending the user to the
        // wrong end of the file.
        func detail(_ flush: QuitLogFlush) -> String {
            if flush.writesWereRefused {
                return "a write was refused earlier in the session, so the file has a hole"
            }
            if flush.droppedBytes > 0 {
                // "up to": the count is an upper bound by at most one chunk
                // (the one between being refused and being released is in
                // both terms of the reading), and the alert must not present
                // a bound as a measurement.
                return "up to \(ByteCountFormatter.string(fromByteCount: Int64(flush.droppedBytes), countStyle: .file)) of output at the end not written"
            }
            return "the last writes did not land in time"
        }
        // The post-mortem copy: an alert is dismissed and gone, and this is
        // the half that is still there tomorrow.
        NSLog("SheepTerm: quit could not complete %d session log(s) — %@",
              names.count,
              unflushed.map { "\($0.session) (\(detail($0)))" }.joined(separator: ", "))
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = names.count == 1
            ? "The end of one session log could not be written."
            : "The end of \(names.count) session logs could not be written."
        let listed = unflushed.prefix(8).map { flush in
            var line = "• \(flush.session)"
            if let name = flush.logName { line += " — \(name)" }
            return line + " (\(detail(flush)))"
        }.joined(separator: "\n")
        let more = unflushed.count > 8 ? "\n• and \(unflushed.count - 8) more" : ""
        alert.informativeText = """
            \(names.count == 1 ? "This log does not match its session." : "These logs do not match their sessions.") \
            SheepTerm waited up to \(Int(QuitLogFlush.budget)) seconds for the disk before quitting. \
            What each one is missing:

            \(listed)\(more)
            """
        alert.addButton(withTitle: "OK")
        // …but not when the Mac is logging out, restarting or shutting down.
        // This alert asks nothing — it reports. A modal that reports during a
        // restart does not inform anybody: nobody is looking at the screen,
        // macOS shows "SheepTerm cancelled the restart", and the restart the
        // user asked for does not happen until they come back and dismiss a
        // dialog about a log file. The NSLog above is the copy that survives
        // and is the one they would read afterwards anyway. A quit the user
        // typed still gets the alert, because then they ARE looking.
        guard !Self.quitIsFromLogoutOrRestart() else { return }
        alert.runModal()
    }

    /// Why this quit happened, as far as the Apple Event says. `nil` for ⌘Q
    /// and for the red button — those carry no reason, which is exactly the
    /// case where someone is at the keyboard.
    ///
    /// The MECHANISM this rests on, so nobody removes it by accident: the
    /// answer is only there while the quit Apple Event is being dispatched.
    /// `applicationShouldTerminate` calls `shutdownSessionsForQuit` and this
    /// synchronously, on the main thread, inside that dispatch — a nested
    /// `runModal` is still on the same stack. If the quit ever becomes
    /// `.terminateLater` with the flush continued asynchronously,
    /// `currentAppleEvent` is nil by the time this runs, the guard passes,
    /// and the alert is back to cancelling restarts with no test to say so.
    /// Keep the quit path synchronous, or carry the reason across yourself.
    private static func quitIsFromLogoutOrRestart() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue
        else { return false }
        switch Int(reason) {
        case Int(kAELogOut), Int(kAEReallyLogOut), Int(kAEShowRestartDialog),
             Int(kAERestart), Int(kAEShowShutdownDialog), Int(kAEShutDown):
            return true
        default:
            return false
        }
    }

    /// Shared guard for every .sheepterm import path (menu panel, Finder
    /// double-click): nothing is imported without an explicit accept, and
    /// duplicates are resolved by the user — never silently (spec 0.4).
    func confirmImport(_ payload: SharePayload) {
        var group = payload.group
        let sender = Self.sanitizedForDialog(payload.sender)
        // Control characters in a stored group or host name would break the
        // sidebar — strip them from the value itself, not just the dialog.
        // Host names reach further than the group name does: the sidebar, the
        // tab title, and SessionLogger's file name — which only replaces "/"
        // and ":". `ConfigurationHygiene` also narrows a port that is not a
        // port; it is the SAME pass `BackupManager` runs on a restore, so the
        // two ways someone else's file becomes your configuration cannot
        // drift apart again.
        var groups = [group]
        let hygiene = ConfigurationHygiene.sanitize(&groups, emptyGroupName: "Imported Group")
        group = groups[0]
        // Not silent: a name that was trimmed or a baud that was replaced is
        // still the user's data, and they get to see which of it changed
        // before they accept the import.
        let corrections = hygiene.summary.map { "\n\n\($0)" } ?? ""

        guard let existing = store.existingGroup(matching: group) else {
            let alert = NSAlert()
            alert.messageText = "Import group?"
            alert.informativeText = "“\(group.name)” (\(group.hosts.count) hosts) from \(sender) will be added as a new group. Passwords are not included.\(corrections)"
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                _ = store.applyImport(group, action: .createNew, replace: [:])
            }
            return
        }

        // 0.4 (ก): duplicate group — three choices, both host counts shown.
        let alert = NSAlert()
        alert.messageText = "Group “\(existing.name)” already exists"
        alert.informativeText = """
        Your group has \(existing.hosts.count) hosts — the file from \(sender) contains \(group.hosts.count) hosts.

        Merge adds new hosts to your group and asks about each conflicting host. Create New Group imports it as a separate numbered group. Passwords are not included.\(corrections)
        """
        alert.addButton(withTitle: "Merge into Existing")
        alert.addButton(withTitle: "Create New Group")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            resolveImportConflicts(group, into: existing)
        case .alertSecondButtonReturn:
            _ = store.applyImport(group, action: .createNew, replace: [:])
        default:
            break
        }
    }

    /// 0.4 (ข): ask Replace/Keep for each conflicting host, showing what
    /// differs, with an apply-to-all checkbox. Nothing is written until
    /// every conflict has an answer — Cancel aborts the whole import.
    private func resolveImportConflicts(_ incoming: HostGroup, into existing: HostGroup) {
        let conflicts = store.conflictingHosts(incoming: incoming, existing: existing)
        var decisions: [UUID: Bool] = [:]
        var applyToAll: Bool?
        for (index, pair) in conflicts.enumerated() {
            if let applyToAll {
                decisions[pair.incoming.id] = applyToAll
                continue
            }
            let alert = NSAlert()
            alert.messageText = "Host “\(Self.sanitizedForDialog(pair.incoming.name))” exists in both"
            alert.informativeText = Self.importDiffDescription(incoming: pair.incoming, existing: pair.existing)
                + "\n\nReplace uses the file's version — your saved password reference is kept. Keep leaves your version untouched."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Keep")
            alert.addButton(withTitle: "Cancel Import")
            let remaining = conflicts.count - index - 1
            let checkbox = NSButton(
                checkboxWithTitle: "Apply to the remaining \(remaining) conflicting host(s)",
                target: nil, action: nil
            )
            alert.accessoryView = checkbox
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return } // abort — nothing written yet
            let replace = response == .alertFirstButtonReturn
            decisions[pair.incoming.id] = replace
            if checkbox.state == .on { applyToAll = replace }
        }
        _ = store.applyImport(incoming, action: .merge, replace: decisions)
    }

    /// 0.4 (ค)5: file-sourced text shown in a dialog is stripped of
    /// control characters and capped at 64 characters. This is the DIALOG
    /// half — the sender line and the diff rows, which are not stored
    /// anywhere. The rule itself lives in `ConfigurationHygiene`, so what is
    /// SHOWN and what is SAVED can never disagree about it.
    private static func sanitizedForDialog(_ text: String) -> String {
        ConfigurationHygiene.sanitizedName(text)
    }

    /// 0.4 (ข): shows exactly which fields differ between the two entries.
    private static func importDiffDescription(incoming: Host, existing: Host) -> String {
        var diffs: [String] = []
        if incoming.name != existing.name {
            diffs.append("name: \(sanitizedForDialog(existing.name)) → \(sanitizedForDialog(incoming.name))")
        }
        if incoming.address != existing.address {
            diffs.append("address: \(sanitizedForDialog(existing.address)) → \(sanitizedForDialog(incoming.address))")
        }
        if incoming.port != existing.port {
            diffs.append("port: \(existing.port) → \(incoming.port)")
        }
        if incoming.username != existing.username {
            diffs.append("username: \(sanitizedForDialog(existing.username)) → \(sanitizedForDialog(incoming.username))")
        }
        // Effective values, as `sameForImport` compares them — nil IS auto,
        // and a line reading "cipher: auto → auto" explained nothing.
        if (incoming.cipherMode ?? .auto) != (existing.cipherMode ?? .auto) {
            diffs.append("cipher: \((existing.cipherMode ?? .auto).rawValue) → \((incoming.cipherMode ?? .auto).rawValue)")
        }
        // `sameForImport` raises a conflict on the family, so the dialog has
        // to be able to name it — a family-only difference used to read
        // "The two entries differ." and nothing else.
        if incoming.highlightVendor != existing.highlightVendor {
            diffs.append("device family: \(existing.highlightVendor.label) → \(incoming.highlightVendor.label)")
        }
        if (incoming.agentForward ?? false) != (existing.agentForward ?? false) {
            let label = { (on: Bool) in on ? "on" : "off" }
            diffs.append("agent forwarding: \(label(existing.agentForward ?? false)) → \(label(incoming.agentForward ?? false))")
        }
        return diffs.isEmpty
            ? "The two entries differ."
            : "Differences (yours → file):\n" + diffs.joined(separator: "\n")
    }

    var selectedTab: SessionTab? {
        tabs.first { $0.id == selectedID }
    }

    /// Keyboard focus belongs to the terminal, like Terminal.app — sidebar
    /// clicks must not strand it on the List (a non-text view leaves the
    /// input-source switcher HUD with no caret to anchor to, so macOS shows
    /// the big centered panel instead of the small caret badge).
    func focusActiveTerminal() {
        guard let tab = selectedTab else { return }
        let view: NSView
        switch tab.content {
        case .local(let controller): view = controller.terminalView
        case .ssh(let controller): view = controller.terminalView
        case .serial(let controller): view = controller.terminalView
        }
        view.window?.makeFirstResponder(view)
    }

    /// The selected tab's terminal view, whatever kind of session it is —
    /// all three sessions host the same `SheepVTRender.TerminalView`.
    var activeTerminalView: TerminalView? {
        guard let tab = selectedTab else { return nil }
        switch tab.content {
        case .local(let controller): return controller.terminalView
        case .ssh(let controller): return controller.terminalView
        case .serial(let controller): return controller.terminalView
        }
    }

    /// Find in scrollback. SheepVT ships the search engine AND the find bar
    /// (`FindBar`, anchored top-trailing inside the terminal view) wired to
    /// the standard `performTextFinderAction:` responder action — the menu
    /// items just have to reach it. The action is sent STRAIGHT to the
    /// terminal view rather than down the responder chain from nil: with the
    /// sidebar search field or the find bar's own field focused, chain
    /// dispatch would land somewhere else entirely.
    private func sendFinderAction(_ action: NSTextFinder.Action) {
        guard let view = activeTerminalView else { return }
        // The view reads the requested action off the sender's tag, so the
        // sender has to be a tagged NSMenuItem.
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: view, from: sender)
    }

    func showFind() { sendFinderAction(.showFindInterface) }
    func findNextMatch() { sendFinderAction(.nextMatch) }
    func findPreviousMatch() { sendFinderAction(.previousMatch) }
    func useSelectionForFind() { sendFinderAction(.setSearchString) }

    /// Discards the lines that scrolled off the top; the visible screen and
    /// the shell's own state are left alone (same meaning as Terminal.app's
    /// Clear Scrollback, not a reset).
    func clearScrollback() {
        activeTerminalView?.clearScrollback()
    }

    /// SSH/serial tabs that are still up — what a quit would actually cut.
    /// A tab with no status yet is mid-connect, which counts: killing it
    /// loses the session just the same.
    var liveRemoteSessions: [SessionTab] {
        tabs.filter { tab in
            switch tab.content {
            case .local: return false
            case .ssh, .serial:
                guard let status = tab.statusInfo else { return true }
                return !status.hasPrefix("disconnected")
            }
        }
    }

    func newLocalTab() {
        // Inherit the working directory of the active local tab (Terminal.app
        // behavior); shells report cwd via OSC 7.
        if let tab = selectedTab, case .local(let current) = tab.content,
           let directory = current.currentDirectoryPath {
            FileManager.default.changeCurrentDirectoryPath(directory)
        }
        let controller = LocalTerminalController()
        let shellName = (LocalTerminalController.userShell() as NSString).lastPathComponent
        let tab = SessionTab(content: .local(controller), title: "\(shellName) — This Mac")
        controller.onTitleChange = { [weak tab] title in
            guard let tab, !title.isEmpty else { return }
            tab.title = title
        }
        controller.onExit = { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            self.close(tab: tab)
        }
        tabs.append(tab)
        selectedID = tab.id
        controller.start()
    }

    /// The one way in for a connection. `completeness` says whether `host` is
    /// an ANSWER (every field is what the user chose, nil included) or a
    /// TARGET (a recents row, a sidebar entry, a typed `user@host`) whose
    /// missing credential/cipher/family may be filled from the saved host on
    /// the same endpoint — see `HostCompleteness`. The default is the
    /// historical behaviour; Quick Connect's Connect button and a reconnect
    /// are the callers that say `.complete`.
    func open(host: Host, completeness: HostCompleteness = .needsCompletion,
              password overridePassword: String? = nil, serialLog: Bool? = nil,
              reusingLogger: SessionLogger? = nil) {
        switch host.kind {
        case .local:
            newLocalTab()
        case .ssh:
            // A target inherits credential/username/cipher/family from the
            // saved host on the same endpoint; an answer is taken as it is.
            // The rule itself is `Host.completed`, out where Tests/tests can
            // run it — it decides which password a session authenticates with.
            var host = host.completed(from: store.groups.flatMap(\.hosts), when: completeness)
            let credential = host.credentialID.flatMap { credentialStore.credential(for: $0) }
            // The credential names the login its password belongs to, so it
            // wins over a username stored beside it — not only when that one
            // is empty. Both forms now save the pair together, but hosts.json
            // still holds entries written while Edit Host paired a new
            // credential with the old username, and connecting as one
            // identity with another's password fails in the least readable
            // way there is: "Access denied" from a name that is spelled right.
            if let credential, !credential.username.isEmpty {
                host.username = credential.username
            }
            let password = overridePassword
                ?? credential.flatMap { credentialStore.password(for: $0) }
                ?? passwordCache["\(host.username)@\(host.address):\(host.port)"]
            let controller = SSHTerminalController(host: host, password: password, reusingLogger: reusingLogger)
            let tab = SessionTab(content: .ssh(controller), title: host.name)
            tab.highlightVendor = host.highlightVendor
            // A saved host with an explicit family is the user's choice —
            // passive detection must never override it. But `.auto` (nil OR a
            // stored literal `auto`, which recents.json carries) is NOT a
            // choice: it means "detect for me", so it must leave detection
            // armed. Only a concrete family suppresses.
            if let v = host.vendor, v != .auto {
                tab.vendorManuallyChosen = true
                controller.suppressVendorDetection()
            }
            // Passive detection names a family via the AUTO path: it sets the
            // tab's vendor (one repaint) without marking it a manual choice.
            controller.onVendorDetected = { [weak tab] detected in
                guard let tab, !tab.vendorManuallyChosen else { return }
                tab.highlightVendor = detected
            }
            tab.highlightEnabled = UserDefaults.standard.object(forKey: "highlightDefault") as? Bool ?? true
            controller.onStatus = { [weak tab, weak self] status in
                guard let tab else { return }
                tab.statusInfo = status
                if status.hasPrefix("ssh2") {
                    tab.wasConnected = true
                    // Note the recent only AFTER the connect succeeded —
                    // noting it at open() time recorded hosts that never
                    // connected. Password auth already noted it via
                    // rememberSessionPassword, so this covers key-only
                    // auth; didNoteRecent keeps it to one write per connect.
                    if !tab.didNoteRecent,
                       case .ssh(let sshController) = tab.content,
                       !sshController.didAuthenticateWithPassword {
                        tab.didNoteRecent = true
                        // The controller's copy carries a username typed at
                        // the prompt; the one captured here may be empty.
                        self?.store.noteRecent(sshController.host)
                    }
                    // "ssh2" means auth succeeded, but the device may still
                    // refuse the shell (VTY full) — resetting attempts here
                    // would loop a 2 s reconnect forever. Reset only if this
                    // session is still alive 30 s later (a dropped one shows
                    // "disconnected"; a reconnected one is a new tab id).
                    let tabID = tab.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                        guard let current = self?.tabs.first(where: { $0.id == tabID }),
                              current.statusInfo?.hasPrefix("ssh2") == true else { return }
                        current.autoReconnectAttempts = 0
                    }
                } else if status == "disconnected" {
                    self?.scheduleAutoReconnect(for: tab)
                }
            }
            tabs.append(tab)
            selectedID = tab.id
            controller.start()
        case .serial:
            let controller = SerialTerminalController(host: host, reusingLogger: reusingLogger)
            controller.logOverride = serialLog
            let tab = SessionTab(content: .serial(controller), title: host.name)
            tab.highlightVendor = host.highlightVendor
            // A saved host with an explicit family is the user's choice —
            // passive detection must never override it. But `.auto` (nil OR a
            // stored literal `auto`, which recents.json carries) is NOT a
            // choice: it means "detect for me", so it must leave detection
            // armed. Only a concrete family suppresses.
            if let v = host.vendor, v != .auto {
                tab.vendorManuallyChosen = true
                controller.suppressVendorDetection()
            }
            // Passive detection names a family via the AUTO path: it sets the
            // tab's vendor (one repaint) without marking it a manual choice.
            controller.onVendorDetected = { [weak tab] detected in
                guard let tab, !tab.vendorManuallyChosen else { return }
                tab.highlightVendor = detected
            }
            tab.highlightEnabled = UserDefaults.standard.object(forKey: "highlightDefault") as? Bool ?? true
            controller.onStatus = { [weak tab, weak self] status in
                guard let tab else { return }
                tab.statusInfo = status
                // The port is open only when this status arrives — note the
                // recent now, not at open() time; a failed open must not be
                // recorded (and must not be written twice).
                if status.hasPrefix("serial ·") {
                    tab.wasConnected = true
                    if !tab.didNoteRecent {
                        tab.didNoteRecent = true
                        self?.store.noteRecent(host)
                    }
                    // Same 30 s rule as SSH: a port that opens and dies right
                    // back (half-seated cable, switch rebooting) must not
                    // reset the attempt counter, or the retries never stop.
                    let tabID = tab.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                        guard let current = self?.tabs.first(where: { $0.id == tabID }),
                              current.statusInfo?.hasPrefix("serial ·") == true else { return }
                        current.autoReconnectAttempts = 0
                    }
                } else if status == "disconnected" {
                    // A console cable pulled mid-reboot is exactly what
                    // auto-reconnect is for; the EBUSY retry in SerialWorker
                    // covers the moment the old descriptor is still open.
                    self?.scheduleAutoReconnect(for: tab)
                }
            }
            tabs.append(tab)
            selectedID = tab.id
            controller.start()
        }
    }

    func rememberSessionPassword(_ password: String, forUser user: String, host: Host) {
        guard !password.isEmpty else { return }
        passwordCache["\(user)@\(host.address):\(host.port)"] = password
        var resolved = host
        resolved.username = user
        store.noteRecent(resolved)
    }

    func openQuickConnect(_ kind: ConnectionKind) {
        quickConnect = QuickConnectRequest(kind: kind)
    }

    /// Opens an ad-hoc connection; when `groupName` is given the session is
    /// also saved into that sidebar group (created if needed). A password
    /// typed in the form is used for this session even when not saved.
    func connectQuick(host: Host, saveTo groupName: String?, password: String? = nil, serialLog: Bool? = nil) {
        if let groupName {
            saveSession(host: host, toGroupNamed: groupName)
        }
        // `.complete`: the form answered every question. "Enter manually" with
        // no password means ask me, "Auto" means detect — neither is a hole to
        // fill from a saved host on the same endpoint, which is what happened
        // when nil meant both (recheck finding 3: the session came up on the
        // saved Cisco host's credential with detection off, and the Update
        // Saved Host prompt ran a turn later and could not have fixed it).
        open(host: host, completeness: .complete, password: password, serialLog: serialLog)
        collapseSidebar()
    }

    /// The "Save session to group" half of Quick Connect.
    ///
    /// The duplicate check used to compare address+port+username and then, on
    /// a match, do NOTHING — no add, no update — while the session opened with
    /// the new values anyway. Changing the name, the credential, the cipher or
    /// the device family and saving to the same group therefore looked like it
    /// worked, and was gone the moment the host was opened from the sidebar
    /// instead. The match also ignored the connection KIND — harmless only
    /// because the sheet's group picker is SSH-only today, which is exactly
    /// the kind of accident that stops being harmless quietly. `sameConnection`
    /// (Models) is the one definition of "same target" in this app — the same
    /// one recents dedup by — and it includes the kind.
    private func saveSession(host: Host, toGroupNamed groupName: String) {
        // Saving from Quick Connect is a user action, so it has to re-arm
        // writes the same way every HostStore mutator does — this path
        // reaches into `groups` directly and used to skip that, which
        // under post-corrupt suppression meant the new group appeared in
        // the sidebar and was never written to disk.
        guard let index = store.groups.firstIndex(where: { $0.name == groupName }) else {
            store.noteExplicitUserMutation()
            store.groups.append(HostGroup(name: groupName, hosts: [host]))
            store.save()
            return
        }
        guard let existing = store.groups[index].hosts.first(where: { $0.sameConnection(as: host) }) else {
            store.noteExplicitUserMutation()
            store.groups[index].hosts.append(host)
            store.save()
            return
        }
        // Same target, already saved. Keep the entry's own id: the sidebar
        // rows and everything else holding a host id are keyed on it, and a
        // fresh id would read as a delete plus an insert.
        var updated = host
        updated.id = existing.id
        // The Session name field is optional and the form fills it with the
        // address (or the device leaf) when it is left empty. That is not a
        // name the user asked to save, so it neither counts as a change nor
        // renames a saved host: nobody ticks "save to group" expecting
        // “Core Switch” to become 10.0.0.1.
        if isGeneratedName(host) { updated.name = existing.name }
        let changes = Self.savedHostChanges(from: existing, to: updated)
        // Nothing differs — the common "connect again to a host I already
        // saved" case. Silence is the right answer only HERE.
        guard !changes.isEmpty else { return }
        // Deferred a turn, for the reason SidebarView.reportNameTaken is:
        // this runs from the sheet's Connect button while the sheet is still
        // on screen, and an alert stacked on a sheet is a mess.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "“\(Self.sanitizedForDialog(existing.name))” is already saved in “\(Self.sanitizedForDialog(groupName))”"
            alert.informativeText = "This session connects to the same target with different settings.\n\n"
                + changes.joined(separator: "\n")
                + "\n\nUpdate rewrites the saved host; Keep leaves it alone. Either way this session opens with the settings you just entered."
            alert.addButton(withTitle: "Update Saved Host")
            alert.addButton(withTitle: "Keep Saved Host")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            // updateHost finds the entry by id, carries matching recents over,
            // re-arms writes and saves.
            self.store.updateHost(updated)
        }
    }

    /// True when this host's name is the one the form invents for an empty
    /// Session name field: the address for SSH, the device leaf for serial.
    private func isGeneratedName(_ host: Host) -> Bool {
        host.name == host.address || host.name == (host.address as NSString).lastPathComponent
    }

    /// What saving this session would change about the host already in the
    /// group, in words. Empty = the two say the same thing, so there is
    /// nothing to ask about. Compared as EFFECTIVE values (a nil cipher is
    /// auto, a nil agentForward is off, a nil vendor is auto) — an entry
    /// written before one of those fields existed must not read as a change
    /// for the rest of its life.
    private static func savedHostChanges(from existing: Host, to incoming: Host) -> [String] {
        var changes: [String] = []
        if incoming.name != existing.name {
            changes.append("name: \(sanitizedForDialog(existing.name)) → \(sanitizedForDialog(incoming.name))")
        }
        if incoming.credentialID != existing.credentialID {
            let label = { (id: UUID?) in id == nil ? "none" : "saved credential" }
            changes.append("credential: \(label(existing.credentialID)) → \(label(incoming.credentialID))")
        }
        if (incoming.cipherMode ?? .auto) != (existing.cipherMode ?? .auto) {
            changes.append("cipher: \((existing.cipherMode ?? .auto).label) → \((incoming.cipherMode ?? .auto).label)")
        }
        if (incoming.agentForward ?? false) != (existing.agentForward ?? false) {
            let label = { (on: Bool) in on ? "on" : "off" }
            changes.append("agent forwarding: \(label(existing.agentForward ?? false)) → \(label(incoming.agentForward ?? false))")
        }
        if incoming.highlightVendor != existing.highlightVendor {
            changes.append("device family: \(existing.highlightVendor.label) → \(incoming.highlightVendor.label)")
        }
        return changes
    }

    func close(tab: SessionTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        switch tab.content {
        case .local(let controller):
            controller.detach()
        case .ssh(let controller):
            controller.stop()
        case .serial(let controller):
            controller.stop()
        }
        tabs.remove(at: index)
        if selectedID == tab.id {
            selectedID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    /// The policy lives in `ReconnectBudget` (Models) so it can be tested
    /// without a window; this is only where it is consulted.
    private var reconnectBudget = ReconnectBudget()

    /// A session that had connected successfully and then dropped gets up to
    /// three automatic reconnect attempts (2 s / 5 s / 10 s backoff). Serial
    /// counts too — a console cable on a rebooting switch drops exactly the
    /// same way an SSH session does.
    private func scheduleAutoReconnect(for tab: SessionTab) {
        guard autoReconnect else { return }
        let host: Host
        switch tab.content {
        case .ssh(let controller): host = controller.host
        case .serial(let controller): host = controller.host
        case .local: return
        }
        let attempts = tab.autoReconnectAttempts
        guard attempts < 3 else {
            // Say so. Three silent failures and then nothing looks exactly
            // like a tab that is still trying, and the user waits for a
            // reconnect that is never coming.
            tab.statusInfo = "disconnected — auto-reconnect gave up"
            return
        }
        // Never loop on a session that failed its very first connect
        // (wrong password / unreachable) — only revive proven sessions.
        guard tab.wasConnected || attempts > 0 else { return }
        // Overall cap on top of the per-drop limit: at most 10 drops per host
        // per hour are recovered from automatically.
        guard reconnectBudget.claim(host: host, attempt: attempts) else {
            tab.statusInfo = "disconnected — auto-reconnect limit reached"
            return
        }

        let delay = [2.0, 5.0, 10.0][attempts]
        let tabID = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Re-check the setting, not just the tab: the user may have turned
            // auto-reconnect off during the 2/5/10 s wait, and a queued block
            // must not connect anyway.
            guard let self, self.autoReconnect,
                  let current = self.tabs.first(where: { $0.id == tabID }),
                  current.statusInfo == "disconnected" else { return }
            let focusBefore = self.selectedID
            self.reconnect(tab: current)
            if let newTab = self.selectedTab {
                newTab.autoReconnectAttempts = attempts + 1
                newTab.wasConnected = true
                // Don't steal focus if the user was working in another tab.
                if focusBefore != tabID {
                    self.selectedID = focusBefore
                }
            }
        }
    }

    /// Tears down an SSH/serial tab and opens a fresh session to the same
    /// host, keeping the tab's position in the strip.
    func reconnect(tab: SessionTab) {
        // A stale caller — a context menu left open across an automatic
        // reconnect — must not open a SECOND session to the host and take
        // the log file out from under the one already running.
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        var host: Host
        var serialLog: Bool?
        var handedLogger: SessionLogger?
        switch tab.content {
        case .ssh(let controller):
            host = controller.host
            // Keep the same log file across the reconnect — a fresh file
            // per attempt scatters one session over N logs.
            handedLogger = controller.handOverLogger()
        case .serial(let controller):
            host = controller.host
            // Carry the per-session logging choice into the new session.
            serialLog = controller.logOverride
            handedLogger = controller.handOverLogger()
        case .local: return
        }
        // The successor tab is rebuilt from scratch, so its highlight state
        // would revert to defaults — throwing away a device family the user
        // picked (or that was auto-detected) mid-session, and the on/off
        // toggle. Carry all three across. (A tab left on .auto with no manual
        // choice will simply re-detect on the reconnected stream anyway.)
        let oldVendor = tab.highlightVendor
        let oldManual = tab.vendorManuallyChosen
        let oldHighlightEnabled = tab.highlightEnabled
        // A family the FINGERPRINT chose is written onto `controller.host` by
        // `adoptVendor`, so `open` would read it as a saved choice and switch
        // detection off for good on the successor — while the tab flag said
        // it was nobody's choice. Open with `.auto`, then hand the family and
        // the provisional lock to the new controller below.
        let carriedAuto = !oldManual && oldVendor != .auto
        if carriedAuto { host.vendor = .auto }
        let index = tabs.firstIndex { $0.id == tab.id }
        close(tab: tab)
        // `.complete`: the controller's host is the one this session actually
        // connected with, completed once already if it was ever a target.
        // Running the lookup again against today's store is how a session
        // that said "Enter manually" drifted onto a saved credential on its
        // reconnect (recheck finding 3); the password it authenticated with is
        // in `passwordCache`, keyed on this very host.
        open(host: host, completeness: .complete, serialLog: serialLog, reusingLogger: handedLogger)
        if let newTab = tabs.last {
            newTab.vendorManuallyChosen = oldManual
            // An explicit choice (including an explicit .auto) must keep
            // passive detection OFF on the new controller too.
            if oldManual {
                switch newTab.content {
                case .ssh(let controller): controller.suppressVendorDetection()
                case .serial(let controller): controller.suppressVendorDetection()
                case .local: break
                }
            }
            // didSet on these re-applies the family (adoptVendor → repaint if
            // enabled) and the on/off state; once the session connects, the
            // onStatus/onData path schedules the first paint.
            newTab.highlightVendor = oldVendor
            if carriedAuto {
                switch newTab.content {
                case .ssh(let controller): controller.carryAutoDetected(oldVendor)
                case .serial(let controller): controller.carryAutoDetected(oldVendor)
                case .local: break
                }
            }
            // Carrying the toggle over is not the user toggling: the didSet
            // writes `highlightDefault` for the NEXT tab, and an automatic
            // reconnect of a tab the user had switched off was silently
            // changing the default for every tab after it. Put it back.
            let defaultBefore = UserDefaults.standard.object(forKey: "highlightDefault")
            newTab.highlightEnabled = oldHighlightEnabled
            UserDefaults.standard.set(defaultBefore, forKey: "highlightDefault")
            if let index, tabs.count > 1, index < tabs.count - 1 {
                tabs.removeLast()
                tabs.insert(newTab, at: index)
            }
        }
    }

    func closeCurrentTab() {
        if let tab = selectedTab {
            close(tab: tab)
        }
        // Closing the last TAB does not close the window. It used to, back
        // when a closed window merely left the app running invisibly; now that
        // the window is the app's life, that made ⇧⌘W on a single tab quit
        // SheepTerm outright. The window has a designed empty state
        // (`EmptyPaneView`) — landing on it is the honest result of closing
        // the last tab, and ⌘Q or the close button are still how you quit.
    }

    func selectTab(number: Int) {
        let index = number - 1
        if tabs.indices.contains(index) {
            selectedID = tabs[index].id
            // ⌘1–9 must hand keyboard focus to the newly shown terminal.
            // The view attaches on the next SwiftUI pass, so focus one
            // runloop tick later — same pattern as the sidebar rows.
            DispatchQueue.main.async { [weak self] in self?.focusActiveTerminal() }
        }
    }

    func selectAdjacentTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedID } ?? 0
        let next = (current + offset + tabs.count) % tabs.count
        selectedID = tabs[next].id
        DispatchQueue.main.async { [weak self] in self?.focusActiveTerminal() }
    }

    /// ⌘⇧H — flips display highlighting for the active SSH/serial session.
    /// Switches the visible tab's highlight pack.
    ///
    /// The choice is remembered on the host too, so the next connect starts
    /// there — a serial console you had to identify by eye should only need
    /// identifying once. Everything already on screen is RE-coloured, which
    /// is the whole reason highlighting moved into the grid; on a full
    /// scrollback that repaint costs ~200 ms of main thread.
    func setHighlightVendorCurrent(_ vendor: Vendor) {
        guard let tab = selectedTab else { return }
        // A local shell has no vendor: nothing below applies to it, and
        // recording a manual choice and a highlightVendor for it only left
        // state that reads as if something had happened. The menu disables the
        // item too; this is the half that cannot be reached around.
        if case .local = tab.content { return }
        // Mark the choice as the user's BEFORE changing the vendor, and stop
        // passive detection on the controller — a deliberate pick (including
        // an explicit Auto) must never be undone by the stream fingerprint.
        tab.vendorManuallyChosen = true
        switch tab.content {
        case .ssh(let controller):
            controller.suppressVendorDetection()
            store.setVendor(vendor, matching: controller.host)
        case .serial(let controller):
            controller.suppressVendorDetection()
            store.setVendor(vendor, matching: controller.host)
        case .local: break
        }
        tab.highlightVendor = vendor
    }

    func toggleHighlightCurrent() {
        guard let tab = selectedTab else { return }
        switch tab.content {
        case .ssh, .serial:
            tab.highlightEnabled.toggle() // didSet records the new default
        case .local:
            break
        }
    }

    func toggleSidebar() {
        sidebarShown.toggle()
        // Closing the sidebar must hand keyboard focus back to the
        // terminal — a sidebar-less window with focus stranded on the
        // (now hidden) List leaves the input-source HUD with no caret.
        if !sidebarShown {
            DispatchQueue.main.async { [weak self] in self?.focusActiveTerminal() }
        }
    }

    @Published var showQuickSearch = false

    /// Sidebar auto-collapses once a session is opened from it,
    /// giving the terminal the full window (expand again with ⌘0).
    func collapseSidebar() {
        sidebarShown = false
        DispatchQueue.main.async { [weak self] in self?.focusActiveTerminal() }
    }

    private func installKeyMonitor() {
        // ⌘W closes the tab (not the window) and ⌘T always opens a local shell,
        // matching Terminal.app; the menu items keep the shortcuts discoverable.
        //
        // ⇧⌘H is here for a different reason: the application menu's Hide
        // (⌘H) wins the key-equivalent match against View → Toggle
        // Highlighting, so pressing ⇧⌘H HID THE APP instead of flipping the
        // colors. A local monitor sees the event before menu dispatch, which
        // is the only way to keep the documented shortcut.
        // The token is dropped on purpose: the monitor lives for the whole run
        // of the app and is never removed.
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Caps Lock (and the keypad/function bits) are in
            // `deviceIndependentFlagsMask` and are not part of the chord:
            // with Caps Lock on, `flags == .command` was false, the event
            // went to menu dispatch, and ⌘W became File → Close (the window)
            // while ⇧⌘H became Hide — the two mistakes this monitor exists
            // to prevent.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            guard flags == .command || flags == [.command, .shift] else { return event }
            // On non-Latin layouts (Thai) charactersIgnoringModifiers is the
            // native glyph ("ธ" for the T key), so matching it alone makes
            // ⌘T/⌘W/⇧⌘H dead whenever the input source is Thai. With ⌘ held,
            // `characters` carries the layout's Latin command plane — fall
            // back to it when the primary string isn't ASCII.
            var characters = event.charactersIgnoringModifiers?.lowercased()
            if characters?.allSatisfy(\.isASCII) != true {
                characters = event.characters?.lowercased()
            }
            guard let characters, characters.allSatisfy(\.isASCII) else { return event }
            // Only intercept in the main terminal window — never inside
            // sheets, auth panels, or the Settings window.
            //
            // Through the shared `isMainTerminalWindow`, not a second copy of
            // the same three tests. A review claimed the copy was a hole — a
            // SwiftUI sheet passing as the main window, so ⌘W would close a
            // tab behind an open form. Measured on this macOS with a probe app
            // of the same shape, it is not: the sheet comes back as a real
            // `NSSheet` (`isSheet == true`) and does NOT carry
            // `.fullSizeContentView`, so both the old copy and this helper
            // exclude it. What is left is the reason to share one predicate
            // anyway — two heuristics that must agree cannot be kept in step
            // by hoping.
            let isMainWindow = MainActor.assumeIsolated {
                guard let key = NSApp?.keyWindow else { return false }
                return isMainTerminalWindow(key)
            }
            guard isMainWindow else { return event }
            switch (flags, characters) {
            case (.command, "w"):
                MainActor.assumeIsolated { AppModel.shared.closeCurrentTab() }
                return nil
            case (.command, "t"):
                MainActor.assumeIsolated { AppModel.shared.newLocalTab() }
                return nil
            case ([.command, .shift], "h"):
                MainActor.assumeIsolated { AppModel.shared.toggleHighlightCurrent() }
                return nil
            default:
                return event
            }
        }
    }
}
