import AppKit
import Foundation
import SheepVTRender
import Synchronization

/// Owns one serial console tab: SheepVT view + termios worker.
final class SerialTerminalController: NSObject {
    /// The view, its fading scroller and SafePaste. See SessionTerminalHost.
    let terminalHost = SessionTerminalHost(safePaste: true)
    var terminalView: TerminalView { terminalHost.terminalView }
    private(set) var host: Host

    var onStatus: ((String) -> Void)?
    /// Fired once when the passive stream fingerprint names a device family
    /// for a tab that was still on `.auto`. Serial consoles carry no
    /// protocol-level vendor signal, but a login banner or `display version`
    /// header often does, so the same detector serves them.
    var onVendorDetected: ((Vendor) -> Void)?
    /// Pushed from the main actor and read from worker/highlight queues.
    /// Swift's Mutex expresses shared ownership without unsafe isolation.
    nonisolated private let highlightState = Mutex(false)
    nonisolated var highlightEnabled: Bool {
        get { highlightState.withLock { $0 } }
        set { highlightState.withLock { $0 = newValue } }
    }
    /// Per-session choice from the New Serial form; nil = follow app setting.
    var logOverride: Bool?
    /// Passive family detector. Active only until a vendor is locked in; see
    /// `vendorDetectionActive`.
    private var fingerprint = VendorFingerprint()
    /// Set once the user (or a saved host) has committed a vendor — including
    /// an explicit `.auto`. Passive detection must never override a decision.
    private var vendorChosenByUser = false

    /// Passive detection runs only while highlighting is on, the family in
    /// effect is still Auto (`host.highlightVendor == .auto` — a quick
    /// connect writes a literal `.auto`, a recent may carry nil or `auto`,
    /// and adopting a detected family makes it something else), and the user
    /// has not committed a choice of their own.
    private var vendorDetectionActive: Bool {
        // Effective family, NOT `host.vendor == nil`: adoptVendor(.auto) —
        // which the tab's highlightVendor didSet fires at open() time — sets
        // host.vendor to a non-nil `.auto`, so a nil check disarmed detection
        // before the first byte ever arrived. Detection runs while the family
        // in effect is still Auto and the user has not committed a choice.
        highlightEnabled && !vendorChosenByUser && (host.highlightVendor == .auto || autoDetected)
    }
    /// A family was named by the fingerprint, not by anyone's choice: the
    /// fingerprint keeps running until its budget is spent so a MORE specific
    /// family seen later (the device's own banner after a neighbour table
    /// that mentioned Linux) can replace it. See `VendorFingerprint`.
    private var autoDetected = false

    /// Stops passive detection for good — the vendor is now the user's (or a
    /// saved host's) explicit choice.
    func suppressVendorDetection() { vendorChosenByUser = true }

    /// A reconnect successor takes over a family the FINGERPRINT chose in
    /// the previous session: detection stays on (only a more specific family
    /// can replace it), and the fresh fingerprint is seeded so a generic
    /// signature in the reconnected stream cannot undo the previous lock.
    /// `AppModel.reconnect` opens the successor with `.auto` so `open` does
    /// not read the carried family as a saved choice, then calls this.
    func carryAutoDetected(_ vendor: Vendor) {
        fingerprint.seed(with: vendor)
        autoDetected = true
    }

    private let worker = SerialWorker()
    /// What the last `worker.write` made through `TerminalViewDelegate.send`
    /// answered. That delegate method returns Void and cannot be changed (it
    /// belongs to the terminal package), so Safe Paste's pacer reads the
    /// answer back through `terminalHost.takeLastSendAccepted`, which clears
    /// it. Starting false means "nothing has been accepted yet": a paced line
    /// whose send never reached the delegate must count as refused, not as
    /// carrying the previous line's verdict.
    private var lastWriteAccepted = false
    /// Shared by the main actor and worker callbacks. SessionLogger
    /// serializes file access; this Mutex protects ownership/reconnection.
    nonisolated private let loggerState: Mutex<SessionLogger?>
    nonisolated private var logger: SessionLogger? {
        get { loggerState.withLock { $0 } }
        set { loggerState.withLock { $0 = newValue } }
    }
    /// Set by handOverLogger(): stop()/onClosed must not close the file —
    /// the reconnecting successor keeps appending to it.
    private var loggerHandedOver = false
    /// Regex stripping + a blocking file write per chunk must not run on
    /// the worker's I/O queue — logging gets its own serial queue (serial
    /// so the log order matches arrival order).
    private let logQueue = DispatchQueue(label: "sheepterm.sessionlog")
    /// Bounds what is queued in FRONT of `SessionLogger.append` — the logger
    /// bounds its own write backlog, but every `logQueue.async` closure holds
    /// its own `[UInt8]`, and those used to pile up without limit behind a
    /// blocked append. See "Session hand-off backpressure" in SessionLogger.swift.
    nonisolated private let logGate = PendingBytesGate(limitBytes: 4 * 1024 * 1024)
    /// The same bound for the worker → main-actor hop, plus coalescing: one
    /// drain per burst instead of one `DispatchQueue.main.async` per chunk.
    nonisolated private let mainFeed = MainFeedQueue(limitBytes: 4 * 1024 * 1024)
    /// Rule index → colour for this session's device family. The renderer's
    /// overlay owns the paragraph assembly, the cache and the "never clobber
    /// the device's colour" rule; this only says which bytes are which colour.
    private let highlightProvider: VendorHighlightProvider

    /// The user's per-tab toggle. The overlay is consulted per frame, so
    /// turning it off takes our colour off everything already on screen — no
    /// buffer pass, no stripping of attributes.
    func setHighlightEnabled(_ enabled: Bool) {
        guard enabled != highlightEnabled else { return }
        highlightEnabled = enabled
        terminalView.highlightEnabled = enabled
    }

    /// Live device-family switch. Updates `host` as well, because reconnect —
    /// manual and automatic — rebuilds the session from this snapshot, so
    /// writing only the provider meant a dropped cable silently reverted the
    /// pack the user had just corrected. The overlay drops every cached
    /// paragraph when the provider's revision moves, so what is already on
    /// screen is re-coloured on the next frame.
    func adoptVendor(_ vendor: Vendor) {
        host.vendor = vendor
        highlightProvider.setVendor(vendor)
        terminalView.setNeedsFrame()
    }

    init(host: Host, reusingLogger: SessionLogger? = nil) {
        highlightProvider = VendorHighlightProvider(vendor: host.highlightVendor)
        self.host = host
        // A reconnect keeps appending to the previous session's log file
        // instead of starting a fresh one per attempt.
        loggerState = Mutex(reusingLogger)
        super.init()
        Theme.apply(to: terminalView)
        terminalView.delegate = self
        // Safe Paste asks after every paced line whether the worker took it.
        terminalHost.takeLastSendAccepted = { [weak self] in
            guard let self else { return false }
            defer { self.lastWriteAccepted = false }
            return self.lastWriteAccepted
        }
        terminalView.highlightProvider = highlightProvider
        terminalView.highlightEnabled = highlightEnabled
        // Parking the worker to bound memory also parks `takeWrites()` — the
        // same I/O loop drains queued keystrokes — so a slow log disk shows up
        // as a session that has stopped echoing. Say so, once per episode.
        // This hop is a plain main.async, deliberately NOT through `mainFeed`:
        // the notice must never queue behind the congestion it is reporting.
        logGate.onThrottleChange = { [weak self] throttled in
            DispatchQueue.main.async { self?.reportLogThrottle(throttled) }
        }

        worker.onData = { [weak self] bytes in
            guard let self else { return }
            // The device's bytes go to the terminal untouched; colour is an
            // overlay the renderer applies to the rows it is about to draw,
            // so nothing here has to schedule a paint.
            //
            // Both hand-offs below are byte-bounded: they park THIS thread —
            // the worker's I/O queue, which is where the pressure belongs,
            // since a paused read lets the driver's own buffer and flow
            // control slow the far end — rather than queueing chunks a
            // stalled consumer will never catch up with. See
            // SessionLogger.swift's "Session hand-off backpressure" note for
            // the lock ordering.
            if self.mainFeed.submit(bytes) {
                DispatchQueue.main.async { [weak self] in
                    self?.drainPendingFeed()
                }
            }
            // Logging (regex strip + blocking file write) must not stall
            // the worker's I/O loop — hand it to the log queue.
            let logger = self.logger
            let count = bytes.count
            self.logGate.reserve(count)
            self.logQueue.async { [logGate = self.logGate] in
                logger?.append(bytes)
                logGate.release(count)
            }
        }
        // Notices/status/closed hop via DispatchQueue.main.async — the same
        // queue feed() uses — so everything delivers in FIFO order (Task
        // scheduling does not guarantee it). MainActor isolation comes from
        // the default-actor build setting, so main-actor state is touched
        // directly inside.
        // A refused write means the device did NOT get that line, so a paced
        // paste must stop rather than keep counting.
        worker.onInputDiscarded = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.terminalHost.cancelSafePaste(reason: .inputDiscarded)
            }
        }
        worker.onNotice = { [weak self] message in
            DispatchQueue.main.async {
                self?.printNotice(message)
            }
        }
        worker.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.onStatus?(status)
            }
        }
        worker.onClosed = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.terminalHost.cancelSafePaste(reason: .sessionEnded)
                self.printNotice(message, error: true)
                // A prompt the user dismissed is a decision, not a drop. Plain
                // "disconnected" is what auto-reconnect keys on, and it would
                // put the same prompt straight back up — three times.
                self.onStatus?(message.hasPrefix("connection cancelled")
                               ? "disconnected — cancelled" : "disconnected")
                // The log is NOT closed here. Auto-reconnect hands this
                // logger to the successor 2–10 s from now, and a logger closed
                // in between dropped every byte of the reconnected session
                // while the successor printed "logging continues". stop()
                // (tab close) and beginShutdownForQuit() own the close.
            }
        }
    }

    func start() {
        printNotice("opening \(host.address) at \(host.port) baud…")
        if let logger {
            // A handed-over logger's notices belong to THIS session now — the
            // controller that opened it is on its way out.
            adoptLogNotices(logger)
            printNotice("logging continues to \(logger.url.path)")
        } else if logOverride ?? (UserDefaults.standard.object(forKey: "logSessions") as? Bool ?? true) {
            do {
                let opened = try SessionLogger.open(sessionName: host.name)
                adoptLogNotices(opened)
                logger = opened
                printNotice("logging to \(opened.url.path)")
            } catch {
                // The log used to just not happen: `if let logger` printed on
                // success and the else branch said nothing, so a host name too
                // long for a file name, a read-only logs folder or a file
                // sitting where the folder should be all looked like a normal
                // session. Red, because the session's evidence is missing.
                printNotice("session logging is OFF — could not create a log file: \(error)", error: true)
            }
        }
        worker.start(devicePath: host.address, baudRate: host.port)
    }

    /// Points the logger's own trouble reports at this session's terminal.
    /// The logger discovers a deleted file or a refused write on its I/O
    /// queue, where the only outlet used to be an NSLog nobody sees; this is
    /// the hop to somewhere the user is looking. Plain `main.async` and never
    /// a wait — see `SessionLogger.onProblem`'s contract.
    private func adoptLogNotices(_ logger: SessionLogger) {
        logger.onProblem = { [weak self] message in
            DispatchQueue.main.async { self?.printNotice(message, error: true) }
        }
    }

    /// Transfers the open log to a reconnecting successor: the old worker
    /// stops but the file stays open, so the new session appends to the
    /// same log instead of starting a fresh file per attempt.
    func handOverLogger() -> SessionLogger? {
        loggerHandedOver = true
        return logger
    }

    /// Quit, phase 1 — nothing here blocks, and that is the whole point.
    /// Stops the worker, closes the hand-off gates so nothing new is
    /// admitted, and queues the log close on `logQueue` BEHIND the appends
    /// already sitting there, so the file keeps its arrival order.
    ///
    /// The WAITING is phase 2 and it belongs to the caller:
    /// `AppModel.shutdownSessionsForQuit` starts every tab before it waits
    /// for any of them, so N tabs cost one budget instead of N. Doing both
    /// halves here, per tab, is what made ⌘Q take 17.06 s for ten tabs on a
    /// volume that had stopped completing writes (35.02 s before the bound
    /// existed at all); it is 2.00 s now.
    /// See `QuitLogFlush` for the budget and the whole table.
    ///
    /// Why the close is queued and not called here: an `append` already on
    /// `logQueue` can be parked in `SessionLogger.waitForRoom` for 5 s, and
    /// this queue is the only thing that keeps the log in order. What comes
    /// back is not "the close was started" but a handle that will know
    /// whether it LANDED — see `QuitLogFlush`.
    func beginShutdownForQuit() -> QuitLogFlush {
        worker.stop()
        // Before anything else: a worker thread parked in reserve()/submit()
        // must be free to notice that the session is over, or it would sit out
        // its whole timeout while the main actor waits behind it. Nothing
        // admitted after this point can reach the file — close() marks the
        // logger closed and every later append no-ops.
        logGate.finish()
        mainFeed.finish()
        onStatus = nil
        // The close itself belongs to `QuitLogFlush`: it is the thing that has
        // to know whether the flush landed, so it is the thing that makes the
        // call and keeps the answer. Handing it the queue keeps the ORDER
        // here, where the queue lives.
        return QuitLogFlush(session: host.name, logger: logger, closingOn: logQueue, gate: logGate)
    }

    func stop() {
        terminalHost.cancelSafePaste(reason: .sessionEnded)
        worker.stop()
        // Nothing will drain these once the tab is gone, so stop gating: a
        // worker thread parked in reserve()/submit() has to be free to notice
        // that its session ended. `take()` still hands back whatever is
        // pending, so no byte already accepted is lost.
        logGate.finish()
        mainFeed.finish()
        // Queued behind the final appends for the same reason as onClosed.
        if !loggerHandedOver {
            let logger = self.logger
            logQueue.async { logger?.close() }
        }
        onStatus = nil
    }

    /// The gate holding the worker back is invisible otherwise: output stops,
    /// echo stops, and nothing on screen says why. `PendingBytesGate` calls
    /// this on the edges of a stall episode only — not per chunk — so a long
    /// stall costs exactly two lines.
    private func reportLogThrottle(_ throttled: Bool) {
        printNotice(throttled
            ? "session log is falling behind — the disk is slow, so output and typing are throttled until it catches up; no log data is dropped"
            : "session log caught up — output and typing are no longer throttled")
    }

    /// Feeds everything the worker has coalesced since the last drain. Runs on
    /// the main actor only, so `MainFeedQueue.take()` has a single consumer.
    private func drainPendingFeed() {
        let pending = mainFeed.take()
        guard !pending.isEmpty else { return }
        terminalView.feed(pending)
        // Passive family detection, after the terminal has the bytes.
        // Bounded — see VendorFingerprint. Detection deliberately CONTINUES
        // after an automatic lock (`autoDetected` keeps
        // `vendorDetectionActive` true even though adopting the family moved
        // `host.highlightVendor` off `.auto`), so a more specific family seen
        // later in the same session — the device's own banner after a
        // neighbour table that mentioned Linux — can still replace it. The
        // fingerprint's own byte budget is what ends it; a choice the USER
        // makes ends it immediately via `suppressVendorDetection`.
        if vendorDetectionActive, let detected = fingerprint.consider(pending) {
            autoDetected = true
            printNotice("auto-detected \(detected.label) — highlighting set")
            onVendorDetected?(detected)
        }
    }

    private func printNotice(_ message: String, error: Bool = false) {
        // Coalescing decoupled "when a chunk arrived" from "when it is fed":
        // a drain scheduled before this notice would otherwise paint device
        // bytes that arrived AFTER it, putting the notice in the wrong place.
        // Flushing first restores the exact arrival order the per-chunk
        // main.async hop used to give for free. Re-entrant via the vendor
        // notice above, and safe — the second take() finds nothing.
        drainPendingFeed()
        let color = error ? "\u{1b}[91m" : "\u{1b}[90m"
        terminalView.feed("\r\n\(color)\(message)\u{1b}[0m\r\n")
    }
}

extension SerialTerminalController: TerminalViewDelegate {
    // The view calls every one of these on the main actor, from inside its own
    // event handling — no nonisolated hops, no assumeIsolated.

    func send(_ view: TerminalView, bytes: [UInt8]) {
        // A refused write means the worker took nothing: keep the answer so
        // a paced paste can end on it instead of counting the line as sent.
        lastWriteAccepted = worker.write(bytes)
    }

    /// Only a real keystroke cancels a running Safe Paste — a DA/DSR reply
    /// or a mouse report also travels through `send` and used to abort it.
    func userTyped(_ view: TerminalView) {
        terminalHost.prepareForOrdinaryUserInput()
    }

    /// A serial line has no window-size channel; the grid is ours alone.
    func sizeChanged(_ view: TerminalView, cols: Int, rows: Int) {}

    /// The overlay repaints from the rows the renderer is about to draw, so
    /// scrolling back needs nothing from here — 2.x had to paint from this
    /// hook or most of the scrollback stayed permanently plain.
    func scrolled(_ view: TerminalView) {}

    func bell(_ view: TerminalView) {
        NSSound.beep()
    }

    /// The device replaced the Mac's clipboard (OSC 52). Said out loud because
    /// nothing else on screen changes when it happens, and what is now on the
    /// clipboard will be pasted somewhere else entirely — a payload ending in a
    /// newline runs itself in the next terminal it lands in.
    func clipboardWritten(_ view: TerminalView, bytes: Int) {
        if bytes < 0 {
            printNotice("the device tried to replace the clipboard with \(-bytes) bytes — refused, that is far more than a copy")
        } else {
            printNotice("the device replaced the clipboard (\(bytes) bytes)")
        }
    }

    func openLink(_ view: TerminalView, url: String) {
        // ⌘-click on an OSC 8 hyperlink. Web links only: a device is free to
        // emit any scheme it likes, and handing those to the system opener is
        // handing it a command line.
        guard let link = URL(string: url), let scheme = link.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        NSWorkspace.shared.open(link)
    }

    func shouldPaste(_ view: TerminalView, text: String) -> Bool {
        terminalHost.shouldPaste(text)
    }
}
