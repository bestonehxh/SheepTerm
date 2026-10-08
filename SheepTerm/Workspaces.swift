import CoreGraphics
import Foundation

/// Split panes (4.2 (7)): the tab strip's entries. A workspace is one tab
/// holding one or more sessions in a `PaneLayout`; every session lives in
/// exactly one workspace. Pure bookkeeping, `nonisolated`, harness-tested —
/// `AppModel` owns one `WorkspaceBook` and asks it every question about
/// which tab shows what and what to select when something closes.
nonisolated struct WorkspaceState: Equatable, Identifiable, Sendable {
    let id: UUID
    var layout: PaneLayout
    /// The session that has (or last had) the keyboard in this workspace.
    var focused: UUID
    /// A pane filling the tab on its own (⇧⌘↵); nil = the whole layout.
    var zoomed: UUID?

    init(session: UUID) {
        id = UUID()
        layout = PaneLayout(session)
        focused = session
    }

    var sessions: [UUID] { layout.leaves }
    var paneCount: Int { layout.count }
}

/// Where a new session goes.
nonisolated enum PanePlacement: Equatable, Sendable {
    /// Its own tab (the default).
    case newTab
    /// Beside `beside` in its workspace, on that side.
    case split(beside: UUID, PaneDirection)
    /// In the place of `old` (a reconnect), which is removed.
    case replacing(UUID)
}

/// A tab chip dragged out of the strip (4.2 (7)): which tab, and where the
/// pointer is in screen coordinates (AppKit's, y up).
nonisolated struct ChipDrag: Equatable, Sendable {
    let workspace: UUID
    let screenPoint: CGPoint
}

/// What a drag in this app carries on the pasteboard: `pane:<uuid>` from a
/// pane header, `host:<uuid>` from the sidebar (which also writes `group:`
/// and `section:` — not droppable on a pane).
nonisolated enum PaneDragPayload: Equatable, Sendable {
    case pane(UUID)
    case host(UUID)

    init?(_ string: String) {
        if string.hasPrefix("pane:"), let id = UUID(uuidString: String(string.dropFirst(5))) {
            self = .pane(id)
        } else if string.hasPrefix("host:"), let id = UUID(uuidString: String(string.dropFirst(5))) {
            self = .host(id)
        } else {
            return nil
        }
    }

    var string: String {
        switch self {
        case .pane(let id): return "pane:\(id.uuidString)"
        case .host(let id): return "host:\(id.uuidString)"
        }
    }
}

nonisolated struct WorkspaceBook: Equatable, Sendable {
    private(set) var workspaces: [WorkspaceState] = []

    // MARK: - reading

    func workspace(containing session: UUID) -> WorkspaceState? {
        workspaces.first { $0.layout.contains(session) }
    }

    func index(ofWorkspaceContaining session: UUID) -> Int? {
        workspaces.firstIndex { $0.layout.contains(session) }
    }

    func workspace(id: UUID) -> WorkspaceState? {
        workspaces.first { $0.id == id }
    }

    var sessions: [UUID] { workspaces.flatMap(\.sessions) }

    // MARK: - attaching

    /// Put `session` where `placement` says. A split beside a session that is
    /// not here, or into a full tab, falls back to a new tab — the session
    /// must land somewhere. Returns the workspace it landed in.
    @discardableResult
    mutating func attach(_ session: UUID, _ placement: PanePlacement = .newTab) -> WorkspaceState {
        precondition(workspace(containing: session) == nil, "session attached twice")
        switch placement {
        case .split(let beside, let direction):
            if let i = index(ofWorkspaceContaining: beside), workspaces[i].layout.insert(session, beside: beside, direction) {
                workspaces[i].focused = session
                workspaces[i].zoomed = nil
                return workspaces[i]
            }
        case .replacing(let old):
            if let i = index(ofWorkspaceContaining: old), workspaces[i].layout.replace(old, with: session) {
                if workspaces[i].focused == old { workspaces[i].focused = session }
                if workspaces[i].zoomed == old { workspaces[i].zoomed = session }
                return workspaces[i]
            }
        case .newTab:
            break
        }
        let fresh = WorkspaceState(session: session)
        workspaces.append(fresh)
        return fresh
    }

    // MARK: - removing

    /// Take `session` out of its workspace; a workspace left empty goes too.
    /// Returns what to select next when `session` was the selected one: a
    /// pane of the same workspace (the focused one, else the nearest by
    /// position), or the focused pane of the neighbouring tab — nil when
    /// nothing is left.
    @discardableResult
    mutating func remove(_ session: UUID) -> UUID? {
        guard let i = index(ofWorkspaceContaining: session) else { return nil }
        if takeOut(session, fromWorkspaceAt: i) {
            guard !workspaces.isEmpty else { return nil }
            return workspaces[min(i, workspaces.count - 1)].focused
        }
        return workspaces[i].focused
    }

    /// Take `session` out of workspace `i`. A pane of several: a pane that
    /// touched it (left/up first) takes the focus if it had it. The last
    /// pane: the workspace goes. Returns true when the workspace went.
    @discardableResult
    private mutating func takeOut(_ session: UUID, fromWorkspaceAt i: Int) -> Bool {
        guard workspaces[i].paneCount > 1 else {
            workspaces.remove(at: i)
            return true
        }
        let layout = workspaces[i].layout
        var next: UUID? = nil
        for direction in [PaneDirection.left, .up, .right, .down] {
            if let found = layout.neighbor(of: session, direction) { next = found; break }
        }
        workspaces[i].layout.remove(session)
        if workspaces[i].focused == session, let next = next ?? workspaces[i].layout.leaves.first {
            workspaces[i].focused = next
        }
        if workspaces[i].zoomed == session || workspaces[i].paneCount == 1 { workspaces[i].zoomed = nil }
        return false
    }

    // MARK: - drag and drop (pane headers, tab chips)

    /// Move `session` (from this workspace or another) next to `target`, on
    /// that side. False — and nothing changes — when it is the target
    /// itself, either is unknown, or the target's tab is full (only a move
    /// from another tab adds a pane). A tab left empty goes; the moved pane
    /// is focused in its new tab, and neither tab stays zoomed.
    @discardableResult
    mutating func move(session: UUID, beside target: UUID, _ direction: PaneDirection) -> Bool {
        guard session != target,
              let si = index(ofWorkspaceContaining: session),
              let ti = index(ofWorkspaceContaining: target) else { return false }
        if si != ti, workspaces[ti].paneCount >= PaneLayout.maxPanes { return false }
        var book = self
        let targetID = book.workspaces[ti].id
        book.workspaces[si].zoomed = nil
        book.takeOut(session, fromWorkspaceAt: si)
        guard let t = book.workspaces.firstIndex(where: { $0.id == targetID }),
              book.workspaces[t].layout.insert(session, beside: target, direction) else { return false }
        book.workspaces[t].focused = session
        book.workspaces[t].zoomed = nil
        self = book
        return true
    }

    /// A whole tab dropped beside `target` (a tab chip dragged onto a
    /// pane): its sessions, in their order, in a row/column on that side —
    /// `target | s1 | s2` for right/down, `s1 | s2 | target` for left/up —
    /// sharing that row evenly. The source tab goes; its focused pane keeps
    /// the focus. False (nothing changes) for the target's own tab or when
    /// the result would exceed `PaneLayout.maxPanes`.
    @discardableResult
    mutating func merge(workspace source: UUID, beside target: UUID, _ direction: PaneDirection) -> Bool {
        guard let si = workspaces.firstIndex(where: { $0.id == source }),
              let ti = index(ofWorkspaceContaining: target), si != ti,
              workspaces[si].paneCount + workspaces[ti].paneCount <= PaneLayout.maxPanes else { return false }
        var book = self
        let moving = book.workspaces[si].sessions
        let focus = book.workspaces[si].focused
        let targetID = book.workspaces[ti].id
        book.workspaces.remove(at: si)
        guard let t = book.workspaces.firstIndex(where: { $0.id == targetID }) else { return false }
        // Each insert lands right beside the target: before it for left/up
        // (so the first goes first), after it for right/down (so the last
        // goes first).
        for session in direction.insertsBefore ? moving : moving.reversed() {
            guard book.workspaces[t].layout.insert(session, beside: target, direction) else { return false }
        }
        book.workspaces[t].layout.equalizeSplit(containing: target)
        book.workspaces[t].focused = focus
        book.workspaces[t].zoomed = nil
        self = book
        return true
    }

    /// A pane of several taken into a tab of its own, right after the one it
    /// came from. nil when it is alone already or unknown.
    @discardableResult
    mutating func detach(session: UUID) -> WorkspaceState? {
        guard let i = index(ofWorkspaceContaining: session), workspaces[i].paneCount > 1 else { return nil }
        workspaces[i].zoomed = nil
        takeOut(session, fromWorkspaceAt: i)
        let fresh = WorkspaceState(session: session)
        workspaces.insert(fresh, at: i + 1)
        return fresh
    }

    /// A pane dropped on a tab chip: to the right of that tab's focused pane.
    @discardableResult
    mutating func move(session: UUID, toWorkspace id: UUID) -> Bool {
        guard let ws = workspace(id: id), !ws.layout.contains(session) else { return false }
        return move(session: session, beside: ws.focused, .right)
    }

    /// Every session of a workspace, in the order they should be closed.
    func sessions(ofWorkspace id: UUID) -> [UUID] {
        workspace(id: id)?.sessions ?? []
    }

    // MARK: - focus and zoom

    /// Record that `session` has the keyboard in its workspace.
    /// A zoomed pane hides the others; the keyboard moving to a hidden one
    /// (⌥⌘→, a menu, a chip) un-zooms, so what has the keyboard is always on
    /// screen — review finding, 4.2 (7).
    mutating func focus(_ session: UUID) {
        guard let i = index(ofWorkspaceContaining: session) else { return }
        workspaces[i].focused = session
        if let zoomed = workspaces[i].zoomed, zoomed != session { workspaces[i].zoomed = nil }
    }

    /// Toggle the zoom of `session` (zoomed ↔ whole layout).
    mutating func toggleZoom(_ session: UUID) {
        guard let i = index(ofWorkspaceContaining: session), workspaces[i].paneCount > 1 else { return }
        workspaces[i].zoomed = workspaces[i].zoomed == session ? nil : session
    }

    mutating func equalize(workspace id: UUID) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].layout.equalize()
    }

    mutating func moveDivider(workspace id: UUID, split: UUID, index: Int, to position: CGFloat) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].layout.moveDivider(ofSplit: split, index: index, to: position)
    }

    // MARK: - tab order

    mutating func move(workspace id: UUID, toGap gap: Int) {
        guard let from = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces = TabOrder.moved(workspaces, from: from, toGap: gap)
    }

    /// The focused session of the workspace `offset` tabs away from the one
    /// holding `session`, wrapping around.
    func focusedSession(ofWorkspaceAdjacentTo session: UUID, offset: Int) -> UUID? {
        guard !workspaces.isEmpty else { return nil }
        let current = index(ofWorkspaceContaining: session) ?? 0
        let next = (current + offset + workspaces.count) % workspaces.count
        return workspaces[next].focused
    }

    /// The focused session of tab number `number` (1-based), if there is one.
    func focusedSession(ofWorkspaceNumber number: Int) -> UUID? {
        let index = number - 1
        return workspaces.indices.contains(index) ? workspaces[index].focused : nil
    }
}
