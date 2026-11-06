import CoreGraphics
import Foundation

/// A tab's stopwatch (6.1 (9), the owner: "นาฬิกาจับเวลา แบบลากได้ ในแต่ละ tab
/// ... จบเวลาอัพโหลด ... หยุดเวลาได้หลายรอบ ... note สั้นๆ Up Down Upgrade"):
/// start, pause, go on, lap as often as wanted, each lap with a few words.
/// Pure — the time is passed in — so the harness drives it
/// (`Tests/tests/StopwatchTests.swift`). Lives in memory with its tab.
nonisolated struct Stopwatch: Equatable, Sendable {
    struct Lap: Equatable, Sendable, Identifiable {
        let id: Int
        /// Time on the watch at the lap.
        let total: TimeInterval
        /// Since the lap before (or the start).
        let split: TimeInterval
        var note: String
    }

    /// The quick notes a lap offers; anything else can be typed.
    static let quickNotes = ["Up", "Down", "Upgrade", "Reboot", "Done"]
    /// A lap's note is kept short (the owner: "สั้นๆ").
    static let noteLimit = 24

    /// Time run before the current stretch (pauses excluded).
    private(set) var banked: TimeInterval = 0
    /// When the current stretch began; nil = stopped or paused.
    private(set) var runningSince: Date?
    private(set) var laps: [Lap] = []

    var isRunning: Bool { runningSince != nil }
    var hasStarted: Bool { isRunning || banked > 0 || !laps.isEmpty }

    func elapsed(at now: Date) -> TimeInterval {
        banked + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Start, or go on after a pause.
    mutating func start(at now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
    }

    mutating func pause(at now: Date) {
        guard let since = runningSince else { return }
        banked += max(0, now.timeIntervalSince(since))
        runningSince = nil
    }

    /// A lap at `now` with `note` (trimmed, cut to `noteLimit`). Newest last.
    @discardableResult
    mutating func lap(at now: Date, note: String = "") -> Lap? {
        guard hasStarted else { return nil }
        let total = elapsed(at: now)
        let split = total - (laps.last?.total ?? 0)
        let lap = Lap(id: (laps.last?.id ?? 0) + 1, total: total, split: split, note: Self.clean(note))
        laps.append(lap)
        return lap
    }

    mutating func setNote(_ note: String, lap id: Int) {
        guard let i = laps.firstIndex(where: { $0.id == id }) else { return }
        laps[i].note = Self.clean(note)
    }

    mutating func reset() { self = Stopwatch() }

    static func clean(_ note: String) -> String {
        String(note.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(noteLimit))
    }

    /// "12:47.3", "1:02:03.4" — tenths shown.
    static func text(_ t: TimeInterval) -> String {
        let tenths = Int((max(0, t) * 10).rounded(.down))
        let h = tenths / 36000, m = (tenths / 600) % 60, s = (tenths / 10) % 60, d = tenths % 10
        return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, s, d) : String(format: "%d:%02d.%d", m, s, d)
    }

    /// The lap's tint: Up / Done green, Down red, Upgrade / Reboot blue, else none.
    enum Tone: Equatable { case good, bad, work, plain }
    static func tone(_ note: String) -> Tone {
        switch note.lowercased() {
        case "up", "done", "ok": return .good
        case "down", "fail", "failed": return .bad
        case "upgrade", "reboot", "upload", "download": return .work
        default: return .plain
        }
    }

    // MARK: Where the cards start

    /// Watch `index`'s first spot over an area (offset from the right edge, from the top):
    /// side by side 262 pt apart, a new row 230 pt down while rows fit, then a 24 pt
    /// cascade — so no two land on the same spot once kept inside the area (Fable).
    static func cardSpot(_ index: Int, area: CGSize, card: CGSize = CGSize(width: 250, height: 200)) -> CGSize {
        let perRow = max(1, Int((area.width - 16) / 262))
        let rows = max(1, Int((area.height - 16 - card.height - 8) / 230) + 1)
        let laid = perRow * rows
        if index < laid { return CGSize(width: 16 + CGFloat(index % perRow) * 262, height: 16 + CGFloat(index / perRow) * 230) }
        let k = CGFloat(index - laid + 1)
        return CGSize(width: 16 + k * 24, height: 16 + k * 24)
    }

    /// Where a card at `offset` is drawn (its top-left), kept 8 pt inside the area — the card view's own rule.
    static func drawn(_ offset: CGSize, area: CGSize, card: CGSize = CGSize(width: 250, height: 200)) -> CGPoint {
        let x = min(max(8, area.width - card.width - offset.width), max(8, area.width - card.width - 8))
        let y = min(max(8, offset.height), max(8, area.height - card.height - 8))
        return CGPoint(x: x, y: y)
    }
}
