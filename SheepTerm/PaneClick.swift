import CoreGraphics

/// A click anywhere else drops a terminal's selection (6.0 (14)).
///
/// The terminal clears its selection on a plain click IN itself
/// (`TerminalView.mouseDown`); a selection in one split pane stayed
/// highlighted while the user clicked another pane, a pane header, the tab
/// strip, the sidebar, the status bar or the window background. The pane
/// tree watches left presses in its window (`PaneTreeView`, a local event
/// monitor — the SheepVT package knows nothing about panes) and asks this.
/// Menus and the menu bar are other windows, and the keyboard is not a
/// press, so ⌘C from the Edit menu still copies.
nonisolated enum SelectionDrop {
    /// A left press at `click` drops the selection of the terminal at
    /// `terminal` (both in the window's coordinates) when the press is in the
    /// same window and lands outside the terminal. The find bar and a
    /// connection card are subviews of the terminal, so a press there is
    /// inside; the terminal's own clicks are its own business (a shift-click
    /// extends the selection).
    static func clears(click: CGPoint, terminal: CGRect, sameWindow: Bool) -> Bool {
        sameWindow && !terminal.isEmpty && !terminal.contains(click)
    }
}

/// The hover look the tab strip's chips and the split-pane headers share
/// (6.0 (14)): one source, so the two stay the same.
nonisolated enum ChipHover {
    /// The disc under the pointer on a chip's ×: the primary colour at this
    /// opacity, this wide (the tab strip's `xmark`, the pane header's ×).
    static let closeDiscOpacity: Double = 0.12
    static let closeDiscSize: CGFloat = 18
    /// A hovered, unselected tab chip: `Theme.tabActive` at this opacity —
    /// darker than the strip's chrome, half-way to the selected chip.
    static let tabChipOpacity: Double = 0.5
    /// A hovered pane header's chip: white at the ×'s disc opacity, twice
    /// its resting 6 % — it lights up on every terminal theme (the tab
    /// strip's darker fill would sink into the card).
    static let headerChipOpacity: Double = closeDiscOpacity
    static let headerRestingOpacity: Double = 0.06
}
