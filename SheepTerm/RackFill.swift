import Foundation

/// Rack Fill (6.1 (8), the owner: a game for a quiet minute, "แบบ block
/// blast" — the genre, not anyone's look): an 8 × 8 rack, three devices at a
/// time to place; a full row or column clears; none of the three fits =
/// game over. Turn-based — no clock, so it can wait while you work. Pure and
/// seeded: the harness plays it (`Tests/tests/RackFillTests.swift`).
nonisolated enum RackFill {
    static let size = 8
    static let handSize = 3
    static let topCount = 5
    /// Hands drawn before settling for one that is not whole-placeable.
    static let dealTries = 40
    /// UserDefaults: the scores (synced). The game in progress is not kept —
    /// it lasts as long as the app (`RackFillSession`).
    static let topKey = "rackFillTop"

    /// A device: its cells as (row, column) offsets from its top-left, and its kind (the colour).
    struct Piece: Codable, Equatable, Sendable {
        let cells: [Cell]
        let kind: Kind

        var width: Int { (cells.map(\.column).max() ?? 0) + 1 }
        var height: Int { (cells.map(\.row).max() ?? 0) + 1 }
    }

    struct Cell: Codable, Hashable, Sendable {
        let row: Int
        let column: Int
    }

    /// What the piece stands for in the rack; the view colours by it.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case sfp, patch, cable, switch1U, server, ups, router
    }

    /// Every shape a hand can deal, as text rows ("#" = a cell), with its kind.
    static let shapes: [(rows: [String], kind: Kind)] = [
        (["#"], .sfp),
        (["##"], .patch), (["#", "#"], .patch),
        (["###"], .cable), (["#", "#", "#"], .cable),
        (["####"], .switch1U), (["#", "#", "#", "#"], .switch1U),
        (["#####"], .switch1U), (["#", "#", "#", "#", "#"], .switch1U),
        (["##", "##"], .server),
        (["###", "###", "###"], .server),
        (["#.", "##"], .ups), (["##", "#."], .ups), (["##", ".#"], .ups), ([".#", "##"], .ups),
        (["#..", "###"], .router), (["###", "..#"], .router), (["..#", "###"], .router), (["###", "#.."], .router),
        (["#.", "#.", "##"], .router), (["##", "#.", "#."], .router),
        (["###", ".#."], .router), ([".#.", "###"], .router),
    ]

    static let pieces: [Piece] = shapes.map { shape in
        var cells: [Cell] = []
        for (r, row) in shape.rows.enumerated() {
            for (c, ch) in row.enumerated() where ch == "#" { cells.append(Cell(row: r, column: c)) }
        }
        return Piece(cells: cells, kind: shape.kind)
    }

    /// A small seeded generator (SplitMix64): the same seed, the same game.
    struct Random: Codable, Equatable, Sendable {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    struct Game: Codable, Equatable, Sendable {
        /// Row-major, `size × size`; nil = empty, else the kind placed there.
        var board: [Kind?] = Array(repeating: nil, count: RackFill.size * RackFill.size)
        /// The hand; a placed slot is nil until all three are used.
        var hand: [Piece?] = []
        var score = 0
        /// Clears in a row (turns that each cleared something), for the bonus.
        var streak = 0
        var over = false
        var random: Random

        init(seed: UInt64) {
            random = Random(state: seed)
            deal()
        }

        func filled(_ row: Int, _ column: Int) -> Bool { board[row * RackFill.size + column] != nil }

        /// Whether `piece` fits with its top-left at (row, column).
        func fits(_ piece: Piece, row: Int, column: Int) -> Bool {
            piece.cells.allSatisfy { cell in
                let r = row + cell.row, c = column + cell.column
                return r >= 0 && c >= 0 && r < RackFill.size && c < RackFill.size && !filled(r, c)
            }
        }

        /// Whether `piece` fits anywhere.
        func fitsAnywhere(_ piece: Piece) -> Bool {
            for r in 0...(RackFill.size - piece.height) {
                for c in 0...(RackFill.size - piece.width) where fits(piece, row: r, column: c) { return true }
            }
            return false
        }

        /// The rows and columns that would be full after placing (for the view's preview).
        func wouldClear(_ piece: Piece, row: Int, column: Int) -> (rows: [Int], columns: [Int]) {
            var trial = self
            for cell in piece.cells { trial.board[(row + cell.row) * RackFill.size + column + cell.column] = piece.kind }
            return trial.fullLines()
        }

        private func fullLines() -> (rows: [Int], columns: [Int]) {
            let n = RackFill.size
            let rows = (0..<n).filter { r in (0..<n).allSatisfy { board[r * n + $0] != nil } }
            let columns = (0..<n).filter { c in (0..<n).allSatisfy { board[$0 * n + c] != nil } }
            return (rows, columns)
        }

        /// Places hand slot `slot` at (row, column). Returns the lines it cleared,
        /// nil when it does not fit (nothing changes).
        @discardableResult
        mutating func place(slot: Int, row: Int, column: Int) -> (rows: [Int], columns: [Int])? {
            guard !over, hand.indices.contains(slot), let piece = hand[slot], fits(piece, row: row, column: column) else { return nil }
            for cell in piece.cells { board[(row + cell.row) * RackFill.size + column + cell.column] = piece.kind }
            hand[slot] = nil
            let lines = fullLines()
            let n = RackFill.size
            for r in lines.rows { for c in 0..<n { board[r * n + c] = nil } }
            for c in lines.columns { for r in 0..<n { board[r * n + c] = nil } }
            score += RackFill.points(cells: piece.cells.count, lines: lines.rows.count + lines.columns.count, streak: streak)
            streak = lines.rows.isEmpty && lines.columns.isEmpty ? 0 : streak + 1
            if hand.allSatisfy({ $0 == nil }) { deal() }
            over = !hand.compactMap { $0 }.contains(where: fitsAnywhere)
            return lines
        }

        /// A new hand (the owner: "มีวิธีแก้ได้"): one that can be placed whole in
        /// SOME order — line clears on the way included — when the board allows
        /// it; else one where a piece at least fits; else what was drawn (the
        /// game is over then, and fairly: nothing could have been dealt).
        mutating func deal() {
            var fallback: [Piece?]?
            for _ in 0..<RackFill.dealTries {
                let drawn: [Piece?] = (0..<RackFill.handSize).map { _ in RackFill.pieces[random.below(RackFill.pieces.count)] }
                let fitting = drawn.compactMap { $0 }.filter(fitsAnywhere).count
                if fallback == nil, fitting > 0 { fallback = drawn }
                // Nothing fits now = the first piece can never go: skip the search. A piece
                // that fits only after another clears a line still counts (Fable).
                guard fitting > 0 else { continue }
                if solvable(drawn) { hand = drawn; return }
            }
            hand = fallback ?? (0..<RackFill.handSize).map { _ in RackFill.pieces[random.below(RackFill.pieces.count)] }
        }

        /// Whether every piece of `hand` can be placed, one after another, in some order.
        func solvable(_ hand: [Piece?]) -> Bool {
            let pieces = hand.compactMap { $0 }
            guard !pieces.isEmpty else { return true }
            for (i, piece) in pieces.enumerated() {
                for r in 0...(RackFill.size - piece.height) {
                    for c in 0...(RackFill.size - piece.width) where fits(piece, row: r, column: c) {
                        var next = self
                        next.lay(piece, row: r, column: c)
                        var rest = pieces; rest.remove(at: i)
                        if next.solvable(rest) { return true }
                    }
                }
            }
            return false
        }

        /// Puts a piece down and clears full lines — no score, no hand (the solver's step).
        private mutating func lay(_ piece: Piece, row: Int, column: Int) {
            let n = RackFill.size
            for cell in piece.cells { board[(row + cell.row) * n + column + cell.column] = piece.kind }
            let lines = fullLines()
            for r in lines.rows { for c in 0..<n { board[r * n + c] = nil } }
            for c in lines.columns { for r in 0..<n { board[r * n + c] = nil } }
        }
    }

    /// A placement's points, the genre's usual rules (the owner: "ให้ระบบเกมเป็น
    /// ของจริง"): a point per cell placed; 10 per line cleared, times the lines
    /// cleared at once (2 lines = double, 3 = triple …); and a streak bonus of
    /// 10 for every move in a row before this one that also cleared (+10, +20, …).
    /// A move that clears nothing resets the streak (`Game.place`).
    static func points(cells: Int, lines: Int, streak: Int) -> Int {
        guard lines > 0 else { return cells }
        return cells + 10 * lines * lines + 10 * streak
    }

    // MARK: Scores

    struct Score: Codable, Equatable, Sendable {
        let points: Int
        let date: Date
    }

    /// A finished game added to the top list: highest first, ties by the earlier date, at most `topCount`.
    static func recording(_ points: Int, at date: Date, into top: [Score]) -> [Score] {
        guard points > 0 else { return top }
        return Array((top + [Score(points: points, date: date)])
            .sorted { $0.points != $1.points ? $0.points > $1.points : $0.date < $1.date }
            .prefix(topCount))
    }

    static func loadTop(_ data: Data?) -> [Score] {
        guard let data, let list = try? JSONDecoder().decode([Score].self, from: data) else { return [] }
        return Array(list.sorted { $0.points > $1.points }.prefix(topCount))
    }
}
