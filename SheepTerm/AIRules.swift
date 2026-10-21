import Foundation

// AI panel: the pure conversation and run rules — which turn / chat / run is
// the live one, how streamed text is gathered, how a run's end is read, and
// the short lines shown for it. Foundation only and in `sharedSources` (root
// Package.swift): SheepTerm for Windows compiles THIS file, so its process
// runner and panel apply the same rules (ARCHITECTURE.md "AI panel" and
// "Shared with Windows"). Spawning, signals and the Codex sandbox stay in the
// Mac-only `AIRunner.swift`.

/// How one CLI run ended (the Mac's `AIProcessRun.Ending`).
public nonisolated enum AIRunEnding: Equatable, Sendable {
    case completed
    case cancelled
    case aborted(String)
    case failed(String)

    /// What a finished process means, in order: a safety abort (the init
    /// check) wins, then the user's Stop, then an error the stream reported,
    /// then a clean exit. A run that delivered its whole answer (`sawDone`)
    /// is complete even when the linger timer had to end it; otherwise the
    /// first line of stderr (or the exit status) is the failure.
    public static func decide(aborted: String?, cancelled: Bool, failure: String?, sawDone: Bool,
                       exitStatus: Int32, signaled: Bool, stderr: String, provider: AIProvider) -> AIRunEnding {
        if let aborted { return .aborted(aborted) }
        if cancelled { return .cancelled }
        if let failure { return .failed(AIRunMessages.friendly(failure, provider: provider)) }
        if exitStatus == 0 && !signaled { return .completed }
        // A complete answer was delivered; the CLI was still flushing when the linger timer ended it.
        if sawDone { return .completed }
        let detail = AICLI.shortError(stderr)
        return .failed(AIRunMessages.friendly(detail.isEmpty ? "exited with status \(exitStatus)" : detail, provider: provider))
    }
}

/// How long a run is given at each step of ending it.
public nonisolated enum AIRunTiming {
    /// Grace between the interrupt (SIGINT / Ctrl-C) and terminate for Stop.
    public static let interruptGrace: TimeInterval = 3
    /// After terminate: how long a process group (or a grandchild that kept
    /// stdout open) may hold the run before it is killed and the readers
    /// are woken, so the ending always fires.
    public static let killGrace: TimeInterval = 1
    /// After the turn's end (`.done`): how long the run may still take to
    /// end by itself before it is ended for it — a helper the CLI left
    /// behind holding stdout would otherwise keep it open forever.
    public static let doneGrace: TimeInterval = 3
    /// stderr kept for the failure line.
    public static let stderrCap = 64 * 1024
}

public nonisolated struct AIMessage: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case user, assistant }
    public let id = UUID()
    public let role: Role
    public var text: String
    public var provider: AIProvider
    public var attachments: [AIAttachment] = []
    /// Pasted images sent with this turn (chips under the user's message).
    public var images: [AIImageAttachment] = []
    /// Short error line under an assistant turn.
    public var failure: String?
    public var stopped = false

    public init(role: Role, text: String, provider: AIProvider, attachments: [AIAttachment] = [],
                images: [AIImageAttachment] = [], failure: String? = nil, stopped: Bool = false) {
        self.role = role
        self.text = text
        self.provider = provider
        self.attachments = attachments
        self.images = images
        self.failure = failure
        self.stopped = stopped
    }
}

/// One session's conversation (in memory only). Here, not in the panel
/// model, so the harness holds its turn / chat identity rules to cases.
public nonisolated struct AIConversation: Equatable, Sendable {
    public var provider: AIProvider
    public var messages: [AIMessage] = []
    public var pending: [AIAttachment] = []
    /// Pasted images waiting with the next turn (chips above the composer).
    public var pendingImages: [AIImageAttachment] = []
    public var draft = ""
    public var running = false
    public var claudeSession = UUID()
    public var claudeStarted = false
    public var codexThread: String?
    /// The session id Gemini reported in its `init` event, resumed next turn.
    public var geminiSession: String?
    /// The send whose run may still start or fail (a newer send or a New
    /// Chat replaces it): anything from an older turn is dropped.
    public var turn = UUID()
    /// This chat (a New Chat is a new one): an attachment masked for an
    /// earlier chat does not land in it.
    public var epoch = UUID()
    /// Where "attach recent lines" stopped last (reset by New Chat; kept
    /// across a provider switch, like the chips).
    public var attachMark: AIAttachMark?
    /// A short line under the chips ("No new output since the last attach").
    public var notice: String?

    public init(provider: AIProvider) { self.provider = provider }

    public func isCurrent(turn: UUID) -> Bool { running && self.turn == turn }

    /// Provider switch: a new conversation that keeps the draft and the
    /// chips (and so the chat identity they were attached to).
    public func switchingProvider(to provider: AIProvider) -> AIConversation {
        var fresh = AIConversation(provider: provider)
        fresh.draft = draft
        fresh.pending = pending
        fresh.pendingImages = pendingImages
        fresh.epoch = epoch
        fresh.attachMark = attachMark
        return fresh
    }

    /// A chip that finished masking: only into the chat it was made for.
    public mutating func land(_ attachment: AIAttachment, epoch: UUID) -> Bool {
        guard self.epoch == epoch else { return false }
        pending.append(attachment)
        return true
    }

    /// A pasted image for this chat (its bytes are already in memory, so
    /// there is nothing to mask — but the epoch rule still applies).
    public mutating func landImage(_ image: AIImageAttachment, epoch: UUID) -> Bool {
        guard self.epoch == epoch else { return false }
        pendingImages.append(image)
        return true
    }
}

/// Which run is the live one for each session. A run's callbacks carry the
/// run itself; anything from a run that is no longer the session's (New
/// Chat, a provider switch, a newer send) is ignored — a stale `ended` must
/// not stop or finish the run that replaced it.
public nonisolated struct AIRunBook<Run: AnyObject> {
    private var runs: [UUID: Run] = [:]

    public init() {}

    public mutating func set(_ run: Run, for session: UUID) { runs[session] = run }

    @discardableResult
    public mutating func remove(_ session: UUID) -> Run? { runs.removeValue(forKey: session) }

    public func run(for session: UUID) -> Run? { runs[session] }

    public func isCurrent(_ run: Run, for session: UUID) -> Bool { runs[session] === run }

    /// A run ended: forgotten only if it is still the session's. Returns
    /// whether the ending is the live run's (and so should be applied).
    public mutating func ended(_ run: Run, for session: UUID) -> Bool {
        guard runs[session] === run else { return false }
        runs.removeValue(forKey: session)
        return true
    }

    public var sessions: [UUID] { Array(runs.keys) }
}

/// Streamed text waiting to reach the conversation. Deltas arrive dozens of
/// times a second; publishing each one re-rendered the panel per delta, so
/// they are gathered here and flushed at most every `interval` — and at once
/// before anything else about the run (a whole message, an error, the end).
public nonisolated struct AIDeltaBuffer {
    public static let interval: TimeInterval = 0.06
    private var pending: [UUID: String] = [:]
    /// A flush is on its way (one timer for all sessions).
    public private(set) var scheduled = false

    public init() {}

    /// Returns true when the caller must schedule the flush.
    public mutating func add(_ text: String, for session: UUID) -> Bool {
        pending[session, default: ""] += text
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    /// The text for one session (an immediate flush); nil if none.
    public mutating func take(_ session: UUID) -> String? {
        pending.removeValue(forKey: session)
    }

    /// Everything (the timer fired).
    public mutating func takeAll() -> [UUID: String] {
        scheduled = false
        defer { pending = [:] }
        return pending
    }

    /// New Chat / provider switch / closed session: the text is not wanted.
    public mutating func drop(_ session: UUID) { pending.removeValue(forKey: session) }

    public var isEmpty: Bool { pending.isEmpty }
}

/// The conversation dictionary's attach rules, pure so the harness tests the
/// real thing: a chat that does not exist yet is MATERIALISED before its epoch
/// is captured (`conversation(for:)` hands out a throwaway with a random
/// epoch, so the first attach on a fresh session would never land), and a chip
/// lands only in a stored chat of the same epoch.
public nonisolated enum AIAttachBook {
    public static func begin(_ conversations: inout [UUID: AIConversation], session: UUID, defaultProvider: AIProvider) -> UUID {
        if conversations[session] == nil { conversations[session] = AIConversation(provider: defaultProvider) }
        return conversations[session]!.epoch
    }

    @discardableResult
    public static func land(_ attachment: AIAttachment, session: UUID, epoch: UUID, in conversations: inout [UUID: AIConversation]) -> Bool {
        guard var c = conversations[session], c.land(attachment, epoch: epoch) else { return false }
        conversations[session] = c
        return true
    }

    /// The same for a pasted image chip.
    @discardableResult
    public static func landImage(_ image: AIImageAttachment, session: UUID, epoch: UUID, in conversations: inout [UUID: AIConversation]) -> Bool {
        guard var c = conversations[session], c.landImage(image, epoch: epoch) else { return false }
        conversations[session] = c
        return true
    }
}

/// Short, actionable lines for what the CLIs print when something is wrong.
public nonisolated enum AIRunMessages {
    public static func notInstalled(_ provider: AIProvider) -> String {
        "\(provider.label) isn't installed — Settings ▸ AI ▸ Install"
    }

    public static func notSignedIn(_ provider: AIProvider) -> String {
        "\(provider.label) isn't signed in — Settings ▸ AI ▸ Sign In"
    }

    public static func apiKey(_ provider: AIProvider) -> String {
        "\(provider.label) is signed in with an API key — Settings ▸ AI ▸ Sign In with your account"
    }

    /// A run that ended with the "not signed in" line: the account state shown
    /// in Settings must follow (signed out, login re-checked on the next send).
    public static func isNotSignedIn(_ ending: AIRunEnding, provider: AIProvider) -> Bool {
        if case .failed(let message) = ending { return message == notSignedIn(provider) }
        return false
    }

    public static func friendly(_ raw: String, provider: AIProvider) -> String {
        let lower = raw.lowercased()
        if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("login required")
            || lower.contains("not signed in") || lower.contains("unauthorized") || lower.contains("401")
            || lower.contains("invalid api key") || lower.contains("authentication")
            || lower.contains("credentials") || lower.contains("api key not valid")
            || lower.contains("permission_denied") || lower.contains("403") {
            return notSignedIn(provider)
        }
        if lower.contains("usage limit") || lower.contains("rate limit") || lower.contains("429")
            || lower.contains("resource_exhausted") || lower.contains("quota") {
            return "\(provider.label): usage limit reached — try again later"
        }
        return "\(provider.label): \(raw)"
    }
}

/// The panel closes itself when the last tab goes: every chat belongs to a
/// tab and is dropped with it, so an open panel would show nothing. Only the
/// step from some tabs to none hides it — a panel the user opens on an empty
/// window stays open.
public nonisolated enum AIPanelAutoClose {
    public static func shouldHide(tabsBefore: Int, tabsAfter: Int, shown: Bool) -> Bool {
        shown && tabsBefore > 0 && tabsAfter == 0
    }
}
