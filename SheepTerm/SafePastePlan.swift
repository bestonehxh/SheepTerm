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
