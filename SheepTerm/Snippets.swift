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

    /// The synthesized Codable's keys, listed so `UnknownFields` can keep the
    /// ones a newer build adds. A new field goes here too.
    enum CodingKeys: String, CodingKey, CaseIterable { case id, name, text, sendReturn }
}

/// Edit Snippets' form (`SnippetsSheet`): nothing typed there is lost unless
/// the user chooses so (Esc, Cancel Edit). Done used to hold Return and close
/// the sheet over a half-typed snippet or an open edit, dropping it.
nonisolated enum SnippetFormPlan {
    /// What Done does.
    enum Done: Equatable { case close, commitThenClose, stay }

    /// Return belongs to Add/Save while there is something to write
    /// (`isPending`); otherwise to Done. An edit left as it was is Done: Save
    /// there rewrote snippets.json for nothing and left the sheet up
    /// (review 6.1 (62)).
    static func returnCommits(editing: Snippet?, name: String, text: String, sendReturn: Bool) -> Bool {
        isPending(editing: editing, name: name, text: text, sendReturn: sendReturn)
    }

    /// Something in the form that is not in the list: new text, or an edit
    /// that changed the snippet. An edit left as it was is not — Done then
    /// writes nothing (a write would also re-arm a quarantined snippets.json).
    static func isPending(editing: Snippet?, name: String, text: String, sendReturn: Bool) -> Bool {
        if let editing { return editing.name != name || editing.text != text || editing.sendReturn != sendReturn }
        return !blank(name) || !blank(text)
    }

    /// Add/Save's own rule: a command to send.
    static func canCommit(text: String) -> Bool { !blank(text) }

    static func done(editing: Snippet?, name: String, text: String, sendReturn: Bool) -> Done {
        guard isPending(editing: editing, name: name, text: text, sendReturn: sendReturn) else { return .close }
        return canCommit(text: text) ? .commitThenClose : .stay
    }

    /// An edit whose snippet went away meanwhile (Sync, another window) is
    /// added back rather than dropped.
    static func commitAdds(editing: Snippet?, existing: [Snippet]) -> Bool {
        guard let editing else { return true }
        return !existing.contains { $0.id == editing.id }
    }

    private static func blank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// How app-composed text reaches the device (Snippets, Broadcast): the body
/// is PASTED and the Return is its own CR afterwards. Folding the newline into
/// the paste puts the CR inside ESC[200~…ESC[201~ when the shell asked for
/// bracketed paste (bash/zsh), so the command is inserted but never run. A
/// network CLI that never asked for it sees body then CR, the same bytes as
/// before. Same shape as the Windows port.
nonisolated enum CommandSendPlan {
    /// `payload` as `Snippet.payload` / `BroadcastPlan.sends` build it: one
    /// trailing LF means "press Return"; everything before it is the body.
    static func split(_ payload: String) -> (body: String, thenReturn: Bool) {
        guard payload.hasSuffix("\n") else { return (payload, false) }
        return (String(payload.dropLast()), true)
    }

    /// The bytes of the separate Return.
    static let returnKey: [UInt8] = [0x0D]

    /// What Safe Paste's review sends for text it took over. `thenReturn` is
    /// the split's answer when the text is a command's body (`sendCommand`),
    /// nil for an ordinary paste. The body has lost its trailing LF, so the
    /// review must put the command's Return back itself — and must not add
    /// one the snippet did not ask for: "Send Line by Line" sends the last
    /// line bare unless Return was asked for, "Paste Immediately" pastes the
    /// body then sends the CR on its own, exactly like an unreviewed send.
    struct Reviewed: Equatable {
        /// "Send Line by Line".
        var plan: SafePastePlan
        /// "Paste Immediately": pasted as is…
        var immediateText: String
        /// …then `returnKey` outside the paste.
        var immediateReturn: Bool
    }

    /// A snippet's / broadcast line's own Return goes out only after its
    /// body was ACCEPTED by the session's worker — a refused body followed
    /// by a lone CR would run whatever was already on the device's line.
    static func returnFollows(thenReturn: Bool, bodyAccepted: Bool) -> Bool {
        thenReturn && bodyAccepted
    }

    /// Whether a command's body reached the worker. `cleanedSend`: Safe
    /// Paste or the guard took the body over and sent its CLEANED text at
    /// once (`GuardedPaste.sendCleaned` → `sendImmediatePaste`) — that
    /// send's own acceptance (nil = it did not). The view then reports "not pasted" (the host
    /// vetoed its copy), which used to drop the command's Return and keep
    /// the tab out of Broadcast's count although the body went out
    /// (6.0 (12) review). Otherwise: handed to the view AND taken by the
    /// worker.
    static func bodyAccepted(handedOver: Bool, cleanedSend: Bool?, lastSendAccepted: () -> Bool) -> Bool {
        if let cleanedSend { return cleanedSend }
        return handedOver && lastSendAccepted()
    }

    /// The one dangerous line `sendCommand` asks about before anything
    /// goes out: a body of one line that will run, checked CLEANED — the
    /// text `shouldPaste` sends (`GuardedPaste`), not the raw body, which
    /// an ESC or a backspace could make read as harmless (6.1 (62)). nil =
    /// nothing to ask here (several lines go to the review, which marks them).
    static func askFirst(_ plan: (body: String, thenReturn: Bool), isDangerous: (String) -> Bool) -> String? {
        guard plan.thenReturn else { return nil }
        let body = PasteHygiene.cleaned(plan.body)
        guard !body.contains(where: \.isNewline), isDangerous(body) else { return nil }
        return body
    }

    static func reviewed(_ plan: SafePastePlan, text: String, thenReturn: Bool?) -> Reviewed {
        guard let thenReturn else { return Reviewed(plan: plan, immediateText: text, immediateReturn: false) }
        var plan = plan
        plan.finalLineWithoutReturn = !thenReturn
        return Reviewed(plan: plan, immediateText: text, immediateReturn: thenReturn)
    }
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
    /// override removed, keeping Tab and LF (`PasteHygiene.commandText`,
    /// shared with clipboard pastes and the Windows build). Shared by
    /// snippets and the broadcast line.
    nonisolated static func commandText(_ text: String) -> String {
        PasteHygiene.commandText(text)
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
            guard kind.isDeviceSession, let status else { return false }
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

    /// Several commands (6.1 (46)): every non-blank line of the cleaned text,
    /// in order. One line = the old Send (`sends`); two or more go to each
    /// tab one at a time, each waiting for its own device (the Safe Paste
    /// pacer, `SessionTerminalHost.sendPacedLines`).
    static func lines(_ text: String) -> [String] {
        SnippetCodec.commandText(text).split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Safe Paste's own ceiling (10,000 lines, 5 MB): the lines ride its
    /// pacer, and a box has no reason to take more than a paste may.
    static func withinLimits(_ lines: [String]) -> Bool {
        lines.count <= SafePastePlan.maxLines && lines.reduce(0) { $0 + $1.utf8.count + 1 } <= SafePastePlan.maxBytes
    }

    /// The ticked AND eligible tabs, in tab order.
    static func targets(_ ticked: Set<UUID>, among tabs: [Candidate]) -> [UUID] {
        eligible(tabs).map(\.id).filter(ticked.contains)
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
            ? String(localized: "No line breaks in a value.") : nil
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
