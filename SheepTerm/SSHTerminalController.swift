import AppKit
import Foundation
import SheepVTRender
import SheepJump
import SheepSSH
import Synchronization

/// Owns one SSH session tab: the SheepVT view plus the SSH worker.
final class SSHTerminalController: NSObject {
    /// The view, its fading scroller and SafePaste. See SessionTerminalHost.
    let terminalHost = SessionTerminalHost(safePaste: true)
    /// The device hears the new size once it settles (`ResizeCoalescer`).
    private lazy var resizes = ResizeCoalescer { [weak self] cols, rows in self?.worker.resize(cols: cols, rows: rows) }
    var terminalView: TerminalView { terminalHost.terminalView }
    private(set) var host: Host
    /// Set by `stop()` (tab closed): no prompt may appear for a tab that is gone.
    private var stopped = false

    var onTitleChange: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    /// The session's forwards, whenever they change (`SessionTab.forwards`).
    var onForwards: (([ForwardState]) -> Void)?
    /// Fired once when the passive stream fingerprint names a device family
    /// for a tab that was still on `.auto`. AppModel routes it to the tab's
    /// highlightVendor via the auto path (never marking it a manual choice).
    var onVendorDetected: ((Vendor) -> Void)?
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
    /// Pushed from the main actor and read from worker/highlight queues.
    /// Swift's Mutex expresses shared ownership without unsafe isolation.
    nonisolated private let highlightState = Mutex(false)
    nonisolated var highlightEnabled: Bool {
        get { highlightState.withLock { $0 } }
        set { highlightState.withLock { $0 = newValue } }
    }

    private let worker = SSHWorker()

    /// A Files tab's way onto this tab's connection (nil unless it is up).
    func openChannelBridge() -> SSHChannelBridge? { worker.openChannelBridge() }
    var canLendConnection: Bool { worker.isInteractive }
    /// What the last `worker.write` made through `TerminalViewDelegate.send`
    /// answered. That delegate method returns Void and cannot be changed (it
    /// belongs to the terminal package), so Safe Paste's pacer reads the
    /// answer back through `terminalHost.takeLastSendAccepted`, which clears
    /// it. Starting false means "nothing has been accepted yet": a paced line
    /// whose send never reached the delegate must count as refused, not as
    /// carrying the previous line's verdict.
    private var lastWriteAccepted = false
    /// The password the session starts with (a saved credential or the
    /// session cache); handed to the worker once and not kept after that.
    private var password: String?
    /// The failure card's Try Again: AppModel reconnects this tab from the
    /// start. The argument names the login the server refused (its password
    /// is asked again, never reused), nil for a failure of another kind.
    var onTryAgain: ((RefusedLogin?) -> Void)?
    /// The password this session was started with was refused (once per
    /// login): AppModel drops it from its session cache. Never the password.
    var onConfiguredPasswordRefused: ((RefusedLogin) -> Void)?
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
    /// Set when password/keyboard-interactive auth succeeded — AppModel
    /// uses it to note the recent-host entry exactly once per connect
    /// (password path notes it via rememberSessionPassword; key-only auth
    /// is noted when the status first reaches "ssh2").
    private(set) var didAuthenticateWithPassword = false
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

    /// The bastion to go through, resolved by `AppModel.open` from the
    /// host's `jumpHostID`; `jumpUnresolved` = the id names a host that no
    /// longer exists, which is reported instead of connecting directly.
    private let jump: JumpHop?
    private let jumpUnresolved: Bool

    init(host: Host, password: String?, jump: JumpHop? = nil, jumpUnresolved: Bool = false,
         reusingLogger: SessionLogger? = nil) {
        highlightProvider = VendorHighlightProvider(vendor: host.highlightVendor)
        self.host = host
        self.password = password
        self.jump = jump
        self.jumpUnresolved = jumpUnresolved
        let address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        hostLabel = host.port == 22 ? address : address.contains(":") ? "[\(address)]:\(host.port)" : "\(address):\(host.port)"
        jumpLabel = jump?.label
        // A reconnect keeps appending to the previous session's log file
        // instead of starting a fresh one per attempt.
        loggerState = Mutex(reusingLogger)
        super.init()
        Theme.apply(to: terminalView)
        terminalView.delegate = self
        terminalHost.guardVendor = { [weak self] in self?.host.highlightVendor ?? .auto }
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
            // the worker's I/O queue, which is exactly where we want the
            // pressure, since a stalled read loop lets SSH's own window slow
            // the device — rather than queueing chunks a stalled consumer
            // will never catch up with. See SessionLogger.swift's
            // "Session hand-off backpressure" note for the lock ordering.
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
        worker.onForwards = { [weak self] status in
            let states = status.map { ForwardState(spec: PortForwardSpec($0.rule), active: $0.active, connections: $0.connections) }
            DispatchQueue.main.async { self?.onForwards?(states) }
        }
        worker.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.onStatus?(status)
                // "ssh2 · …" is sent once, after the shell was granted — the
                // first moment a command can go to the device.
                if status.hasPrefix("ssh2") {
                    // The shell is up: the connection card's job is done.
                    self.cancelPendingProgress()
                    self.terminalHost.closeConnectionCard()
                    self.disablePagingIfAsked()
                }
            }
        }
        worker.onClosed = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.terminalHost.cancelSafePaste(reason: .sessionEnded)
                // Nothing can be waiting on a card once the session closed.
                self.cancelPrompt()
                // Close on the card already said "cancelled" and set the
                // status; whatever the stopped worker reports after it is noise.
                // A cancelled session never wants a card — not even one a racing question put back up.
                guard !self.connectCancelledByUser else {
                    self.cancelPendingProgress()
                    self.terminalHost.closeConnectionCard()
                    return
                }
                self.printNotice(message, error: true)
                // A prompt the user dismissed is a decision, not a drop. Plain
                // "disconnected" is what auto-reconnect keys on, and it would
                // put the same prompt straight back up — three times.
                // …and so is a refused host key (CHANGED / other type /
                // unreadable known_hosts): retrying re-raises the MITM
                // warning up to three times and never gets anywhere.
                let status: String
                if message.hasPrefix("connection cancelled") {
                    status = "disconnected — cancelled"
                } else if message.hasPrefix(SSHWorker.hostKeyRefusedPrefix) {
                    status = "disconnected — host key refused"
                } else if message.hasPrefix(SSHWorker.sessionEndedPrefix) {
                    // `exit` / logout / the device's idle timeout: the session
                    // ended on purpose — not a drop to reconnect.
                    status = "disconnected — session ended"
                } else {
                    status = "disconnected"
                }
                self.onStatus?(status)
                // A pinned key that no longer matches (or a revoked one):
                // offer the way out — File → Known Hosts…, pre-filtered.
                // Nothing is deleted here; the user decides in the sheet.
                let conflict = SSHWorker.knownHostsConflict(message)
                if message.hasPrefix("connection cancelled") {
                    // The user's own Close / Escape: nothing to report.
                    self.cancelPendingProgress()
                    self.terminalHost.closeConnectionCard()
                } else if self.terminalHost.hasConnectionCard {
                    // Still connecting: the card turns into the failure, red,
                    // at the stage it got to (with Open Known Hosts… for a
                    // pin that no longer matches — instead of the sheet).
                    self.showFailure(message, conflict: conflict)
                } else if let conflict {
                    self.offerKnownHosts(conflict)
                }
                // The log is NOT closed here. Auto-reconnect hands this
                // logger to the successor 2–10 s from now, and a logger closed
                // in between dropped every byte of the reconnected session
                // while the successor printed "logging continues". stop()
                // (tab close) and beginShutdownForQuit() own the close.
            }
        }
        // Every question the worker asks — first-seen host key, username,
        // password, challenge — is a card inside this tab (4.2 (9)), never a
        // modal panel. See `askInTab`. The host-key prompt must stay wired:
        // nil there refuses every new host.
        worker.hostKeyPrompt = { [weak self] question, isCancelled in
            guard let self else { return .stopped }
            return self.askHostKeyInTab(question, isCancelled: isCancelled)
        }
        // `rejected`: the server refused the last answer and allows another
        // on this same connection — the same Password page comes back, its
        // field empty, "Wrong password" under it (5.0 (19)).
        worker.passwordPrompt = { [weak self] prompt, rejected in
            self?.askInTab(prompt, rejected: rejected) { host, _ in
                // "Password for user@host" — the account is what the card names.
                let account = prompt.hasPrefix("Password for ") ? String(prompt.dropFirst(13)) : host
                return .password(account: SSHWorker.printable(account))
            }
        }
        worker.challengePrompt = { [weak self] prompt, secure, rejected in
            self?.askInTab(prompt, rejected: rejected) { _, _ in .challenge(text: SSHWorker.printable(prompt), secure: secure) }
        }
        worker.onConfiguredPasswordRefused = { [weak self] side in
            DispatchQueue.main.async { self?.onConfiguredPasswordRefused?(side) }
        }
        worker.onPasswordWorked = { [weak self] user, password in
            DispatchQueue.main.async {
                guard let self else { return }
                self.didAuthenticateWithPassword = true
                self.host.username = user
                AppModel.shared.rememberSessionPassword(password, forUser: user, host: self.host)
            }
        }
        worker.onJumpPasswordWorked = { [weak self] user, password in
            DispatchQueue.main.async {
                guard let self, let jump = self.jump else { return }
                // The bastion's login goes under the bastion's own key — and
                // nowhere near this tab's host, username or recents.
                AppModel.shared.rememberJumpPassword(password, forUser: user, address: jump.host, port: jump.port)
            }
        }
        worker.usernamePrompt = { [weak self] prompt in
            self?.askInTab(prompt) { _, _ in .username }
        }
        // Reconnect rebuilds the session from `host`, so a username typed at
        // the prompt has to land there whatever auth method follows.
        worker.onUsernameResolved = { [weak self] user in
            DispatchQueue.main.async { self?.host.username = user }
        }
    }

    // MARK: - connection prompts (4.2 (9))

    /// Who a question from the worker is about, as the card names it: the
    /// jump host while the worker is logging into it, else this tab's host.
    nonisolated private func promptSubject() -> (host: String, viaJump: Bool, tabHost: String) {
        let tabHost = SSHWorker.printable(hostLabel)
        if worker.isAskingForJumpHost, let jump = jumpLabel {
            return (SSHWorker.printable(jump), true, tabHost)
        }
        return (tabHost, false, tabHost)
    }
    /// "address" or "address:port" — fixed at init, read from the worker queue.
    nonisolated private let hostLabel: String
    nonisolated private let jumpLabel: String?

    /// A text question (username, password, challenge) from the worker queue,
    /// answered by a card in this tab. The worker blocks here; the main
    /// thread never does: the card is put up with `main.async` and the
    /// answer comes back through a `PromptBridge`. A stopped worker (tab
    /// closed, quit) frees the wait even if no card ever answered.
    nonisolated private func askInTab(_ text: String, rejected: Bool = false,
                                      step: (_ host: String, _ viaJump: Bool) -> ConnectionPrompt.Step) -> String? {
        let subject = promptSubject()
        let prompt = ConnectionPrompt(step: step(subject.host, subject.viaJump), host: subject.host,
                                      viaJump: subject.viaJump, tabHost: subject.tabHost, fallbackText: text,
                                      rejected: rejected)
        // Never on main (the worker has its own queue). If it ever were, the
        // card could not be answered while main blocks — fall back to the
        // old panel rather than deadlock.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { AuthPrompt.ask(prompt: text, secure: prompt.isSecure) }
        }
        let worker = self.worker
        return PromptBridge<String>.ask(isCancelled: { !worker.isRunning }) { bridge in
            DispatchQueue.main.async { [weak self] in
                // A question that arrives after the user cancelled (the reply raced the Cancel click) must not put a card
                // back up for a stopped worker — nothing would ever take it down.
                guard let self, ConnectionCardPlan.acceptsQuestion(stopped: self.stopped, cancelledByUser: self.connectCancelledByUser) else {
                    bridge.answer(nil); return
                }
                self.cancelPendingProgress()
                self.terminalHost.presentPrompt(prompt, header: self.cardHeader,
                                                onCancelAfterAnswer: { [weak self] in self?.cancelConnecting() }) { [weak self] reply in
                    guard case .text(let value) = reply else { bridge.answer(nil); return }
                    bridge.answer(value)
                    self?.showProgress(after: prompt)
                }
#if DEBUG
                // Screenshot runs only (compiled out of Release): see `debugAnswers`.
                if case .password = prompt.step, let scripted = Self.nextDebugAnswer() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        if bridge.answer(scripted) { self?.showProgress(after: prompt) }
                    }
                }
#endif
            }
        }
    }

#if DEBUG
    /// Debug builds only, for screenshots without touching the screen:
    /// SHEEPTERM_DEBUG_PASSWORD_ANSWERS="a,b" answers the first password
    /// questions as if typed (the card shows each one first);
    /// SHEEPTERM_DEBUG_HOSTKEY=once answers a first-seen key with Connect Once.
    nonisolated private static let debugAnswers = Mutex<[String]>(
        (ProcessInfo.processInfo.environment["SHEEPTERM_DEBUG_PASSWORD_ANSWERS"] ?? "")
            .split(separator: ",").map(String.init))
    nonisolated private static func nextDebugAnswer() -> String? {
        debugAnswers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
#endif

    /// The first-seen host key, the same way. Escape / Cancel → `.cancel`
    /// (the worker closes with "connection cancelled — host key not
    /// trusted…"); a stopped session → `.stopped`, whatever the card said.
    nonisolated private func askHostKeyInTab(_ question: SSHWorker.HostKeyQuestion,
                                             isCancelled: @escaping @Sendable () -> Bool) -> SSHWorker.HostKeyAnswer {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { AuthPrompt.confirmHostKey(question, isCancelled: isCancelled) }
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["SHEEPTERM_DEBUG_HOSTKEY"] == "once" { return .trustOnce }
#endif
        let subject = promptSubject()
        // Everything shown went through the worker's sanitizer: the host is
        // the user's, but the key type is the server's.
        let shown = SSHWorker.HostKeyQuestion(host: SSHWorker.printable(question.host), port: question.port,
                                              keyType: SSHWorker.printable(question.keyType),
                                              fingerprint: SSHWorker.printable(question.fingerprint),
                                              conflict: question.conflict)
        let prompt = ConnectionPrompt(step: .hostKey(shown), host: subject.host, viaJump: subject.viaJump,
                                      tabHost: subject.tabHost, fallbackText: question.target)
        return PromptBridge<SSHWorker.HostKeyAnswer>.askHostKey(isCancelled: isCancelled) { bridge in
            DispatchQueue.main.async { [weak self] in
                guard let self, ConnectionCardPlan.acceptsQuestion(stopped: self.stopped, cancelledByUser: self.connectCancelledByUser) else {
                    bridge.answer(nil); return
                }
                self.cancelPendingProgress()
                self.terminalHost.presentPrompt(prompt, header: self.cardHeader) { [weak self] reply in
                    switch reply {
                    case .trust: bridge.answer(.trust)
                    case .trustOnce: bridge.answer(.trustOnce)
                    case .text, .cancel: bridge.answer(.cancel); return
                    }
                    self?.showProgress(after: prompt)
                }
            }
        }
    }

    /// Settles a question still on screen (its worker gets nil / cancel).
    private func cancelPrompt() {
        terminalHost.dismissPrompt()
    }

    // MARK: - connection card (4.2 (9))

    /// Set by the card's Close while connecting: the worker was stopped on
    /// the user's word, and what it reports afterwards is not news.
    private var connectCancelledByUser = false

    /// The session's title and "SSH address:port" for the card.
    private var cardHeader: ConnectionCardHeader {
        let address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = SSHWorker.printable(name.isEmpty ? address : name)
        let endpoint = address.contains(":") ? "[\(address)]:\(host.port)" : "\(address):\(host.port)"
        return ConnectionCardHeader(title: title, subtitle: "SSH " + SSHWorker.printable(endpoint),
                                    windowTitle: name.isEmpty || name == address
                                        ? SSHWorker.printable(endpoint) : "\(title) — \(SSHWorker.printable(endpoint))")
    }

    /// The spinner page waiting to be shown after an answer (see below).
    private var pendingProgress: DispatchWorkItem?

    /// Back to the spinner once a question is answered, at its stage — but
    /// only if the next page has not arrived within `answerGrace`.
    /// Username → password usually takes a few milliseconds, and flashing a
    /// spinner page in between read as a flicker (the user, 2026-10-09).
    /// After the LAST answer (the password) the same flash happened the
    /// other way: "Authenticating…" for a blink, then the card closed — so
    /// the grace is a full second, longer than a LAN login takes, and a
    /// quick login goes straight from the password page to the shell (5.0 (1)).
    private func showProgress(after prompt: ConnectionPrompt) {
        guard !stopped else { return }
        pendingProgress?.cancel()
        // The password is the last question: the card stays on it until the
        // shell (card closes) or a failure / another question replaces it —
        // no "Authenticating…" page at the end (the user, 5.0 (3)).
        guard prompt.stage != .password else { pendingProgress = nil; return }
        let text = prompt.stage == .hostKey ? String(localized: "Connecting…") : String(localized: "Authenticating…")
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.terminalHost.showConnectionProgress(text, stage: prompt.stage) { [weak self] in self?.cancelConnecting() }
        }
        pendingProgress = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerGrace, execute: work)
    }

    /// A newer page is taking over: a spinner still waiting its turn must not
    /// paint over it.
    /// How long a connect may take before "Connecting…" is worth a card.
    /// Long enough that a host with a known key and saved credentials never
    /// shows one: 0.6 s was not — an Aruba CX takes over a second to check a
    /// password and open the shell, so the card flashed up and away (5.0 (4)).
    /// The terminal's "connecting to …" line and the status bar say it meanwhile.
    static let cardGrace: TimeInterval = 3.0
    /// How long after an answer the card keeps its page before "Authenticating…".
    static let answerGrace: TimeInterval = 1.0

    /// "Connecting…" once the connect has taken `cardGrace` — unless a
    /// question, a failure or the shell got there first (they all cancel it
    /// through `cancelPendingProgress`).
    private func scheduleConnectingCard() {
        pendingProgress?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.terminalHost.beginConnectionCard(self.cardHeader)
            self.terminalHost.showConnectionProgress(String(localized: "Connecting…"), stage: .connect) { [weak self] in self?.cancelConnecting() }
        }
        pendingProgress = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cardGrace, execute: work)
    }

    private func cancelPendingProgress() {
        pendingProgress?.cancel()
        pendingProgress = nil
    }

    /// Close / Escape on the card while connecting: the connection is
    /// cancelled (the worker stopped) — the same end as Escape on a question.
    private func cancelConnecting() {
        guard !stopped, !connectCancelledByUser else { return }
        connectCancelledByUser = true
        worker.stop()
        cancelPendingProgress()
        terminalHost.closeConnectionCard()
        printNotice("connection cancelled", error: true)
        onStatus?("disconnected — cancelled")
    }

    /// The card's failure page for a close that happened while connecting.
    private func showFailure(_ message: String, conflict: SSHWorker.KnownHostsConflict?) {
        let target = refusedTarget()
        let title: String
        switch conflict {
        case .changed?: title = String(localized: "The host key for \(target) has CHANGED")
        case .revoked?: title = String(localized: "The host key for \(target) is revoked")
        case nil:
            title = message.hasPrefix(SSHWorker.hostKeyRefusedPrefix) ? String(localized: "Host key refused") : String(localized: "Connection failed")
        }
        let hostKeyProblem = conflict != nil || message.hasPrefix(SSHWorker.hostKeyRefusedPrefix)
        let knownHosts: (() -> Void)? = conflict == nil ? nil : {
            AppModel.shared.openKnownHosts(search: target)
        }
        // Try Again (5.0 (19)): a new connection to the same host from the
        // start. After a refused login it asks that login's password again —
        // the refused one is not reused.
        let refused = worker.refusedLogin
        let tryAgain: (() -> Void)? = ConnectionCardPlan.offersTryAgain(message: message, hostKeyProblem: hostKeyProblem)
            && onTryAgain != nil ? { [weak self] in self?.onTryAgain?(refused) } : nil
        cancelPendingProgress()
        terminalHost.beginConnectionCard(cardHeader)
        terminalHost.showConnectionFailure(title: title, message: message, hostKeyProblem: hostKeyProblem,
                                           onKnownHosts: knownHosts, onTryAgain: tryAgain) { [weak self] in
            self?.terminalHost.closeConnectionCard()
        }
    }

    /// The host whose key was refused — through a jump host it may be the
    /// bastion, and the wrong pin must not be offered.
    private func refusedTarget() -> String {
        let address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        return worker.refusedHost ?? (host.port == 22 ? address
            : address.contains(":") ? "[\(address)]:\(host.port)" : "\(address):\(host.port)")
    }

    func start() {
        printNotice("connecting to \(host.address):\(host.port)…")
        // The card is NOT up from the first moment (5.0 (1), the user's call):
        // a host whose key is known and whose credentials are saved connects
        // with no card at all. A question puts it up at once (`presentPrompt`),
        // a failure too (`showFailure`); a connect that is merely slow shows
        // "Connecting…" after `cardGrace` (§15).
        scheduleConnectingCard()
        if let logger {
            // A handed-over logger's notices belong to THIS session now — the
            // controller that opened it is on its way out.
            adoptLogNotices(logger)
            printNotice("logging continues to \(logger.url.path)")
        } else if Host.shouldLogSession(host: host, global: UserDefaults.standard.object(forKey: "logSessions") as? Bool ?? true) {
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
        if jumpUnresolved {
            // Never "connect directly instead": the user set a path on purpose.
            printNotice("this host connects via a jump host that no longer exists (or is itself behind a jump host — one hop only) — edit the host and pick another, or None", error: true)
            onStatus?("disconnected — jump host missing")
            cancelPendingProgress()
            terminalHost.beginConnectionCard(cardHeader)
            terminalHost.showConnectionFailure(title: String(localized: "Jump host missing"),
                                               message: String(localized: "This host connects via a jump host that no longer exists (or is itself behind a jump host — one hop only). Edit the host and pick another, or None."),
                                               hostKeyProblem: false, onKnownHosts: nil) { [weak self] in
                self?.terminalHost.closeConnectionCard()
            }
            return
        }
        worker.start(SSHConfig(
            host: host.address,
            port: host.port,
            username: host.username,
            password: takePassword(),
            mode: host.cipherMode ?? .auto,
            initialCols: terminalView.cols,
            initialRows: terminalView.rows,
            agentForward: host.agentForward ?? false,
            jump: jump,
            forwards: forwardRules()
        ))
    }

    /// Status bar menu → Stop / Start one forward of the live session.
    func setForward(_ spec: PortForwardSpec, enabled: Bool) {
        worker.setForward(spec.rule, enabled: enabled)
    }

    /// The host's port forwards as SheepSSH rules. An entry that does not
    /// parse (a hand-edited hosts.json, another build) is named, not dropped
    /// in silence.
    private func forwardRules() -> [ForwardRule] {
        let specs = host.forwardSpecs
        let unreadable = (host.forwards ?? []).filter { PortForwardSpec.parse($0) == nil }
        if !unreadable.isEmpty {
            printNotice("port forward not understood, skipped: " + unreadable.joined(separator: ", "), error: true)
        }
        return specs.map(\.rule)
    }

    /// The start password, handed over once: the controller does not keep
    /// a copy for the tab's lifetime (a refused one least of all).
    private func takePassword() -> String? {
        defer { password = nil }
        return password
    }

    // MARK: - paging

    /// Per-session `--More--` detector; see `PagerDetector`.
    private var pager = PagerDetector()

    /// Auto-page: a chunk that ends in a pager prompt gets a space, as the
    /// user would type. Global switch in View → Auto-page.
    private func answerPagerIfNeeded(_ chunk: [UInt8]) {
        guard AppModel.shared.autoPage, pager.consume(chunk) else { return }
        worker.write([0x20])
    }

    /// Edit Host → "Disable paging on connect": the family's pager-off
    /// command, typed once after the shell is up. Visible in the session and
    /// the log like anything else typed. Nothing for Auto / Linux / FortiOS
    /// (see `Vendor.disablePagingCommand`).
    private func disablePagingIfAsked() {
        guard host.disablePaging == true, let command = host.highlightVendor.disablePagingCommand else { return }
        worker.write(Array((command + "\r").utf8))
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
        cancelPendingProgress()
        terminalHost.closeConnectionCard()
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

    /// After a host-key refusal that a known_hosts line decided: say so and
    /// offer the Known Hosts sheet filtered to this host. Cancel is the
    /// default (Return/Escape) — removing a pin is never one keystroke away.
    private func offerKnownHosts(_ conflict: SSHWorker.KnownHostsConflict) {
        guard !stopped else { return }
        let target = refusedTarget()
        let alert = SheepAlert()
        alert.alertStyle = .warning
        switch conflict {
        case .changed:
            alert.messageText = String(localized: "The host key for \(target) has changed")
            alert.informativeText = String(localized: "The connection was refused — this can mean a man-in-the-middle. ")
                + String(localized: "Only if you know the device was reinstalled or its key replaced, remove the old key in Known Hosts and connect again.")
        case .revoked:
            alert.messageText = String(localized: "The host key for \(target) is revoked")
            alert.informativeText = String(localized: "known_hosts marks this key @revoked, so the connection was refused. ")
                + String(localized: "Known Hosts shows the entry.")
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Open Known Hosts…"))
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn {
                AppModel.shared.openKnownHosts(search: target)
            }
        }
        if let window = terminalView.window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    func stop() {
        stopped = true
        terminalHost.cancelSafePaste(reason: .sessionEnded)
        worker.stop()
        // A question still up is answered "no" — the worker, blocked on it,
        // is free at once (its own poll would free it within 0.1 s anyway) —
        // and the card goes with the tab (and its panel, if it had one).
        cancelPendingProgress()
        terminalHost.closeConnectionCard()
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
        onTitleChange = nil
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

extension SSHTerminalController: TerminalViewDelegate {
    // The view calls every one of these on the main actor, from inside its own
    // event handling — no nonisolated hops, no assumeIsolated.

    /// Split panes: the pane the keyboard went to is the selected session.
    func focusChanged(_ view: TerminalView, focused: Bool) {
        guard focused else { return }
        AppModel.shared.noteFocus(view: view)
        // A connection question is up: the keyboard belongs to its card.
        terminalHost.terminalTookKeyboard()
        terminalHost.terminalTookKeyboardForGuard()
    }

    func send(_ view: TerminalView, bytes: [UInt8]) {
        // Every early return below = not taken; a stale true from an earlier
        // keystroke must not answer `takeLastSendAccepted` for these bytes.
        lastWriteAccepted = false
        // A typed Return on a dangerous command is held for the user's
        // answer (Danger Command Guard) — and the keys behind it.
        guard terminalHost.admitOutgoing(bytes) else { return }
        // A refused write means the worker took nothing: keep the answer so
        // a paced paste can end on it instead of counting the line as sent.
        lastWriteAccepted = worker.write(bytes)
        terminalHost.noteOutgoing(bytes)
    }

    /// Only a real keystroke cancels a running Safe Paste — a DA/DSR reply
    /// or a mouse report also travels through `send` and used to abort it.
    func userTyped(_ view: TerminalView) {
        terminalHost.prepareForOrdinaryUserInput()
    }

    func sizeChanged(_ view: TerminalView, cols: Int, rows: Int) {
        resizes.changed(cols: cols, rows: rows)
    }

    func titleChanged(_ view: TerminalView, title: String) {
        onTitleChange?(title)
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

// The app's spelling of a forward and SheepSSH's, both ways.
nonisolated extension PortForwardSpec {
    var rule: ForwardRule {
        switch self {
        case .local(let bind, let target, let port): return .local(bindPort: bind, host: target, port: port)
        case .socks(let bind): return .dynamic(bindPort: bind)
        // No address = "" on the wire: the server's loopback (OpenSSH's default).
        case .remote(let address, let bind, let target, let port):
            return .remote(bindAddress: address ?? "", bindPort: bind, host: target, port: port)
        case .remoteSocks(let address, let bind): return .remoteDynamic(bindAddress: address ?? "", bindPort: bind)
        }
    }

    init(_ rule: ForwardRule) {
        switch rule {
        case .local(let bind, let host, let port): self = .local(bindPort: bind, host: host, port: port)
        case .dynamic(let bind): self = .socks(bindPort: bind)
        case .remote(let address, let bind, let host, let port):
            self = .remote(bindAddress: address.isEmpty ? nil : address, bindPort: bind, host: host, port: port)
        case .remoteDynamic(let address, let bind):
            self = .remoteSocks(bindAddress: address.isEmpty ? nil : address, bindPort: bind)
        }
    }
}
