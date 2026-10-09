import Foundation

/// A saved command (4.2 (4)): what the Snippets menu sends to the current
/// tab. Pure model + codec + the broadcast plan, compiled into
/// `Tests/run.sh tests`; the store with its alerts is `SnippetStore`.
nonisolated struct Snippet: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// What is typed. May hold several lines; they reach the device the way
    /// a paste does (Safe Paste asks about a multi-line one).
    var text: String
    /// Press Return after the text (the common case for a command).
    var sendReturn = true

    /// The bytes-as-text handed to `TerminalView.pasteText`: the text, plus a
    /// newline when Return is wanted (the paste encoder turns newlines into
    /// CR, which is what a terminal's Return sends).
    var payload: String { sendReturn ? text + "\n" : text }
}

// MainActor (not `nonisolated`): `ConfigurationHygiene.cleanedName` is main-actor bound.
enum SnippetCodec {
    /// Same hygiene every other name in the app gets: control characters
    /// out, ends trimmed, length capped; an empty result gets a placeholder.
    static func cleanedName(_ raw: String) -> String {
        let cleaned = ConfigurationHygiene.cleanedName(raw)
        return cleaned.isEmpty ? "Unnamed Snippet" : cleaned
    }

    /// Normalise what the editor hands over: name cleaned, CR LF / CR folded
    /// to LF so the stored text is one shape, trailing newlines dropped (the
    /// `sendReturn` switch owns the final Return), and every control
    /// character but Tab and LF removed — a command has no use for ESC or
    /// C1 controls, and a snippets.json (or a restored backup) that carried
    /// one could otherwise type an escape sequence straight into a device.
    static func normalised(_ snippet: Snippet) -> Snippet {
        var out = snippet
        out.name = cleanedName(snippet.name)
        var text = snippet.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = commandText(text)
        while text.hasSuffix("\n") { text.removeLast() }
        out.text = text
        return out
    }

    /// `text` with every escape SEQUENCE and every C0/C1 control and bidi
    /// override removed, keeping Tab and LF. Whole sequences, not just the
    /// ESC: dropping the ESC alone would leave `[2J` to be typed as text.
    /// Shared by snippets and the broadcast line.
    nonisolated static func commandText(_ text: String) -> String {
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
            case 0x2028, 0x2029, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                i += 1
            default:
                out.append(scalars[i]); i += 1
            }
        }
        return String(out)
    }

    static func encode(_ snippets: [Snippet]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snippets)
    }

    static func decode(_ data: Data) throws -> [Snippet] {
        var seen = Set<UUID>()
        return try JSONDecoder().decode([Snippet].self, from: data).map { raw in
            var snippet = normalised(raw)
            // A hand-edited file with two entries on one id would make the
            // menu's ForEach ambiguous and `remove` delete both.
            if !seen.insert(snippet.id).inserted { snippet.id = UUID(); seen.insert(snippet.id) }
            return snippet
        }
    }
}

/// Broadcast (4.2 (4)): one line to several tabs at once. The plan is pure
/// so the eligibility rule is tested without a UI: only SSH and serial tabs
/// that are connected can take a command, and nothing is sent to a tab that
/// was not ticked.
nonisolated enum BroadcastPlan {
    struct Candidate: Equatable, Sendable {
        var id: UUID
        var title: String
        var kind: ConnectionKind
        /// The tab's status line; nil while connecting.
        var status: String?

        /// A live remote session. A local shell is left out on purpose (a
        /// broadcast is for devices), and so is a tab that is connecting,
        /// disconnected or reconnecting — the text would go nowhere, or to
        /// a login prompt.
        var eligible: Bool {
            guard kind != .local, let status else { return false }
            return !status.hasPrefix("disconnected") && !status.hasPrefix("reconnect")
        }
    }

    /// The tabs a broadcast may go to, in tab order.
    static func eligible(_ tabs: [Candidate]) -> [Candidate] {
        tabs.filter(\.eligible)
    }

    /// What one Send does: the text (one line, Return appended) for each
    /// ticked AND eligible tab. Empty text or no ticks = nothing.
    static func sends(text: String, to ticked: Set<UUID>, among tabs: [Candidate]) -> [(id: UUID, payload: String)] {
        // One line: controls out (same rule as a snippet), then only what is
        // before the first newline — a pasted paragraph is not a broadcast.
        let cleaned = SnippetCodec.commandText(text)
        let firstLine = cleaned.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let line = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !ticked.isEmpty else { return [] }
        return eligible(tabs).filter { ticked.contains($0.id) }.map { ($0.id, line + "\n") }
    }
}

/// Snippet variables (5.0 (1)): `{{name}}` and `{{name=default}}` in a
/// snippet body (or a broadcast line) are asked for once before sending.
/// Name = letters, digits, `_`, `-`, case-sensitive. The default runs to the
/// first `}}` and may be empty. Anything that is not a well-formed
/// placeholder — `{{`, `{{ a }}`, `{{a b}}`, `{{a`, a default with a line
/// break — is ordinary text and passes through untouched, so a body that
/// never used the feature behaves exactly as before.
nonisolated enum SnippetVariables {
    enum Token: Equatable, Sendable {
        case text(String)
        case variable(name: String, defaultValue: String?)
    }

    struct Variable: Equatable, Sendable {
        var name: String
        var defaultValue: String?
    }

    static func isNameCharacter(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        return c.isLetter || c.isNumber || c == "_" || c == "-"
    }

    static func tokens(_ template: String) -> [Token] {
        let chars = Array(template)
        var out: [Token] = []
        var text = ""
        var i = 0
        func flush() { if !text.isEmpty { out.append(.text(text)); text = "" } }
        while i < chars.count {
            if chars[i] == "{", i + 1 < chars.count, chars[i + 1] == "{", let (token, next) = placeholder(chars, at: i) {
                flush()
                out.append(token)
                i = next
            } else {
                text.append(chars[i])
                i += 1
            }
        }
        flush()
        return out
    }

    /// A placeholder starting at `start` (the first `{`), and the index after it.
    private static func placeholder(_ chars: [Character], at start: Int) -> (Token, Int)? {
        var i = start + 2
        let nameStart = i
        while i < chars.count, isNameCharacter(chars[i]) { i += 1 }
        guard i > nameStart else { return nil }
        let name = String(chars[nameStart..<i])
        if i + 1 < chars.count, chars[i] == "}", chars[i + 1] == "}" {
            return (.variable(name: name, defaultValue: nil), i + 2)
        }
        guard i < chars.count, chars[i] == "=" else { return nil }
        i += 1
        let valueStart = i
        while i + 1 < chars.count {
            if chars[i] == "\n" || chars[i] == "\r" { return nil }
            if chars[i] == "}", chars[i + 1] == "}" {
                return (.variable(name: name, defaultValue: String(chars[valueStart..<i])), i + 2)
            }
            i += 1
        }
        return nil
    }

    static func hasPlaceholders(_ template: String) -> Bool {
        guard template.contains("{{") else { return false }
        return tokens(template).contains { if case .variable = $0 { return true } else { return false } }
    }

    /// Each distinct name once, in order of first appearance; the default is
    /// the first one given for that name.
    static func variables(in template: String) -> [Variable] {
        var order: [String] = []
        var defaults: [String: String] = [:]
        for case .variable(let name, let def) in tokens(template) {
            if !order.contains(name) { order.append(name) }
            if defaults[name] == nil, let def { defaults[name] = def }
        }
        return order.map { Variable(name: $0, defaultValue: defaults[$0]) }
    }

    /// Why `value` cannot be used, or nil. A line break would turn one
    /// command into two — and run the second without being asked.
    static func error(for value: String) -> String? {
        value.unicodeScalars.contains { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" || $0 == "\u{85}" }
            ? "No line breaks in a value." : nil
    }

    /// The text with every placeholder replaced: the typed value, else the
    /// placeholder's own default, else (nothing given for it) the placeholder
    /// text itself. Controls are stripped from the result the way a snippet's
    /// are, so the preview is what is sent.
    static func render(_ template: String, values: [String: String]) -> String {
        var out = ""
        var defaults: [String: String] = [:]
        for v in variables(in: template) { if let d = v.defaultValue { defaults[v.name] = d } }
        for token in tokens(template) {
            switch token {
            case .text(let s): out += s
            case .variable(let name, _):
                if let v = values[name] ?? defaults[name] { out += v } else { out += "{{\(name)}}" }
            }
        }
        return SnippetCodec.commandText(out)
    }

    /// What the form starts each field with: the value last used for that name
    /// in this run, else the default, else empty.
    static func initialValues(for template: String, remembered: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for v in variables(in: template) { out[v.name] = remembered[v.name] ?? v.defaultValue ?? "" }
        return out
    }
}
