import AppKit
import Foundation
import SheepVTRender
import Synchronization

/// Owns one console tab: SheepVT view + the line under it — a termios port
/// (`SerialWorker`) or, for a `.telnet` host, a telnet socket
/// (`TelnetWorker`). Both are a plain byte pipe, so everything above the
/// worker (log, highlight, paging, prompt name, Safe Paste, Confirm
/// Dangerous Commands) is one code path; line speed and XMODEM are the
/// cable's alone.
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

    // MARK: prompt name (5.0 (1)) — see PromptName.swift
    /// Fired once when the device's prompt names a session that was called
    /// after its cable or bare address. AppModel retitles the tab.
    var onPromptName: ((String) -> Void)?
    /// Passive, one-shot, bounded; nil detector (zero cost) for a session
    /// with a real name, a carried name, or once it has decided.
    private lazy var promptNaming = PromptNaming(
        applies: PromptName.applies(name: host.name, address: host.address, kind: host.kind))
    /// The name the prompt gave this session, if any.
    var learnedPromptName: String? { promptNaming.learned }
    /// A reconnect successor keeps the name its tab learned: no rescan, and a
    /// NEW log (none was handed over) starts under that name.
    func carryPromptName(_ name: String) { promptNaming.carry(name) }
    /// What the log file and the quit report call this session.
    private var sessionName: String { promptNaming.sessionName(original: host.name) }

    /// After the terminal has the bytes, like the vendor fingerprint. Never
    /// sends anything. On a lock the OPEN log is renamed in place (the
    /// logger orders that with its own writes; a refusal keeps the old name).
    private func considerPromptName(_ bytes: [UInt8]) {
        guard promptNaming.scanning, let name = promptNaming.consume(bytes) else { return }
        logger?.rename(toSessionName: PromptName.title(learned: name, original: host.name))
        onPromptName?(name)
    }

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

    /// The line, whichever kind it is.
    private let worker: any ConsoleWorker
    /// The same object when the line is a cable: speed and XMODEM.
    private let serialWorker: SerialWorker?
    /// The same object when the line is a telnet socket: window size.
    private let telnetWorker: TelnetWorker?
    var isTelnet: Bool { telnetWorker != nil }
    /// A telnet server that will not echo: typed text is drawn here.
    private var telnetLocalEcho = false
    private lazy var resizes = ResizeCoalescer { [weak self] cols, rows in self?.telnetWorker?.resize(cols: cols, rows: rows) }
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
        if host.kind == .telnet {
            let telnet = TelnetWorker()
            worker = telnet
            telnetWorker = telnet
            serialWorker = nil
        } else {
            let serial = SerialWorker()
            worker = serial
            serialWorker = serial
            telnetWorker = nil
        }
        super.init()
        Theme.apply(to: terminalView)
        terminalView.delegate = self
        terminalHost.guardVendor = { [weak self] in self?.host.highlightVendor ?? .auto }
        terminalHost.lineBusy = { [weak self] in self?.worker.isTransferring ?? false }
        // A Safe Paste paced run takes the top-right corner: the wrong-speed
        // hint goes and the stream is judged afresh after the run.
        terminalHost.onPacedRunStart = { [weak self] in self?.baudGuess.reset() }
        // Safe Paste times its line delay from here: bytes still in the
        // worker (or the tty's output queue / telnet's socket outbox) = not yet.
        terminalHost.lineDrained = { [weak self] in !(self?.worker.hasUnsentWrites ?? false) }
        // ...and caps that wait by the line's speed (telnet: unknown, flat cap).
        terminalHost.lineBaud = { [weak self] in
            guard let self, !self.isTelnet else { return nil }
            return self.host.port
        }
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
        telnetWorker?.onLocalEcho = { [weak self] on in
            DispatchQueue.main.async {
                guard let self, self.telnetLocalEcho != on else { return }
                self.telnetLocalEcho = on
                self.printNotice(on ? "the server does not echo — echoing typed text locally"
                                    : "the server echoes again — local echo off")
            }
        }
        serialWorker?.onBaudChanged = { [weak self] baud in
            DispatchQueue.main.async {
                guard let self else { return }
                self.baudGuessRestart(leaving: self.host.port)
                // Reconnect (manual or automatic) opens `host`: it keeps the
                // speed that worked. The saved host is not touched.
                self.host.port = baud
                self.printNotice("speed set to \(baud) baud")
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
                self.terminalHost.hideBaudHint()
                self.printNotice(message, error: true)
                // A prompt the user dismissed is a decision, not a drop. Plain
                // "disconnected" is what auto-reconnect keys on, and it would
                // put the same prompt straight back up — three times.
                // A telnet session the far end ended (`exit`, exec-timeout)
                // is over, not dropped — SSH's rule (4.1 (36)): no reconnect.
                self.onStatus?(message.hasPrefix("connection cancelled") ? "disconnected — cancelled"
                               : message.hasPrefix(SSHWorker.sessionEndedPrefix) ? "disconnected — session ended"
                               : "disconnected")
                // The log is NOT closed here. Auto-reconnect hands this
                // logger to the successor 2–10 s from now, and a logger closed
                // in between dropped every byte of the reconnected session
                // while the successor printed "logging continues". stop()
                // (tab close) and beginShutdownForQuit() own the close.
            }
        }
    }

    func start() {
        if let telnetWorker {
            startTelnet(telnetWorker)
            return
        }
        // A console that names itself (an Aruba CX USB-C port) says so, and
        // says when the speed asked for is not the one it runs at.
        let known = ConsoleBaud.known(SerialWatcher.usbDevice(at: host.address))
        if let known, known.baud == host.port {
            printNotice("opening \(host.address) at \(host.port) baud (\(known.label))…")
        } else {
            printNotice("opening \(host.address) at \(host.port) baud…")
            if let known {
                printNotice("this port is an \(known.label), which runs at \(known.baud) baud — click the speed in the status bar to change it")
            }
        }
        openLogIfWanted()
        serialWorker?.start(devicePath: host.address, baudRate: host.port)
    }

    private func openLogIfWanted() {
        if let logger {
            // A handed-over logger's notices belong to THIS session now — the
            // controller that opened it is on its way out.
            adoptLogNotices(logger)
            printNotice("logging continues to \(logger.url.path)")
        } else if Host.shouldLogSession(host: host, global: UserDefaults.standard.object(forKey: "logSessions") as? Bool ?? true, override: logOverride) {
            do {
                let opened = try SessionLogger.open(sessionName: sessionName)
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
    }

    private func startTelnet(_ telnet: TelnetWorker) {
        printNotice("connecting to \(host.address) port \(host.port) (telnet — not encrypted)…")
        openLogIfWanted()
        telnet.start(host: host.address, port: host.port, cols: terminalView.cols, rows: terminalView.rows)
    }

    /// Per-session `--More--` detector; see `PagerDetector`.
    private var pager = PagerDetector()

    /// Auto-page on a console: same as SSH. "Disable paging on connect" is
    /// SSH-only on purpose — a console may be sitting at a login prompt or
    /// a boot loader, where typing a command blind is wrong.
    private func answerPagerIfNeeded(_ chunk: [UInt8]) {
        guard AppModel.shared.autoPage, pager.consume(chunk) else { return }
        worker.write([0x20])
    }

    /// Send Break (⌃⌥B): a break condition on the line, for a boot loader
    /// that wants one. The worker reports "break sent" through `onNotice`
    /// when the driver accepted it; here only the refusal is worth a line.
    func sendBreak() {
        if !worker.sendBreak() {
            printNotice(worker.isTransferring ? "a file transfer is running — break not sent"
                                              : "no session — break not sent", error: true)
        }
    }

    // MARK: - Line speed (5.0 (39))

    /// The status bar's baud menu. A live port changes speed in place
    /// (`onBaudChanged` confirms it); a closed one keeps the choice for the
    /// next connect (Reconnect).
    func setBaud(_ baud: Int) {
        guard let serialWorker, baud != host.port, Host.serialBaudRange.contains(baud) else { return }
        if serialWorker.setBaud(baud) { return }
        if worker.isTransferring {
            printNotice("a file transfer is running — speed not changed", error: true)
        } else {
            baudGuessRestart(leaving: host.port)
            host.port = baud
            printNotice("the next connection opens at \(baud) baud")
        }
    }

    // MARK: - Wrong-speed hint (6.0 (12)) — ConsoleBaudGuess

    /// AppModel's `setBaud(_:for:)` — the status bar menu's own path, so the
    /// hint's Try changes the speed exactly as the menu does (port changed in
    /// place, recent moved, the saved host untouched).
    var onTryBaud: ((Int) -> Void)?
    /// Passive: reads what the port RECEIVES; never sends a byte.
    private var baudGuess = ConsoleBaudGuess.Detector()
    /// Speeds this tab session has left (by the hint or the menu): not
    /// offered again.
    private var triedBauds: Set<Int> = []
    /// × on the hint: no more hints in this tab session.
    private var baudHintDismissed = false

    /// A cable only (never telnet), and never once dismissed. Never while
    /// the line is busy — XMODEM (the device's ACK/NAK are not text) or a
    /// Safe Paste paced run: both put their progress in the top-right corner
    /// the hint uses, so a hint already up goes away and the stream is judged
    /// afresh once the run is over (`Detector.feed`). A saved host's speed is
    /// offered a change too: a saved speed can be wrong, and Try leaves the
    /// saved host as it is, like the menu.
    private func considerBaudGuess(_ bytes: [UInt8]) {
        let lineBusy = ConsoleBaudGuess.lineBusy(transferring: worker.isTransferring, pacingPaste: terminalHost.isPacingPaste,
                                                 statusHUDShown: terminalHost.hasStatusHUD)
        if lineBusy { terminalHost.hideBaudHint() }
        guard serialWorker != nil, !baudHintDismissed,
              !terminalHost.hasBaudHint, baudGuess.feed(bytes, lineBusy: lineBusy),
              let rate = ConsoleBaudGuess.suggestion(current: host.port, tried: triedBauds) else { return }
        terminalHost.showBaudHint(rate: rate, onTry: { [weak self] in
            guard let self else { return }
            self.terminalHost.hideBaudHint()
            self.onTryBaud?(rate)
        }, onDismiss: { [weak self] in
            self?.baudHintDismissed = true
            self?.terminalHost.hideBaudHint()
        })
    }

    /// The speed moved off `old` (the hint's Try or the menu): `old` is
    /// tried, and the stream is judged afresh at the new one.
    private func baudGuessRestart(leaving old: Int) {
        triedBauds.insert(old)
        baudGuess.reset()
        terminalHost.hideBaudHint()
    }

    // MARK: - Send File via XMODEM (5.0 (22))

    /// Bigger than any bootloader or switch image; at 115200 baud this is
    /// already ~6 hours of line, and the whole file is held in memory.
    static let maxTransferBytes = 256 * 1024 * 1024

    var isTransferring: Bool { worker.isTransferring }

    /// Sends `url` to the device, which must already be waiting for it
    /// (ROMMON `xmodem -c flash:x.bin`, a BootROM's download menu). The
    /// terminal shows a line at the start and the end; the HUD shows the
    /// progress and Stop (the protocol's abort, CAN).
    func sendFile(_ url: URL, mode: XModemSender.Mode) {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxTransferBytes else {
            printNotice("\(name) is larger than \(Self.maxTransferBytes / 1_048_576) MB — not sent", error: true)
            return
        }
        let data: [UInt8]
        do {
            data = [UInt8](try Data(contentsOf: url, options: .mappedIfSafe))
        } catch {
            printNotice("cannot read \(name): \(error.localizedDescription)", error: true)
            return
        }
        let label = Self.modeLabel(mode)
        let started = Date()
        let job = SerialWorker.Transfer(
            data: data, fileName: name, mode: mode,
            onProgress: { [weak self] done, total in
                DispatchQueue.main.async { self?.showTransferProgress(label: label, done: done, total: total, started: started) }
            },
            onFinish: { [weak self] phase in
                DispatchQueue.main.async {
                    self?.transferEnded(phase, label: label, name: name, total: data.count, started: started)
                }
            })
        // A paste still on its way — paced lines to come, or bytes the
        // worker took and has not written — is never cut off by the file:
        // refused, nothing lost (it used to be stopped and its queued bytes
        // dropped without a word). The worker checks the queue again itself.
        let pasteNotice = "the paste is still being sent — wait for it, then send the file"
        guard !worker.isTransferring, !terminalHost.isPacingPaste, !worker.hasQueuedWrites else {
            printNotice(worker.isTransferring ? "a transfer is already running" : pasteNotice, error: true)
            return
        }
        // A dangerous-command question still up: its Send could only be
        // refused once the line is the file's.
        terminalHost.cancelCommandGuard()
        guard worker.startTransfer(job) else {
            printNotice(worker.isTransferring ? "a transfer is already running"
                        : worker.hasQueuedWrites ? pasteNotice : "no serial session — nothing sent", error: true)
            return
        }
        // The corner is the transfer's; the stream is judged afresh after it.
        terminalHost.hideBaudHint()
        baudGuess.reset()
        printNotice("\(label): \(name) (\(Self.sizeText(data.count))) — waiting for the device to ask for it…")
        if isTelnet {
            printNotice("over telnet: binary mode was asked for — a console server that refuses it will corrupt the file")
        }
        showTransferProgress(label: label, done: 0, total: data.count, started: started)
    }

    private func showTransferProgress(label: String, done: Int, total: Int, started: Date) {
        guard worker.isTransferring else { return }
        let text: String
        if done == 0 {
            text = String(localized: "\(label) · waiting for the device")
        } else {
            let percent = total > 0 ? done * 100 / total : 100
            let rate = Double(done) / max(Date().timeIntervalSince(started), 0.001)
            text = "\(label) \(percent)% · \(Self.sizeText(Int(rate)))/s"
        }
        terminalHost.showStatusHUD(text, stopHelp: String(localized: "Stop the transfer (the device gets the abort)")) { [weak self] in
            self?.worker.cancelTransfer()
        }
    }

    private func transferEnded(_ phase: XModemSender.Phase, label: String, name: String, total: Int, started: Date) {
        terminalHost.hideStatusHUD()
        // The protocol's bytes are behind it: judge the text afresh.
        baudGuess.reset()
        let seconds = Int(Date().timeIntervalSince(started).rounded())
        let elapsed = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
        switch phase {
        case .done:
            printNotice("\(label): \(name) sent — \(Self.sizeText(total)) in \(elapsed)")
        case .failed(let failure):
            printNotice("\(label): \(name) not sent — \(Self.failureText(failure))", error: true)
        default:
            break
        }
    }

    static func modeLabel(_ mode: XModemSender.Mode) -> String {
        switch mode {
        case .xmodem: return "XMODEM"
        case .xmodem1K: return "XMODEM-1K"
        case .ymodem: return "YMODEM"
        }
    }

    static func failureText(_ failure: XModemSender.Failure) -> String {
        switch failure {
        case .noReceiver: return "the device never asked for it (start the receive on the device first)"
        case .receiverCancelled: return "the device cancelled the transfer"
        case .tooManyRetries(let block): return "block \(block) was refused \(XModemSender.maxAttempts) times"
        case .eotNotAcknowledged: return "the device did not confirm the end of the file"
        case .cancelledByUser: return "stopped"
        case .sessionEnded: return "the session ended"
        }
    }

    private static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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
        return QuitLogFlush(session: sessionName, logger: logger, closingOn: logQueue, gate: logGate)
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
        answerPagerIfNeeded(pending)
        considerPromptName(pending)
        considerBaudGuess(pending)
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

    /// Split panes: the pane the keyboard went to is the selected session.
    func focusChanged(_ view: TerminalView, focused: Bool) {
        guard focused else { return }
        AppModel.shared.noteFocus(view: view)
        terminalHost.terminalTookKeyboardForGuard()
    }

    func send(_ view: TerminalView, bytes: [UInt8]) {
        // Every early return below = not taken; a stale true from an earlier
        // keystroke must not answer `takeLastSendAccepted` for these bytes.
        lastWriteAccepted = false
        // The line is the file's while a transfer runs.
        if worker.isTransferring {
            terminalHost.discardPendingKeystroke()
            NSSound.beep()
            return
        }
        // A typed Return on a dangerous command is held for the user's
        // answer (Confirm Dangerous Commands) — and the keys behind it.
        guard terminalHost.admitOutgoing(bytes) else { return }
        // A refused write means the worker took nothing: keep the answer so
        // a paced paste can end on it instead of counting the line as sent.
        lastWriteAccepted = worker.write(bytes)
        terminalHost.noteOutgoing(bytes)
        if telnetLocalEcho, lastWriteAccepted {
            let echo = TelnetProtocol.localEcho(bytes)
            if !echo.isEmpty { terminalView.feed(echo) }
        }
    }

    /// Only a real keystroke cancels a running Safe Paste — a DA/DSR reply
    /// or a mouse report also travels through `send` and used to abort it.
    func userTyped(_ view: TerminalView) {
        terminalHost.prepareForOrdinaryUserInput()
    }

    /// A serial line has no window-size channel; telnet has NAWS, coalesced
    /// like SSH's window-change (a drag must not redraw the prompt 12 times).
    func sizeChanged(_ view: TerminalView, cols: Int, rows: Int) {
        if isTelnet { resizes.changed(cols: cols, rows: rows) }
    }

    /// The overlay repaints from the rows the renderer is about to draw, so
    /// scrolling back needs nothing from here — 2.x had to paint from this
    /// hook or most of the scrollback stayed permanently plain.
    func scrolled(_ view: TerminalView) {}

    func bell(_ view: TerminalView) {
        NSSound.beep()
    }

    /// OSC 52: only when the user turned it on in Settings → Clipboard.
    func allowsClipboardWrite(_ view: TerminalView) -> Bool {
        SessionTerminalHost.clipboardWriteAllowed
    }

    /// Said out loud because nothing else on screen changes when the device
    /// sets (or is refused) the clipboard; the host records a write so the
    /// next paste of that text asks first.
    func clipboardWrite(_ view: TerminalView, outcome: ClipboardWriteOutcome) {
        if let notice = terminalHost.clipboardWriteNotice(outcome, source: "device") {
            printNotice(notice)
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
