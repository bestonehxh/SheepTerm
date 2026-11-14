import Foundation

/// Add Hosts ▸ the preview beside the grid (6.1 (17), Design/workspaces/
/// PLAN.md round 4): the group the batch goes to, as the sidebar will show
/// it once Add is pressed — its subgroups (the ones that exist drawn dim),
/// the new hosts filed into them by their Subgroup cell, and a warning on a
/// row that would not land as it reads. Pure: rows and the store's groups
/// in, a tree out; the sheet draws it and turns a drop into the row's new
/// Subgroup cell, so the grid stays the one thing that is saved.
///
/// Filing follows the store's rule (`GroupTree.fileLabels`): a path step
/// joins an existing subgroup of that name (case and spacing folded), and a
/// path deeper than the user may make stops at the deepest level allowed.
@MainActor enum AddHostsPreview {
    struct Row: Equatable {
        var id: UUID
        var name: String
        var address: String
        var port: Int
        var kind: ConnectionKind
        /// Part of what makes two rows the same connection (`Host.connectionKey`).
        var username = ""
        var section: String
        /// False when the row would be skipped at Add (no usable address).
        var valid = true
    }

    enum Warning: Equatable {
        /// Skipped at Add: nothing in it a host can be made of.
        case invalid
        /// Already saved in this group (the same connection).
        case alreadySaved
        /// Twice in this batch.
        case repeated
        /// Its path goes deeper than a subgroup may be made: filed higher.
        case tooDeep
    }

    final class Node: Identifiable {
        let id: String
        let name: String
        /// Typed path below the batch's group ("Bldg 1/Floor 2"); "" = the group itself.
        let path: String
        /// A subgroup that exists already (drawn dim) or one Add will make.
        let exists: Bool
        let depth: Int
        var children: [Node] = []
        var rows: [(row: Row, warning: Warning?)] = []
        init(id: String, name: String, path: String, exists: Bool, depth: Int) {
            self.id = id; self.name = name; self.path = path; self.exists = exists; self.depth = depth
        }
        /// New hosts in it and below.
        var count: Int { rows.count + children.reduce(0) { $0 + $1.count } }
    }

    /// The tree for a batch into `root` (nil = a new group named `newName`).
    static func tree(rows: [Row], root: UUID?, newName: String, groups: [HostGroup]) -> Node {
        let rootDepth = root.map { GroupTree.depth(of: $0, in: groups) } ?? 1
        let top = Node(id: "root", name: root.flatMap { id in groups.first { $0.id == id }?.name } ?? newName,
                       path: "", exists: root != nil, depth: rootDepth)
        var byPath: [String: Node] = ["": top]
        // The subgroups that exist, in tree order, each under its parent.
        if let root {
            for id in GroupTree.subtreeIDs(of: root, in: groups).dropFirst() {
                guard let path = GroupTree.relativePath(of: id, below: root, in: groups),
                      let group = groups.first(where: { $0.id == id }) else { continue }
                let parentPath = path.split(separator: GroupTree.separator).dropLast().joined(separator: String(GroupTree.separator))
                guard let parent = byPath[key(parentPath)] else { continue }
                let node = Node(id: "g-\(id.uuidString)", name: group.name, path: path, exists: true, depth: parent.depth + 1)
                parent.children.append(node)
                byPath[key(path)] = node
            }
        }
        // Connections saved in the group already, and in this batch so far.
        let saved = Set((root.map { GroupTree.subtreeIDs(of: $0, in: groups) } ?? [])
            .compactMap { id in groups.first { $0.id == id } }
            .flatMap(\.hosts).map(\.connectionKey))
        var seen = Set<String>()
        for row in rows {
            var node = top
            var warning: Warning?
            for step in GroupTree.components(row.section) {
                guard node.depth < GroupTree.userDepth else { warning = .tooDeep; break }
                let path = node.path.isEmpty ? step : node.path + String(GroupTree.separator) + step
                if let known = byPath[key(path)] { node = known; continue }
                let made = Node(id: "n-\(key(path))", name: step, path: path, exists: false, depth: node.depth + 1)
                node.children.append(made)
                byPath[key(path)] = made
                node = made
            }
            // The store's own identity, or the warnings would disagree with
            // what Add does (admin@x and root@x are two hosts).
            let link = Host(name: "", kind: row.kind, address: row.address, port: row.port, username: row.username).connectionKey
            if !row.valid { warning = .invalid }
            else if saved.contains(link) { warning = .alreadySaved }
            else if !seen.insert(link).inserted { warning = .repeated }
            node.rows.append((row, warning))
        }
        return top
    }

    /// A path folded the way the store compares subgroup names.
    private static func key(_ path: String) -> String {
        GroupTree.components(path).map { HostStore.headingKey($0) ?? $0 }.joined(separator: "/")
    }
}
