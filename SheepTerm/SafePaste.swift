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
/// or sent meanwhile), then the QUIET gap, then the next line. SSH tabs are
/// always drained. Windows: `PasteRun.readiness`.
///
/// The quiet gap (6.0 (14), seen on an Aruba 2930F console): the delay is
/// counted from the DEVICE's last byte, not from ours. A `show system` at
/// 9600 prints for seconds; the next line sent into that output lost its
/// first character (ArubaOS-Switch drops type-ahead while printing — Cisco
/// and Huawei buffer it, a console cable meets both). So after the drain the
/// run polls `quietFor` — milliseconds since the last byte the session
/// received AFTER this line went out, nil = nothing yet — and sends only once
/// the device has been quiet for the whole delay AND its prompt is back
/// (`promptAtEnd`: the last line ends in `#` `>` `$` `%` `]`) — or, with no
/// prompt-like line at all, quiet for `promptFallbackMilliseconds`. The
/// prompt matters: the same 2930F PAUSES in the middle of `show system`
/// (gathering counters) for longer than the delay, and a line sent into that
/// pause lost its first character just the same (seen live). Nothing
/// received since the line went out = wait up to `firstReplyGraceMilliseconds`
/// (or the delay, if longer) for the device's first byte, then take it as
/// silent (a device that does not echo, or a shell with no reply) — the echo
/// of a console line can take > 50 ms to reach the app (seen with a pty
/// bridge on the 2930F: a line sent blind into the start of the output). A device that never falls quiet
/// (a debug log streaming) ends the run after `quietCapMilliseconds` with
/// `.stillSending`, which says so; Paste Immediately is the way past it. A
/// pager prompt is answered during the run (the controllers' Auto-page path)
/// and each answer restarts that cap (`noteProgress`); the line after a paged
/// output also waits `pagedSettleMilliseconds` of silence with the prompt back.
/// The 2 s fallback never types into a pager prompt (`pagerShown`); a run
/// stuck at one ends after the cap with `.atPager`.
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
        /// Drained; the device has not been quiet for the whole delay yet: poll again shortly.
        case waitForQuiet
        case finish
        /// The sent line did not leave within `drainCap`: end the run.
        case stalled
        /// The device kept sending for `quietCapMilliseconds` after the line left: end the run.
        case stillSending
        /// The cap passed with the device sitting at a pager prompt nobody turned: end the run.
        case atPager
    }
    static let drainPollMilliseconds = 10
    /// How long the run waits for the device to fall quiet before giving up.
    static let quietCapMilliseconds = 60_000
    /// Quiet this long with no prompt-like last line counts as the end of the
    /// device's output anyway (a menu, a pager, a CLI whose prompt ends oddly).
    static let promptFallbackMilliseconds = 2_000
    /// After a PAGED output the prompt alone is not enough: an ArubaOS-Switch
    /// does housekeeping once its pager ends and drops input for ~100+ ms
    /// (seen live: `show version` after a paged `show running-config` arrived
    /// as `rsion`). A line whose output was paged waits for its prompt and
    /// at least this much silence; an unpaged line keeps the plain delay.
    static let pagedSettleMilliseconds = 500
    /// Nothing back yet since the line went out: wait this long for the
    /// device's first byte (its echo) before taking it as silent. Seen with a
    /// pty bridge logging every byte to and from a 2930F: `show version` left
    /// 54 ms after `show running-config\r`, BEFORE the echo of line 1 reached
    /// the app (FTDI latency + the main-queue feed put the first byte > 50 ms
    /// out), so the run took the device for silent and sent blind; the switch
    /// was starting to print, dropped "show ve" and kept "rsion".
    static let firstReplyGraceMilliseconds = 1_000

    /// Whether the device's last line reads like a prompt — it is waiting for
    /// input: after dropping escape sequences and trailing blanks, the line
    /// ends in `#` `>` `$` `%` or `]` (Cisco `Switch#` / `(config)#`, Huawei
    /// `<HW>` / `[HW]`, FortiGate `FG # `, Aruba `sw# `, Linux `$`, MikroTik
    /// `] >`). Deliberately NOT `:` or `?`: a 2930F's `System Location  :` is a
    /// line in the middle of `show system`, right where it pauses; a password
    /// or `(y/n)?` prompt is reached by the fallback instead.
    static func promptAtEnd(_ tail: [UInt8]) -> Bool {
        var line = tail[...]
        if let nl = line.lastIndex(of: 0x0A) { line = line[(nl + 1)...] }
        if let cr = line.lastIndex(of: 0x0D) { line = line[(cr + 1)...] }
        var clean: [UInt8] = []
        var i = line.startIndex
        while i < line.endIndex {
            let b = line[i]
            if b == 0x1B {
                i += 1
                guard i < line.endIndex else { break }
                switch line[i] {
                case 0x5B:                                  // CSI … final 0x40–0x7E
                    i += 1
                    while i < line.endIndex, !(0x40...0x7E).contains(line[i]) { i += 1 }
                    if i < line.endIndex { i += 1 }
                case 0x5D, 0x50, 0x5E, 0x5F:                // OSC / DCS / PM / APC … BEL or ESC \
                    i += 1
                    while i < line.endIndex, line[i] != 0x07, line[i] != 0x1B { i += 1 }
                    if i < line.endIndex { i += line[i] == 0x1B ? 2 : 1 }
                default:                                    // ESC + one byte
                    i += 1
                }
                continue
            }
            if b >= 0x20 || b == 0x09 { clean.append(b) }
            i += 1
        }
        while let last = clean.last, last == 0x20 || last == 0x09 { clean.removeLast() }
        guard let last = clean.last, clean.count <= 200 else { return false }
        return last == UInt8(ascii: "#") || last == UInt8(ascii: ">") || last == UInt8(ascii: "$") || last == UInt8(ascii: "%") || last == UInt8(ascii: "]")
    }

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
    /// Polls spent waiting for the device to fall quiet after the current line, in milliseconds.
    private(set) var quietWaitedMilliseconds = 0
    private enum Phase: Sendable { case send, drain, quiet, done }
    private var phase: Phase

    init(total: Int, delayMilliseconds: Int, lineBytes: [Int] = [], baud: Int? = nil) {
        self.total = total
        self.delayMilliseconds = max(delayMilliseconds, 1)
        self.lineBytes = lineBytes
        self.baud = baud
        phase = total > 0 ? .send : .done
    }

    /// The device made progress that is not silence — a pager prompt was
    /// answered for this run (`-- MORE --` → space): the quiet cap starts
    /// over, so a long paged output is not ended as "still sending".
    mutating func noteProgress() {
        quietWaitedMilliseconds = 0
        pagedThisLine = true
    }
    /// A pager prompt was answered for the current line's output
    /// (`noteProgress`): the next line needs `pagedSettleMilliseconds` of
    /// silence with the prompt back. Cleared when a line is sent.
    private(set) var pagedThisLine = false

    /// `drained` is asked only while a sent line waits to leave the worker;
    /// `quietFor` only after it left: milliseconds since the last byte the
    /// session received AFTER the line went out, nil = none yet;
    /// `promptShown` whether the device's last line is a prompt (`promptAtEnd`).
    /// `pagerShown` whether it is a pager prompt (`PagerPrompt.endsWithPrompt`): the fallback never types into one.
    mutating func step(drained: () -> Bool, quietFor: () -> Int? = { nil }, promptShown: () -> Bool = { true }, pagerShown: () -> Bool = { false }) -> Step {
        switch phase {
        case .send:
            let line = nextLine
            nextLine += 1
            phase = nextLine < total ? .drain : .done
            drainWaitedMilliseconds = 0
            quietWaitedMilliseconds = 0
            pagedThisLine = false
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
            phase = .quiet
            quietWaitedMilliseconds = 0
            return step(drained: drained, quietFor: quietFor, promptShown: promptShown, pagerShown: pagerShown)
        case .quiet:
            if let quiet = quietFor() {
                // The device answered: the whole delay of silence after its last
                // byte, and its prompt back (or the fallback's silence without one);
                // after a paged output, the prompt plus the settle's silence. The
                // fallback never applies at a pager prompt: the line would quit
                // the pager (ArubaOS-Switch) or turn its page — the answer path
                // moves it on (`noteProgress`), the cap still ends a stuck one.
                let settle = pagedThisLine ? max(delayMilliseconds, Self.pagedSettleMilliseconds) : delayMilliseconds
                if quiet >= delayMilliseconds,
                   promptShown() ? quiet >= settle : (quiet >= Self.promptFallbackMilliseconds && !pagerShown()) {
                    phase = .send
                    return step(drained: drained, quietFor: quietFor, promptShown: promptShown, pagerShown: pagerShown)
                }
                guard quietWaitedMilliseconds < Self.quietCapMilliseconds else {
                    phase = .done
                    return pagerShown() && !promptShown() ? .atPager : .stillSending
                }
            } else if quietWaitedMilliseconds >= max(delayMilliseconds, Self.firstReplyGraceMilliseconds) {
                // Nothing came back at all: the device is silent (or does not echo)
                // after the first-reply grace — never sooner, the echo may be late.
                phase = .send
                return step(drained: drained, quietFor: quietFor, promptShown: promptShown, pagerShown: pagerShown)
            }
            quietWaitedMilliseconds += Self.drainPollMilliseconds
            return .waitForQuiet
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
        /// The device kept sending for `PaceSchedule.quietCapMilliseconds`
        /// after a line left (a log streaming): the next line would be lost in it.
        case deviceStillSending
        /// The cap passed with the device at a pager prompt (two spaces lost,
        /// or a pager the detector does not answer): typing on would quit it.
        case deviceAtPager
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
    /// - Parameter lastDeviceByte: when the session last received a byte
    ///   from the device (any byte, the echo included); nil = never. The
    ///   quiet gap counts from it (`PaceSchedule`, 6.0 (14)).
    ///
    /// - Parameter deviceTail: the device's last (partial) line, for
    ///   `PaceSchedule.promptAtEnd`; empty = nothing known.
    ///
    /// - Parameter lastPagerAnswer: when the session last answered a pager
    ///   prompt for this run; a newer one than the run has seen is progress
    ///   (`PaceSchedule.noteProgress`). nil = never.
    ///
    /// - Parameter baud: the line's speed, for the drain cap (serial); nil =
    ///   unknown (telnet), a flat cap.
    func start(
        plan: SafePastePlan,
        delayMilliseconds: Int,
        send: @escaping ([UInt8]) -> Bool,
        drained: @escaping () -> Bool = { true },
        lastDeviceByte: @escaping () -> Date? = { nil },
        deviceTail: @escaping () -> [UInt8] = { [] },
        lastPagerAnswer: @escaping () -> Date? = { nil },
        baud: Int? = nil,
        progress: @escaping (_ sent: Int, _ total: Int) -> Void,
        completion: @escaping (_ reason: EndReason, _ sent: Int) -> Void
    ) {
        stop(reason: .replaced)
        sentCount = 0
        self.completion = completion
        var schedule = PaceSchedule(total: plan.lines.count, delayMilliseconds: delayMilliseconds,
                                    lineBytes: plan.lines.indices.map { plan.bytes(forLine: $0).count }, baud: baud)

        // The moment the current line went out: only bytes that arrived
        // after it count as the device's answer to it.
        var sentAt = Date.distantPast
        let quietFor: () -> Int? = {
            guard let last = lastDeviceByte(), last > sentAt else { return nil }
            return max(0, Int(Date().timeIntervalSince(last) * 1000))
        }
        // A pager answered for this run (the controller sends the space) is
        // progress: the quiet cap starts over.
        var seenPagerAnswer = lastPagerAnswer() ?? .distantPast
        task = Task { @MainActor [weak self] in
            while true {
                guard !Task.isCancelled, self != nil else { return }
                if let answered = lastPagerAnswer(), answered > seenPagerAnswer {
                    seenPagerAnswer = answered
                    schedule.noteProgress()
                }
                switch schedule.step(drained: drained, quietFor: quietFor, promptShown: { PaceSchedule.promptAtEnd(deviceTail()) },
                                     pagerShown: { PagerPrompt.endsWithPrompt(deviceTail()) }) {
                case .send(let index):
                    sentAt = Date()
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
                case .waitForQuiet:
                    do { try await Task.sleep(for: .milliseconds(PaceSchedule.drainPollMilliseconds)) } catch { return }
                case .finish:
                    guard !Task.isCancelled else { return }
                    self?.finish(reason: .finished)
                    return
                case .stalled:
                    guard !Task.isCancelled else { return }
                    self?.finish(reason: .deviceNotTakingInput)
                    return
                case .stillSending:
                    guard !Task.isCancelled else { return }
                    self?.finish(reason: .deviceStillSending)
                    return
                case .atPager:
                    guard !Task.isCancelled else { return }
                    self?.finish(reason: .deviceAtPager)
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
