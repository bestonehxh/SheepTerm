import Foundation
import Synchronization

/// One question from a worker queue to the UI, answered at most once
/// (4.2 (9), connection prompts in the tab).
///
/// The SSH worker asks for a username, a password, a challenge answer or a
/// host-key decision synchronously, on its own serial queue, in the middle of
/// a handshake. The answer comes from a card inside the session's tab
/// (`ConnectionPromptView`), which lives on the main actor. This is the part
/// in between, with nothing AppKit in it so the workers harness compiles it:
///
/// - the WORKER calls `ask`: `present` hands the bridge to the UI (the app
///   does a `DispatchQueue.main.async` there — never a `main.sync`), then the
///   worker blocks on a semaphore. The main thread never waits for anything.
/// - the UI calls `answer` exactly when the user decides — or with nil when
///   the card goes away unanswered (Escape, the tab closed). The first answer
///   wins; anything later is ignored and says so (`false`).
/// - `isCancelled` is polled while waiting: a session stopped from anywhere
///   (tab closed, quit) frees the worker even if no UI ever answers, so a
///   card that never made it on screen cannot pin a thread.
///
/// Calling `ask` ON the main thread would deadlock the app's presenter (it
/// queues onto main and then blocks main); the caller keeps a main-thread
/// fallback instead (see `SSHTerminalController.askInTab`).
nonisolated final class PromptBridge<Answer: Sendable>: Sendable {
    private enum Slot: Sendable {
        case waiting
        case answered(Answer?)
    }
    private let slot = Mutex<Slot>(.waiting)
    private let signal = DispatchSemaphore(value: 0)

    init() {}

    /// The UI's answer (any thread). nil = no answer (cancelled). Returns
    /// false when the question was already settled — answered, or abandoned
    /// by a stopped session.
    @discardableResult
    func answer(_ value: Answer?) -> Bool {
        let first = slot.withLock { slot -> Bool in
            guard case .waiting = slot else { return false }
            slot = .answered(value)
            return true
        }
        if first { signal.signal() }
        return first
    }

    /// Settled one way or the other.
    var isSettled: Bool {
        slot.withLock { slot in
            if case .waiting = slot { return false }
            return true
        }
    }

    /// Blocks until `answer` or until `isCancelled()` turns true (checked
    /// every `poll`). A cancel wins over an answer that races it: a stopped
    /// session must not act on its behalf. Nothing is left waiting either way.
    func wait(poll: DispatchTimeInterval = .milliseconds(100), isCancelled: () -> Bool) -> Answer? {
        while signal.wait(timeout: .now() + poll) == .timedOut {
            if isCancelled() {
                answer(nil)
                return nil
            }
        }
        if isCancelled() { return nil }
        return slot.withLock { slot in
            if case .answered(let value) = slot { return value }
            return nil
        }
    }

    /// The whole round trip, on the asking (worker) thread.
    static func ask(poll: DispatchTimeInterval = .milliseconds(100),
                    isCancelled: () -> Bool,
                    present: (PromptBridge<Answer>) -> Void) -> Answer? {
        let bridge = PromptBridge<Answer>()
        if isCancelled() { return nil }
        present(bridge)
        return bridge.wait(poll: poll, isCancelled: isCancelled)
    }
}

nonisolated extension PromptBridge where Answer == SSHWorker.HostKeyAnswer {
    /// The first-seen host-key question over the bridge, with the worker's
    /// meaning of each outcome: the card's "Add and continue" → `.trust`,
    /// "Continue" → `.trustOnce`; Close, Escape
    /// or a card taken down unanswered → `.cancel` (the worker closes with
    /// "connection cancelled — host key not trusted…"); a session stopped
    /// while the card was up → `.stopped`, whatever the card said — nothing
    /// may be pinned on behalf of a tab that is gone.
    static func askHostKey(poll: DispatchTimeInterval = .milliseconds(100),
                           isCancelled: () -> Bool,
                           present: (PromptBridge<SSHWorker.HostKeyAnswer>) -> Void) -> SSHWorker.HostKeyAnswer {
        let answer = ask(poll: poll, isCancelled: isCancelled, present: present)
        if isCancelled() { return .stopped }
        switch answer {
        case .trust?: return .trust
        case .trustOnce?: return .trustOnce
        case .stopped?: return .stopped
        case .cancel?, nil: return .cancel
        }
    }
}
