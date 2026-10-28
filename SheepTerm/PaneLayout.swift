import CoreGraphics
import Foundation

/// Split panes (4.2 (7)): how the sessions of one tab are arranged.
///
/// A tab ("workspace") holds a binary-ish split tree: a leaf is a session, a
/// split is a row (`.horizontal`, children left → right) or a column
/// (`.vertical`, children top → bottom) of nodes with fractions that sum to
/// one. Pure value type, `nonisolated`, compiled into `Tests/run.sh tests`:
/// every rule the view and the model rely on is pinned there.
///
/// Geometry here is top-left based (y grows DOWN), the way the eye reads the
/// screen and the way `up`/`down` are named. The AppKit view converts.
nonisolated enum PaneAxis: Equatable, Sendable {
    /// Children side by side.
    case horizontal
    /// Children stacked.
    case vertical
}

nonisolated enum PaneDirection: Equatable, Sendable, CaseIterable {
    case left, right, up, down

    var axis: PaneAxis {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    /// The new pane goes before (`left`/`up`) or after the target.
    var insertsBefore: Bool { self == .left || self == .up }
}

nonisolated indirect enum PaneNode: Equatable, Sendable {
    case leaf(UUID)
    case split(id: UUID, axis: PaneAxis, children: [PaneNode], fractions: [CGFloat])
}

nonisolated struct PaneLayout: Equatable, Sendable {
    /// Panes per tab, at most: a full 3 × 3 grid (`isGrid`, 6.0 (12)).
    static let maxPanes = 9
    /// Children of one split, at most: three columns, three rows, three
    /// cells in a column or row.
    static let maxPerSplit = 3
    /// No pane may be dragged narrower than this share of its split.
    static let minFraction: CGFloat = 0.08

    private(set) var root: PaneNode

    init(_ session: UUID) {
        root = .leaf(session)
    }

    /// A tree built elsewhere, taken as it is (the harness builds the
    /// shapes older builds could make; nothing here rebuilds them).
    init(root: PaneNode) {
        self.root = root
    }

    // MARK: - reading

    /// Sessions, depth-first, left/top first.
    var leaves: [UUID] {
        var out: [UUID] = []
        func walk(_ node: PaneNode) {
            switch node {
            case .leaf(let id): out.append(id)
            case .split(_, _, let children, _): children.forEach(walk)
            }
        }
        walk(root)
        return out
    }

    var count: Int { leaves.count }

    /// The sessions under one split node (its whole subtree).
    func leaves(ofSplit target: UUID) -> [UUID] {
        var out: [UUID] = []
        var inside = false
        func walk(_ node: PaneNode) {
            switch node {
            case .leaf(let id): if inside { out.append(id) }
            case .split(let id, _, let children, _):
                let was = inside
                if id == target { inside = true }
                children.forEach(walk)
                inside = was
            }
        }
        walk(root)
        return out
    }

    func contains(_ id: UUID) -> Bool { leaves.contains(id) }

    /// Every split with its axis and fractions, for the view and the tests.
    var splits: [(id: UUID, axis: PaneAxis, fractions: [CGFloat])] {
        var out: [(UUID, PaneAxis, [CGFloat])] = []
        func walk(_ node: PaneNode) {
            if case .split(let id, let axis, let children, let fractions) = node {
                out.append((id, axis, fractions))
                children.forEach(walk)
            }
        }
        walk(root)
        return out.map { (id: $0.0, axis: $0.1, fractions: $0.2) }
    }

    /// Frames of every leaf inside `bounds`, with `divider` points left
    /// between siblings. Fractions apply to what is left after the dividers.
    func rects(in bounds: CGRect, divider: CGFloat = 0) -> [UUID: CGRect] {
        var out: [UUID: CGRect] = [:]
        func walk(_ node: PaneNode, _ rect: CGRect) {
            switch node {
            case .leaf(let id):
                out[id] = rect
            case .split(_, let axis, let children, let fractions):
                let n = children.count
                let total = axis == .horizontal ? rect.width : rect.height
                let usable = max(0, total - divider * CGFloat(n - 1))
                var offset: CGFloat = 0
                for (child, fraction) in zip(children, fractions) {
                    let length = usable * fraction
                    let childRect = axis == .horizontal
                        ? CGRect(x: rect.minX + offset, y: rect.minY, width: length, height: rect.height)
                        : CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: length)
                    walk(child, childRect)
                    offset += length + divider
                }
            }
        }
        walk(root, bounds)
        return out
    }

    /// Divider strips inside `bounds`: the gap between sibling `index` and
    /// `index + 1` of split `id`, `divider` points thick.
    func dividerRects(in bounds: CGRect, divider: CGFloat) -> [(split: UUID, index: Int, rect: CGRect)] {
        var out: [(UUID, Int, CGRect)] = []
        func walk(_ node: PaneNode, _ rect: CGRect) {
            guard case .split(let id, let axis, let children, let fractions) = node else { return }
            let n = children.count
            let total = axis == .horizontal ? rect.width : rect.height
            let usable = max(0, total - divider * CGFloat(n - 1))
            var offset: CGFloat = 0
            for (index, (child, fraction)) in zip(children, fractions).enumerated() {
                let length = usable * fraction
                let childRect = axis == .horizontal
                    ? CGRect(x: rect.minX + offset, y: rect.minY, width: length, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: length)
                walk(child, childRect)
                offset += length
                if index < n - 1 {
                    let strip = axis == .horizontal
                        ? CGRect(x: rect.minX + offset, y: rect.minY, width: divider, height: rect.height)
                        : CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: divider)
                    out.append((id, index, strip))
                    offset += divider
                }
            }
        }
        walk(root, bounds)
        return out.map { (split: $0.0, index: $0.1, rect: $0.2) }
    }

    /// The pane next to `id` in `direction`: the neighbour sharing the most
    /// edge, nearest first. nil at the edge of the tab.
    func neighbor(of id: UUID, _ direction: PaneDirection) -> UUID? {
        let frames = rects(in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        guard let me = frames[id] else { return nil }
        let eps: CGFloat = 0.5
        var best: (id: UUID, overlap: CGFloat, distance: CGFloat, along: CGFloat)?
        for (other, rect) in frames where other != id {
            let adjacent: Bool
            let overlap: CGFloat
            let distance: CGFloat
            switch direction {
            case .right:
                adjacent = rect.minX >= me.maxX - eps
                overlap = min(rect.maxY, me.maxY) - max(rect.minY, me.minY)
                distance = rect.minX - me.maxX
            case .left:
                adjacent = rect.maxX <= me.minX + eps
                overlap = min(rect.maxY, me.maxY) - max(rect.minY, me.minY)
                distance = me.minX - rect.maxX
            case .down:
                adjacent = rect.minY >= me.maxY - eps
                overlap = min(rect.maxX, me.maxX) - max(rect.minX, me.minX)
                distance = rect.minY - me.maxY
            case .up:
                adjacent = rect.maxY <= me.minY + eps
                overlap = min(rect.maxX, me.maxX) - max(rect.minX, me.minX)
                distance = me.minY - rect.maxY
            }
            guard adjacent, overlap > eps else { continue }
            // A full tie (two panes stacked beside a tall one) goes to the
            // top/left one. `frames` is a Dictionary, so without this the
            // answer changed from run to run.
            let along = direction.axis == .horizontal ? rect.minY : rect.minX
            if let current = best {
                let sameDistance = abs(distance - current.distance) <= eps
                let sameOverlap = abs(overlap - current.overlap) <= eps
                if distance < current.distance - eps
                    || (sameDistance && overlap > current.overlap + eps)
                    || (sameDistance && sameOverlap && along < current.along) {
                    best = (other, overlap, distance, along)
                }
            } else {
                best = (other, overlap, distance, along)
            }
        }
        return best?.id
    }

    /// A Ping pane keeps half the tab at least (the owner, 6.0 (2): its table
    /// must not be squeezed out of scale): it is alone, or one of exactly two
    /// halves of the top split — left|right or top/bottom. The OTHER half may
    /// be split as deep as any tab.
    func keepsWhole(_ compact: Set<UUID>) -> Bool {
        let here = leaves.filter(compact.contains)
        guard !here.isEmpty else { return true }
        switch root {
        case .leaf: return true
        case .split(_, _, let children, _):
            return children.count == 2 && here.allSatisfy { children.contains(.leaf($0)) }
        }
    }

    /// The tidy grid (the owner, 2026-10-28): at most two levels — the root
    /// split (columns or rows) with ≤ 3 children, each a leaf or a split in
    /// the OTHER axis holding ≤ 3 leaves. Every edit keeps a tab on it; a tab
    /// that is off it (built by an older rule) is left as it is and only
    /// refuses to grow (`insert`) until closes bring it back.
    var isGrid: Bool {
        guard case .split(_, let axis, let children, _) = root else { return true }
        guard children.count <= PaneLayout.maxPerSplit else { return false }
        return children.allSatisfy { child in
            guard case .split(_, let inner, let cells, _) = child else { return true }
            return inner != axis && cells.count <= PaneLayout.maxPerSplit
                && cells.allSatisfy { if case .leaf = $0 { return true }; return false }
        }
    }

    private static func evenShares(_ n: Int) -> [CGFloat] {
        Array(repeating: 1 / CGFloat(n), count: n)
    }

    private static func holds(_ node: PaneNode, _ id: UUID) -> Bool {
        switch node {
        case .leaf(let leaf): return leaf == id
        case .split(_, _, let children, _): return children.contains { holds($0, id) }
        }
    }

    // MARK: - editing

    /// Put `new` beside `target`, on the grid (`isGrid`):
    /// - one pane → two columns (left/right) or two rows (up/down);
    /// - along the root's axis → a new column/row beside the TARGET'S
    ///   column/row (so Split Right on a pane in a column adds a column);
    /// - across it → the target's column/row splits into cells.
    /// The split that gains the pane shares its length evenly; the rest keep
    /// their shares. False — nothing changes — when the target is unknown,
    /// `new` is already here, the tab is full, that split has three already,
    /// or the tab is off the grid. `pinned` is unused on the grid (no
    /// splicing happens); kept for the callers' one signature.
    @discardableResult
    mutating func insert(_ new: UUID, beside target: UUID, _ direction: PaneDirection, keepingWhole pinned: Set<UUID> = []) -> Bool {
        guard contains(target), !contains(new), count < PaneLayout.maxPanes, isGrid else { return false }
        let fresh = PaneNode.leaf(new)
        func pair(_ node: PaneNode) -> [PaneNode] { direction.insertsBefore ? [fresh, node] : [node, fresh] }
        switch root {
        case .leaf:
            root = .split(id: UUID(), axis: direction.axis, children: pair(root), fractions: Self.evenShares(2))
        case .split(let id, let axis, var children, let fractions):
            guard let k = children.firstIndex(where: { Self.holds($0, target) }) else { return false }
            if direction.axis == axis {
                guard children.count < PaneLayout.maxPerSplit else { return false }
                children.insert(fresh, at: direction.insertsBefore ? k : k + 1)
                root = .split(id: id, axis: axis, children: children, fractions: Self.evenShares(children.count))
            } else {
                switch children[k] {
                case .leaf:
                    children[k] = .split(id: UUID(), axis: direction.axis, children: pair(children[k]), fractions: Self.evenShares(2))
                case .split(let cellID, let cellAxis, var cells, _):
                    guard cells.count < PaneLayout.maxPerSplit, let j = cells.firstIndex(of: .leaf(target)) else { return false }
                    cells.insert(fresh, at: direction.insertsBefore ? j : j + 1)
                    children[k] = .split(id: cellID, axis: cellAxis, children: cells, fractions: Self.evenShares(cells.count))
                }
                root = .split(id: id, axis: axis, children: children, fractions: fractions)
            }
        }
        return true
    }

    /// A split directly inside a split of the same axis is spliced into it
    /// (its children take its share, scaled). `remove` makes such a tree —
    /// A | (B over (C | D)), close B — and Even Out Panes would then give A
    /// half and C, D a quarter each (review finding).
    /// `pinned`: a split that directly holds one of these leaves (a Ping
    /// pane) keeps a same-axis child split as a child — splicing it in made
    /// `h[ping, B, C]`, where Ping no longer kept half (review 6.0 (2)).
    private mutating func normalize(pinned: Set<UUID> = []) {
        func walk(_ node: PaneNode) -> PaneNode {
            guard case .split(let id, let axis, let children, let fractions) = node else { return node }
            var newChildren: [PaneNode] = []
            var newFractions: [CGFloat] = []
            let holdsPinned = children.contains { if case .leaf(let leaf) = $0 { return pinned.contains(leaf) }; return false }
            for (child, share) in zip(children.map(walk), fractions) {
                if !holdsPinned, case .split(_, let childAxis, let grandchildren, let grandFractions) = child, childAxis == axis {
                    newChildren.append(contentsOf: grandchildren)
                    newFractions.append(contentsOf: grandFractions.map { $0 * share })
                } else {
                    newChildren.append(child)
                    newFractions.append(share)
                }
            }
            return .split(id: id, axis: axis, children: newChildren, fractions: newFractions)
        }
        root = walk(root)
    }

    /// Take `id` out; the siblings left in its split share the length evenly
    /// (the owner, 2026-10-28: every add or close re-evens), a split left
    /// with one child collapses into it. False for an unknown id or the last
    /// pane.
    @discardableResult
    mutating func remove(_ id: UUID, keepingWhole pinned: Set<UUID> = []) -> Bool {
        guard contains(id), count > 1 else { return false }
        func walk(_ node: PaneNode) -> PaneNode {
            guard case .split(let splitID, let axis, let children, let fractions) = node else { return node }
            if let index = children.firstIndex(of: .leaf(id)) {
                var newChildren = children
                var newFractions = fractions
                newChildren.remove(at: index)
                newFractions.remove(at: index)
                if newChildren.count == 1 { return newChildren[0] }
                newFractions = Self.evenShares(newChildren.count)
                return .split(id: splitID, axis: axis, children: newChildren, fractions: newFractions)
            }
            return .split(id: splitID, axis: axis, children: children.map(walk), fractions: fractions)
        }
        root = walk(root)
        normalize(pinned: pinned)
        return true
    }

    /// `tree` (another tab's whole layout) in the place of the leaf
    /// `placeholder`, kept as one subtree. False for an unknown placeholder
    /// or a session already here.
    @discardableResult
    mutating func graft(_ tree: PaneLayout, at placeholder: UUID) -> Bool {
        guard contains(placeholder), Set(leaves).isDisjoint(with: tree.leaves) else { return false }
        func walk(_ node: PaneNode) -> PaneNode {
            switch node {
            case .leaf(let id): return id == placeholder ? tree.root : node
            case .split(let id, let axis, let children, let fractions):
                return .split(id: id, axis: axis, children: children.map(walk), fractions: fractions)
            }
        }
        root = walk(root)
        return true
    }

    /// A reconnect replaces the session but keeps its place.
    @discardableResult
    mutating func replace(_ old: UUID, with new: UUID) -> Bool {
        guard contains(old), !contains(new) else { return false }
        func walk(_ node: PaneNode) -> PaneNode {
            switch node {
            case .leaf(let id): return .leaf(id == old ? new : id)
            case .split(let id, let axis, let children, let fractions):
                return .split(id: id, axis: axis, children: children.map(walk), fractions: fractions)
            }
        }
        root = walk(root)
        return true
    }

    /// Every split shares its length equally (Even Out Panes).
    mutating func equalize() {
        func walk(_ node: PaneNode) -> PaneNode {
            guard case .split(let id, let axis, let children, _) = node else { return node }
            let n = CGFloat(children.count)
            return .split(id: id, axis: axis, children: children.map(walk),
                          fractions: Array(repeating: 1 / n, count: children.count))
        }
        root = walk(root)
    }

    /// The split that directly holds `leaf` shares its length evenly (a tab
    /// merged in beside a pane). The rest of the tree keeps its shares.
    mutating func equalizeSplit(containing leaf: UUID) {
        func walk(_ node: PaneNode) -> PaneNode {
            guard case .split(let id, let axis, let children, let fractions) = node else { return node }
            if children.contains(.leaf(leaf)) {
                return .split(id: id, axis: axis, children: children,
                              fractions: Array(repeating: 1 / CGFloat(children.count), count: children.count))
            }
            return .split(id: id, axis: axis, children: children.map(walk), fractions: fractions)
        }
        root = walk(root)
    }

    // MARK: - drop zones (drag and drop onto a pane)

    /// Which side of `rect` a drop at `point` means: the nearest edge, each
    /// distance taken as a share of the pane's width or height so a wide
    /// pane does not favour top/bottom. Ties go left, right, up, down.
    static func dropDirection(at point: CGPoint, in rect: CGRect) -> PaneDirection {
        let w = max(rect.width, 1), h = max(rect.height, 1)
        let distances: [(PaneDirection, CGFloat)] = [
            (.left, (point.x - rect.minX) / w),
            (.right, (rect.maxX - point.x) / w),
            (.up, (point.y - rect.minY) / h),
            (.down, (rect.maxY - point.y) / h),
        ]
        var best = distances[0]
        for candidate in distances.dropFirst() where candidate.1 < best.1 { best = candidate }
        return best.0
    }

    /// The half of `rect` on `direction`'s side — what the drop zone covers.
    static func dropZoneRect(_ rect: CGRect, _ direction: PaneDirection) -> CGRect {
        switch direction {
        case .left: return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .up: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .down: return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }

    /// The pane under `point` (a divider strip counts as nobody's) and the
    /// side a drop there means. `frames` are the panes as laid out.
    static func dropTarget(at point: CGPoint, frames: [UUID: CGRect]) -> (pane: UUID, direction: PaneDirection)? {
        guard let hit = frames.first(where: { $0.value.contains(point) }) else { return nil }
        return (hit.key, dropDirection(at: point, in: hit.value))
    }

    /// A divider drag: new fractions for one split. Refused unless the count
    /// matches, every share is at least `minFraction`, and they sum to one.
    @discardableResult
    mutating func setFractions(ofSplit target: UUID, _ fractions: [CGFloat]) -> Bool {
        guard fractions.allSatisfy({ $0 >= PaneLayout.minFraction - 0.0001 }),
              abs(fractions.reduce(0, +) - 1) < 0.001 else { return false }
        var done = false
        func walk(_ node: PaneNode) -> PaneNode {
            guard case .split(let id, let axis, let children, let old) = node else { return node }
            if id == target {
                guard fractions.count == children.count else { return node }
                done = true
                return .split(id: id, axis: axis, children: children, fractions: fractions)
            }
            return .split(id: id, axis: axis, children: children.map(walk), fractions: old)
        }
        root = walk(root)
        return done
    }

    /// Move the divider after child `index` of split `target` so that the
    /// boundary sits at `position` (0…1 of the split's length). The two
    /// neighbours of the divider change; the rest keep their shares. Clamped
    /// to `minFraction` on both sides.
    @discardableResult
    mutating func moveDivider(ofSplit target: UUID, index: Int, to position: CGFloat) -> Bool {
        guard let split = splits.first(where: { $0.id == target }), index >= 0, index + 1 < split.fractions.count else { return false }
        var fractions = split.fractions
        let before = fractions[0..<index].reduce(0, +)
        let pairTotal = fractions[index] + fractions[index + 1]
        let lo = before + PaneLayout.minFraction
        let hi = before + pairTotal - PaneLayout.minFraction
        guard hi > lo else { return false }
        let clamped = min(max(position, lo), hi)
        fractions[index] = clamped - before
        fractions[index + 1] = pairTotal - fractions[index]
        return setFractions(ofSplit: target, fractions)
    }
}
