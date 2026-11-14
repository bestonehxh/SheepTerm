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

/// How wide the sidebar is (6.1 (20)–(22), the owner's numbers): the width
/// follows the tree the sidebar shows — a level-7 row at 200 pt was an
/// indent and three letters. Levels count the top-level group: up to 2 =
/// the user's own width (233 until they drag), 3–4 = at least 243, 5–6 =
/// at least 253, 7 = at least 263 (a level steps in 10 pt; the owner picked
/// these in 6.1 (53) from a trial menu; 233 since 6.1 (54), the steps from it
/// since 6.1 (55)). The user may still drag wider, never
/// under the tree's floor. Nothing is stored for it: the `sidebarWidth`
/// setting stays the user's own, so an older build reads the same number.
nonisolated enum SidebarWidth {
    static let range: ClosedRange<Double> = 200...320
    static let standard: Double = 233

    /// The user's width from the stored setting (0 = never dragged).
    static func own(stored: Double) -> Double {
        stored == 0 || !stored.isFinite ? standard : min(max(stored, range.lowerBound), range.upperBound)
    }

    /// The least width a tree `levels` deep is drawn at (1 = groups only).
    static func floor(levels: Int) -> Double {
        switch levels {
        case ...2: return range.lowerBound
        case 3...4: return 243
        case 5...6: return 253
        default: return 263
        }
    }

    /// The user's own width after dragging the edge to `width`, the tree's
    /// floor being `floor`: wider than the floor is theirs; at or under it
    /// the tree is what holds the sidebar there, so their own width stays
    /// what it was (never raised to the floor — a deep tree deleted must
    /// give their narrow sidebar back).
    static func dragged(own: Double, floor: Double, to width: Double) -> Double {
        width > floor ? min(width, range.upperBound) : min(own, floor)
    }

    /// The width drawn.
    static func shown(own: Double, levels: Int) -> Double { max(own, floor(levels: levels)) }
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
