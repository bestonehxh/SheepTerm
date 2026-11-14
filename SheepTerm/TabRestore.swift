import Foundation

/// Reopen Last Tabs (6.1 (35), the owner: "คืนแท็บเดิมตอนเปิดแอป"): what was
/// open at quit — tabs, their order, each tab's panes and their shares — is
/// kept in `open-tabs.json` and built again at the next launch. Pure: tabs in,
/// a tree out; a tree and new session ids in, a `PaneLayout` out. `AppModel`
/// owns the file and the opening.
///
/// THIS Mac's only (not synced, not in a backup), and OFF until Settings ▸
/// Optimization turns it on. Nothing is dialled at launch: an SSH, Telnet or
/// console pane comes back with the connection card's Connect button, a Ping
/// pane with its targets stopped. A password is never in here (a host only
/// names its credential), and no scrollback.
@MainActor enum TabRestore {
    static let settingKey = "restoreTabsAtLaunch"
    static let fileName = "open-tabs.json"

    /// What one pane was.
    enum Pane: Codable, Equatable {
        case local
        /// SSH, Telnet, a console cable or a web page: the session's own host.
        case host(Host)
        /// A Ping tab's targets, in its order.
        case ping([String])
    }

    /// A tab's panes as they were laid out.
    indirect enum Node: Codable, Equatable {
        case pane(Pane)
        /// `vertical`: the children are stacked (rows); else side by side.
        case split(vertical: Bool, children: [Node], fractions: [Double])

        /// The panes in reading order — the order `layout(_:sessions:)` takes its ids in.
        var panes: [Pane] {
            switch self {
            case .pane(let pane): return [pane]
            case .split(_, let children, _): return children.flatMap(\.panes)
            }
        }
    }

    struct Saved: Codable, Equatable {
        var tabs: [Node] = []
        /// The tab that was in front, an index into `tabs`.
        var selected: Int?
    }

    // MARK: At quit

    /// `layout` with every leaf named by `pane`; a leaf it cannot name (a
    /// Files tab, a session that is gone) is left out and its neighbours
    /// share its room. nil = nothing of the tab can be kept.
    static func node(_ layout: PaneNode, pane: (UUID) -> Pane?) -> Node? {
        switch layout {
        case .leaf(let id):
            return pane(id).map { .pane($0) }
        case .split(_, let axis, let children, let fractions):
            var kept: [(Node, Double)] = []
            for (index, child) in children.enumerated() {
                guard let made = node(child, pane: pane) else { continue }
                kept.append((made, index < fractions.count ? Double(fractions[index]) : 1))
            }
            guard kept.count > 1 else { return kept.first?.0 }
            let total = kept.reduce(0) { $0 + max($1.1, 0) }
            let shares = kept.map { total > 0 ? max($0.1, 0) / total : 1 / Double(kept.count) }
            return .split(vertical: axis == .vertical, children: kept.map(\.0), fractions: shares)
        }
    }

    static func snapshot(_ workspaces: [WorkspaceState], selected: UUID?, pane: (UUID) -> Pane?) -> Saved {
        var saved = Saved()
        for workspace in workspaces {
            guard let made = node(workspace.layout.root, pane: pane) else { continue }
            if let selected, workspace.sessions.contains(selected) { saved.selected = saved.tabs.count }
            saved.tabs.append(made)
        }
        return saved
    }

    // MARK: At launch

    /// The tab's layout over the sessions opened for `node.panes`, in that
    /// order. A tree this build would not make itself (off the 3 × 3 grid —
    /// a file from somewhere else) becomes the plain grid; nil when the
    /// counts differ or there are more panes than a tab holds.
    static func layout(_ node: Node, sessions: [UUID]) -> PaneLayout? {
        guard sessions.count == node.panes.count, !sessions.isEmpty, sessions.count <= PaneLayout.maxPanes else { return nil }
        var next = 0
        func build(_ node: Node) -> PaneNode {
            switch node {
            case .pane:
                defer { next += 1 }
                return .leaf(sessions[next])
            case .split(let vertical, let children, let fractions):
                let made = children.map(build)
                let usable = fractions.count == made.count && fractions.allSatisfy { $0.isFinite && $0 >= Double(PaneLayout.minFraction) }
                let total = fractions.reduce(0, +)
                let shares = usable && total > 0 ? fractions.map { CGFloat($0 / total) }
                    : Array(repeating: 1 / CGFloat(made.count), count: made.count)
                return .split(id: UUID(), axis: vertical ? .vertical : .horizontal, children: made, fractions: shares)
            }
        }
        let made = PaneLayout(root: build(node))
        guard made.isGrid, Set(made.leaves).count == sessions.count else { return PaneLayout.grid(sessions) }
        return made
    }

    // MARK: The file

    /// nil = nothing to reopen (no file, or one this build cannot read — it
    /// is only last time's window, never worth a warning).
    static func load(_ data: Data?) -> Saved? {
        guard let data, let saved = try? JSONDecoder().decode(Saved.self, from: data), !saved.tabs.isEmpty else { return nil }
        return saved
    }

    /// What a quit does with `open-tabs.json`. `restorePending`: the launch's
    /// restore (one main-queue turn after `AppModel.init`, 6.1 (52)) has not
    /// run yet — the tabs on screen are not last time's, so the file is kept
    /// rather than written over with an empty list.
    enum QuitWrite: Equatable { case keep, remove, write }

    static func quitWrite(settingOn: Bool, restorePending: Bool, tabsToSave: Int) -> QuitWrite {
        guard settingOn else { return .remove }
        if restorePending { return .keep }
        return tabsToSave > 0 ? .write : .remove
    }

    /// The tab focused after the launch's restore: one the user opened before
    /// it ran (a link or a file opened at launch) keeps the focus; else the
    /// tab that was selected at quit, else the first brought back.
    static func launchFocus(selected: Int?, front: [Int: UUID], alreadyOpen: UUID?) -> UUID? {
        if let alreadyOpen { return alreadyOpen }
        return selected.flatMap { front[$0] } ?? front.sorted(by: { $0.key < $1.key }).first?.value
    }

    static func save(_ saved: Saved) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(saved)
    }

    // MARK: Save Split… (6.1 (36), `SavedSplit`)

    /// A tab's panes as a saved split: local shells, and SSH / Telnet / web
    /// panes by their endpoint (`hostID` when `isSaved` knows the host). A
    /// console cable, a Ping pane (and whatever `node` already left out) is
    /// not kept — a cable is whichever is plugged in that day. nil = fewer
    /// than two panes are left: not a split.
    static func savedSplit(_ node: Node, isSaved: (UUID) -> Bool) -> SavedSplit? {
        func convert(_ node: Node) -> SavedSplit.Node? {
            switch node {
            case .pane(.local):
                return .pane(SavedSplit.Pane())
            case .pane(.ping):
                return nil
            case .pane(.host(let host)):
                guard host.kind == .ssh || host.kind == .telnet || host.kind == .web else { return nil }
                return .pane(SavedSplit.Pane(hostID: isSaved(host.id) ? host.id : nil, kind: host.kind.rawValue, name: host.name,
                                             address: host.address, port: host.port, username: host.username))
            case .split(let vertical, let children, let fractions):
                var kept: [(SavedSplit.Node, Double)] = []
                for (index, child) in children.enumerated() {
                    guard let made = convert(child) else { continue }
                    kept.append((made, index < fractions.count ? fractions[index] : 1))
                }
                guard kept.count > 1 else { return kept.first?.0 }
                let total = kept.reduce(0) { $0 + max($1.1, 0) }
                return .split(vertical: vertical, children: kept.map(\.0),
                              fractions: kept.map { total > 0 ? max($0.1, 0) / total : 1 / Double(kept.count) })
            }
        }
        guard let root = convert(node), root.panes.count >= 2 else { return nil }
        return SavedSplit(root: root)
    }

    /// A saved split as the panes to open: the saved host as it is NOW (its
    /// credential, its jump path) when it still exists, else the endpoint
    /// the split kept — a typed target, which asks for its login.
    static func node(_ split: SavedSplit, saved: (UUID) -> Host?,
                     endpoint: ((ConnectionKind, String, Int, String) -> Host?)? = nil) -> Node {
        func convert(_ node: SavedSplit.Node) -> Node {
            switch node {
            case .split(let vertical, let children, let fractions):
                return .split(vertical: vertical, children: children.map(convert), fractions: fractions)
            case .pane(let pane):
                if let host = pane.hostID.flatMap(saved), host.kind == .ssh || host.kind == .telnet || host.kind == .web {
                    return .pane(.host(host))
                }
                guard let kind = ConnectionKind(rawValue: pane.kind), kind == .ssh || kind == .telnet || kind == .web else { return .pane(.local) }
                // Its id is gone (deleted and put back from Recently Deleted
                // = a new id): the saved host at the same endpoint is the
                // one — a typed target would skip its group's Jump Server
                // and dial the device directly (6.1 (52)).
                // A typed target (no id) stays the typed target it was.
                if pane.hostID != nil, let twin = endpoint?(kind, pane.address, pane.port, pane.username) { return .pane(.host(twin)) }
                return .pane(.host(Host(name: pane.name, kind: kind, address: pane.address, port: pane.port, username: pane.username)))
            }
        }
        return convert(split.root)
    }
}
