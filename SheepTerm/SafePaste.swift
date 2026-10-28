import Foundation

/// "Is what is on the clipboard right now something a terminal session put
/// there (OSC 52)?" — the decision behind the planted-paste prompt, kept pure
/// so the standalone harness tests the real thing.
///
/// A device that may set the clipboard can plant `evil-cmd\n`; a one-line
/// paste with a trailing newline is not a multi-line paste, so Safe Paste
/// (and a local tab, which has none) would send it without asking and the
/// newline would run it. So every paste of device-written text asks first,
/// whatever Safe Paste says and in every tab kind.
///
/// Identity is the pasteboard's `changeCount` recorded right after the
/// device's write — process-wide, because every tab shares the one
/// pasteboard. Any other copy (here or in any other app) moves the count and
/// the prompt goes away on its own; nothing compares text.
nonisolated struct PlantedClipboard: Equatable, Sendable {
    /// The pasteboard's change count right after the last device write that
    /// actually reached it; nil when no device write ever did.
    private(set) var plantedChangeCount: Int?

    /// Every OSC 52 outcome lands here. A write that was blocked (setting
    /// off) or refused (too large) never touched the pasteboard, so it
    /// records nothing — and it does NOT forget an earlier plant either:
    /// turning the setting off later does not make text already planted safe.
    mutating func noteDeviceWrite(reachedPasteboard: Bool, changeCount: Int) {
        guard reachedPasteboard else { return }
        plantedChangeCount = changeCount
    }

    /// True when the clipboard still holds exactly what a device put there.
    func needsConfirmation(currentChangeCount: Int) -> Bool {
        guard let plantedChangeCount else { return false }
        return plantedChangeCount == currentChangeCount
    }

    static let previewLimit = 200

    /// The text as the prompt shows it: one line, every control character
    /// made visible (a line break is THE thing the user must see — it is
    /// what runs the command), bidi overrides neutralised so the preview
    /// cannot be made to read differently from what will be sent, and cut at
    /// `limit` characters with the remainder counted.
    static func preview(_ text: String, limit: Int = previewLimit) -> String {
        var out = ""
        var shown = 0
        var index = text.unicodeScalars.startIndex
        let scalars = text.unicodeScalars
        while index < scalars.endIndex {
            let scalar = scalars[index]
            var next = scalars.index(after: index)
            let piece: String
            switch scalar.value {
            case 0x0D:
                if next < scalars.endIndex, scalars[next].value == 0x0A { next = scalars.index(after: next) }
                piece = "⏎"
            case 0x0A:
                piece = "⏎"
            case 0x09:
                piece = "⇥"
            case 0x00...0x1F, 0x7F...0x9F,
                 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0x061C:
                piece = "\u{FFFD}"
            default:
                piece = String(scalar)
            }
            if shown >= limit {
                let rest = scalars[index...].count
                out += String(localized: "… (+\(rest) more)")
                return out
            }
            out += piece
            shown += 1
            index = next
        }
        return out
    }
}

/// What a running Safe Paste does with other input to the same tab. Nothing
/// may land BETWEEN two paced lines: a one-line paste there used to go out
/// at once and the device ran `10.0.0.1interface vlan 10`.
/// - a key the user typed stops the run (then goes out as typed) — in every
///   tab kind, the local shell included (the AI panel's review runs there);
/// - any other paste, snippet, broadcast line or AI paste is refused with a
///   beep while the run lasts — the multi-line one too, which used to cancel
///   the run for its own review: a config cut off by a second clipboard is
///   the same hole, and Stop / a key is one press away;
/// - the run's own lines pass.
nonisolated enum PacedRunGate {
    enum Input: Equatable { case keystroke, paste, pacedLine }
    enum Verdict: Equatable { case pass, stopRun, refuse }

    static func verdict(_ input: Input, runActive: Bool) -> Verdict {
        guard runActive else { return .pass }
        switch input {
        case .pacedLine: return .pass
        case .keystroke: return .stopRun
        case .paste: return .refuse
        }
    }
}

/// A name cut in the MIDDLE ("core-sw…-floor3") until `fits` accepts it —
/// the Safe Paste subtitle keeps its sentence whole and one line, and
/// gives way in the session name only (6.0 (12)). Both ends stay readable;
/// nothing fits → just "…".
nonisolated enum MiddleTruncation {
    static func fit(_ name: String, fits: (String) -> Bool) -> String {
        if fits(name) { return name }
        let characters = Array(name)
        var keep = characters.count - 1
        while keep > 0 {
            let head = (keep + 1) / 2
            let tail = keep - head
            let candidate = String(characters[..<head]) + "…" + String(characters[(characters.count - tail)...])
            if fits(candidate) { return candidate }
            keep -= 1
        }
        return "…"
    }
}

/// The paced run's clock (6.0 (12)): the delay between lines counts from
/// when a line has LEFT the session's worker, not from when the worker took
/// it. A serial (or telnet) worker accepts a line into its queue at once; at
/// 9600 baud a 50 ms gap timed from acceptance let lines pile up and leave
/// the UART back to back. So after each line (except the last): wait while
/// the worker still holds bytes (`drained` false — polled, nothing counted
/// or sent meanwhile), then one whole delay, then the next line. SSH and
/// local tabs are always drained. Windows: `PasteRun.readyToSend`.
///
/// The wait for a drain is CAPPED (`drainCap`): under hardware flow control
/// a device that holds CTS low leaves the line in the tty's output queue
/// for ever, and the worker's 60 s write-stall deadline never fires (the
/// worker's own write went through — the bytes sit below it). Past the cap
/// the run ends (`stalled`) and says the device is not taking input.
nonisolated struct PaceSchedule: Sendable {
    enum Step: Equatable, Sendable {
        case send(line: Int)
        /// The worker still holds bytes: poll again shortly.
        case waitForDrain
        /// The gap after a drained line, in milliseconds.
        case sleep(Int)
        case finish
        /// The sent line did not leave within `drainCap`: end the run.
        case stalled
    }
    static let drainPollMilliseconds = 10

    /// How long one line may take to leave: its time on the wire at `baud`
    /// (10 bits a byte) plus a second, never under 10 s — console gear holds
    /// flow control for seconds while an earlier `write memory` / `copy`
    /// runs, and that must not read as "not taking input" (review 6.0 (12):
    /// a 2 s floor was too tight); a flat 10 s when the speed is not known
    /// (telnet, or no line lengths given).
    static let drainFloorMilliseconds = 10_000
    static func drainCap(lineBytes: Int?, baud: Int?) -> Int {
        guard let lineBytes, let baud, baud > 0 else { return drainFloorMilliseconds }
        return max(drainFloorMilliseconds, lineBytes * 10 * 1000 / baud + 1000)
    }

    let total: Int
    let delayMilliseconds: Int
    /// Bytes of each line, by index (for `drainCap`); empty = unknown.
    let lineBytes: [Int]
    let baud: Int?
    private(set) var nextLine = 0
    /// Polls spent waiting for the current line, in milliseconds.
    private(set) var drainWaitedMilliseconds = 0
    private enum Phase: Sendable { case send, drain, done }
    private var phase: Phase

    init(total: Int, delayMilliseconds: Int, lineBytes: [Int] = [], baud: Int? = nil) {
        self.total = total
        self.delayMilliseconds = max(delayMilliseconds, 1)
        self.lineBytes = lineBytes
        self.baud = baud
        phase = total > 0 ? .send : .done
    }

    /// `drained` is asked only while a sent line waits to leave the worker.
    mutating func step(drained: () -> Bool) -> Step {
        switch phase {
        case .send:
            let line = nextLine
            nextLine += 1
            phase = nextLine < total ? .drain : .done
            drainWaitedMilliseconds = 0
            return .send(line: line)
        case .drain:
            guard drained() else {
                let line = nextLine - 1
                let cap = Self.drainCap(lineBytes: lineBytes.indices.contains(line) ? lineBytes[line] : nil, baud: baud)
                guard drainWaitedMilliseconds < cap else {
                    phase = .done
                    return .stalled
                }
                drainWaitedMilliseconds += Self.drainPollMilliseconds
                return .waitForDrain
            }
            phase = .send
            return .sleep(delayMilliseconds)
        case .done:
            return .finish
        }
    }
}

@MainActor
final class SafePastePacer {
    enum EndReason: Equatable {
        case finished
        case stopped
        case keyboardInput
        case sessionEnded
        case replaced
        /// The transport refused the line — the session's worker did NOT take
        /// those bytes, so the run must not be reported as finished.
        case inputDiscarded
        /// A line the worker took did not leave it within
        /// `PaceSchedule.drainCap` (flow control held, far end not reading).
        case deviceNotTakingInput
    }

    private var task: Task<Void, Never>?
    private var completion: ((EndReason, Int) -> Void)?
    private(set) var sentCount = 0

    var isActive: Bool { task != nil }

    /// - Parameter send: hands one line's bytes to the session and returns
    ///   whether they were ACCEPTED — meaning the session's worker took them
    ///   into its write queue. It is not, and cannot be, an acknowledgement
    ///   from the device: nothing in this design reads a reply back, so a
    ///   line that was accepted may still be rejected by the CLI at the far
    ///   end. Accepted is the strongest fact available here, and it is the
    ///   one the run needs: a refusal means those bytes went nowhere.
    ///
    /// - Parameter drained: whether the session's worker has put every byte
    ///   it accepted on the line (serial/telnet; SSH and local: always true).
    ///   The delay starts only then (`PaceSchedule`).
    ///
    /// - Parameter baud: the line's speed, for the drain cap (serial); nil =
    ///   unknown (telnet), a flat cap.
    func start(
        plan: SafePastePlan,
        delayMilliseconds: Int,
        send: @escaping ([UInt8]) -> Bool,
        drained: @escaping () -> Bool = { true },
        baud: Int? = nil,
        progress: @escaping (_ sent: Int, _ total: Int) -> Void,
        completion: @escaping (_ reason: EndReason, _ sent: Int) -> Void
    ) {
        stop(reason: .replaced)
        sentCount = 0
        self.completion = completion
        var schedule = PaceSchedule(total: plan.lines.count, delayMilliseconds: delayMilliseconds,
                                    lineBytes: plan.lines.indices.map { plan.bytes(forLine: $0).count }, baud: baud)

        task = Task { @MainActor [weak self] in
            while true {
                guard !Task.isCancelled, self != nil else { return }
                switch schedule.step(drained: drained) {
                case .send(let index):
                    // Acceptance is a VALUE handed straight back, not something
                    // inferred from the passage of time. The worker also reports
                    // a refusal through `onInputDiscarded`, but that hops to the
                    // main queue, so the old `await Task.yield()` before
                    // finishing was a hope, not a guarantee: a refused LAST line
                    // regularly showed N/N with no warning. The refusal now ends
                    // the run on the spot, and the line that was refused is not
                    // counted as sent.
                    guard send(plan.bytes(forLine: index)) else {
                        self?.finish(reason: .inputDiscarded)
                        return
                    }
                    self?.sentCount = index + 1
                    progress(index + 1, plan.lines.count)
                case .waitForDrain:
                    // Cancellable with the run. Bounded by the schedule's
                    // drain cap (`stalled` below), NOT by the worker's 60 s
                    // write-stall deadline: bytes held in the tty's output
                    // queue by flow control never trip that one.
                    do { try await Task.sleep(for: .milliseconds(PaceSchedule.drainPollMilliseconds)) } catch { return }
                case .sleep(let milliseconds):
                    do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
                case .finish:
                    guard !Task.isCancelled else { return }
                    self?.finish(reason: .finished)
                    return
                case .stalled:
                    guard !Task.isCancelled else { return }
                    self?.finish(reason: .deviceNotTakingInput)
                    return
                }
            }
        }
    }

    func stop(reason: EndReason) {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        let callback = completion
        completion = nil
        // sentCount counts only lines the session's worker ACCEPTED — the
        // send closure's answer is what advances it — so there is nothing to
        // discount here any more. The old `-1` for `.inputDiscarded` existed
        // because a line was counted before its fate was known; a refusal now
        // ends the run through `finish` before the count moves, and this
        // late-arriving stop finds the task already gone.
        callback?(reason, sentCount)
    }

    private func finish(reason: EndReason) {
        guard task != nil else { return }
        task = nil
        let callback = completion
        completion = nil
        callback?(reason, sentCount)
    }
}
