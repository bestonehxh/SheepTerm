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
