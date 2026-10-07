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
    /// `sendReturn` switch owns the final Return).
    static func normalised(_ snippet: Snippet) -> Snippet {
        var out = snippet
        out.name = cleanedName(snippet.name)
        var text = snippet.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        while text.hasSuffix("\n") { text.removeLast() }
        out.text = text
        return out
    }

    static func encode(_ snippets: [Snippet]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snippets)
    }

    static func decode(_ data: Data) throws -> [Snippet] {
        try JSONDecoder().decode([Snippet].self, from: data).map(normalised)
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
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !ticked.isEmpty else { return [] }
        return eligible(tabs).filter { ticked.contains($0.id) }.map { ($0.id, line + "\n") }
    }
}
