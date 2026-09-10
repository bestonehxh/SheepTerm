import Darwin
import Foundation
import Synchronization

// MARK: - Session hand-off backpressure
//
// A worker's I/O queue hands every chunk it reads to two consumers: the
// terminal (main actor) and the session log (a per-session log queue).
// `SessionLogger` bounds its OWN backlog — see its doc comment — but nothing
// used to bound the work that had not reached it yet: the controllers did
//
//     DispatchQueue.main.async { self.terminalView.feed(bytes) }
//     logQueue.async { logger?.append(bytes) }
//
// per chunk, and each of those closures already owns its `[UInt8]`. Once a
// consumer falls behind the device — a stalled disk under `append`, a modal
// sheet or a long hitch under `feed` — the closures pile up with nothing to
// stop the worker reading more, so RAM tracks the device's output rate for as
// long as the stall lasts. Tests/backpressure measures exactly that: ~100 MB
// resident after 10 s of 10 MB/s against a 1 MB/s sink, and it keeps climbing.
//
// Both types below fix that the same way, and it is backpressure rather than
// dropping on purpose: a session log is evidence for a network engineer, and
// quietly losing a slice of a `show tech` is worse than a pause. Blocking the
// worker's read loop is the *point* — SSH's own window then does the rest and
// the device stops sending, which is the behaviour you want. A serial line has
// no window, but the FTDI/USB driver's own buffer plus flow control take the
// same role, and a dropped byte there would be just as wrong.
//
// Lock ordering (the thing that must not regress — SessionLogger's doc comment
// records what happened the last time this was got wrong):
//
//     worker I/O queue  →  waits on PendingBytesGate / MainFeedQueue
//     log queue         →  waits on SessionLogger.pendingCondition
//     logger ioQueue    →  waits on nothing
//     main actor        →  waits on nothing held by the worker
//
// The chain is strictly one-way: nothing the log queue, the logger's ioQueue
// or the main actor waits for is ever the gate the worker is parked on, so no
// cycle exists. Neither type below ever calls into `SessionLogger` (or
// anything else) while holding its condition — it only touches an Int.
//
// `SessionLogger.onProblem` is the one place `ioQueue` calls OUT, and it keeps
// that row honest: it fires with no lock held and its contract is that it must
// not block (the controllers hop to the main actor with a plain `async`). An
// `onProblem` that waited on anything above it would put the cycle back.

/// A byte-counted admission gate between a producer that must be slowed down
/// and a serial consumer queue that drains at its own pace.
///
/// `reserve` blocks the *calling* thread — always a worker's I/O queue, never
/// the main actor — while the consumer is more than `limitBytes` behind, and
/// the consumer calls `release` when it is done with a chunk. This is the same
/// shape as `SessionLogger.pendingCondition`, one level further out, and it
/// bounds by BYTES rather than by closure count: 60 000 queued 4 KB chunks and
/// 240 queued 1 MB chunks cost the same RAM and only one of them is visible to
/// a counter of closures.
///
/// Parking that thread is not free, and the cost is not only slower output:
/// the worker's I/O loop is also what drains `pendingWrites` (`takeWrites()`
/// at the top of `SSHWorker.run`'s poll loop), so while `reserve` is parked a
/// keystroke sits in the queue and never reaches the device. A session can
/// therefore look frozen — no echo, no output — for up to `stallLimit`. That
/// is the right trade against unbounded memory, but only if the user is told
/// which is why `onThrottleChange` exists.
nonisolated final class PendingBytesGate: Sendable {
    private let condition = NSCondition()
    private let limitBytes: Int
    /// How long `reserve` will wait before admitting a chunk anyway. A dead
    /// volume (an unplugged network share) must not freeze a session forever,
    /// and dropping the chunk is not on the table. Note what admitting-anyway
    /// actually costs: the producer has already been parked for the whole
    /// timeout, so growth past the cap is one chunk per `stallLimit`, not the
    /// unbounded stream this class exists to stop.
    ///
    /// What the user sees while this is engaged: one grey notice in the
    /// session saying the log is falling behind and that output and typing are
    /// being throttled, then a session that produces roughly one chunk every
    /// `stallLimit` seconds — echo included — until the disk recovers and a
    /// second notice says so. Slow and explained beats fast and lossy.
    private let stallLimit: TimeInterval
    /// A wait at least this long is worth telling the user about. Deliberately
    /// well under `stallLimit`: `stallCount` only counts waits that ran all the
    /// way out, and by then the session has already been silent for the whole
    /// timeout — the right trigger for a notice is "typing just stopped
    /// working", not "we gave up".
    private let noticeAfter: TimeInterval
    /// Floor between announcements, so a sink that flaps in and out cannot
    /// paper the screen with notice pairs.
    private let reannounceAfter: TimeInterval
    /// `nonisolated(unsafe)`: mutated only under `condition`'s own lock — an
    /// external synchronization primitive the compiler cannot see, the same
    /// justification `SessionLogger.pendingBytes` carries.
    nonisolated(unsafe) private var outstanding = 0
    nonisolated(unsafe) private var stalls = 0
    nonisolated(unsafe) private var finished = false
    /// Whether a stall episode is currently open. One episode spans however
    /// many consecutive chunks had to wait — the notice fires on the edge into
    /// it, never per chunk.
    nonisolated(unsafe) private var throttling = false
    nonisolated(unsafe) private var announcedEpisode = false
    nonisolated(unsafe) private var lastAnnounce: Date?

    /// Called with `true` when the gate starts holding the producer up and
    /// `false` when it stops — once per episode each, never per chunk. Fires
    /// on the producer's thread with no lock held, so the controller is free
    /// to hop to the main actor from inside it.
    private let throttleCallback = Mutex<(@Sendable (Bool) -> Void)?>(nil)
    var onThrottleChange: (@Sendable (Bool) -> Void)? {
        get { throttleCallback.withLock { $0 } }
        set { throttleCallback.withLock { $0 = newValue } }
    }

    init(limitBytes: Int, stallLimit: TimeInterval = 5,
         noticeAfter: TimeInterval = 1, reannounceAfter: TimeInterval = 30) {
        self.limitBytes = limitBytes
        self.stallLimit = stallLimit
        self.noticeAfter = noticeAfter
        self.reannounceAfter = reannounceAfter
    }

    /// Bytes handed to the consumer but not yet released — i.e. read from the
    /// device, accepted by the app, and still somewhere between the worker and
    /// the log file.
    ///
    /// The quit reads this at the instant it cuts a stuck log off
    /// (`QuitLogFlush.startForcedClose`), because at that instant it is exactly
    /// the data the cut-off is about to throw away: every one of those chunks
    /// is either parked in `SessionLogger.waitForRoom` or still queued behind
    /// one that is, and a closed logger refuses all of them at its own
    /// `guard !state.closed`. It is an upper bound by at most one chunk — the
    /// one whose `append` has returned but whose `release` has not run yet,
    /// whose bytes are already on the logger's ioQueue and will land.
    var outstandingBytes: Int { condition.lock(); defer { condition.unlock() }; return outstanding }
    /// How many times `reserve` gave up waiting. This counts only waits that
    /// ran all the way out — a four-second wait that then succeeded is not in
    /// here — so it is the right number for "did the soft bound engage?" and
    /// the wrong one for "should the user be told?". See `noticeAfter`.
    var stallCount: Int { condition.lock(); defer { condition.unlock() }; return stalls }

    /// Blocks until the consumer is within `limitBytes`, then books `count`.
    /// Returns false when it timed out and admitted the chunk regardless.
    @discardableResult
    func reserve(_ count: Int) -> Bool {
        guard count > 0 else { return true }
        condition.lock()
        var admittedOnTime = true
        let started = Date()
        // `outstanding > 0` matters for the same reason it does in
        // SessionLogger.waitForRoom: one chunk larger than the cap must still
        // go through when nothing else is in flight, or it would wait forever
        // for room that can never appear.
        if !finished, outstanding >= limitBytes, outstanding > 0 {
            let deadline = started.addingTimeInterval(stallLimit)
            while !finished, outstanding >= limitBytes, outstanding > 0 {
                if !condition.wait(until: deadline) {
                    stalls += 1
                    admittedOnTime = false
                    break
                }
            }
        }
        outstanding += count
        let announcement = noteWait(Date().timeIntervalSince(started))
        condition.unlock()
        // Outside the lock: the callback hops to the main actor, and holding
        // `condition` across that would put the notice behind exactly the
        // congestion it is reporting.
        if let announcement { onThrottleChange?(announcement) }
        return admittedOnTime
    }

    /// Episode bookkeeping. Called with `condition` held and touching nothing
    /// but counters — it returns the announcement for `reserve` to make once
    /// the lock is released, rather than calling out from under it.
    private func noteWait(_ waited: TimeInterval) -> Bool? {
        if waited >= noticeAfter {
            guard !throttling else { return nil }   // already inside this episode
            throttling = true
            let now = Date()
            if let last = lastAnnounce, now.timeIntervalSince(last) < reannounceAfter {
                announcedEpisode = false            // too soon; stay quiet, both ways
                return nil
            }
            lastAnnounce = now
            announcedEpisode = true
            return true
        }
        // A chunk that sailed through means the consumer caught up.
        guard throttling else { return nil }
        throttling = false
        // Only ever say "recovered" for an episode the user was told about.
        guard announcedEpisode else { return nil }
        announcedEpisode = false
        return false
    }

    /// Called from the consumer queue once a chunk has been dealt with.
    /// `broadcast`, not `signal`: a reconnect can briefly leave two workers
    /// sharing one session's consumers.
    func release(_ count: Int) {
        guard count > 0 else { return }
        condition.lock()
        outstanding -= count
        condition.broadcast()
        condition.unlock()
    }

    /// The session is over: wake anything parked here and stop gating, so a
    /// worker shutting down cannot be held by a consumer that will never run
    /// again. The callback goes with it — a tab that is closing has nowhere
    /// left to print, and "log caught up" after the session ended would be a
    /// lie anyway.
    func finish() {
        condition.lock()
        finished = true
        throttling = false
        announcedEpisode = false
        condition.broadcast()
        condition.unlock()
        onThrottleChange = nil
    }
}

/// The worker → main-actor half of the same problem, with one extra job:
/// coalescing. Instead of one `DispatchQueue.main.async` per chunk, bytes are
/// appended to a single pending buffer and exactly one drain is scheduled per
/// empty→non-empty transition, so a main thread that unsticks after a hitch
/// does one `feed` of everything rather than tens of thousands of them.
///
/// Coalescing alone does NOT bound memory — it replaces N arrays plus N block
/// objects with one array of the same total size, which is a constant-factor
/// win (~150 B of closure overhead per chunk), not a bound. The cap is what
/// bounds it, so both are here: `submit` blocks its caller once the buffer is
/// over `limitBytes`, exactly like `PendingBytesGate`.
///
/// Order is preserved because `submit` appends and `take` drains under one
/// lock, and the main queue is FIFO: bytes submitted after a drain was
/// scheduled either make it into that drain or into the next one, never
/// out of order and never twice.
///
/// No `onThrottleChange` counterpart here, unlike `PendingBytesGate`, and not
/// by oversight: this one only backs up when the MAIN ACTOR is stuck, and a
/// notice is painted by the main actor. There would be nothing to see until
/// the stall was already over, at which point the message would be describing
/// the past. The log gate is the one that can stall a session whose UI is
/// otherwise perfectly responsive, so it is the one that has to explain itself.
nonisolated final class MainFeedQueue: Sendable {
    private let condition = NSCondition()
    private let limitBytes: Int
    private let stallLimit: TimeInterval
    /// `nonisolated(unsafe)`: mutated only under `condition`'s own lock.
    nonisolated(unsafe) private var pending: [UInt8] = []
    nonisolated(unsafe) private var scheduled = false
    nonisolated(unsafe) private var stalls = 0
    nonisolated(unsafe) private var finished = false

    init(limitBytes: Int, stallLimit: TimeInterval = 5) {
        self.limitBytes = limitBytes
        self.stallLimit = stallLimit
    }

    var outstandingBytes: Int { condition.lock(); defer { condition.unlock() }; return pending.count }
    var stallCount: Int { condition.lock(); defer { condition.unlock() }; return stalls }

    /// Adds a chunk, blocking the caller while the main actor is more than
    /// `limitBytes` behind. Returns true when the caller must schedule a drain
    /// on the main queue — i.e. when this chunk is the one that made the
    /// buffer non-empty with no drain already pending.
    func submit(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        condition.lock()
        if !finished, pending.count >= limitBytes, !pending.isEmpty {
            let deadline = Date().addingTimeInterval(stallLimit)
            while !finished, pending.count >= limitBytes, !pending.isEmpty {
                if !condition.wait(until: deadline) {
                    stalls += 1
                    break
                }
            }
        }
        pending.append(contentsOf: bytes)
        let needsDrain = !scheduled
        scheduled = true
        condition.unlock()
        return needsDrain
    }

    /// Hands the whole pending buffer to the main actor and re-arms
    /// scheduling. Clearing `scheduled` here, under the same lock that empties
    /// the buffer, is what keeps "someone is going to drain this" and "there
    /// is something to drain" from disagreeing.
    func take() -> [UInt8] {
        condition.lock()
        let drained = pending
        pending = []
        scheduled = false
        condition.broadcast()
        condition.unlock()
        return drained
    }

    /// See `PendingBytesGate.finish`.
    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Writes a plain-text log of everything a session receives, with ANSI
/// escape sequences stripped so the file reads like the on-screen output.
/// Files land in ~/Documents/SheepTerm Logs/.
///
/// `append` is called from a per-session log queue while `close` can run on
/// the main actor. Two different primitives now split the job on purpose:
/// the Mutex guards only cheap bookkeeping (closed/carry/written/truncated —
/// no I/O ever happens while it's held), and `ioQueue`, a serial dispatch
/// queue private to this logger, is the sole place `handle` is touched.
///
/// That used to not be true: `append` held the Mutex across a blocking
/// `FileHandle.write`, and `close` (called from the main actor when a tab
/// closes) took that same Mutex. Since `state` is a per-instance property,
/// this was never cross-session contention — a tab could only ever be
/// blocked behind *its own* logger's in-flight write, never another
/// session's. But that was still a real, visible UI freeze: `~/Documents`
/// is iCloud-synced on many Macs, where a single `write(contentsOf:)` can
/// be held up well past local-disk latency by the file-provider layer, and
/// closing a tab mid-stream landed you on exactly that write.
///
/// The fix moves the write itself off the calling thread and onto
/// `ioQueue`, with two things preserved deliberately:
///
/// 1. **Bounded backlog, not unbounded.** Simply making `append` fire off
///    an unawaited `ioQueue.async` for every chunk would trade a bounded
///    wait (one write) for an *unbounded* one: a session streaming fast
///    against a stalled file provider would queue `Data` forever, and
///    `close()` — which still has to wait for its own tail write to land,
///    see below — would end up waiting for that entire backlog to drain
///    instead of one write. That's worse than the bug it fixes. So, same
///    pattern as `HighlightBuffer`'s `pendingBytes`: a separate counter
///    (guarded by `pendingCondition`, deliberately not `state`'s Mutex —
///    see its doc comment) tracks bytes handed to `ioQueue` but not yet
///    written, and `append` blocks the *calling* thread — the per-session
///    log queue, never the main actor — once that backlog crosses
///    `maxPendingBytes`. Blocking that thread is fine: it is exactly the
///    natural backpressure the old synchronous design gave for free, and
///    unlike dropping bytes, no log data is lost.
/// 2. **FIFO order across two producers.** `append`/`close` run on
///    different threads, so submission order to `ioQueue` has to be
///    decided somewhere both agree on: the Mutex. The submit-to-`ioQueue`
///    call for both happens *inside* the Mutex critical section
///    (submission is a fast, non-blocking call — not the write itself).
///    Whichever of `append`/`close` wins the Mutex race enqueues its work
///    first, and once `close` sets `closed = true` under the lock, no
///    later `append` can enqueue anything at all — it returns at its own
///    `guard !state.closed`, still under the Mutex, before ever reaching
///    `ioQueue`.
///
/// `close()` still makes one synchronous wait, and it is now bounded by
/// `maxPendingBytes` worth of backlog instead of being unbounded: callers
/// (including `Tests/tests/main.swift`'s write-then-read-back check) rely
/// on "closed means fully flushed and the fd is released" the instant
/// `close()` returns.
///
/// (`Mutex` is itself unconditionally `@unchecked Sendable` — that's what
/// let it wrap a non-Sendable payload before. `handle` is Sendable on its
/// own now, but Sendable only certifies "safe to hand off between queues,"
/// not "safe to use from two queues at once" — `ioQueue` being the single
/// place it's ever called from is what actually keeps access exclusive,
/// standing in for the Mutex's old role.)
nonisolated final class SessionLogger: Sendable {
    let url: URL
    /// Every actual disk write/close lives here, off the caller's thread —
    /// see the class doc comment for why this exists.
    private let ioQueue = DispatchQueue(label: "SheepTerm.SessionLogger.io")
    /// Touched only from `ioQueue` — never under `state`'s Mutex, and never
    /// synchronously from `append`'s or `close`'s caller thread. (FileHandle
    /// is itself Sendable, so `nonisolated(unsafe)` here is about the VAR, not
    /// the value — Sendable only means "safe to hand off," not "safe to use
    /// from two queues at once": exclusivity still comes from `ioQueue` being
    /// the only place this is ever read or assigned.)
    ///
    /// A `var` since 3.0 (26): `relinkIfUnlinked` replaces it when the file is
    /// deleted out from under a live session. That is also why `close()` reads
    /// `self.handle` from inside its own `ioQueue` closure instead of
    /// capturing it at the call site — capturing would read it off `ioQueue`.
    nonisolated(unsafe) private var handle: FileHandle
    private struct State {
        var closed = false
        /// Tail that can't be logged yet — a split UTF-8 character or an
        /// unterminated escape sequence — prepended to the next append.
        var carry: [UInt8] = []
        /// Bytes handed to `ioQueue` so far — incremented at *enqueue* time,
        /// not when the physical write completes. That's deliberate, not an
        /// oversight: incrementing here happens under the same Mutex as the
        /// cap check below, so the next `append` call sees an up-to-date
        /// total immediately, regardless of how far behind the actual disk
        /// write is. Incrementing only after the write completes would mean
        /// crossing back into this Mutex from the `ioQueue` closure, and
        /// would let the cap check under-count work that's already been
        /// committed to — i.e. a slow disk could let far more than 100 MB
        /// get queued up before the truncation notice ever fires.
        var written = 0
        var truncated = false
        /// Bytes an `append` brought here after `closed` — accepted by the
        /// session, refused by this guard, written nowhere. Counted at the
        /// guard because the guard is the one place every refused chunk
        /// passes, whichever queue it came down and whichever gate it was
        /// reserved on (a reconnect's predecessor queue included). The quit
        /// adds it to the gate's outstanding count; see
        /// `QuitLogFlush.droppedBytes`.
        var refused = 0
    }
    private let state: Mutex<State>

    /// Output the session accepted that this logger refused because it was
    /// already closed. Exact for everything that has REACHED the guard; a
    /// chunk still queued or parked on its way here is not in it yet.
    var refusedBytes: Int { state.withLock { $0.refused } }
    /// True once any write was refused by the volume — the other half of
    /// `close()`'s answer, exposed so the quit can say which half it was.
    var writesWereRefused: Bool { writeFailureReported.withLock { $0 } }

    /// Beyond this the log stops growing — a runaway session must not
    /// fill the disk.
    private static let maxSize = 100 * 1024 * 1024
    /// An escape run longer than this is garbage, not a sequence — log it
    /// rather than hold it in `carry` forever.
    private static let maxEscapeHold = 1024 * 1024

    /// Bytes submitted to `ioQueue` but not yet physically written — the
    /// backpressure counterpart to `HighlightBuffer.pendingBytes`, and for
    /// the same reason: it must not share `state`'s Mutex, or `append`
    /// couldn't keep enqueueing (thus growing this count) while `ioQueue` is
    /// mid-write (thus shrinking it) — the two need to be visible to each
    /// other independent of whoever holds `state` at the moment.
    /// `NSCondition`, not another `Mutex`, because backpressure needs a
    /// blocking thread to be woken *by* the drain, not just to read a
    /// number: a `Mutex` has no wait/signal.
    private let pendingCondition = NSCondition()
    /// Set after the first failed write, so a full disk produces one line in
    /// the system log rather than one per chunk forever — and read back by
    /// `close()`, whose answer it is half of.
    private let writeFailureReported = Mutex(false)

    /// Where "your log is not what you think it is" goes. An NSLog was the
    /// only report this class made, and nobody reads the system log while
    /// they are on a switch — the controllers point this at their own
    /// `printNotice`, so the news lands in the session it is about.
    ///
    /// Called from `ioQueue` with no lock held, and MUST NOT BLOCK: the lock
    /// ordering at the top of this file has `ioQueue` waiting on nothing, and
    /// this is the only place it calls out. Hop, do not wait.
    private let problemCallback = Mutex<(@Sendable (String) -> Void)?>(nil)
    var onProblem: (@Sendable (String) -> Void)? {
        get { problemCallback.withLock { $0 } }
        set { problemCallback.withLock { $0 = newValue } }
    }

    private func report(_ message: String) {
        problemCallback.withLock { $0 }?(message)
    }

    /// How often `ioQueue` asks the kernel whether the file it is writing to
    /// still exists. Deliberately a time cadence and not per-write: a session
    /// streaming a `show tech` does thousands of writes a second, and this
    /// costs four `fstat`s a second whatever the rate. A quarter second is the
    /// price of being wrong — that much output can land on an unlinked inode
    /// before we notice — which is nothing against losing the whole file.
    private static let linkCheckInterval: UInt64 = 250_000_000  // ns
    /// Floor between "the log file vanished" notices, so a cleanup daemon that
    /// deletes the folder in a loop cannot paper the terminal with them.
    private static let relinkReportInterval: UInt64 = 30_000_000_000  // ns
    /// Both touched only from `ioQueue`, like `handle`.
    nonisolated(unsafe) private var lastLinkCheck: UInt64 = 0
    nonisolated(unsafe) private var lastRelinkReport: UInt64 = 0
    /// `noteIfRenamed` fires once per session: a moved log stays moved.
    nonisolated(unsafe) private var renameReported = false
    /// `nonisolated(unsafe)`: mutated only while `pendingCondition`'s own
    /// lock is held (in `waitForRoom`/`addPending`/`removePending`) — an
    /// external synchronization primitive the compiler can't see, the same
    /// justification the class doc comment gives for `Mutex` itself.
    nonisolated(unsafe) private var pendingBytes = 0
    /// Cap on outstanding (enqueued-but-not-yet-written) bytes. Past this,
    /// `append` blocks its caller — the per-session log queue, never the
    /// main actor — until `ioQueue` drains below it again. This bounds two
    /// things at once: worst-case RAM held by queued `Data`, and — more to
    /// the point — `close()`'s one unavoidable wait, which is for this same
    /// backlog to finish draining. 4 MB is a few hundred KB of typical
    /// terminal output either side of the cap (comfortably more than one
    /// write ever needs in the common fast-disk case, so this essentially
    /// never engages), while still bounding a stalled-disk close() wait to
    /// "flush 4 MB" instead of "flush however much a runaway session
    /// produced before someone closed the tab."
    private static let maxPendingBytes = 4 * 1024 * 1024

#if SHEEPTERM_TESTING
    /// Test-only slow-disk injection: `ioQueue` sleeps this long before every
    /// write, so `Tests/backpressure` can reproduce a stalled volume (a network
    /// share, an iCloud file provider, Time Machine mid-thrash) on a fast local
    /// SSD. Compiled out of the app entirely — only Tests/run.sh passes
    /// `-D SHEEPTERM_TESTING`.
    /// Behind a Mutex, not `nonisolated(unsafe)`: the harness changes it from
    /// its own thread while `ioQueue` is reading it, and an unsynchronized
    /// global there is a genuine race — ThreadSanitizer says so, and a probe
    /// that reports races of its own is worse than no probe.
    private static let writeDelay = Mutex(TimeInterval(0))
    static var writeDelaySeconds: TimeInterval {
        get { writeDelay.withLock { $0 } }
        set { writeDelay.withLock { $0 = newValue } }
    }
    private static func simulateSlowDisk() {
        let delay = writeDelaySeconds
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }
#else
    @inline(__always) private static func simulateSlowDisk() {}
#endif

    static var logsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Why a log could not be opened, in the words the volume used. The
    /// controllers print this in the SESSION — a log that silently never
    /// started is the failure mode this type exists to make impossible.
    struct OpenFailure: Error, CustomStringConvertible {
        let path: String
        let code: Int32
        var description: String {
            "\(String(cString: strerror(code))) — \(path)"
        }
    }

    /// APFS and HFS+ cap a single path component at 255 UTF-16 code units —
    /// units, not bytes, which is why an 80-emoji host name (320 bytes) used
    /// to log fine while a 229-character ASCII one did not.
    private static let maxNameUnits = 255

    /// How many times to redraw the uniquifier before giving up. Each draw is
    /// 16 bits, and the open below is O_EXCL, so a repeat costs one failed
    /// syscall rather than the earlier session's log; four draws all colliding
    /// is not something that happens to a real user.
    private static let maxOpenAttempts = 8

    /// The public failable form the tests and every existing caller use.
    /// `open` is the one the app takes, because the app has somewhere to print
    /// the reason.
    convenience init?(sessionName: String) {
        do { try self.init(opening: sessionName) } catch { return nil }
    }

    /// Opens a log, or says why it could not. See `OpenFailure`.
    static func open(sessionName: String) throws -> SessionLogger {
        try SessionLogger(opening: sessionName)
    }

    private init(opening sessionName: String) throws {
        let formatter = DateFormatter()
        // Pin the locale: the device calendar can be Buddhist-era, which
        // would put a 543-year offset into the filename.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let stamp = formatter.string(from: Date())
        let safeName = sessionName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            // A NUL ends the C string the kernel actually sees, so `url` and
            // the file on disk would disagree about the name. Fold it away
            // rather than let the two drift apart.
            .replacingOccurrences(of: "\0", with: "-")
            // Every other control character too: legal on APFS, hostile in
            // Finder and in a shell — a host named with a CR LF in it made a
            // two-line file name.
            .components(separatedBy: .controlCharacters).joined()
        // Evaluated once: the getter creates the directory as a side effect.
        let dir = Self.logsDirectory

        // `-XXXX.log` plus the " yyyy-MM-dd HHmmss" stamp is the fixed part;
        // whatever is left of the 255 units is what the host name may use. A
        // name too long for that is TRIMMED, never a reason to skip logging —
        // an unloggable session is a far worse outcome than a shortened file
        // name, and the stamp and uniquifier still tell the files apart.
        var budget = Self.maxNameUnits - " \(stamp)-XXXX.log".utf16.count

        var opened: (url: URL, fd: Int32)?
        var lastFailure = OpenFailure(path: dir.path, code: EEXIST)
        for _ in 0..<Self.maxOpenAttempts {
            let unique = UUID().uuidString.prefix(4)
            let candidate = dir.appendingPathComponent(
                "\(Self.trimmed(safeName, toUTF16Units: budget)) \(stamp)-\(unique).log")
            // O_EXCL is the whole point: `createFile(atPath:contents:nil)`
            // TRUNCATES, so two sessions of one host started in the same
            // second used to destroy the first one's bytes and then interleave
            // at independent offsets. Refusing to land on an existing path and
            // redrawing costs one failed syscall instead.
            let fd = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 { opened = (candidate, fd); break }
            lastFailure = OpenFailure(path: candidate.path, code: errno)
            switch lastFailure.code {
            case EEXIST:
                continue        // same second, same name — draw again
            case ENAMETOOLONG where budget > 16:
                // A volume with a stricter limit than APFS's (a mounted share,
                // an exFAT stick). Halve and retry rather than lose the log.
                budget /= 2
            default:
                throw lastFailure
            }
        }
        guard let opened else { throw lastFailure }
        url = opened.url
        handle = FileHandle(fileDescriptor: opened.fd, closeOnDealloc: true)
        state = Mutex(State())
    }

    /// Cuts `name` to at most `units` UTF-16 code units on a Character
    /// boundary, marking the cut. Character-wise so a trim never lands
    /// between the halves of a surrogate pair or inside a family emoji.
    private static func trimmed(_ name: String, toUTF16Units units: Int) -> String {
        guard units > 0 else { return "" }
        guard name.utf16.count > units else { return name }
        var out = ""
        var used = 0
        for character in name {
            let width = String(character).utf16.count
            guard used + width <= units - 1 else { break }   // -1 for the ellipsis
            out.append(character)
            used += width
        }
        return out + "…"
    }

    /// How long `waitForRoom` will hold its caller before giving up. The wait
    /// used to be unbounded, which was fine as long as `ioQueue` always made
    /// progress — but a volume that never completes a write (an unplugged
    /// network share) parks the log queue forever, and quitting used to wait on
    /// that queue synchronously, which hung ⌘Q on the main actor. (The
    /// controllers no longer wait that way — they close under one deadline for
    /// the whole shutdown — but the reason for bounding this wait is unchanged:
    /// an unbounded one puts the parked chunk beyond anyone's reach.)
    /// Timing out admits the chunk instead of dropping it: the caller has
    /// already been slowed by the whole timeout, so the backlog past the cap
    /// grows by one chunk per stall, not without limit. By the time this
    /// engages the controller's `PendingBytesGate` has already told the user
    /// in the session that the log is falling behind and that output and
    /// typing are throttled — this layer stays silent rather than repeating it.
    private static let maxStallSeconds: TimeInterval = 5

    /// Set under `pendingCondition` — deliberately NOT read from `state`, even
    /// though `state.closed` says the same thing. `append` takes `state` and
    /// then `pendingCondition` (via `addPending`), so reading `state` from
    /// inside `pendingCondition` here would invert that order and deadlock the
    /// two against each other. A second flag under the right lock is cheaper
    /// than the trap.
    nonisolated(unsafe) private var pendingClosed = false
    /// Set under `pendingCondition` by the `ioQueue` closure that performs the
    /// close, once the tail write and `handle.close()` are done. It is what
    /// `close()`'s return value reports, and what lets a second caller learn
    /// the outcome of a flush it did not perform itself.
    nonisolated(unsafe) private var closeFinished = false

    /// Blocks the caller — always the per-session log queue, never the main
    /// actor — while the outstanding write backlog is at or above the cap.
    /// The `pendingBytes > 0` half of the condition matters: a single chunk
    /// larger than the cap must still go through once nothing else is
    /// in flight, or a chunk bigger than `maxPendingBytes` would deadlock
    /// forever waiting for room that can never appear.
    private func waitForRoom() {
        pendingCondition.lock()
        let deadline = Date().addingTimeInterval(Self.maxStallSeconds)
        while !pendingClosed, pendingBytes >= Self.maxPendingBytes, pendingBytes > 0 {
            // A closed logger will never drain another byte on our behalf, and
            // the `guard !state.closed` below turns this call into a no-op
            // anyway — waiting on for room we do not need would only delay the
            // tab teardown queued behind us.
            if !pendingCondition.wait(until: deadline) { break }
        }
        pendingCondition.unlock()
    }

    private func addPending(_ count: Int) {
        guard count > 0 else { return }
        pendingCondition.lock()
        pendingBytes += count
        pendingCondition.unlock()
    }

    /// Called from `ioQueue` once a write completes. `signal()`, not
    /// `broadcast()`, is enough — at most one thread (the single per-session
    /// log queue) ever waits on this logger at a time.
    private func removePending(_ count: Int) {
        guard count > 0 else { return }
        pendingCondition.lock()
        pendingBytes -= count
        pendingCondition.broadcast()   // a reconnect can hand this logger to a second log queue
        pendingCondition.unlock()
    }

    private func reportWriteFailureOnce(_ error: Error) {
        let first = writeFailureReported.withLock { reported -> Bool in
            guard !reported else { return false }
            reported = true
            return true
        }
        guard first else { return }
        NSLog("SheepTerm: session log %@ stopped accepting writes (%@) — it no longer matches the session",
              url.lastPathComponent, error.localizedDescription)
        // The NSLog stays for the post-mortem; this is the half the user is
        // actually in front of. A full volume is the common cause.
        report("session log stopped accepting writes — \(error.localizedDescription). "
             + "\(url.lastPathComponent) no longer matches this session; free some space and reconnect to start a new log")
    }

    /// Reported once: the file still has a name, but not the one we opened it
    /// through. A rename does not change `st_nlink`, so `relinkIfUnlinked` sees
    /// a perfectly healthy file and says nothing — correctly, since the writes
    /// follow the inode and no output is lost. What goes wrong is quieter: the
    /// session went on naming a path that stopped existing when the file was
    /// moved, and every later message about "the log" named the wrong place.
    /// Found by the soak, which renamed a log mid-session and watched 43.7 MB
    /// land safely in a file the app could no longer name.
    ///
    /// Deliberately a report and not a relink: the bytes are already going to
    /// the right file, and re-creating the old path would split one session's
    /// log across two files just to make a string true.
    private func noteIfRenamed(_ info: stat) {
        guard !renameReported else { return }
        var onDisk = stat()
        let stillOurs = stat(url.path, &onDisk) == 0
            && onDisk.st_ino == info.st_ino
            && onDisk.st_dev == info.st_dev
        guard !stillOurs else { return }
        renameReported = true
        report("the session log was renamed or replaced — this session is still writing to the file it "
             + "opened (nothing is lost), but that file is no longer \(url.path)")
    }

    /// Asks the kernel — cheaply and rarely, see `linkCheckInterval` — whether
    /// the file this logger is writing to still has a name.
    ///
    /// This exists because an open `FileHandle` outlives the directory entry
    /// it was opened through: deleting `~/Documents/SheepTerm Logs` mid-session
    /// left every `write` SUCCEEDING against an unlinked inode, so nothing
    /// threw, nothing was reported, the session went on saying "logging to
    /// …/x.log", and at close there was no file at all. `st_nlink == 0` is the
    /// one signal that distinguishes that from a healthy write, and `fstat` on
    /// an fd we already hold asks it without a path lookup.
    ///
    /// Runs on `ioQueue` only, so `handle` and the two timestamps are
    /// exclusive without a lock.
    private func relinkIfUnlinked() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastLinkCheck >= Self.linkCheckInterval else { return }
        lastLinkCheck = now

        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return }
        guard info.st_nlink == 0 else {
            noteIfRenamed(info)
            return
        }

        // Put the folder back if it went too, then re-create the file at the
        // same path. Not O_EXCL here, and O_APPEND on purpose: if something
        // has since taken the path (a restored backup, a second SheepTerm),
        // adding to it beats losing the rest of the session.
        _ = Self.logsDirectory
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        // `== 0` is "never reported": the interval alone would swallow the
        // first notice on a Mac that booted less than 30 s ago, which is
        // exactly when a login-item SheepTerm is starting its sessions.
        let shouldReport = lastRelinkReport == 0 || now &- lastRelinkReport >= Self.relinkReportInterval
        guard fd >= 0 else {
            // No way back — the folder is read-only now, or a file sits where
            // it was. The old handle stays: writes to an unlinked inode still
            // SUCCEED, so nothing here will ever throw, and saying so is the
            // only report there is. We retry on the next cadence tick in case
            // whatever took the path goes away.
            if shouldReport {
                lastRelinkReport = now
                report("session log file \(url.lastPathComponent) was deleted and could not be re-created "
                     + "(\(String(cString: strerror(errno)))) — this session is no longer being logged")
            }
            return
        }
        try? handle.close()
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if shouldReport {
            lastRelinkReport = now
            report("session log file was deleted underneath this session — re-created \(url.path). "
                 + "Everything up to the deletion is gone, and up to \(Int(Self.linkCheckInterval / 1_000_000)) ms "
                 + "of output after it went to the deleted file")
        }
    }

    func append(_ bytes: [UInt8]) {
        // Backpressure gate, deliberately outside `state`'s Mutex: if this
        // blocks, `close()` must still be free to run (it needs `state`,
        // not `pendingCondition`) and mark the logger closed while we wait
        // — this call will simply no-op once it wakes and sees `closed`.
        waitForRoom()

        // Computed under the Mutex (cheap: bookkeeping + byte scanning, no
        // I/O); the write itself is submitted to `ioQueue` before the lock
        // is released (see class doc comment) and runs after we return.
        state.withLock { state in
            guard !state.closed else { state.refused += bytes.count; return }

            // Cap checked BEFORE any work: past 100 MB nothing is written,
            // so scanning the chunk is pure waste on runaway sessions.
            if state.written >= Self.maxSize {
                state.carry = []
                if !state.truncated {
                    state.truncated = true
                    let notice = Data("\n--- log truncated at 100 MB ---\n".utf8)
                    addPending(notice.count)
                    ioQueue.async { [self] in
                        Self.simulateSlowDisk()
                        try? handle.write(contentsOf: notice)
                        removePending(notice.count)
                        // Say it in the SESSION too, not only in the file. The
                        // line above is at the end of a 100 MB file nobody is
                        // looking at, so the session went on scrolling with
                        // everything after this point unrecorded and nothing on
                        // screen to say so — the same silence `open()` and the
                        // relink check were both fixed for. On ioQueue, and
                        // therefore outside `state`'s lock: `report` calls into
                        // the controller, which must never run under it.
                        report("this session's log reached its 100 MB limit and stopped recording — "
                             + "output from here on is not being saved to \(url.lastPathComponent)")
                    }
                }
                return
            }

            var data: [UInt8]
            if state.carry.isEmpty {
                // [UInt8] is copy-on-write: the common no-carry path borrows
                // incoming storage instead of allocating carry + bytes.
                data = bytes
            } else {
                data = state.carry
                data.append(contentsOf: bytes)
                state.carry = []
            }

            // One cut index for both holds, taking the minimum so neither
            // hold loses the other's bytes.
            var cut = data.count
            if let utf8Cut = Self.incompleteUTF8Tail(data) {
                cut = utf8Cut
            }
            cut = min(cut, Self.incompleteEscapeTail(data) ?? data.count)
            if cut < data.count {
                state.carry = Array(data[cut...])
                data = Array(data[..<cut])
            }

            guard let chunk = Self.encodedLogChunk(data) else { return }
            state.written += chunk.count
            addPending(chunk.count)
            ioQueue.async { [self] in
                Self.simulateSlowDisk()
                // Before the write, not after: a re-link that happens first
                // means this chunk lands in the file the user can still find.
                relinkIfUnlinked()
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    // A swallowed write means the log quietly stops matching
                    // the wire — a disk that filled up looks exactly like a
                    // quiet session. Say it once per file, not per chunk.
                    reportWriteFailureOnce(error)
                }
                removePending(chunk.count)
            }
        }
    }

    /// How long `close()` waits for the flush to land before giving up and
    /// saying so. A stalled volume (network disk, iCloud Desktop) must not
    /// turn ⌘Q into an indefinite beachball; a truncated tail is the lesser
    /// evil — but only if the caller is TOLD it was truncated, which is what
    /// the return value is for.
    private static let closeFlushSeconds: TimeInterval = 2

    /// Closes the log and waits for the flush. **Returns whether the log is
    /// complete** — the flush landed AND no write was ever refused. False
    /// means the file does not match the session: its tail is missing, or a
    /// full volume threw part of it away earlier.
    ///
    /// A call that can fail should hand back whether it did. This is the third
    /// time in this file pair that a function knew the answer and made its
    /// caller guess: `CredentialStore.save()` returned Void while its caller
    /// deleted the Keychain item on the assumption it had worked;
    /// `QuitLogFlush.waitForForcedClose` inferred "flushed" from "the call
    /// returned"; and this one waited for its own flush, learned the answer,
    /// and dropped it on the floor (`_ = flushed.wait(...)`). Each time the
    /// guess was wrong in the direction that loses data quietly, and each time
    /// it was found by measurement rather than by reading. If you are about to
    /// write `_ =` in front of a wait, a write, or a save in this file, that is
    /// the bug arriving for the fourth time.
    ///
    /// Every caller may ignore it (`@discardableResult`): a tab close has
    /// nowhere to report it and the tests read the file back instead. Nothing
    /// about their timing changes — the wait below is the one that was always
    /// here, and the value is a by-product of it.
    ///
    /// What a SECOND caller gets, and why: the same answer, by waiting for the
    /// same flush. The question is "is this file complete?", which is a
    /// property of the LOG, not of the call — the quit's cut-off close asks it
    /// about a flush the in-order close owns, and answering "true, I returned"
    /// there is exactly the mistake this whole chain is made of. So the early
    /// `alreadyClosed` return is gone: a later caller skips the work and joins
    /// the wait.
    @discardableResult
    func close() -> Bool {
        // Whichever of append/close wins the Mutex first enqueues its
        // ioQueue work first, so FIFO order on ioQueue matches call order
        // even though the two run on different threads (log queue vs.
        // main actor). Once `closed` flips to true here, no later append()
        // can reach `ioQueue` at all — it returns at its own `guard` above,
        // still under this same Mutex.
        var alreadyClosed = false
        state.withLock { state in
            guard !state.closed else { alreadyClosed = true; return }
            // Flush what is still held — the tail of a session is the part
            // you most want in the log. Only an unfinished fragment drops.
            var finalChunk: Data?
            if !state.carry.isEmpty, state.written < Self.maxSize {
                var cut = state.carry.count
                if let utf8Cut = Self.incompleteUTF8Tail(state.carry) {
                    cut = utf8Cut
                }
                cut = min(cut, Self.incompleteEscapeTail(state.carry) ?? state.carry.count)
                if let chunk = Self.encodedLogChunk(Array(state.carry[..<cut])) {
                    state.written += chunk.count
                    finalChunk = chunk
                }
            }
            state.carry = []
            state.closed = true
            // Snapshot to an immutable local: `finalChunk` above is a `var`
            // only so the `if` block can assign it, but the async closure
            // needs a fixed value, not a reference to a box that could
            // (in principle) be mutated again after capture.
            let chunkToFlush = finalChunk
            ioQueue.async { [self] in
                // Unconditional, ignoring the cadence: this is the last look
                // anyone gets, and "the file you were told about is not there"
                // has to be said before the session ends rather than never. It
                // costs one `fstat` per session.
                lastLinkCheck = 0
                relinkIfUnlinked()
                if let chunkToFlush {
                    Self.simulateSlowDisk()
                    do {
                        try handle.write(contentsOf: chunkToFlush)
                    } catch {
                        // The report `append` makes, for the same reason. This
                        // `try?` was the last place in the file that knew an
                        // answer and dropped it; the return value carries it.
                        reportWriteFailureOnce(error)
                    }
                }
                do {
                    try handle.close()
                } catch {
                    reportWriteFailureOnce(error)
                }
                // Under `pendingCondition` and broadcast rather than a
                // semaphore signal, so EVERY caller waiting on this close —
                // not just the first one — learns that it landed. `ioQueue`
                // already takes this lock in `removePending`, so this adds no
                // edge to the lock ordering at the top of this file.
                noteCloseFinished()
            }
        }
        if !alreadyClosed {
            // Outside `state`'s Mutex on purpose (`append` takes state → pending;
            // taking them the other way round here would invert that order). Any
            // `append` parked in `waitForRoom` wakes now, sees the logger closed,
            // and returns at its own guard instead of sitting out the timeout —
            // which matters because the flush below is queued behind it.
            pendingCondition.lock()
            pendingClosed = true
            pendingCondition.broadcast()
            pendingCondition.unlock()
        }
        // The one synchronous wait left in this class: callers rely on
        // "closed means fully flushed and the fd is released" the instant
        // close() returns (the test harness reads the file back right
        // after this call). The Mutex is already free by this point.
        //
        // What this waits for, precisely: `ioQueue` is FIFO, so this is the
        // tail write plus whatever this session's own backlog of prior
        // `append` writes hadn't finished yet — bounded by `maxPendingBytes`
        // (append() blocks its own caller once that cap is hit, so the
        // backlog can never exceed it). Contrast with the old bug: there,
        // `close` and `append` shared one Mutex per session, so `close`
        // could be blocked for as long as whichever single write `append`
        // happened to be inside when the lock was requested — never another
        // session's, `state` is per-instance, but still an unbounded stall
        // if that one write was slow (e.g. an iCloud-synced file provider).
        // Now `append` never holds a lock across I/O at all, so the only
        // thing left to wait for is this bounded backlog actually landing.
        let landed = waitForCloseToLand()
        // "Finished" is not "complete". `closeFinished` says the close closure
        // ran to its end — tail written or not, descriptor released — and a
        // write the volume REFUSED (a full disk: `handle.write` throws at
        // once) finishes just as promptly as one that landed. The file was
        // 0 bytes and this returned true (recheck finding 4). The refusal is
        // already recorded once per file by `reportWriteFailureOnce`; it is
        // the other half of the answer. Read after the wait, so a refused
        // tail write counts too.
        let refused = writeFailureReported.withLock { $0 }
        // Same reasoning as `PendingBytesGate.finish`: a session that is over
        // has nowhere left to print, and the callback holds the controller.
        // Only the caller that did the closing clears it — a later one has no
        // business taking the outlet away from whoever is still using it.
        if !alreadyClosed { onProblem = nil }
        return landed && !refused
    }

    /// Called from `ioQueue` once the file is written and the descriptor
    /// released. `broadcast`, not `signal`: two callers can be waiting on one
    /// close (the quit's in-order close and its cut-off close).
    private func noteCloseFinished() {
        pendingCondition.lock()
        closeFinished = true
        pendingCondition.broadcast()
        pendingCondition.unlock()
    }

    /// Blocks until the close has landed or `closeFlushSeconds` runs out, and
    /// says which. Every caller of `close()` ends here, so they all get the
    /// same answer about the same file.
    private func waitForCloseToLand() -> Bool {
        pendingCondition.lock()
        defer { pendingCondition.unlock() }
        let deadline = Date().addingTimeInterval(Self.closeFlushSeconds)
        while !closeFinished {
            if !pendingCondition.wait(until: deadline) { break }
        }
        return closeFinished
    }

    /// Index of a trailing incomplete UTF-8 sequence — a lead byte whose
    /// continuation bytes haven't all arrived yet — or nil when the buffer
    /// ends on a character boundary (or on invalid bytes, which are passed
    /// through rather than held forever).
    private static func incompleteUTF8Tail(_ bytes: [UInt8]) -> Int? {
        var index = bytes.count
        var continuation = 0
        while index > 0 {
            let byte = bytes[index - 1]
            if byte & 0xC0 == 0x80 {
                continuation += 1
                index -= 1
                if continuation > 3 { return nil } // invalid stream — don't carry
                continue
            }
            // Valid UTF-8 lead bytes only: 0xC2-0xDF need 1 continuation,
            // 0xE0-0xEF need 2, 0xF0-0xF4 need 3. 0xF5-0xFF are NOT lead
            // bytes — holding them back only delayed the same U+FFFD by a
            // chunk (same rule as HighlightBuffer.incompleteUTF8Tail).
            if byte >= 0xC2, byte <= 0xF4 {
                let needed = byte >= 0xF0 ? 3 : (byte >= 0xE0 ? 2 : 1)
                if continuation < needed { return index - 1 }
            }
            return nil
        }
        return nil
    }

    /// Index where an incomplete trailing escape sequence starts, or nil
    /// when the buffer doesn't end mid-sequence. Covers CSI (final byte
    /// pending), OSC (BEL/ST pending) and DCS/APC string payloads (ST
    /// pending) — an unterminated run must be carried over, or its raw
    /// bytes would be logged half-stripped.
    private static func incompleteEscapeTail(_ bytes: [UInt8]) -> Int? {
        guard let esc = bytes.lastIndex(of: 0x1B),
              bytes.count - esc <= Self.maxEscapeHold else { return nil }
        let tail = bytes[(esc + 1)...]
        if tail.isEmpty {
            // A dangling final ESC may be the ST half of an open string
            // sequence (ESC ] / ESC P / ESC _ … ESC \) — hold from that
            // opener when one is still unterminated.
            return Self.unterminatedStringOpener(bytes, before: esc) ?? esc
        }
        let complete: Bool
        if tail.first == UInt8(ascii: "[") {
            // CSI: complete at a final byte 0x40–0x7E.
            complete = tail.dropFirst().contains { $0 >= 0x40 && $0 <= 0x7E }
        } else if tail.first == UInt8(ascii: "]") {
            // OSC: BEL terminates; ST's ESC would be the last ESC, so only
            // BEL can complete the sequence inside `tail`.
            complete = tail.contains(0x07)
        } else if tail.first == UInt8(ascii: "P") || tail.first == UInt8(ascii: "_") {
            // DCS / APC: ST (ESC \) only, and the terminating ESC would be
            // the last ESC — a sequence still open at `esc` is incomplete.
            complete = false
        } else if let first = tail.first, first >= 0x20, first <= 0x2F {
            // ESC + intermediates + final (ESC ( B, ESC # 8, ESC SP F):
            // complete at the first byte past the intermediate range. A
            // control byte inside it is malformed, not pending — never hold
            // on it.
            complete = tail.dropFirst().contains { $0 >= 0x30 || $0 < 0x20 }
        } else {
            // Two-byte sequence like ESC c.
            complete = true
        }
        guard !complete else { return nil }
        // The incomplete command may be the one ABORTING a string sequence
        // (an OSC/DCS/APC with no terminator before it). Cut there, the
        // string reaches `stripANSIBytes` alone, which cannot tell "aborted"
        // from "oversized" and keeps the payload as text — an OSC 52
        // clipboard or OSC 8 hyperlink logged whenever the device's next SGR
        // straddled a read boundary. Hold from the opener so the abort is
        // seen whole; the hold cap still applies.
        if let opener = Self.unterminatedStringOpener(bytes, before: esc),
           bytes.count - opener <= Self.maxEscapeHold {
            return opener
        }
        return esc
    }

    /// Start index of an ESC ] / ESC P / ESC _ sequence with no terminator
    /// before `end`, or nil. A string payload's trailing ST-ESC looks like
    /// a dangling escape but actually belongs to the payload.
    private static func unterminatedStringOpener(_ bytes: [UInt8], before end: Int) -> Int? {
        var index = end
        while index > 0 {
            index -= 1
            guard bytes[index] == 0x1B else { continue }
            switch bytes[index + 1] {
            case UInt8(ascii: "\\"):
                return nil // an ST — any opener before it is closed
            case UInt8(ascii: "]"):
                // OSC also ends at BEL.
                return bytes[(index + 2)..<end].contains(0x07) ? nil : index
            case UInt8(ascii: "P"), UInt8(ascii: "_"):
                return index
            default:
                continue // CSI / two-byte sequences don't close a string
            }
        }
        return nil
    }

    /// Single-pass byte scanner for terminal control sequences. It removes
    /// CSI, OSC, DCS, APC, ordinary two-byte ESC commands, and CR without
    /// creating five intermediate Strings as the previous regex pipeline did.
    /// `incompleteEscapeTail` ensures normal calls never end mid-sequence.
    static func stripANSIBytes(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0

        while index < input.count {
            let byte = input[index]
            if byte == 0x0D { // normalize CRLF to LF
                index += 1
                continue
            }
            guard byte == 0x1B, index + 1 < input.count else {
                output.append(byte)
                index += 1
                continue
            }

            let introducer = input[index + 1]
            if introducer == UInt8(ascii: "[") { // CSI
                var end = index + 2
                while end < input.count, input[end] >= 0x30, input[end] <= 0x3F { end += 1 }
                while end < input.count, input[end] >= 0x20, input[end] <= 0x2F { end += 1 }
                if end < input.count, input[end] >= 0x40, input[end] <= 0x7E {
                    index = end + 1
                    continue
                }
            } else if introducer == UInt8(ascii: "]")
                        || introducer == UInt8(ascii: "P")
                        || introducer == UInt8(ascii: "_") { // OSC / DCS / APC
                var end = index + 2
                var terminated = false
                while end < input.count {
                    if introducer == UInt8(ascii: "]"), input[end] == 0x07 {
                        end += 1
                        terminated = true
                        break
                    }
                    if input[end] == 0x1B {
                        if end + 1 < input.count, input[end + 1] == UInt8(ascii: "\\") {
                            end += 2
                            terminated = true
                        }
                        break // ST, or another ESC aborts the string sequence
                    }
                    end += 1
                }
                if terminated {
                    index = end
                    continue
                }
                if end < input.count, input[end] == 0x1B {
                    // The payload before an aborting ESC is non-display data;
                    // discard it and re-examine the new ESC as a command.
                    index = end
                    continue
                }
                // Oversized malformed sequence: match the old fallback by
                // stripping its two-byte introducer but retaining the payload.
                index += 2
                continue
            } else if introducer >= 0x20 && introducer <= 0x2F {
                // ECMA-48 with intermediates: ESC ( B, ESC ) 0, ESC # 8,
                // ESC SP F, ESC % G — what vim/less/top/tmux emit constantly.
                // Falling to "preserve the ESC" wrote a raw ESC AND the text
                // `(B` into every Linux session's log.
                var end = index + 2
                while end < input.count, input[end] >= 0x20, input[end] <= 0x2F { end += 1 }
                if end < input.count, input[end] >= 0x30, input[end] <= 0x7E {
                    index = end + 1
                    continue
                }
            } else if introducer >= 0x30 && introducer <= 0x7E {
                index += 2 // ordinary two-byte ESC command
                continue
            }

            // Not a recognized complete sequence: preserve the ESC exactly.
            output.append(byte)
            index += 1
        }
        return output
    }

    /// Produces UTF-8 log bytes. Plain ASCII without controls is the dominant
    /// router-output path and writes directly; non-ASCII still takes the lossy
    /// UTF-8 normalization path so invalid bytes retain the established U+FFFD
    /// behavior covered by tests.
    private static func encodedLogChunk(_ input: [UInt8]) -> Data? {
        guard !input.isEmpty else { return nil }
        if input.allSatisfy({ $0 < 0x80 && $0 != 0x1B && $0 != 0x0D }) {
            return Data(input)
        }
        let stripped = stripANSIBytes(input)
        guard !stripped.isEmpty else { return nil }
        if stripped.allSatisfy({ $0 < 0x80 }) {
            return Data(stripped)
        }
        return String(decoding: stripped, as: UTF8.self).data(using: .utf8)
    }

    static func stripANSI(_ input: String) -> String {
        String(decoding: stripANSIBytes(Array(input.utf8)), as: UTF8.self)
    }
}
