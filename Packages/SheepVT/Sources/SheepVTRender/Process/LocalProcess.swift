//
//  LocalProcess.swift — a child process on the other end of a pty.
//
//  Port of SwiftTerm's `LocalProcess.swift` (MIT), rebuilt around this package's threading rule:
//  the object and its delegate are main-actor (the whole target is), the read loop lives on one
//  serial utility queue, and everything crosses to the delegate through `DispatchQueue.main.async`
//  so it stays FIFO-ordered with the view's own `feed`.
//
//  Five details are load-bearing:
//
//  * **Batch before hopping.** A pty hands out ~1 KiB per read; posting each of those to main is
//    the pitfall in the study (§3.10) — thousands of hops per screenful. The reader drains to
//    EAGAIN and hands the delegate at most 64 KiB per callback.
//  * **Bounded hand-off.** Those batches go into one `Feed` per child, and the reader SUSPENDS its
//    read source once the delegate is `pendingLimit` bytes behind. See `Feed` for why that is a
//    suspend rather than the blocking gate the SSH/serial side uses.
//  * **Reap in `terminate()`.** The exit `DispatchSourceProcess` stays armed across a terminate,
//    so the SIGHUP'd child is `waitpid`ed by the same code path as a child that quit on its own
//    and `processTerminated` still fires exactly once. That is what makes the app's separate
//    zombie-reaper (`LocalTerminalController.reapAfterTerminate`) unnecessary.
//  * **One session object, one owner.** Everything about a running child that is not plain
//    main-actor state — the two dispatch sources, the "read side is finished" and "child is
//    reaped" flags, and the *read* descriptor itself — lives in a `Session` that belongs to
//    `ioQueue` and to nobody else. The main actor only ever holds the reference: it compares it
//    by identity and hands it to a block, and never reads or writes a member. That is what makes
//    the `@unchecked Sendable` honest, and it is what stops a tab closing mid-EOF from racing the
//    reader over the same descriptor. Each `start` makes a *fresh* `Session`, so a block left
//    over from a finished child can neither touch the next child's state nor deliver its bytes,
//    its EOF or its exit to the delegate (`self.session === session` is checked on main).
//  * **Every background closure is built in a `nonisolated` context.** This target's default
//    isolation is `MainActor`, so a closure written inline inside a main-actor method is itself
//    main-actor — and handing that to a GCD source traps in `dispatch_assert_queue` the moment
//    the utility queue runs it. Hence the `nonisolated static` factories below: they are the only
//    place these blocks may be created.
//
//  One lock, and only one: `Feed`, which is by definition shared between the reader and the main
//  queue. Everything else below is confined to one serial queue (or to the main actor), which is
//  the only synchronisation GCD is asked for.
//
//  Descriptor ownership, in one place:
//
//  * the pty master (`Session.fd`) is `ioQueue`'s. It is closed exactly once, in the read
//    source's cancel handler, and the read source is cancelled only from `ioQueue`. Main-side
//    teardown does not close it — it *posts* `enqueueReadTeardown`, which marks the read side
//    done and then cancels, in that order, so an exit event that arrives afterwards can never
//    drain a descriptor that is on its way out (or one the kernel has since recycled).
//  * the private dup (`writeFd`) is the main actor's: only main assigns it, and the actual
//    `close` runs on `writeQueue` behind `writeClosed`, always after main has already set the
//    variable to -1. `resize` uses this descriptor too, so the main actor never touches the read
//    descriptor at all.
//

import Foundation
import Dispatch
import Synchronization

/// Receives the child's output and its death. Both callbacks land on the main queue.
public protocol LocalProcessDelegate: AnyObject {
    /// A batch of bytes read from the pty, at most 64 KiB. Delivered in order.
    func dataReceived(_ process: LocalProcess, bytes: [UInt8])
    /// Called exactly once per successful `start`. `exitCode` is nil when the child was killed by
    /// a signal (or could not be reaped).
    func processTerminated(_ process: LocalProcess, exitCode: Int32?)
}

/// A one-value box confined to a single serial queue — the queue is the synchronisation, so the
/// unchecked conformance is honest as long as every access stays on that queue.
private nonisolated final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// The reader → main hand-off for one child: bounded, and coalescing.
///
/// What this replaces: a `DispatchQueue.main.async` per batch with nothing counting what was
/// already in flight. Measured on the real thing — 64 MiB pushed through a pty with the main actor
/// deliberately busy for 2 s, against a delegate that only counts bytes — the old shape delivered
/// **0 bytes** during the stall and took the process up by **491–711 MiB**, all of it batches queued
/// behind the stall. Nothing was lost (every byte arrived once main was released) but a `cat` of a
/// big file in a local shell while the UI hitches is not allowed to cost hundreds of megabytes.
///
/// Two jobs, and they are worth keeping apart because only one of them is a bound:
///
/// * **Coalescing.** One drain is scheduled per empty→non-empty transition rather than one per
///   read, so a main thread that unsticks after a hitch runs a single block instead of tens of
///   thousands. That is a constant-factor win (~150 B of block object per batch), not a bound.
/// * **The bound.** `submit` reports whether there is room left, and the reader answers by
///   suspending its read source. That is the actual fix: unread bytes stay in the pty, the pty
///   buffer fills, and the child blocks in `write(2)` — the same backpressure a real terminal
///   applies, and the reason nothing has to be dropped.
///
/// **Nothing here ever blocks**, which is where this parts company with `PendingBytesGate` /
/// `MainFeedQueue` in the app's SessionLogger.swift. Those park their producer on an `NSCondition`,
/// and that is right for them: the producer is an SSH or serial worker with a thread of its own,
/// and stopping it is what closes the SSH window. This producer is a GCD event handler running on
/// `ioQueue` — the same serial queue that owns the read source, the exit source, the SIGKILL
/// escalation and every teardown block. Parking it would park all of those behind it: a tab closed
/// during a stall could not cancel the read source, and a dead child could not be reaped. So the
/// producer *stops* instead of *waiting*, and the queue stays free for teardown.
///
/// Batches are kept as they were read, never concatenated: it saves copying everything a second
/// time, and it keeps the delegate's ≤ 64 KiB-per-callback contract intact.
///
/// Order is preserved because `submit` appends and `take` drains under one lock and the main queue
/// is FIFO: bytes submitted after a drain was scheduled land either in that drain or in the next
/// one, never out of order and never twice.
private nonisolated final class Feed: Sendable {
    /// What `submit` tells the reader.
    struct Admission {
        /// This batch made the buffer non-empty with no drain pending — schedule one.
        let needsDrain: Bool
        /// Still under the cap. False means: stop reading the pty.
        let hasRoom: Bool
    }

    private struct State {
        var batches: [[UInt8]] = []
        var bytes = 0
        var scheduled = false
        var stalls = 0
    }

    /// See `LocalProcess.pendingLimit` for the number and why it is that number.
    private let limit: Int
    private let state = Mutex(State())

    init(limit: Int) { self.limit = limit }

    var outstandingBytes: Int { state.withLock { $0.bytes } }
    /// How many times the reader has been told to stop. Tests assert on this so they prove the
    /// mechanism engaged, not merely that RAM happened to stay low.
    var stallCount: Int { state.withLock { $0.stalls } }

    func submit(_ batch: [UInt8]) -> Admission {
        state.withLock { state in
            state.batches.append(batch)
            state.bytes += batch.count
            let needsDrain = !state.scheduled
            state.scheduled = true
            let hasRoom = state.bytes < limit
            if !hasRoom { state.stalls += 1 }
            return Admission(needsDrain: needsDrain, hasRoom: hasRoom)
        }
    }

    /// Hands the whole backlog to the caller and re-arms scheduling. Clearing `scheduled` under the
    /// same lock that empties the buffer is what keeps "someone is going to drain this" and "there
    /// is something to drain" from ever disagreeing.
    func take() -> [[UInt8]] {
        state.withLock { state in
            let drained = state.batches
            state.batches = []
            state.bytes = 0
            state.scheduled = false
            return drained
        }
    }
}

/// Why a `drain` stopped.
private nonisolated enum DrainOutcome {
    /// EAGAIN: the pty has nothing more for now. The source will fire again when it does.
    case wouldBlock
    /// The delegate is a full `Feed` behind. Stop reading — see `Feed`.
    case full
    /// EOF, or EIO, which is a pty master's way of saying the last slave descriptor is gone.
    case finished
}

/// One child's worth of state, confined to `ioQueue`. The identity of the object doubles as the
/// session identity: a stale block holds a stale `Session`, and everything that crosses back to
/// main compares it against the current one before acting.
///
/// Every stored property here is read and written on `ioQueue` only. The main actor holds the
/// reference and compares it with `===`; that is the whole contract.
private nonisolated final class Session: @unchecked Sendable {
    /// The child. Immutable, so main may read it — it does not.
    let pid: pid_t
    /// Master side of the pty. Closed exactly once, by the read source's cancel handler.
    let fd: Int32

    /// EOF cancels this right on `ioQueue`: a pty master at EOF is permanently readable, and an
    /// armed source whose handler reads nothing re-fires in a tight loop until cancelled —
    /// measured: a full core for as long as the main queue took to turn.
    var readSource: DispatchSourceRead?
    /// The exit handler has to cancel this *before* `waitpid`: once the child is reaped the kernel
    /// drops the proc, and a still-armed NOTE_EXIT knote then reports EV_VANISHED, which
    /// libdispatch treats as a fatal client bug.
    var exitSource: DispatchSourceProcess?

    /// The read side has hit EOF (or been torn down) and `fd` is closed or closing. The exit
    /// handler checks it before draining, so it can never read a descriptor the cancel handler has
    /// closed (and the kernel may since have handed to something else).
    var readDone = false
    /// The exit source has reaped the child; read by the SIGKILL timer so a recycled pid is never
    /// signalled.
    var reaped = false
    /// The read source is suspended because the delegate is behind. This flag is what keeps
    /// suspend/resume balanced — exactly one resume per suspend, whether it comes from a main-queue
    /// drain or from teardown — and an over-resume is a hard crash, not a leak.
    var paused = false

    init(pid: pid_t, fd: Int32) {
        self.pid = pid
        self.fd = fd
    }
}

/// Runs one program under a pseudo-terminal and pipes it to a delegate.
@MainActor
public final class LocalProcess {
    /// Largest batch handed to the delegate in one main-queue hop.
    private nonisolated static let batchLimit = 64 * 1024
    /// One `read(2)` at a time; the pty rarely returns more than 1 KiB anyway.
    private nonisolated static let chunkSize = 4 * 1024
    /// How far the delegate may fall behind before the reader stops pulling on the pty (see `Feed`
    /// for the mechanism). 4 MiB, the number the app side settled on for the same hand-off
    /// (`MainFeedQueue`): two to three screenfuls of a 400-column tab, so an ordinary burst never
    /// touches it, and small enough that the worst case — the cap plus the one batch in flight — is
    /// noise beside the ~24 MB of scrollback the tab already owns.
    private nonisolated static let pendingLimit = 4 * 1024 * 1024
    /// How long a SIGHUP'd child gets before SIGKILL.
    private nonisolated static let killGrace: TimeInterval = 1.0

    public private(set) var pid: pid_t = 0
    public private(set) var running: Bool = false

    private weak var delegate: (any LocalProcessDelegate)?

    /// The read source, the exit source and the SIGKILL escalation all share this queue, so they
    /// are mutually exclusive: output already queued for main is posted before the exit is.
    private let ioQueue = DispatchQueue(label: "com.sheepterm.sheepvt.pty.io", qos: .utility)
    /// Writes are serialised here, and the write descriptor is closed here too, so a `send` can
    /// never write into a descriptor that has been closed (and possibly recycled) under it.
    private let writeQueue = DispatchQueue(label: "com.sheepterm.sheepvt.pty.write", qos: .userInitiated)

    /// The current child, or nil before the first `start`. Only the *reference* is main-actor
    /// state — see `Session`.
    private var session: Session?

    /// A private duplicate of the master, owned by the main actor. Splitting the descriptor keeps
    /// the read side's teardown (GCD closes it in the source's cancel handler, on `ioQueue`) from
    /// ever racing a write in flight — or a `resize`, which uses this descriptor for the same
    /// reason.
    private var writeFd: Int32 = -1
    /// Set on `writeQueue` when `writeFd` has been closed.
    private var writeClosed = Box(false)

    /// Main-actor guard: `processTerminated` fires once.
    private var terminationDelivered = false

    /// The current child's hand-off buffer. Replaced by every `start` for the same reason
    /// `writeClosed` is: a block left over from the previous child holds the previous `Feed`, so it
    /// can neither hand this child's delegate stale bytes nor take room from it.
    private var feed = Feed(limit: pendingLimit)

    /// How many times the reader has had to stop because the delegate was behind. Not public: the
    /// app has no use for it, the tests that drive a stalled main actor do.
    var readStallCount: Int { feed.stallCount }
    /// Bytes read but not yet handed to the delegate. Same audience as `readStallCount`.
    var pendingByteCount: Int { feed.outstandingBytes }

    public init(delegate: any LocalProcessDelegate) {
        self.delegate = delegate
    }

    // MARK: - Lifecycle

    /// Forks the child and arms the read and exit sources.
    /// - Returns: false if a process is already running or `forkpty` failed.
    @discardableResult
    public func start(
        executable: String,
        args: [String],
        environment: [String],
        execName: String?,
        cols: Int,
        rows: Int
    ) -> Bool {
        guard !running else { return false }
        guard let (childPid, master) = Pty.fork(
            executable: executable,
            args: args,
            environment: environment,
            execName: execName,
            cols: cols,
            rows: rows
        ) else { return false }

        // The read loop drains to EAGAIN, so the master must not block. Done before the descriptor
        // is handed to `ioQueue`; after that it is not ours to touch.
        Self.setNonBlocking(master)

        // Publish state before arming anything: a fast-exiting child can make the exit handler run
        // almost immediately.
        pid = childPid
        writeFd = dup(master)
        running = true
        terminationDelivered = false
        // A fresh box rather than a reset flag: the previous session's close may still be sitting
        // on `writeQueue`, and it must not be able to mark *this* session's descriptor closed.
        writeClosed = Box(false)
        // Likewise fresh: see the property.
        let feed = Feed(limit: Self.pendingLimit)
        self.feed = feed
        // Likewise a fresh session: blocks from the previous child keep the old object, so they
        // cannot see — let alone clobber — this one.
        let session = Session(pid: childPid, fd: master)
        self.session = session

        // Both sources are created, published *and* consumed on `ioQueue`, so no field of
        // `Session` is ever touched from two threads. `start` returns before the block runs; that
        // only means the first bytes arrive a queue hop later.
        Self.arm(
            session: session,
            on: ioQueue,
            deliver: makeDataDeliverer(session: session, feed: feed, on: ioQueue),
            eof: makeEOFHandler(session: session),
            finish: makeExitDeliverer(session: session)
        )
        return true
    }

    /// Writes to the child's terminal. Returns immediately; the write is serialised on a private
    /// queue and retried through short writes and EINTR.
    public func send(_ bytes: [UInt8]) {
        guard running, writeFd >= 0, !bytes.isEmpty else { return }
        Self.enqueueWrite(bytes, fd: writeFd, on: writeQueue, closed: writeClosed)
    }

    /// Reports a new geometry to the pty; the kernel raises SIGWINCH in the child.
    ///
    /// Uses the main actor's own dup, never the read descriptor: `ioQueue` may close that one at
    /// EOF at any moment, and an `ioctl` on a recycled descriptor is the kind of bug that surfaces
    /// somewhere else entirely.
    public func resize(cols: Int, rows: Int) {
        guard running, writeFd >= 0 else { return }
        Pty.setWinSize(writeFd, cols: cols, rows: rows)
    }

    /// SIGHUP now, SIGKILL a second later if that was not enough, and let the still-armed exit
    /// source `waitpid` the corpse — so the child never becomes a zombie and `processTerminated`
    /// still arrives exactly once.
    public func terminate() {
        guard running, pid > 0, let session else { return }
        Self.signal(SIGHUP, to: pid)
        Self.scheduleKill(session: session, after: Self.killGrace, on: ioQueue)
    }

    /// A `LocalProcess` dropped while its child is alive (tab closed in the same runloop turn as
    /// `terminate()`) must not leak the pty master and its dup: releasing an armed DispatchSource
    /// does NOT run its cancel handler, so the read source has to be cancelled explicitly — but
    /// from `ioQueue`, which owns it, and only after the read side is marked done so a pending
    /// exit event cannot drain the descriptor the cancel handler is about to close. If the reader
    /// is parked at the time, `closeRead` resumes it first: a *suspended* source does not run its
    /// cancel handler either.
    ///
    /// The exit source is left armed on purpose: it keeps itself alive through its handler until
    /// the child is reaped, which is what stops a terminated child becoming a zombie.
    isolated deinit {
        if let session {
            Self.enqueueReadTeardown(session: session, on: ioQueue)
        }
        if writeFd >= 0 {
            Self.enqueueClose(fd: writeFd, on: writeQueue, closed: writeClosed)
            writeFd = -1
        }
    }

    // MARK: - Arming (all of it on `ioQueue`)

    /// Builds and activates both sources on the queue that owns them. Enqueued from `start`, so it
    /// is always the first block of the session — any teardown posted later lands behind it on the
    /// same serial queue and therefore always finds the sources in place.
    private nonisolated static func arm(
        session: Session,
        on queue: DispatchQueue,
        deliver: @escaping Sink,
        eof: @escaping @Sendable () -> Void,
        finish: @escaping @Sendable (Int32?) -> Void
    ) {
        queue.async {
            let read = DispatchSource.makeReadSource(fileDescriptor: session.fd, queue: queue)
            read.setEventHandler(handler: makeReadHandler(session: session, deliver: deliver, eof: eof))
            // GCD guarantees no handler is running once the cancel handler is invoked, and it runs
            // on this same serial queue — so closing there can never pull the descriptor out from
            // under a `drain` in flight.
            read.setCancelHandler(handler: makeCloseHandler(fd: session.fd))
            session.readSource = read

            let exit = DispatchSource.makeProcessSource(identifier: session.pid,
                                                        eventMask: .exit,
                                                        queue: queue)
            exit.setEventHandler(handler: makeExitHandler(session: session,
                                                          deliver: deliver,
                                                          finish: finish))
            session.exitSource = exit

            // Publish before activating. Both handlers cancel the source they find on the session,
            // and an already-dead child fires the exit handler the instant the source goes live —
            // but not before this block returns, because the queue is serial.
            read.activate()
            exit.activate()
        }
    }

    /// Main-side teardown: hand the read source, the flag and the descriptor to their owner. Order
    /// inside `closeRead` is the point — `readDone` first, then the cancel that closes `fd`.
    /// Idempotent, so `finish` and `deinit` may both post it.
    private nonisolated static func enqueueReadTeardown(session: Session, on queue: DispatchQueue) {
        queue.async { closeRead(session) }
    }

    /// The delegate's end of a batch: takes the bytes and answers whether the reader may keep
    /// going. The Bool is the whole backpressure signal — see `Feed`.
    private typealias Sink = @Sendable ([UInt8]) -> Bool

    // MARK: - Reading

    private nonisolated static func makeReadHandler(
        session: Session,
        deliver: @escaping Sink,
        eof: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        {
            // `paused` cannot normally be true here — a suspended source does not fire — but the
            // suspend takes effect only after this handler returns, so the check costs nothing and
            // says what the invariant is.
            guard !session.readDone, !session.paused else { return }
            switch drain(fd: session.fd, deliver: deliver, honourBackpressure: true) {
            case .finished:
                closeRead(session)
                eof()
            case .full:
                pauseRead(session)
            case .wouldBlock:
                break
            }
        }
    }

    /// `ioQueue` only, and only from the read handler: stop pulling bytes out of the pty until the
    /// main queue has taken what is already queued.
    ///
    /// Suspending the source is the only way to stop. Returning early from the handler instead
    /// would spin: a pty master with unread data in it is permanently readable, and an armed source
    /// whose handler reads nothing re-fires in a tight loop — the same full-core behaviour the EOF
    /// note on `Session.readSource` records, measured there.
    private nonisolated static func pauseRead(_ session: Session) {
        guard !session.paused else { return }
        session.paused = true
        session.readSource?.suspend()
    }

    /// `ioQueue` only. The one place a suspend is undone, from both the main-queue drain and every
    /// teardown path.
    ///
    /// Teardown has to come through here *before* it cancels: a suspended DispatchSource does not
    /// run its cancel handler until it is resumed, and this source's cancel handler is what closes
    /// the pty master. Closing a tab while the reader was parked would otherwise leak two
    /// descriptors and never reap anything (`droppingTheProcessWhileOutputIsArrivingIsSafe` and
    /// `manyProcessesInARowLeakNoDescriptors` are the tests that would catch it).
    private nonisolated static func resumeRead(_ session: Session) {
        guard session.paused else { return }
        session.paused = false
        session.readSource?.resume()
    }

    private nonisolated static func enqueueResume(session: Session, on queue: DispatchQueue) {
        queue.async { resumeRead(session) }
    }

    private nonisolated static func makeCloseHandler(fd: Int32) -> @Sendable () -> Void {
        { close(fd) }
    }

    /// `ioQueue` only. Marks the read side finished and cancels the source, whose cancel handler
    /// closes `fd` — exactly once, because a DispatchSource runs its cancel handler at most once.
    private nonisolated static func closeRead(_ session: Session) {
        session.readDone = true
        // Before the cancel, always — see `resumeRead`.
        resumeRead(session)
        session.readSource?.cancel()
        session.readSource = nil
    }

    /// Reads until the pty would block, handing the bytes to `deliver` in ≤ 64 KiB batches.
    ///
    /// `honourBackpressure` is false on exactly one path, the exit handler's — see it for why.
    private nonisolated static func drain(
        fd: Int32,
        deliver: Sink,
        honourBackpressure: Bool
    ) -> DrainOutcome {
        /// A *fresh* buffer after every hand-off. `removeAll(keepingCapacity:)` would reuse the
        /// storage of the batch that is at that moment being read on the main queue: the write is
        /// guarded only by Array's uniqueness check, which is a refcount load, not a barrier — so
        /// it is a data race ThreadSanitizer reports at -O (found doing exactly that), and one
        /// retain elision could turn into a real one.
        ///
        /// Empty, with no `reserveCapacity`: the common pty read is a keystroke's echo of a few
        /// bytes, and reserving 32 KiB for each of those was ~99% waste — paid on every drain, of
        /// which there is one per keypress. The reservation moved into the loop below, where there
        /// is evidence it will be needed.
        func freshBatch() -> [UInt8] { [] }

        var batch = freshBatch()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var finished = false
        var full = false

        loop: while true {
            let want = min(chunkSize, batchLimit - batch.count)
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, want)
            }
            if n > 0 {
                // A read that filled the buffer is the only honest sign that a burst rather than a
                // keystroke is arriving: grow once to the batch limit instead of letting Array
                // double its way there four times.
                if n == want, batch.capacity < batchLimit { batch.reserveCapacity(batchLimit) }
                batch.append(contentsOf: buffer[0..<n])
                if batch.count >= batchLimit {
                    let hasRoom = deliver(batch)
                    batch = freshBatch()
                    if honourBackpressure, !hasRoom {
                        full = true
                        break loop
                    }
                }
                continue
            }
            if n == 0 {
                finished = true
                break loop
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                break loop
            default:
                // EIO on a pty master means the last slave fd closed: the child is gone.
                finished = true
                break loop
            }
        }

        if !batch.isEmpty {
            let hasRoom = deliver(batch)
            if honourBackpressure, !hasRoom { full = true }
        }
        // EOF wins over a full buffer: there is nothing left to read, so pausing would only park a
        // source that has to be cancelled anyway.
        if finished { return .finished }
        return full ? .full : .wouldBlock
    }

    /// The hand-off, built once per `start`. Appends to `feed`, schedules at most one main-queue
    /// drain at a time, and reports back whether the reader may keep going.
    private nonisolated func makeDataDeliverer(
        session: Session,
        feed: Feed,
        on queue: DispatchQueue
    ) -> Sink {
        { [weak self] bytes in
            let admission = feed.submit(bytes)
            if admission.needsDrain {
                DispatchQueue.main.async {
                    // Taken whether or not the object is still there: an abandoned backlog should
                    // be freed, not held by a block that returned early.
                    let batches = feed.take()
                    if let self {
                        MainActor.assumeIsolated {
                            guard self.isCurrent(session) else { return }
                            for batch in batches { self.delegate?.dataReceived(self, bytes: batch) }
                        }
                    }
                    // After the delegate, not before: the bound is then `pendingLimit` plus the one
                    // batch in flight, rather than `pendingLimit` plus whatever the reader manages
                    // to add while the view is painting. Unconditional for the same reason `take`
                    // is — a reader left suspended by a stale or deallocated session cannot even
                    // reach its own EOF, and teardown would have to undo the suspend anyway.
                    Self.enqueueResume(session: session, on: queue)
                }
            }
            return admission.hasRoom
        }
    }

    /// The pty said the child side is gone. The exit source carries the status, so all this does
    /// is stop reading; the fd is released with the source, on `ioQueue`.
    private nonisolated func makeEOFHandler(session: Session) -> @Sendable () -> Void {
        { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated { self.stopReading(session: session) }
            }
        }
    }

    /// True while `session` is the child this object is currently running — the guard that keeps a
    /// finished child's late callback from touching its successor.
    private func isCurrent(_ session: Session) -> Bool {
        self.session === session
    }

    private func stopReading(session: Session) {
        guard isCurrent(session) else { return }
        Self.enqueueReadTeardown(session: session, on: ioQueue)
        if writeFd >= 0 {
            Self.enqueueClose(fd: writeFd, on: writeQueue, closed: writeClosed)
            writeFd = -1
        }
    }

    // MARK: - Exit

    private nonisolated static func makeExitHandler(
        session: Session,
        deliver: @escaping Sink,
        finish: @escaping @Sendable (Int32?) -> Void
    ) -> @Sendable () -> Void {
        {
            guard !session.reaped else { return }
            session.reaped = true
            // Everything the child wrote before dying is still sitting in the pty buffer. Drain it
            // here, on the same serial queue the read source uses, so those batches are posted to
            // main *ahead* of the termination callback. Skipped once the read side is done: the
            // descriptor is closed or closing and there is nothing left in it anyway.
            //
            // This is the one drain that ignores the cap, and it has to: `finish` below leads
            // straight to teardown closing `fd`, so whatever is not taken now is lost, and losing
            // the tail of a command's output is the one outcome this whole file rules out. The
            // overshoot is bounded anyway — the child is already dead, so what is left is what the
            // kernel's tty buffer holds (kilobytes), not the file it was cat-ing.
            //
            // Safe while the reader is suspended: `ioQueue` is serial, so no read handler can be
            // running, and `closeRead` resumes before it cancels.
            if !session.readDone {
                if case .finished = drain(fd: session.fd, deliver: deliver, honourBackpressure: false) {
                    closeRead(session)
                }
            }
            // Cancel before reaping: waitpid destroys the proc, and a live NOTE_EXIT knote on a
            // destroyed proc is the EV_VANISHED that makes libdispatch abort the process.
            session.exitSource?.cancel()
            session.exitSource = nil
            finish(reap(session.pid))
        }
    }

    /// Blocking `waitpid` on a child the kernel has already told us is dead.
    /// - Returns: the exit status, or nil if it died of a signal (or was reaped elsewhere).
    private nonisolated static func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, 0)
        } while result < 0 && errno == EINTR
        guard result == pid else { return nil }
        // WIFEXITED / WEXITSTATUS: the macros are not imported into Swift.
        guard status & 0x7f == 0 else { return nil }
        return (status >> 8) & 0xff
    }

    private nonisolated func makeExitDeliverer(session: Session) -> @Sendable (Int32?) -> Void {
        { [weak self] code in
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated { self.finish(session: session, exitCode: code) }
            }
        }
    }

    private func finish(session: Session, exitCode: Int32?) {
        guard isCurrent(session), !terminationDelivered else { return }
        terminationDelivered = true
        running = false
        stopReading(session: session)
        // The exit source has already cancelled and cleared itself on `ioQueue`; the read source
        // is `ioQueue`'s too, and `stopReading` posts the work there rather than reaching in.
        delegate?.processTerminated(self, exitCode: exitCode)
    }

    // MARK: - POSIX helpers, all built off the main actor

    private nonisolated static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    /// Signals the child's whole process group when it has one — `forkpty` calls `setsid`, so the
    /// child leads its own group and a job it started dies with it. Falls back to the child alone.
    private nonisolated static func signal(_ sig: Int32, to pid: pid_t) {
        if killpg(pid, sig) != 0 {
            _ = kill(pid, sig)
        }
    }

    private nonisolated static func scheduleKill(
        session: Session,
        after grace: TimeInterval,
        on queue: DispatchQueue
    ) {
        queue.asyncAfter(deadline: .now() + grace) {
            guard !session.reaped else { return }
            signal(SIGKILL, to: session.pid)
        }
    }

    private nonisolated static func enqueueWrite(
        _ bytes: [UInt8],
        fd: Int32,
        on queue: DispatchQueue,
        closed: Box<Bool>
    ) {
        queue.async {
            guard !closed.value else { return }
            writeAll(fd: fd, bytes: bytes)
        }
    }

    private nonisolated static func enqueueClose(fd: Int32, on queue: DispatchQueue, closed: Box<Bool>) {
        queue.async {
            guard !closed.value else { return }
            closed.value = true
            close(fd)
        }
    }

    private nonisolated static func writeAll(fd: Int32, bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN {
                    // The descriptor is a dup of the non-blocking master; wait for room rather
                    // than spinning. A child that never reads blocks this queue, which is the same
                    // backpressure a real terminal applies.
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&descriptor, 1, 250) < 0 && errno != EINTR { return }
                    continue
                }
                return
            }
        }
    }
}
