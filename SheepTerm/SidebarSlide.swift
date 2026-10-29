import Foundation

/// A web page beside the left sidebar (5.0 (27)): the page's frame starts
/// where it would with the sidebar CLOSED and runs under the sidebar; WebKit
/// is told that strip is covered (`obscuredContentInsets.left`), so the page
/// lays itself out in the visible part only.
///
/// Why: WebKit paints a resize a frame or two late and pins that late
/// picture to the frame's LEFT edge. The right AI panel never showed it —
/// the page's left edge stays put and the late part is on the right, under
/// the panel. The left sidebar moved the page's left edge every frame, so
/// the late picture was drawn at the wrong place on the uncovered right
/// (measured: the right edge kicked 54 px; pinning the width instead made
/// centred content jump once). With the frame's left edge fixed in the
/// window, the left sidebar now behaves exactly like the right panel: only
/// the covered strip changes, and the page's right edge never moves.
nonisolated enum SidebarCover {
    /// How much of the page the sidebar covers: how far the pane sits right
    /// of where it sits with the sidebar closed. Whole points, never negative.
    static func cover(paneLeft: Double, closedLeft: Double) -> Double {
        max(0, (paneLeft - closedLeft).rounded())
    }
}

/// Settings ▸ Sidebar ▸ Show Sidebar at Launch (6.0 (12)): off = today's
/// launch (clean, like Terminal.app; ⌘0 opens it). A per-Mac layout choice
/// like `sidebarWidth`: in a backup, never synced
/// (`SheepTermSync.localOnlySettings`).
nonisolated enum SidebarLaunch {
    static let key = "sidebarAtLaunch"

    /// Whether the window starts with the sidebar open: only a stored true
    /// (never set, or anything else = off).
    static func shown(stored: Any?) -> Bool {
        (stored as? Bool) == true
    }
}

/// View ▸ Sidebar / Settings ▸ Sidebar ▸ Keep Sidebar Open (6.0 (13)): off
/// (the default) = today's behaviour — opening a session from the sidebar,
/// ＋, Quick Connect, Quick Search, a USB console's shadow tab… closes the
/// sidebar (`AppModel.collapseSidebar`, the ONE path every one of them takes);
/// on = it stays open. ⌘0 / Toggle Sidebar still closes it by hand. Per-Mac
/// like `sidebarAtLaunch`: in a backup, never synced.
nonisolated enum SidebarKeepOpen {
    static let key = "sidebarStaysOpen"

    /// Whether opening a session closes the sidebar: yes unless a stored
    /// true says keep it (never set, or anything else = today's auto-close).
    static func closesOnOpen(stored: Any?) -> Bool {
        (stored as? Bool) != true
    }
}
