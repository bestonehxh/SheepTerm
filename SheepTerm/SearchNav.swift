import Foundation

/// Spotlight-style ↑/↓ for the sidebar search and the ⌘K palette: the caret
/// stays in the search field, the arrows only move a selection through the
/// results. Pure on purpose (harness-tested); the views ask "which row?" and do
/// what the answer says. Keyboard only — nothing here is about clicks.
nonisolated enum SearchNav {
    /// The next row to select. `eligible[i]` says whether row i can be
    /// selected (a host / a result; headings are not). `current` is the
    /// selected row, nil = nothing selected yet.
    /// - ↓ (delta > 0) from nothing: the first eligible row; ↑ from nothing:
    ///   the last one.
    /// - Otherwise the nearest eligible row in that direction; at an end the
    ///   selection STAYS (no wrap).
    /// - A `current` that is no longer a valid eligible row (the list was
    ///   re-filtered under it) is treated as nothing selected.
    /// - nil only when no row is eligible.
    static func step(current: Int?, delta: Int, eligible: [Bool]) -> Int? {
        guard delta != 0, eligible.contains(true) else { return current.flatMap { eligible.indices.contains($0) && eligible[$0] ? $0 : nil } }
        let valid = current.flatMap { eligible.indices.contains($0) && eligible[$0] ? $0 : nil }
        guard let valid else {
            return delta > 0 ? eligible.firstIndex(of: true) : eligible.lastIndex(of: true)
        }
        if delta > 0 {
            return (eligible.indices.first { $0 > valid && eligible[$0] }) ?? valid
        }
        return (eligible.indices.last { $0 < valid && eligible[$0] }) ?? valid
    }

    /// After the text changed: the selected id survives if the host is still
    /// among the results, otherwise nothing is selected.
    static func keptSelection(_ id: String?, results: [String]) -> String? {
        guard let id, results.contains(id) else { return nil }
        return id
    }
}

/// Lets the search field (SwiftUI) drive the outline (AppKit) without taking
/// the keyboard from it: the outline's coordinator fills the closures in.
final class SidebarKeyBridge {
    /// ↓ (+1) / ↑ (-1): move the outline's selection through the hosts.
    var move: (Int) -> Void = { _ in }
    /// Return in the field: open the host the arrows selected. False when the
    /// arrows selected nothing (Return then does what it always did).
    var activateSelection: () -> Bool = { false }
    /// What lights the group level bars — the SwiftUI side reports the
    /// pointer and the search field's focus, the outline its own focus and
    /// drags.
    let barActivity = SidebarBarActivity()
}

/// Whether the user is working in the sidebar (`GroupTree.barsActive`), fed
/// by events only — no timer. `onChange` fires once per real change.
final class SidebarBarActivity {
    var pointerInside = false { didSet { settle() } }
    var focusedList = false { didSet { settle() } }
    var focusedSearch = false { didSet { settle() } }
    var dragging = false { didSet { settle() } }
    var onChange: (Bool) -> Void = { _ in }
    private(set) var active = false

    private func settle() {
        let now = GroupTree.barsActive(pointerInside: pointerInside, focused: focusedList || focusedSearch,
                                       dragging: dragging)
        guard now != active else { return }
        active = now
        onChange(now)
    }
}
