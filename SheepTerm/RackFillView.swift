import Combine
import SwiftUI

/// Rack Fill on a Home tile (6.1 (8)): drag a device from the three below
/// onto the rack; its shadow shows where it lands (blue fits, red does
/// not). A full row or column lights green, runs and clears; several at
/// once or in a row show a combo. Animations play only on a move — the tile
/// is still otherwise. The game in progress lives as long as the app does
/// (`RackFillSession`: another tab, Home redrawn, the small tile's popover —
/// it is the same game until it is lost; the owner: "จนกว่าจะแพ้ นอกจากกดปิด
/// app"); the scores are kept and travel with Sync.
@MainActor final class RackFillSession: ObservableObject {
    static let shared = RackFillSession()
    @Published var game = RackFill.Game(seed: UInt64.random(in: 1...UInt64.max))
}

struct RackFillView: View {
    /// A small tile: the scores and a Play button; the game opens in a popover.
    var compact = false
    @AppStorage(RackFill.topKey) private var storedTop: Data?
    @ObservedObject private var session = RackFillSession.shared
    private var game: RackFill.Game {
        get { session.game }
        nonmutating set { session.game = newValue }
    }
    /// Dragging hand slot `slot`, the pointer at `point` (in the board's space).
    @State private var drag: (slot: Int, point: CGPoint)?
    @State private var popped: Set<Int> = []
    /// Cells clearing: their kind before, for the green run.
    @State private var clearing: [Int: RackFill.Kind] = [:]
    @State private var combo: Int?
    @State private var shake = 0
    @State private var dealt = 0
    @State private var newBest = false
    @State private var showTop = false
    @State private var playing = false

    private var top: [RackFill.Score] { RackFill.loadTop(storedTop) }
    private var best: Int { top.first?.points ?? 0 }
    private static let space = "rackfill"
    /// The rack's top inside the tile's space: the score bar (26) and the gap (6).
    private static let boardTop: CGFloat = 32

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 6) {
                    Text("\(best)").font(.system(size: 26, weight: .semibold).monospacedDigit())
                    Text("best").font(.system(size: 11)).foregroundStyle(Theme.dimText)
                    Button("Play") { playing = true }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .popover(isPresented: $playing, arrowEdge: .bottom) {
                    RackFillView().frame(width: 300, height: 330).padding(12)
                }
            } else {
                GeometryReader { geo in board(in: geo.size) }
            }
        }
    }

    // MARK: the board

    /// The hand's row: taller on a big board (the floating card) so the
    /// pieces read at a size near the rack's own.
    private static func handHeight(_ size: CGSize) -> CGFloat { size.height > 340 ? 92 : 54 }

    private func cellSize(_ size: CGSize) -> CGFloat {
        let handHeight = Self.handHeight(size), header: CGFloat = 32
        return max(10, min(size.width / CGFloat(RackFill.size), (size.height - handHeight - header) / CGFloat(RackFill.size)).rounded(.down))
    }

    @ViewBuilder private func board(in size: CGSize) -> some View {
        let cell = cellSize(size)
        let side = cell * CGFloat(RackFill.size)
        let ghost = ghostSpot(cell: cell)
        VStack(spacing: 6) {
            // The score bar (the owner: "สวยๆหน่อย"): the best on the left (a click
            // lists the top five), the score big in the middle, the streak on the right.
            ZStack {
                HStack(spacing: 0) {
                    Button { showTop = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trophy.fill").font(.system(size: 10)).foregroundStyle(Theme.warn)
                            Text("\(best)").font(.system(size: 11, weight: .medium).monospacedDigit())
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.dimText)
                    .help(String(localized: "Top scores"))
                    .accessibilityLabel(String(localized: "Top scores"))
                    .popover(isPresented: $showTop) { topList }
                    Spacer(minLength: 0)
                    if game.streak > 1 {
                        HStack(spacing: 3) {
                            Image(systemName: "flame.fill").font(.system(size: 10))
                            Text("×\(game.streak)").font(.system(size: 11, weight: .bold).monospacedDigit())
                        }
                        .foregroundStyle(Theme.ok)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(Theme.ok.opacity(0.14)))
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                Text("\(game.score)")
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: Double(game.score)))
                    .animation(.easeOut(duration: 0.3), value: game.score)
            }
            .frame(height: 26)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: game.streak > 1)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25))
                ForEach(0..<(RackFill.size * RackFill.size), id: \.self) { index in
                    cellView(index: index, cell: cell, ghost: ghost)
                }
                if let combo {
                    Text(combo > 1 ? "Combo ×\(combo)" : "Clear!")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.ok)
                        .frame(width: side, height: side)
                        .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity),
                                                removal: .move(edge: .top).combined(with: .opacity)))
                }
                if game.over { gameOver(side: side) }
            }
            .frame(width: side, height: side)
            .offset(x: shake % 2 == 0 ? 0 : 6)
            hand(cell: cell, side: side, slotHeight: Self.handHeight(size) - 6)
        }
        .frame(width: max(side, 0))
        .coordinateSpace(name: Self.space)
        .overlay(alignment: .topLeading) {
            // The piece under the pointer, at the rack's own cell size, held a little above it.
            if let drag, let piece = game.hand[drag.slot] {
                pieceView(piece, cell: cell)
                    .position(x: drag.point.x, y: drag.point.y - lift(piece, cell: cell))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func cellView(index: Int, cell: CGFloat, ghost: (cells: Set<Int>, fits: Bool, clears: Set<Int>)?) -> some View {
        let row = index / RackFill.size, column = index % RackFill.size
        let kind = game.board[index] ?? clearing[index]
        let isGhost = ghost?.cells.contains(index) == true
        let willClear = ghost?.clears.contains(index) == true
        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 3)
                .fill(clearing[index] != nil ? Theme.ok
                      : kind.map(Self.color) ?? (isGhost ? (ghost?.fits == true ? Theme.accent.opacity(0.35) : Theme.destructive.opacity(0.35))
                                                : Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(willClear ? Theme.ok : Color.white.opacity(kind == nil ? 0.05 : 0.1), lineWidth: 1))
            if kind != nil, cell >= 14 {
                Circle().fill(clearing[index] != nil ? Color.white : Theme.ok.opacity(0.9))
                    .frame(width: 3, height: 3).padding(3)
            }
        }
        .frame(width: cell - 2, height: cell - 2)
        .scaleEffect(popped.contains(index) ? 1.12 : 1)
        .opacity(clearing[index] != nil ? 0.9 : 1)
        .offset(x: CGFloat(column) * cell + 1, y: CGFloat(row) * cell + 1)
    }

    private func hand(cell: CGFloat, side: CGFloat, slotHeight: CGFloat) -> some View {
        let mini = max(6, min(18, cell * 0.55))
        return HStack(spacing: 0) {
            ForEach(0..<RackFill.handSize, id: \.self) { slot in
                ZStack {
                    if let piece = game.hand[slot] {
                        // ONE block size for every piece in hand (the owner: blocks must
                        // match), small enough for the longest (5) in its slot.
                        pieceView(piece, cell: drag?.slot == slot ? 0 : handCell(mini: mini, side: side, slotHeight: slotHeight))
                            .opacity(drag?.slot == slot ? 0 : 1)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .id("\(dealt)-\(slot)")
                            .opacity(game.over ? 0.4 : 1)
                    }
                }
                .frame(width: side / CGFloat(RackFill.handSize), height: slotHeight, alignment: .center)
                .contentShape(Rectangle())
                // The whole slot takes the drag, not only the piece's own small cells
                // (the owner: "คลิ๊ก block ไม่ค่อยติด").
                .gesture(dragGesture(slot: slot, cell: cell))
                .pointerStyle(game.hand[slot] == nil || game.over ? .default : .grabIdle)
            }
        }
        .frame(width: side)
    }

    /// The hand's block size: the same for all three, the longest piece (5 blocks) fitting a slot.
    private func handCell(mini: CGFloat, side: CGFloat, slotHeight: CGFloat) -> CGFloat {
        let longest = CGFloat(RackFill.pieces.map { max($0.width, $0.height) }.max() ?? 5)
        return min(mini, (slotHeight - 4) / longest, (side / CGFloat(RackFill.handSize) - 10) / longest).rounded(.down)
    }

    /// How far above the pointer a dragged piece is held: its centre, plus a little.
    private func lift(_ piece: RackFill.Piece, cell: CGFloat) -> CGFloat { cell * CGFloat(piece.height) / 2 + 12 }

    private func pieceView(_ piece: RackFill.Piece, cell: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(piece.cells.enumerated()), id: \.offset) { _, c in
                RoundedRectangle(cornerRadius: 2).fill(Self.color(piece.kind))
                    .frame(width: max(cell - 2, 0), height: max(cell - 2, 0))
                    .offset(x: CGFloat(c.column) * cell, y: CGFloat(c.row) * cell)
            }
        }
        .frame(width: CGFloat(piece.width) * cell, height: CGFloat(piece.height) * cell, alignment: .topLeading)
    }

    // MARK: drag

    private func dragGesture(slot: Int, cell: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard !game.over else { return }
                drag = (slot, value.location)
            }
            .onEnded { value in
                defer { drag = nil }
                guard let spot = topLeft(slot: slot, at: value.location, cell: cell) else { return }
                place(slot: slot, row: spot.row, column: spot.column)
            }
    }

    /// The rack cell the dragged piece's top-left would take: the piece is
    /// held a little above the pointer, centred on it.
    private func topLeft(slot: Int, at point: CGPoint, cell: CGFloat) -> (row: Int, column: Int)? {
        guard let piece = game.hand[slot] else { return nil }
        let x = point.x - cell * CGFloat(piece.width) / 2
        let y = point.y - Self.boardTop - lift(piece, cell: cell) - cell * CGFloat(piece.height) / 2
        let column = Int((x / cell).rounded()), row = Int((y / cell).rounded())
        guard row >= -1, column >= -1, row < RackFill.size + 1, column < RackFill.size + 1 else { return nil }
        return (row, column)
    }

    private func ghostSpot(cell: CGFloat) -> (cells: Set<Int>, fits: Bool, clears: Set<Int>)? {
        guard let drag, let piece = game.hand[drag.slot], let spot = topLeft(slot: drag.slot, at: drag.point, cell: cell) else { return nil }
        let n = RackFill.size
        let cells = Set(piece.cells.compactMap { c -> Int? in
            let r = spot.row + c.row, col = spot.column + c.column
            return r >= 0 && col >= 0 && r < n && col < n ? r * n + col : nil
        })
        let fits = game.fits(piece, row: spot.row, column: spot.column)
        var clears = Set<Int>()
        if fits {
            let lines = game.wouldClear(piece, row: spot.row, column: spot.column)
            for r in lines.rows { for c in 0..<n { clears.insert(r * n + c) } }
            for c in lines.columns { for r in 0..<n { clears.insert(r * n + c) } }
        }
        return (cells, fits, clears)
    }

    // MARK: moves

    private func place(slot: Int, row: Int, column: Int) {
        guard let piece = game.hand[slot] else { return }
        let before = game
        let streakBefore = game.streak
        let handBefore = game.hand.compactMap { $0 }.count
        guard let lines = game.place(slot: slot, row: row, column: column) else { return }
        let n = RackFill.size
        let placedCells = Set(piece.cells.map { (row + $0.row) * n + column + $0.column })
        // Pop in.
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { popped = placedCells }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { withAnimation(.easeOut(duration: 0.12)) { popped = [] } }
        // The green run over what clears, from the board as it was with the piece in.
        var gone: [Int: RackFill.Kind] = [:]
        var full = before.board
        for i in placedCells { full[i] = piece.kind }
        for r in lines.rows { for c in 0..<n { gone[r * n + c] = full[r * n + c] } }
        for c in lines.columns { for r in 0..<n { gone[r * n + c] = full[r * n + c] } }
        if !gone.isEmpty {
            for (i, kind) in gone {
                let delay = Double(i % n) * 0.025
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { withAnimation(.easeOut(duration: 0.1)) { clearing[i] = kind } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32 + delay) { withAnimation(.easeIn(duration: 0.15)) { _ = clearing.removeValue(forKey: i) } }
            }
            let count = lines.rows.count + lines.columns.count
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { combo = max(count, streakBefore + 1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { withAnimation(.easeOut(duration: 0.25)) { combo = nil } }
        }
        if handBefore == 1 { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dealt += 1 } }
        if game.over { finish() }
    }

    private func finish() {
        let wasBest = best
        storedTop = try? JSONEncoder().encode(RackFill.recording(game.score, at: Date(), into: top))
        newBest = game.score > wasBest && game.score > 0
        for i in 1...4 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) { withAnimation(.linear(duration: 0.05)) { shake = i } } }
    }

    private func newGame() {
        withAnimation(.easeInOut(duration: 0.2)) {
            game = RackFill.Game(seed: UInt64.random(in: 1...UInt64.max))
            newBest = false
            dealt += 1
            shake = 0
        }
    }

    // MARK: pieces of UI

    private func gameOver(side: CGFloat) -> some View {
        VStack(spacing: 6) {
            if newBest { Text("New best").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.warn) }
            Text("\(game.score)").font(.system(size: 26, weight: .semibold).monospacedDigit())
            Button("New Game") { newGame() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
        }
        .frame(width: side, height: side)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
        .transition(.opacity)
    }

    private var topList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top scores").font(.system(size: 12, weight: .semibold))
            if top.isEmpty { Text("No games yet").font(.system(size: 11)).foregroundStyle(Theme.dimText) }
            ForEach(Array(top.enumerated()), id: \.offset) { index, score in
                HStack {
                    Text("\(index + 1).").foregroundStyle(Theme.dimText).frame(width: 18, alignment: .trailing)
                    Text("\(score.points)").monospacedDigit()
                    Spacer(minLength: 12)
                    Text(score.date, style: .date).foregroundStyle(Theme.dimText)
                }
                .font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    static func color(_ kind: RackFill.Kind) -> Color {
        switch kind {
        case .sfp: return Color(red: 0.62, green: 0.65, blue: 0.72)
        case .patch: return Color(red: 0.24, green: 0.55, blue: 0.75)
        case .cable: return Color(red: 0.20, green: 0.48, blue: 0.40)
        case .switch1U: return Color(red: 0.13, green: 0.37, blue: 0.63)
        case .server: return Color(red: 0.33, green: 0.29, blue: 0.68)
        case .ups: return Color(red: 0.55, green: 0.36, blue: 0.10)
        case .router: return Color(red: 0.12, green: 0.50, blue: 0.48)
        }
    }
}
