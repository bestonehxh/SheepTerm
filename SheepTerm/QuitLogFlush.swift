import Foundation
import Synchronization

/// One session's quit-time log close, in flight.
///
/// `SSHTerminalController` / `SerialTerminalController` hand one of these back
/// from `beginShutdownForQuit()`: by then the worker is stopped, the hand-off
/// gates are closed and `SessionLogger.close()` is already queued on that
/// session's log queue, behind whatever appends were still waiting there.
/// What is left is the waiting — and the waiting is the part that has to be
/// shared, because it is the part that takes seconds.
///
/// Why any of it takes seconds: a queued `append` can be parked in
/// `SessionLogger.waitForRoom` for 5 s when the volume has stopped completing
/// writes, and `close()` waits up to 2 s for its own flush. Measured with
/// 4 MB already handed to a logger's ioQueue and three 16 KB chunks queued in
/// front of it, on a volume that never completes a write:
///
///     one tab,  `logQueue.sync { logger?.close() }`     17.03 s
///     ten tabs, `logQueue.sync { logger?.close() }`     35.02 s
///     one tab,  bounded per tab                          2.00 s
///     ten tabs, bounded per tab, in a loop              17.06 s
///     ten tabs, started first, then waited for as one    2.00 s
///     ten healthy tabs                                   0.002 s (every
///                                                        byte in order)
@MainActor
final class QuitLogFlush {
    /// The whole quit gets this long — ONE budget for every tab together, not
    /// one each. 2 s and not more because `SessionLogger.close()` already caps
    /// its own flush wait there: quitting must never block longer than a
    /// single close does, however many tabs are open behind it.
    static let budget: TimeInterval = 2
    /// Of that budget, how long the IN-ORDER closes get before the appends
    /// still queued in front of them are cut off. Everything that lands inside
    /// it is logged in arrival order, exactly as it would have been; the
    /// remainder is what the cut-off gets to write the carry and release the
    /// file descriptor.
    static let orderedShare: TimeInterval = 1

    /// The session this log belongs to, for the notice at the end.
    let session: String
    private let logger: SessionLogger?
    /// The controller's admission gate for this log: what it still holds at
    /// the instant of a cut-off is what the cut-off throws away.
    private let gate: PendingBytesGate
    /// Output the session had already ACCEPTED that was not written: the sum
    /// of what the logger has refused at its closed guard so far
    /// (`SessionLogger.refusedBytes`) and what the gate still holds
    /// (`gate.outstandingBytes` — chunks parked in `waitForRoom` or queued
    /// behind the close, all of which that guard will refuse). Read at two
    /// moments: when the in-order close lands, and just before a cut-off
    /// close — BEFORE, because the cut-off is what wakes the parked appends,
    /// gets them refused and released, and the release empties the gate.
    ///
    /// Why both terms: the gate alone missed a chunk the worker delivered
    /// after `beginShutdownForQuit` had started (the worker thread is not
    /// joined; it can be mid-`onData`), which queued BEHIND the close, was
    /// refused, released, and — on a healthy disk where the in-order close
    /// landed in time and nothing was ever cut off — reported complete: 8192
    /// bytes accepted, 4096 in the file, 0 reported (recheck of 3.0 (58)).
    /// The refused count is exact for everything that reached the guard; the
    /// gate covers what has not got there yet. An upper bound by at most one
    /// chunk: the one between being refused and being released, which is in
    /// both terms for the width of two statements on the log queue.
    ///
    /// This is the number the old quit did not have at all: a forced close
    /// whose prefix flush landed reported `true`, and the chunks it had just
    /// made the logger refuse were counted by nobody (recheck finding 5).
    private(set) var droppedBytes = 0

    /// The volume refused a write at some point in this log's life. Then the
    /// file does not match the session even when its tail landed — the hole
    /// is earlier — and the notice has to say that rather than "the last
    /// writes did not land".
    var writesWereRefused: Bool { logger?.writesWereRefused ?? false }

    /// Never decreases: each reading is a floor, and the last one before the
    /// report is the one that counts.
    private func accountDropped() {
        droppedBytes = Swift.max(droppedBytes, (logger?.refusedBytes ?? 0) + gate.outstandingBytes)
    }

    /// Re-read the accounting at reporting time. The reading taken when the
    /// in-order close landed is only current as of that instant, and the
    /// worker thread is not joined by `beginShutdownForQuit` — a chunk it was
    /// already carrying can be refused AFTER that reading and before the quit
    /// says anything, which reported a complete log with a missing tail.
    func refreshDropped() { accountDropped() }
    private let closedInOrder = DispatchSemaphore(value: 0)
    private var forced: DispatchSemaphore?
    /// What `SessionLogger.close()` ANSWERED, for each of the two calls. Not
    /// "did the call return" — that is the inference this type was built on
    /// twice and got wrong twice. `nonisolated` because the closes run off the
    /// main actor and write their answer from there.
    nonisolated private let inOrderLanded = Mutex(false)
    nonisolated private let forcedLanded = Mutex(false)

    /// Starts the in-order close: queued on the session's own log queue,
    /// BEHIND the appends already sitting there, so the file keeps its
    /// arrival order. Nothing here blocks — the waiting is the caller's, and
    /// it is shared across every tab.
    init(session: String, logger: SessionLogger?, closingOn queue: DispatchQueue, gate: PendingBytesGate) {
        self.session = session
        self.logger = logger
        self.gate = gate
        queue.async { [self] in
            // The answer, not the fact that we got here.
            inOrderLanded.withLock { $0 = logger?.close() ?? true }
            closedInOrder.signal()
        }
    }

    /// The log file whose tail is missing, named the way the user will find
    /// it in ~/Documents/SheepTerm Logs.
    var logName: String? { logger?.url.lastPathComponent }

    /// True when the in-order close finished before `cutoff` AND said the
    /// flush landed. A close that returns because it gave up waiting is not a
    /// closed log, and this is the level that used to conflate the two.
    ///
    /// Re-askable: a semaphore hands its signal to ONE waiter, so a second
    /// call used to time out and say "not closed" about a log that was —
    /// the answer is the log's, not the call's, so the signal is put back.
    func waitForOrderedClose(until cutoff: DispatchTime) -> Bool {
        guard closedInOrder.wait(timeout: cutoff) == .success else { return false }
        closedInOrder.signal()
        // The close has run: everything queued in front of it was released,
        // so whatever the gate still holds is queued BEHIND it and will be
        // refused, and whatever the logger has refused already is counted.
        accountDropped()
        return inOrderLanded.withLock { $0 }
    }

    /// Cut-off, and it does not wait: the appends still queued are parked in
    /// the logger's own admission wait, which only `close()` can end — and the
    /// close that would do it is stuck behind them on that same queue. Calling
    /// it from a thread that is NOT the log queue breaks the circle:
    /// `close()` broadcasts `pendingClosed`, every parked append wakes, sees
    /// the logger closed and returns at its own guard.
    ///
    /// Calling `close()` twice is safe and deliberate: the second call skips
    /// the work, joins the first one's wait, and reports the same outcome for
    /// the same file — see `SessionLogger.close()`, which is where that
    /// promise lives now.
    ///
    /// What it costs: whatever those appends were carrying is not written. On
    /// a volume this dead it was never going to be, and the file still ends on
    /// a clean prefix — `close()` flushes the carry, so nothing lands out of
    /// order. The user is told which logs those were, and how much of the
    /// session's output they are missing.
    func startForcedClose() {
        // Read BEFORE the close, not after: the close is what makes the parked
        // appends wake up, get refused and release their bytes, so afterwards
        // the gate is empty and the loss is invisible. See `droppedBytes`.
        accountDropped()
        let done = DispatchSemaphore(value: 0)
        let logger = self.logger
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            forcedLanded.withLock { $0 = logger?.close() ?? true }
            done.signal()
        }
        forced = done
    }

    /// True when this log is really closed AND flushed before `deadline`.
    /// False means the tail of it is missing — say so rather than pretend.
    ///
    /// One wait, because `close()` now answers for the LOG rather than for the
    /// call: when the in-order close owns the flush, the cut-off close waits
    /// for that same outcome and hands it back. Two earlier shapes of this
    /// method were wrong in the same way — the first waited only on the
    /// cut-off semaphore (which a second caller signals immediately, so a tab
    /// whose tail was still being written was reported flushed: 47 of 60 in
    /// the measured worst case, then 13 of 60 after the first fix), and the
    /// second added a wait on the in-order semaphore, which still only proved
    /// that a call had RETURNED. Asking the callee what happened is what
    /// finally made this row true.
    ///
    /// `forced == nil` — no cut-off was ever started — means the in-order
    /// close finished inside its share, which IS flushed. Unreachable from
    /// `shutdownSessionsForQuit`, which asks only the tabs it has just cut
    /// off, but answered properly rather than left for a reader to prove.
    ///
    /// Re-askable, like `waitForOrderedClose`: the harness asks again after
    /// `waitForAll` to check the prefix landed, and got "no" for a whole file.
    func waitForForcedClose(until deadline: DispatchTime) -> Bool {
        guard let forced else { return true }
        guard forced.wait(timeout: deadline) == .success else { return false }
        forced.signal()
        return forcedLanded.withLock { $0 }
    }

    /// Phase 2 of the quit, for every tab at once — the waiting that
    /// `AppModel.shutdownSessionsForQuit` used to do inline. Returns the
    /// flushes whose log is NOT complete, the ones the user has to be told
    /// about, in the order they were given.
    ///
    /// One budget for all of them, taken once, here. Both deadlines are
    /// ABSOLUTE: waiting for the tabs one after another is fine precisely
    /// because their waits overlap in wall-clock time. Every cut-off is
    /// STARTED before any of them is waited on: a log that needs 5 ms to
    /// close must not queue behind one that will never finish.
    ///
    /// "Not complete" is two different things and both are in the result:
    /// the tail did not land (`waitForForcedClose` said so — the disk did not
    /// accept the last writes in time, or refused them), or the tail landed
    /// but the cut-off threw away output the session had already accepted
    /// (`droppedBytes`). The second used to pass as complete: the forced
    /// close reported that its flush landed, which was true of the prefix,
    /// and the three chunks parked behind it were refused at the closed
    /// logger's guard with nobody counting (recheck finding 5).
    ///
    /// A static on this type rather than a method on AppModel so that
    /// Tests/backpressure can drive the real thing against real loggers —
    /// which is how findings 4 and 5 were found, with a copy of this code
    /// pulled out of AppModel by hand.
    static func waitForAll(_ flushes: [QuitLogFlush], from started: DispatchTime = .now()) -> [QuitLogFlush] {
        let cutoff = started + orderedShare
        let deadline = started + budget
        var stuck: [QuitLogFlush] = []
        for flush in flushes where !flush.waitForOrderedClose(until: cutoff) {
            stuck.append(flush)
        }
        for flush in stuck { flush.startForcedClose() }
        // Every flush, not only the cut-off ones: a tab whose in-order close
        // landed in time can still have refused a chunk that arrived behind
        // it (`droppedBytes`). `waitForForcedClose` answers true at once for
        // a tab that was never cut off.
        // Three passes, and the split is the point. Waiting, accounting and
        // deciding in one loop per tab means the FIRST tab is judged while the
        // last one is still being waited for — and its worker, which
        // `beginShutdownForQuit` never joined, can have a chunk refused during
        // that wait. Only the last tab in the list got the honest reading.
        // Every wait finishes, then every count is re-read, then the answer is
        // formed.
        var landed: [Bool] = []
        landed.reserveCapacity(flushes.count)
        for flush in flushes { landed.append(flush.waitForForcedClose(until: deadline)) }
        for flush in flushes { flush.refreshDropped() }
        var incomplete: [QuitLogFlush] = []
        for (flush, itLanded) in zip(flushes, landed)
        where !itLanded || flush.droppedBytes > 0 {
            incomplete.append(flush)
        }
        return incomplete
    }
}
