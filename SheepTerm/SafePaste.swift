import Foundation

/// A bounded, normalized multi-line paste ready to be sent one command at a
/// time. Parsing is UI-independent so newline and size behaviour stays covered
/// by the standalone test harness.
nonisolated struct SafePastePlan: Equatable, Sendable {
    static let maxBytes = 5 * 1024 * 1024
    static let maxLines = 10_000

    enum ParseError: Error, Equatable {
        case singleLine
        case tooManyBytes
        case tooManyLines
    }

    let lines: [String]
    let sourceByteCount: Int

    static func parse(
        _ text: String,
        maxBytes: Int = SafePastePlan.maxBytes,
        maxLines: Int = SafePastePlan.maxLines
    ) throws -> SafePastePlan {
        let byteCount = text.utf8.count
        guard byteCount <= maxBytes else { throw ParseError.tooManyBytes }

        // Clipboard text can come from Unix, Windows, or a serial capture.
        // Split on any of "\r\n", "\r", or "\n" in one pass instead of
        // normalizing then splitting (each of those was a full string copy,
        // and this can run on paste text up to maxBytes on the main actor).
        // Scanning is done over UTF-8 bytes, not Characters: grapheme-cluster
        // iteration walks the Unicode segmentation algorithm at every step,
        // which is far more expensive than a byte comparison. A byte scan is
        // safe here because UTF-8 continuation bytes are always >= 0x80, so
        // 0x0D and 0x0A can only ever appear as themselves, never as part of
        // a multi-byte character's encoding - the scan cannot split a
        // character. Removing exactly one terminal empty component consumes
        // the separator after the final command while preserving intentional
        // blank lines.
        let utf8 = text.utf8
        var lines: [String] = []
        var start = utf8.startIndex
        var idx = utf8.startIndex
        while idx < utf8.endIndex {
            let byte = utf8[idx]
            // Refuse as soon as the cap is passed, not after every line of a
            // 5 MB clipboard has been materialised on the main actor.
            if lines.count > maxLines { throw ParseError.tooManyLines }
            if byte == 0x0D {
                lines.append(String(decoding: utf8[start..<idx], as: UTF8.self))
                var next = utf8.index(after: idx)
                if next < utf8.endIndex, utf8[next] == 0x0A {
                    next = utf8.index(after: next)
                }
                idx = next
                start = idx
            } else if byte == 0x0A {
                lines.append(String(decoding: utf8[start..<idx], as: UTF8.self))
                idx = utf8.index(after: idx)
                start = idx
            } else {
                idx = utf8.index(after: idx)
            }
        }
        lines.append(String(decoding: utf8[start...], as: UTF8.self))
        if lines.last == "" { lines.removeLast() }

        guard lines.count > 1 else { throw ParseError.singleLine }
        guard lines.count <= maxLines else { throw ParseError.tooManyLines }
        return SafePastePlan(lines: lines, sourceByteCount: byteCount)
    }

    /// Network CLIs expect the Return key (CR), not a clipboard's platform
    /// newline. Safe mode deliberately submits the final line too; the user
    /// chose "Send N Lines", rather than byte-for-byte immediate paste.
    func bytes(forLine index: Int) -> [UInt8] {
        Array(lines[index].utf8) + [0x0D]
    }
}

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
                out += "… (+\(rest) more)"
                return out
            }
            out += piece
            shown += 1
            index = next
        }
        return out
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
    func start(
        plan: SafePastePlan,
        delayMilliseconds: Int,
        send: @escaping ([UInt8]) -> Bool,
        progress: @escaping (_ sent: Int, _ total: Int) -> Void,
        completion: @escaping (_ reason: EndReason, _ sent: Int) -> Void
    ) {
        stop(reason: .replaced)
        sentCount = 0
        self.completion = completion
        let delay = max(delayMilliseconds, 1)

        task = Task { @MainActor [weak self] in
            for index in plan.lines.indices {
                guard !Task.isCancelled, self != nil else { return }
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
                guard index + 1 < plan.lines.count else { continue }
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.finish(reason: .finished)
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
