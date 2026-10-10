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
                    AppModel.shared.importFile(at: url)
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
        let live = AppModel.shared.liveRemoteSessions
        guard !live.isEmpty else { return .nothingToAsk }
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = live.count == 1
            ? "Quit SheepTerm? One session is still open."
            : "Quit SheepTerm? \(live.count) sessions are still open."
        let names = live.prefix(8).map { "• \($0.title)" }.joined(separator: "\n")
        let more = live.count > 8 ? "\n• and \(live.count - 8) more" : ""
        alert.informativeText = "Quitting closes \(live.count == 1 ? "it" : "them") right away.\n\n\(names)\(more)"
        let quit = alert.addButton(withTitle: "Quit")
        let cancel = alert.addButton(withTitle: "Cancel")
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
        case .local, nil: return false
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
            Button("New Serial Console…") { model.openQuickConnect(.serial) }
            // Main window only — while Settings is key, ⌘⇧W must not close
            // a terminal tab in the background.
            Button("Close Tab") { model.closeCurrentWorkspace() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!mainWindowKey.isKey)
            Divider()
            Button("Credentials…") { model.showCredentials = true }
            Button("Known Hosts…") { model.openKnownHosts() }
            Divider()
            Toggle("Log Sessions to File", isOn: $model.sessionLogging)
            Button("Open Logs Folder") {
                NSWorkspace.shared.open(SessionLogger.logsDirectory)
            }
            Button("Search Logs…") { model.showLogSearch = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Import Group…") { model.importGroupViaPanel() }
            Divider()
            Button("Back Up Configuration…") { BackupManager.backUp() }
            Button("Restore Configuration…") { BackupManager.restore() }
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Toggle("Safe Multi-line Paste", isOn: $model.safePasteEnabled)
            // A break condition on a serial console (a boot loader's "press
            // Break now"). Greyed out everywhere else: SSH and a local shell
            // have no line to put one on.
            Button("Send Break") { model.sendBreak() }
                .keyboardShortcut("b", modifiers: [.control, .option])
                .disabled(!model.canSendBreak)
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
                    Toggle(family.label, isOn: Binding(
                        get: { model.selectedTab?.highlightVendor == family },
                        set: { _ in model.setHighlightVendorCurrent(family) }
                    ))
                }
            } label: {
                Label("Device Family", systemImage: "cpu")
            }
            .disabled(!isRemoteSessionSelected)
            Button {
                model.clearScrollback()
            } label: {
                Label("Clear Scrollback", systemImage: "eraser")
            }
            // ⌘K already belongs to Quick Connect here, so this takes ⌘L.
            // Only the history above the screen goes — the visible screen and
            // the remote session are untouched.
            .keyboardShortcut("l", modifiers: .command)
            .disabled(model.selectedTab == nil)
            Divider()
            Toggle(isOn: $model.showStatusBar) {
                Label("Show Bottom Bar", systemImage: "rectangle.bottomthird.inset.filled")
            }
            Menu {
                Toggle("Session Info", isOn: $model.statusShowSession)
                Toggle("Shortcut Hints", isOn: $model.statusShowHints)
                Toggle("This Mac IP", isOn: $model.statusShowIP)
                Toggle("Clock", isOn: $model.statusShowClock)
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
                Button("Bigger") { model.stepTerminalFontSize(1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Smaller") { model.stepTerminalFontSize(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Default Size (\(Int(Theme.defaultFontSize)) pt)") {
                    model.terminalFontSize = Theme.defaultFontSize
                }
                Divider()
                Toggle(Theme.fontFamilyLabel(Theme.systemFontFamily), isOn: Binding(
                    get: { model.terminalFontFamily == Theme.systemFontFamily },
                    set: { _ in model.terminalFontFamily = Theme.systemFontFamily }
                ))
                ForEach(Theme.availableMonospaceFamilies, id: \.self) { family in
                    Toggle(family, isOn: Binding(
                        get: { model.terminalFontFamily == family },
                        set: { _ in model.terminalFontFamily = family }
                    ))
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
                        .disabled(model.selectedTab == nil)
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
                .disabled(model.selectedTab == nil || !mainWindowKey.isKey)
            Button("Split Down") { model.splitFocusedPane(.down) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.selectedTab == nil || !mainWindowKey.isKey)
            Button("Close Pane") { model.closeCurrentTab() }
                .disabled(model.selectedTab == nil)
            // Also by dragging the pane's header onto the empty tab strip.
            Button("Move Pane to New Tab") { model.moveFocusedPaneToNewTab() }
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
