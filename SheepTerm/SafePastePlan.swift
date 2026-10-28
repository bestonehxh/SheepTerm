import Foundation

// Safe Paste's plan (how a multi-line paste is split and what each line
// sends) and the AI panel's paste route. Foundation only and in
// `sharedSources` (root Package.swift): SheepTerm for Windows compiles this
// same file — ARCHITECTURE.md "Shared with Windows". The pacer and the
// planted-clipboard rule stay in `SafePaste.swift`.

/// A bounded, normalized multi-line paste ready to be sent one command at a
/// time. Parsing is UI-independent so newline and size behaviour stays covered
/// by the standalone test harness.
public nonisolated struct SafePastePlan: Equatable, Sendable {
    public static let maxBytes = 5 * 1024 * 1024
    public static let maxLines = 10_000

    /// "Delay between lines" (Send Line by Line): the menu's choices and the
    /// default when nothing valid is saved (`safePasteDelayMilliseconds`).
    /// 100 ms since 6.0 (12) (was 200); a saved choice still wins.
    public static let delayChoices = [50, 100, 200, 300, 500, 1_000]
    public static let delayDefault = 100

    /// The delay the sheet starts on: the saved choice, else the default
    /// (UserDefaults answers 0 for a key never set).
    public static func delay(saved: Int) -> Int {
        delayChoices.contains(saved) ? saved : delayDefault
    }

    public enum ParseError: Error, Equatable, Sendable {
        case singleLine
        case tooManyBytes
        case tooManyLines
    }

    public let lines: [String]
    public let sourceByteCount: Int
    /// The AI panel's "Paste into Tab": the LAST line is typed without its
    /// CR, so the user presses Return on it themselves (`AIPasteRoute`).
    public var finalLineWithoutReturn = false

    public init(lines: [String], sourceByteCount: Int, finalLineWithoutReturn: Bool = false) {
        self.lines = lines
        self.sourceByteCount = sourceByteCount
        self.finalLineWithoutReturn = finalLineWithoutReturn
    }

    public static func parse(
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
    public func bytes(forLine index: Int) -> [UInt8] {
        if finalLineWithoutReturn, index == lines.count - 1 { return Array(lines[index].utf8) }
        return Array(lines[index].utf8) + [0x0D]
    }
}

extension SafePastePlan {
    /// A CLIPBOARD paste (⌘V and friends) as the review shows and the pacer
    /// sends it (6.0 (12)): cleaned by `PasteHygiene.cleaned` (so the line
    /// count, the dangerous-line marks and the bytes are one text), and the
    /// LAST line's Return only when the text itself ends with a line break —
    /// `…\nreload` copied without one must not run reload, the same as Paste
    /// Immediately. Snippets and the AI panel keep their own last-line rule
    /// (`CommandSendPlan.reviewed`, `AIPasteRoute`).
    public static func parseClipboard(
        _ text: String,
        maxBytes: Int = SafePastePlan.maxBytes,
        maxLines: Int = SafePastePlan.maxLines
    ) throws -> SafePastePlan {
        guard text.utf8.count <= maxBytes else { throw ParseError.tooManyBytes }
        let cleaned = PasteHygiene.cleaned(text)
        var plan = try parse(cleaned, maxBytes: maxBytes, maxLines: maxLines)
        plan.finalLineWithoutReturn = !PasteHygiene.endsWithLineBreak(cleaned)
        return plan
    }
}

/// What a paste may carry to a device (6.0 (12), shared with Windows).
/// One rule for snippets, the broadcast line and clipboard pastes: escape
/// sequences, C0/C1 controls (Tab and LF kept, DEL dropped) and bidi /
/// direction marks out — a line that reads one way in the review must not
/// send another (U+202E reverses what is shown; ESC or NUL reach the device
/// unseen).
public nonisolated enum PasteHygiene {
    /// Clipboard text: CR LF, CR, U+2028, U+2029 and NEL (U+0085) become LF
    /// first — the review's text view breaks lines on all of them, so the
    /// splitter must too — then `commandText`.
    public static func cleaned(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previousCR = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousCR { scalars.append("\n") }
                previousCR = false
            case 0x0D, 0x2028, 0x2029, 0x85:
                scalars.append("\n")
                previousCR = scalar.value == 0x0D
            default:
                scalars.append(scalar)
                previousCR = false
            }
        }
        return commandText(String(scalars))
    }

    /// The text ends with a line break (after `cleaned`, LF is the only one).
    public static func endsWithLineBreak(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last?.value else { return false }
        return last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029 || last == 0x85
    }

    /// `text` with every escape SEQUENCE and every C0/C1 control and bidi
    /// override removed, keeping Tab and LF. Whole sequences, not just the
    /// ESC: dropping the ESC alone would leave `[2J` to be typed as text.
    /// (Was `SnippetCodec.commandText`, which now forwards here.)
    public static func commandText(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func skipCSI() {           // parameters/intermediates 0x20–0x3F, final 0x40–0x7E
            while i < scalars.count, scalars[i].value < 0x40 || scalars[i].value > 0x7E { i += 1 }
            if i < scalars.count { i += 1 }
        }
        func skipString() {        // OSC/DCS/APC/PM body until BEL or ST (ESC \ or 0x9C)
            while i < scalars.count {
                let v = scalars[i].value
                if v == 0x07 || v == 0x9C { i += 1; return }
                if v == 0x1B {
                    i += 1
                    if i < scalars.count, scalars[i].value == 0x5C { i += 1 }
                    return
                }
                i += 1
            }
        }
        while i < scalars.count {
            let v = scalars[i].value
            switch v {
            case 0x1B:
                i += 1
                guard i < scalars.count else { break }
                switch scalars[i].value {
                case 0x5B: i += 1; skipCSI()                              // ESC [
                case 0x5D, 0x50, 0x5E, 0x5F: i += 1; skipString()          // ESC ] P ^ _
                default: i += 1                                           // ESC + one byte
                }
            case 0x9B: i += 1; skipCSI()                                   // C1 CSI
            case 0x9D, 0x90, 0x9E, 0x9F: i += 1; skipString()              // C1 OSC DCS APC PM
            case 0x09, 0x0A:
                out.append(scalars[i]); i += 1
            case _ where v < 0x20 || v == 0x7F || (v >= 0x80 && v < 0xA0):
                i += 1
            case 0x2028, 0x2029, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0x061C:
                i += 1
            default:
                out.append(scalars[i]); i += 1
            }
        }
        return String(out)
    }
}

/// How an AI answer's code block reaches a session ("Paste into Tab"). The
/// model must never be able to run anything:
/// - one line → typed with NO Return, no question;
/// - several lines → ALWAYS the Safe Paste review (also in a local tab and
///   with Safe Paste off in Settings), sent line by line, the last line
///   typed WITHOUT its CR — the user reads it on the prompt and presses
///   Return. There is no "Paste Immediately" for it (that would send every
///   line's newline).
/// Ordinary pastes (⌘V, snippets, broadcast) never come here.
public nonisolated enum AIPasteRoute: Equatable, Sendable {
    case empty
    case typeLine(String)
    case review(SafePastePlan)
    case refused(SafePastePlan.ParseError)

    public static func route(_ code: String) -> AIPasteRoute {
        let text = AIAnswerParser.pasteText(code)
        guard !text.isEmpty else { return .empty }
        do {
            var plan = try SafePastePlan.parse(text)
            plan.finalLineWithoutReturn = true
            return .review(plan)
        } catch SafePastePlan.ParseError.singleLine {
            // `pasteText` already removed every line break; belt and braces.
            return .typeLine(text.filter { $0 != "\n" && $0 != "\r" && $0 != "\r\n" })
        } catch let error as SafePastePlan.ParseError {
            return .refused(error)
        } catch {
            return .refused(.tooManyBytes)
        }
    }

    /// Every byte the route would hand the session, in order (tests; the
    /// review case as the pacer sends it after "Send Line by Line").
    public var wireBytes: [UInt8] {
        switch self {
        case .empty, .refused: return []
        case .typeLine(let line): return Array(line.utf8)
        case .review(let plan): return plan.lines.indices.flatMap { plan.bytes(forLine: $0) }
        }
    }
}
