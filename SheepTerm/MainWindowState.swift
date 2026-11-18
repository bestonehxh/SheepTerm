import Combine
import Foundation

/// A sheet on the main window (6.1 (62)). Every form the app shows over the
/// window — Add Host, Edit Host, Credentials, Known Hosts, … — is a SwiftUI
/// sheet, and a menu shortcut still reaches the menu while one is up: ⌘N
/// over a half-typed Add Host replaced it (the typed form gone), ⌘N over
/// Credentials queued a second sheet that popped up on its own once the
/// first closed, and ⌘0 took the sidebar away with the sheet it presented.
/// `MainWindowKeyMonitor.sheetUp` follows the main window's own sheet
/// notifications through this rule; the menu commands that present a sheet
/// are disabled while it is true. The sidebar's hiding reads only its own
/// sheets (`sidebarMayHide`).
nonisolated enum SheetGate {
    enum Event: Sendable { case willBegin, didEnd }

    /// "A sheet is up on the main window" after a sheet notification. Only the
    /// main window's own notifications move it: a confirm opened from inside a
    /// sheet begins and ends on the SHEET's window, and the main window's sheet
    /// is still up when it goes.
    static func sheetUp(after event: Event, onMainWindow: Bool, was: Bool) -> Bool {
        guard onMainWindow else { return was }
        return event == .willBegin
    }

    /// The sheets the SIDEBAR presents: they live in its view tree and go
    /// with it, edits and all, when it hides.
    enum SidebarSheet: Hashable, Sendable {
        case editHost, renameGroup, newGroup, newSubgroup, groupIcon, workspace
    }

    /// Which of them are presented, from the sidebar's own bindings
    /// (`SidebarView` hands the result to `AppModel.sidebarSheets`).
    static func sidebarSheets(editHost: Bool, renameGroup: Bool, newGroup: Bool, newSubgroup: Bool,
                              groupIcon: Bool, workspace: Bool) -> Set<SidebarSheet> {
        var up = Set<SidebarSheet>()
        if editHost { up.insert(.editHost) }
        if renameGroup { up.insert(.renameGroup) }
        if newGroup { up.insert(.newGroup) }
        if newSubgroup { up.insert(.newSubgroup) }
        if groupIcon { up.insert(.groupIcon) }
        if workspace { up.insert(.workspace) }
        return up
    }

    /// Hiding the sidebar (⌘0, or a session opening with Keep Sidebar Open
    /// off) waits only while one of its OWN sheets is up. Not any sheet on
    /// the window (`sheetUp`): Quick Connect ▸ Connect asks to hide while its
    /// sheet is still closing (didEndSheet comes after the animation), so the
    /// sidebar stopped folding on connect, and ⌘0 beeped over Credentials or
    /// What's New, which nothing loses when the sidebar goes (review 6.1 (62)).
    static func sidebarMayHide(sidebarSheets: Set<SidebarSheet>) -> Bool { sidebarSheets.isEmpty }
}

/// The main window's full-screen state, ONE source for the views that place
/// themselves round the traffic lights (6.1 (62), UI review). `TopBarView`
/// owns the reading — its own window only, healed from that window's
/// notifications and styleMask (ARCHITECTURE §2) — and mirrors it here; the
/// sidebar's top gap follows it. The sidebar used to keep its own copy that
/// heard EVERY window's will*FullScreen (Logs or the Guide going full screen
/// moved the main sidebar's gap) and read `NSApp.keyWindow` at onAppear (nil
/// on a relaunch straight into full screen: a blank 36 pt band until the
/// next toggle).
@MainActor final class MainWindowFullScreen: ObservableObject {
    static let shared = MainWindowFullScreen()
    @Published private(set) var isOn = false

    /// Writes only a change: the top bar heals on didResize, per frame.
    func set(_ on: Bool) {
        if on != isOn { isOn = on }
    }

    /// Whether a window notification moves a top bar's OWN spacer. Until the
    /// top bar knows its window, any window counts — a restore straight into
    /// full screen must not lose its will*/did* pair (§2); once known, only
    /// it. That reading stays local until `writes` says it may be shared.
    nonisolated static func counts(_ noteWindow: AnyObject?, host: AnyObject?) -> Bool {
        guard let host else { return true }
        return noteWindow === host
    }

    /// Whether a top bar's reading may be written HERE: only once it knows its
    /// window and that window is the main one. A top bar with no window yet
    /// (its reading may come from any window's notification) or in another
    /// window (the DEBUG top-bar picture's offscreen one wrote `false` on
    /// appear) never moves the shared state (review 6.1 (62)).
    nonisolated static func writes<W: AnyObject>(host: W?, isMain: (W) -> Bool) -> Bool {
        guard let host else { return false }
        return isMain(host)
    }
}
