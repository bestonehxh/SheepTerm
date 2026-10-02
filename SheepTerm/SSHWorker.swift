import Foundation
import Network
import SheepSSH
import Synchronization

struct SSHConfig: Sendable {
    var host: String
    var port: Int
    var username: String
    var password: String?
    var mode: CipherMode
    var initialCols: Int
    var initialRows: Int
    /// ForwardAgent: let the remote host reach the local ssh-agent so a
    /// hop from there can use our keys. Off unless the host asks for it —
    /// anyone with root on the far end can use the socket while we sit there.
    var agentForward: Bool = false
}

/// Runs one SSH session (our own SheepSSH stack) on its own serial queue.
/// The transport, userauth and connection objects are not thread-safe, so
/// every call into them happens on that queue; the UI talks to this class
/// only through the locked buffers and the callback closures.
nonisolated final class SSHWorker: Sendable {
    private let queue = DispatchQueue(label: "sheepterm.ssh.session")
    private struct State: Sendable {
        var pendingWrites = ByteQueue()
        var pendingResize: (cols: Int, rows: Int)?
        /// The size the channel last accepted, so a redundant request — the
        /// terminal view re-measuring its font without the grid changing —
        /// is dropped here instead of reaching the device as a window-size
        /// change (which every network OS answers with a fresh prompt).
        var appliedResize: (cols: Int, rows: Int)?
        /// True from start() until run() has completed all of its defers.
        /// Kept separate from `running`, which stop() clears immediately.
        var runActive = false
        var running = false
        /// Write end of the self-pipe; -1 when the loop isn't up.
        var wakeFD: Int32 = -1
        /// Set when input was discarded because the buffer is full; cleared
        /// by the next accepted write, so one stall produces one notice.
        var writeOverflowNotified = false
        var onData: (@Sendable ([UInt8]) -> Void)?
        var onNotice: (@Sendable (String) -> Void)?
        /// Fired when a write was refused. A paced paste has to stop: the
        /// pacer counts lines it HANDED OVER, so without this the HUD
        /// reports a full send while the device got a config with holes.
        var onInputDiscarded: (@Sendable () -> Void)?
        var onStatus: (@Sendable (String) -> Void)?
        var onClosed: (@Sendable (String) -> Void)?
        var passwordPrompt: (@Sendable (String) -> String?)?
        var challengePrompt: (@Sendable (_ prompt: String, _ secure: Bool) -> String?)?
        var usernamePrompt: (@Sendable (String) -> String?)?
        var hostKeyPrompt: HostKeyPrompt?
        var onPasswordWorked: (@Sendable (String, String) -> Void)?
        /// Fired as soon as a username typed at the prompt is known, before
        /// authentication. Without it the controller's `host` kept an empty
        /// username for a key-authenticated session, so every reconnect —
        /// including an unattended automatic one — put the prompt back up.
        var onUsernameResolved: (@Sendable (String) -> Void)?
        /// Set when the user dismissed a credential prompt. Reported apart
        /// from a real authentication failure so auto-reconnect does not
        /// re-raise the same prompt three times.
        var authCancelled = false
        /// Set when authentication ended because the TRANSPORT died, not
        /// because a credential was wrong. Telling them apart is what stops a
        /// link that dropped mid-handshake from being blamed on the user.
        var authTransportError: String?
    }
    private let state = Mutex(State())
    /// Cap on buffered input — a wedged session must not grow it forever.
    ///
    /// Sized ABOVE the app's own paste limit on purpose. At 1 MB it was
    /// smaller than `SafePastePlan.maxBytes`, so a legal 2 MB paste — or any
    /// single-line clipboard over 1 MB, which bypasses Safe Paste entirely —
    /// was refused whole on a perfectly healthy session and reported as if
    /// the connection had stalled.
    private static let maxPendingWrites = SafePastePlan.maxBytes + 1024 * 1024

    var onData: (@Sendable ([UInt8]) -> Void)? {
        get { state.withLock { $0.onData } }
        set { state.withLock { $0.onData = newValue } }
    }
    var onUsernameResolved: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onUsernameResolved } }
        set { state.withLock { $0.onUsernameResolved = newValue } }
    }
    private var authCancelled: Bool {
        get { state.withLock { $0.authCancelled } }
        set { state.withLock { $0.authCancelled = newValue } }
    }
    private var authTransportError: String? {
        get { state.withLock { $0.authTransportError } }
        set { state.withLock { $0.authTransportError = newValue } }
    }
    var onNotice: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onNotice } }
        set { state.withLock { $0.onNotice = newValue } }
    }

    var onInputDiscarded: (@Sendable () -> Void)? {
        get { state.withLock { $0.onInputDiscarded } }
        set { state.withLock { $0.onInputDiscarded = newValue } }
    }
    var onStatus: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onStatus } }
        set { state.withLock { $0.onStatus = newValue } }
    }
    var onClosed: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onClosed } }
        set { state.withLock { $0.onClosed = newValue } }
    }
    /// Asks the UI for a password; returns nil when the user cancels.
    var passwordPrompt: (@Sendable (String) -> String?)? {
        get { state.withLock { $0.passwordPrompt } }
        set { state.withLock { $0.passwordPrompt = newValue } }
    }
    /// Asks the UI for a keyboard-interactive challenge. `secure` mirrors
    /// the server's echo flag (password/OTP prompts normally request no echo).
    var challengePrompt: (@Sendable (_ prompt: String, _ secure: Bool) -> String?)? {
        get { state.withLock { $0.challengePrompt } }
        set { state.withLock { $0.challengePrompt = newValue } }
    }
    /// Asks the UI for a username when the host has none configured.
    var usernamePrompt: (@Sendable (String) -> String?)? {
        get { state.withLock { $0.usernamePrompt } }
        set { state.withLock { $0.usernamePrompt = newValue } }
    }
    /// Asks the user whether to trust a host key seen for the first time
    /// (nothing pinned for the host in either known_hosts file). Called on
    /// the worker queue, synchronously, inside the key exchange — before
    /// anything is saved and before any credential is sent — exactly like
    /// `passwordPrompt`. The second argument turns true once the session is
    /// stopped (tab closed, quit): the dialog must then go away and answer
    /// `.stopped`. nil = no way to ask = the key is refused (fail closed).
    var hostKeyPrompt: HostKeyPrompt? {
        get { state.withLock { $0.hostKeyPrompt } }
        set { state.withLock { $0.hostKeyPrompt = newValue } }
    }
    typealias HostKeyPrompt = @Sendable (HostKeyQuestion, _ isCancelled: @escaping @Sendable () -> Bool) -> HostKeyAnswer
    /// Reports the (username, password) that actually authenticated, so the
    /// app can remember it for reconnects.
    var onPasswordWorked: (@Sendable (String, String) -> Void)? {
        get { state.withLock { $0.onPasswordWorked } }
        set { state.withLock { $0.onPasswordWorked = newValue } }
    }


    // The algorithm lists live in SheepSSH: `AlgorithmPreferences.modern`
    // (libssh 0.12's client default) and `.legacy` (modern first, then the
    // old algorithms, so new gear still negotiates the best it has while
    // 15-year-old switches connect).

    // MARK: Thread-safe surface

    func start(_ config: SSHConfig) {
        let accepted = state.withLock { state in
            // One session owns this worker queue at a time. In
            // particular, do not let start() race teardown after stop().
            guard !state.runActive else { return false }
            state.runActive = true
            state.running = true
            state.pendingWrites.removeAll()
            state.writeOverflowNotified = false
            state.pendingResize = nil
            return true
        }
        // A refusal must SAY so. Every caller today builds a fresh worker, so
        // this cannot fire; a future in-place reconnect that rejected here in
        // silence would leave the tab on "connecting…" with nothing to show.
        guard accepted else {
            closeSession("a session is still shutting down on this connection — try again")
            return
        }
        queue.async { [weak self] in
            self?.run(config)
        }
    }

    func stop() {
        state.withLock { state in
            state.running = false
            // Holding the Mutex prevents a race with teardown closing and
            // invalidating (or reusing) the descriptor.
            if state.wakeFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.write(state.wakeFD, &byte, 1)
            }
        }
    }

    /// Returns false when the input was refused, so a paced paste can stop
    /// instead of reporting lines it never sent.
    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        // Fired outside the lock: onNotice hops to the main actor, and this
        // Mutex is not recursive.
        var notice: (@Sendable (String) -> Void)?
        var message = ""
        var accepted = false
        var discarded: (@Sendable () -> Void)?
        state.withLock { state in
            // A dead session refuses the same way a wedged one does: the Bool
            // says so, and `onInputDiscarded` fires, so a paced paste stops
            // here instead of counting the line. SerialWorker already did.
            guard state.running else { discarded = state.onInputDiscarded; return }
            // All-or-nothing. The old code appended `bytes.prefix(room)`,
            // which on a wedged session sent the FRONT of a paste and threw
            // the rest away — half an escape sequence or half a config line
            // reaching the device is worse than nothing reaching it.
            guard state.pendingWrites.count + bytes.count <= Self.maxPendingWrites else {
                discarded = state.onInputDiscarded
                if !state.writeOverflowNotified {
                    state.writeOverflowNotified = true
                    notice = state.onNotice
                    // Two different failures wear one message otherwise, and
                    // the wrong one sends you debugging a healthy link.
                    message = bytes.count > Self.maxPendingWrites
                        ? "that paste is larger than SheepTerm will send in one go — nothing was sent"
                        : "connection is not draining — input is being discarded until it recovers"
                }
                return
            }
            state.writeOverflowNotified = false
            state.pendingWrites.append(contentsOf: bytes)
            accepted = true
            if state.wakeFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.write(state.wakeFD, &byte, 1)
            }
        }
        if let notice { notice(message) }
        discarded?()
        return accepted
    }

    func resize(cols: Int, rows: Int) {
        state.withLock { state in
            guard state.running else { return }
            if let applied = state.appliedResize, applied.cols == cols, applied.rows == rows,
               state.pendingResize == nil {
                return
            }
            state.pendingResize = (cols, rows)
            if state.wakeFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.write(state.wakeFD, &byte, 1)
            }
        }
    }

    private var isRunning: Bool {
        state.withLock { $0.running }
    }

    /// Up to `limit` bytes from the front of the input queue. The rest stays
    /// queued — and counted against `maxPendingWrites` — so a stalled link
    /// fills the bounded queue (and the user is told) rather than the
    /// channel's buffer.
    private func takeWrites(limit: Int) -> [UInt8] {
        state.withLock { state in
            state.pendingWrites.take(limit)
        }
    }

    private func takeResize() -> (cols: Int, rows: Int)? {
        state.withLock { state in
            let resize = state.pendingResize
            state.pendingResize = nil
            return resize
        }
    }

    /// Every close message goes out through here.
    ///
    /// `hostKeyRefusedPrefix` must only ever START a message this worker
    /// wrote about a host key it refused: the controller keys on it to stop
    /// auto-reconnect and show the MITM warning. Round 2 moved the prefix to
    /// the front wherever it appeared, and most messages quote the server
    /// (its version line, DISCONNECT reason, open-failure text) — so a hostile
    /// server could forge the warning, with its own instructions. Refusals
    /// are now carried as a type (`HandshakeFailure.hostKey`,
    /// `hostKeyRefusal(in:)`), and anything else that happens to start with
    /// the prefix is defused.
    /// Every notice goes through here: most quote the server.
    private func notice(_ message: String) {
        onNotice?(Self.printable(message))
    }

    /// Server-controlled text (version line, DISCONNECT reason, algorithm
    /// names — all accepted in cleartext before the host key is checked)
    /// with its control characters made harmless before it reaches the
    /// terminal: an escape sequence there could rewrite the clipboard
    /// (OSC 52) or repaint a forged host-key warning over our prefix.
    /// C0/C1 controls, DEL and bidi controls become U+FFFD; line breaks and
    /// tabs a space. (OpenSSH strnvis-escapes the same strings.) The bidi
    /// set is every explicit directional formatting character: the
    /// embeddings/overrides (U+202A–202E), the isolates (U+2066–2069) AND the
    /// three marks — LRM U+200E, RLM U+200F, ALM U+061C — which reorder
    /// neutral runs (digits, "-", ":") just as well and are enough to make
    /// "host key refused" text or a fingerprint read differently.
    static func printable(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: out.append(" ")
            case 0x00...0x1F, 0x7F, 0x80...0x9F, 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                out.append("\u{FFFD}")
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    private func closeSession(_ message: String, hostKeyRefusal: Bool = false, endedNormally: Bool = false) {
        // Sanitized first, then checked: the controller matches the prefix on
        // what it receives, so the check here must see the same text.
        let clean = Self.printable(message)
        if !hostKeyRefusal, clean.hasPrefix(Self.hostKeyRefusedPrefix)
            || !endedNormally && clean.hasPrefix(Self.sessionEndedPrefix) {
            onClosed?("server said: " + clean)
        } else {
            onClosed?(clean)
        }
    }

    /// The refusal text when `error` is (or wraps) a host key that changed
    /// during a rekey — a host-key decision, reported without any context
    /// prefix.
    static func hostKeyRefusal(in error: Error) -> String? {
        var underlying: Error = error
        if case .transport(let t)? = error as? UserAuthError { underlying = t }
        if case .transport(let t)? = error as? ConnectionError { underlying = t }
        if case .hostKeyChangedDuringRekey? = underlying as? SSHTransportError { return describe(underlying) }
        return nil
    }

    // MARK: Session lifecycle (everything below runs on `queue`)

    /// Why the handshake (TCP, key exchange, host key) did not produce a
    /// session. `.stopped` means the tab closed — nothing is reported.
    nonisolated private enum HandshakeFailure: Error {
        case stopped
        case negotiation(String)
        case message(String)
        /// A host key this worker refused; reported as is (it starts with
        /// `hostKeyRefusedPrefix`).
        case hostKey(String)
    }

    private func run(_ initialConfig: SSHConfig) {
        // Every return path — prompt cancellation, connection/authentication
        // failure, remote EOF, local stop, or I/O error — must make the public
        // surface reject further input and discard bytes belonging to the dead
        // session. This defer was registered first so the resource defers below
        // run before runActive is released for a possible later start().
        defer {
            state.withLock { state in
                state.running = false
                state.pendingWrites.removeAll(keepingCapacity: false)
                state.pendingResize = nil
                state.runActive = false
            }
        }
        var config = initialConfig
        if config.username.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let user = usernamePrompt?("Username for \(config.host)")?
                .trimmingCharacters(in: .whitespaces), !user.isEmpty else {
                closeSession("connection cancelled — no username given")
                return
            }
            config.username = user
            onUsernameResolved?(user)
        }
        // config.port is an unvalidated Int.
        guard (1...65535).contains(config.port) else {
            closeSession("invalid port \(config.port) — must be between 1 and 65535")
            return
        }

        // Self-pipe so write()/resize()/stop() wake whichever poll is waiting —
        // the handshake's as well as the interactive loop's. The write end is
        // non-blocking so a full pipe can never stall a caller.
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            closeSession("pipe failed: \(String(cString: strerror(errno)))")
            return
        }
        let pipeRead = pipeFDs[0]
        let pipeWrite = pipeFDs[1]
        _ = fcntl(pipeWrite, F_SETFL, O_NONBLOCK)
        _ = fcntl(pipeRead, F_SETFL, O_NONBLOCK)
        // Never inherited by a local shell tab's child (see openTCP).
        _ = fcntl(pipeWrite, F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipeRead, F_SETFD, FD_CLOEXEC)
        state.withLock { $0.wakeFD = pipeWrite }
        defer {
            state.withLock { $0.wakeFD = -1 }
            close(pipeRead)
            close(pipeWrite)
        }

        var usedLegacy = config.mode == .legacy
        let link: SSHLink
        switch connectAndExchangeKeys(config, legacy: usedLegacy, wake: pipeRead) {
        case .success(let established):
            link = established
        case .failure(.negotiation(let why)) where config.mode == .auto:
            notice("modern negotiation failed (\(why)) — retrying with legacy algorithms…")
            usedLegacy = true
            switch connectAndExchangeKeys(config, legacy: true, wake: pipeRead) {
            case .success(let established):
                link = established
            case .failure(let failure):
                report(failure)
                return
            }
        case .failure(let failure):
            report(failure)
            return
        }
        defer { link.shutdown() }

        authCancelled = false
        authTransportError = nil
        guard authenticate(link, config, legacy: usedLegacy, wake: pipeRead) else {
            // Only a live session reports failure — a tab closed mid-auth
            // must not print a fake "authentication failed". A prompt the
            // user dismissed is reported as a cancellation: the controller
            // turns that into a status auto-reconnect leaves alone.
            if isRunning {
                // A link that died during the handshake is NOT a credential
                // problem, and saying it was did real damage: the prompt came
                // up on a socket that was already gone, the dismissal was
                // recorded as "cancelled", and "cancelled" is exactly the
                // status auto-reconnect refuses to act on. The one moment a
                // drop is most likely to be misread was also the one moment
                // recovery was switched off.
                if let refusal = hostKeyRefusedDuringAuth {
                    closeSession(refusal, hostKeyRefusal: true)
                } else if let transport = authTransportError {
                    closeSession(transport)
                } else {
                    closeSession(authCancelled ? "connection cancelled — no password given" : "authentication failed")
                }
            }
            return
        }

        let connection = SSHConnection(transport: link.transport)
        // Messages that arrived with (or right after) USERAUTH_SUCCESS belong
        // to the connection layer now.
        link.route = { try connection.handle($0) }
        do {
            try link.drainMessages()
        } catch {
            closeSession("connection lost: \(Self.describe(error))")
            return
        }

        let channel: UInt32
        do {
            channel = try connection.openSession()
        } catch {
            closeSession("channel open failed: \(Self.describe(error))")
            return
        }
        var pending: [SSHConnection.Event] = []
        switch waitFor(link, connection, wake: pipeRead, collecting: &pending, until: { events in
            events.contains { event in
                switch event {
                case .channelOpened(channel), .channelOpenFailed(channel, _, _): return true
                default: return false
                }
            }
        }) {
        case .failure(let failure):
            report(failure, prefix: "channel open failed: ")
            return
        case .success:
            for event in pending {
                if case .channelOpenFailed(channel, _, let description) = event {
                    closeSession("channel open failed: \(description.isEmpty ? "refused by the server" : description)")
                    return
                }
            }
        }

        // pty first. Only record a size the server actually took. `resize`
        // skips a request that matches the last APPLIED size, so claiming this
        // one regardless meant a refused pty-size swallowed the first real
        // resize to the same dimensions — and the far end never learned how
        // big the window was.
        guard let ptyGranted = requestAndWait("pty-req", link, connection, channel, wake: pipeRead, collecting: &pending, send: {
            try connection.requestPTY(channel, columns: config.initialCols, rows: config.initialRows)
        }) else { return }
        if ptyGranted {
            state.withLock { $0.appliedResize = (config.initialCols, config.initialRows) }
        }

        // Agent forwarding: the far end asks for our keys by opening an
        // "auth-agent@openssh.com" channel per request; the connection layer
        // only accepts those after auth-agent-req.
        var forwarder: AgentForwarder?
        if config.agentForward {
            if let path = SSHAgent.socketPath {
                // No reply is asked for (as OpenSSH and libssh): a device that
                // never answers must not stall the shell. A refusal simply
                // means no agent channel ever opens.
                do {
                    try connection.requestAgentForwarding(channel)
                    forwarder = AgentForwarder(socketPath: path)
                } catch {
                    closeSession("auth-agent-req failed: \(Self.describe(error))")
                    return
                }
            } else {
                notice("agent forwarding: SSH_AUTH_SOCK is not set — no ssh-agent to forward")
            }
        }
        defer { forwarder?.closeAll() }

        guard let shellGranted = requestAndWait("shell", link, connection, channel, wake: pipeRead, collecting: &pending, send: {
            try connection.requestShell(channel)
        }) else { return }
        guard shellGranted else {
            closeSession("shell request failed: the server refused to start a shell")
            return
        }

        // Only now is the session actually usable — reporting "Connected"
        // before the shell is granted would lie on VTY-full devices.
        let negotiated = link.transport.negotiated
        let kex = negotiated?.kex.rawValue ?? "?"
        let cipher = negotiated?.cipherClientToServer.rawValue ?? "?"
        var status = "ssh2 · \(cipher) · \(kex) · \(config.host):\(config.port) · \(config.username)"
        if usedLegacy { status += " · LEGACY" }
        if forwarder != nil { status += " · agent" }
        onStatus?(status)

        // Output that arrived while the pty/shell replies were awaited (a
        // device that prints its prompt before answering) is not lost.
        var endedDuringSetup = false
        for event in pending {
            deliver(event, channel: channel, forwarder: forwarder, connection: connection)
            // A VTY-full device can grant the shell, print "All lines busy"
            // and close in the same read: that is a normal end, not a drop.
            switch event {
            case .eof(channel), .closed(channel): endedDuringSetup = true
            default: break
            }
        }

        // Live from here: a network change the socket itself cannot see is
        // reported by the path watcher, not by the keepalive clocks inside
        // ioLoop (they own every slower death). See SessionPathWatcher.
        let pathWatcher = SessionPathWatcher()
        pathWatcher.start(local: SessionPathWatcher.localAddress(of: link.fd), wake: pipeWrite)
        // stop() must run BEFORE the self-pipe's write end is closed by the
        // defer registered earlier — a late handler writing a reused fd is a
        // poke at someone else's descriptor. LIFO gives exactly that.
        defer { pathWatcher.stop() }

        let failure = endedDuringSetup ? nil
            : ioLoop(link: link, connection: connection, channel: channel, pipeRead: pipeRead,
                     forwarder: forwarder, watcher: pathWatcher)

        if connection.isOpen(channel) {
            try? connection.sendEOF(channel)
            try? connection.close(channel)
        }
        if let failure {
            closeSession(failure.message, hostKeyRefusal: failure.hostKeyRefusal)
        } else {
            // `exit`, logout, or the device closing the session itself (an
            // idle exec-timeout): an end, not a drop — auto-reconnect must
            // leave it alone (the owner's call; libssh-era builds logged
            // straight back in).
            closeSession(Self.sessionEndedPrefix + "\(config.host) closed.", endedNormally: true)
        }
    }

    private func report(_ failure: HandshakeFailure, prefix: String = "") {
        guard isRunning else { return }
        switch failure {
        case .stopped: return
        case .negotiation(let why): closeSession(prefix + why)
        case .message(let message): closeSession(prefix + message)
        case .hostKey(let refusal): closeSession(refusal, hostKeyRefusal: true)
        }
    }

#if SHEEPTERM_TESTING
    /// Compiled only by the standalone worker regression harness.
    func _testLifecycleSnapshot() -> (
        running: Bool,
        runActive: Bool,
        pendingWriteCount: Int,
        hasPendingResize: Bool
    ) {
        state.withLock {
            ($0.running, $0.runActive, $0.pendingWrites.count, $0.pendingResize != nil)
        }
    }
#endif

    // MARK: Connect + key exchange

    /// Holds a host-key refusal made inside the key exchange (the validator
    /// runs synchronously on this queue, but is a @Sendable closure).
    /// Set by authenticate() when a rekey during authentication presented a
    /// different host key. Worker-queue only.
    nonisolated(unsafe) private var hostKeyRefusedDuringAuth: String?

    /// A lookup's result, handed between the resolver thread and the worker.
    /// The list travels as a bit pattern: an Int is Sendable, a pointer is not.
    nonisolated private final class ResolutionBox: Sendable {
        nonisolated struct Outcome: Sendable { var done = false, abandoned = false, rc: Int32 = 0, list = 0 }
        let outcome = Mutex(Outcome())
        let finished = DispatchSemaphore(value: 0)
    }

    nonisolated private enum AuthStep { case success, partial, exhausted, stop }

    /// A keyboard-interactive prompt's own words: letters only, and only
    /// what follows "user@host's " when the device embeds that (a host or
    /// user name must not read as "new" or "again").
    static func promptWords(_ normalized: String) -> Set<String> {
        Set(ownText(normalized).split { !$0.isLetter }.map(String.init))
    }

    private static func ownText(_ normalized: String) -> Substring {
        var text = Substring(normalized)
        if let range = text.range(of: "'s ", options: .backwards) { text = text[range.upperBound...] }
        return text
    }

    /// What a keyboard-interactive prompt asks for, from its own words (a
    /// host named encoder-03 or newyork-core must not read as "code"/"new").
    /// `newPassword`: a password change ("New password:", "Retype new
    /// password:", "Verify password:", "Re-enter password:") — the word
    /// password is required, so a SecurID "new PIN" / "new passcode" is not
    /// taken for one (and never saved as the password).
    static func classifyPrompt(_ normalized: String) -> (additionalFactor: Bool, newPassword: Bool) {
        let words = promptWords(normalized)
        let text = ownText(normalized)
        let additional = !words.isDisjoint(with: ["otp", "token", "tokencode", "verification", "code", "passcode", "pin"])
        let mentionsPassword = words.contains("password") || text.contains("newpassword")
        let changeWords = !words.isDisjoint(with: ["new", "retype", "reenter", "again", "confirm", "verify"])
            || text.contains("re-enter") || text.contains("newpassword")
        return (additional, mentionsPassword && changeWords && !additional)
    }

    nonisolated private final class RefusalBox: Sendable {
        /// Why the validator said no: `.hostKey` (a refusal), `.message` (the
        /// user declined a first-seen key) or `.stopped` (the tab closed
        /// while the question was open).
        let reason = Mutex<HandshakeFailure?>(nil)
        /// Time the validator spent waiting for the user to answer the
        /// first-connection question. The connect budget is for the network:
        /// a person reading a fingerprint must not run it out.
        let waitedForUser = Mutex<Duration>(.zero)
    }

    nonisolated private final class KnownHostsSnapshot: Sendable {
        let files: Mutex<KnownHostsFiles?>
        init(_ files: KnownHostsFiles) { self.files = Mutex(files) }
    }

#if SHEEPTERM_TESTING
    /// Shortened by the worker harness so "the dialog does not eat the
    /// budget" is checked in seconds, not in 15.
    nonisolated(unsafe) static var connectBudget: Duration = .seconds(15)
#else
    static let connectBudget: Duration = .seconds(15)
#endif

    /// TCP connect, version exchange, key exchange, host key check — within
    /// the same 15 s libssh's SSH_OPTIONS_TIMEOUT gave the whole connect.
    /// Time spent waiting on the first-connection trust question is NOT
    /// counted: the deadline moves out by exactly that long (the password
    /// prompt gets the same treatment by running before its own clock).
    private func connectAndExchangeKeys(_ config: SSHConfig, legacy: Bool, wake: Int32) -> Result<SSHLink, HandshakeFailure> {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.connectBudget)
        let fd: Int32
        switch Self.openTCP(host: config.host, port: config.port, deadline: deadline, isRunning: { [weak self] in self?.isRunning ?? false }) {
        case .success(let socket): fd = socket
        case .failure(let failure): return .failure(failure)
        }
        enableTCPKeepalive(on: fd)

        let refusal = RefusalBox()
        let host = config.host, port = config.port
        // Offer the key types already pinned for this host first, as libssh
        // did: a device pinned as ECDSA or RSA that also has an ed25519 key
        // would otherwise present ed25519 and be refused as a type change.
        let base: AlgorithmPreferences = legacy ? .legacy : .modern
        let knownHosts = Self.loadKnownHosts()
        let snapshot = KnownHostsSnapshot(knownHosts)
        let transportConfig = SSHTransport.Configuration(
            preferences: base.preferringHostKeyTypes(knownHosts.pinnedKeyTypes(host: host, port: port)),
            softwareVersion: "SheepTerm",
            // Legacy also takes 1024-bit group-exchange primes: it already
            // offers diffie-hellman-group1-sha1, which is 1024-bit.
            groupExchangeBits: legacy ? 1024...8192 : 2048...8192,
            hostKeyValidator: { [weak self] key in
                guard let self else { return false }
                // Called once; the parsed files are not kept for the life
                // of the session (a managed Mac's system file can be large).
                let files = snapshot.files.withLock { f in defer { f = nil }; return f } ?? Self.loadKnownHosts()
                if let reason = self.verifyHostKey(key, host: host, port: port, files: files,
                                                   waited: { d in refusal.waitedForUser.withLock { $0 += d } }) {
                    refusal.reason.withLock { $0 = reason }
                    return false
                }
                return true
            })
        let link = SSHLink(fd: fd, transport: SSHTransport(configuration: transportConfig))
        link.transport.start()
        let outcome = pump(link, wake: wake, deadline: deadline,
                           slack: { refusal.waitedForUser.withLock { $0 } }) { link.isReady }
        switch outcome {
        case .success:
            return .success(link)
        case .failure(let failure):
            link.close()
            if case .message(let text) = failure, text == Self.hostKeyRejectedMarker,
               let reason = refusal.reason.withLock({ $0 }) {
                return .failure(reason)
            }
            return .failure(failure)
        }
    }

    static let hostKeyRejectedMarker = "\u{0}host-key-rejected"

    /// Pumps the link until `done()`, the deadline, a stop, or a failure.
    /// `slack`: how far the deadline has moved out (time spent waiting on
    /// the user inside the handshake), read on every pass.
    private func pump(_ link: SSHLink, wake: Int32, deadline: ContinuousClock.Instant?,
                      slack: () -> Duration = { .zero },
                      until done: () -> Bool) -> Result<Void, HandshakeFailure> {
        let clock = ContinuousClock()
        while true {
            if done() { return .success(()) }
            guard isRunning else { return .failure(.stopped) }
            if let deadline, clock.now >= deadline.advanced(by: slack()) {
                return .failure(.message(link.transport.isDiscardingCorruptPacket
                    ? "corrupted packet from the server (impossible length) — connection dropped"
                    : "timed out waiting for the server"))
            }
            do {
                try link.step(timeoutMS: 200, wake: wake, extra: [])
            } catch {
                return .failure(Self.handshakeFailure(error))
            }
        }
    }

    private static func handshakeFailure(_ error: Error) -> HandshakeFailure {
        if let refusal = hostKeyRefusal(in: error) { return .hostKey(refusal) }
        if let transport = error as? SSHTransportError {
            switch transport {
            case .negotiation: return .negotiation(describe(transport))
            // A group-exchange prime below modern's 2048 bits is what legacy
            // (1024…8192) exists to accept. A prime over 8192 bits or a bad
            // generator fails the same way under legacy, so no retry.
            case .keyExchange(.groupTooSmall): return .negotiation(describe(transport))
            case .hostKeyRejected: return .message(hostKeyRejectedMarker)
            // Some old devices do not send a KEXINIT we could fail to match:
            // they read ours and hang up with DISCONNECT ("no matching key
            // exchange method", reason 3). libssh's error text carried "kex"
            // and auto mode fell back to legacy; it must still.
            case .disconnectedByServer(let reason, let description):
                let text = description.lowercased()
                if reason == 3 || ["no match", "key exchange", "kex", "algorithm", "cipher"].contains(where: text.contains) {
                    return .negotiation(describe(transport))
                }
            default: break
            }
        }
        return .message(describe(error))
    }

    /// Human-readable text for anything SheepSSH or the socket can throw.
    static func describe(_ error: Error) -> String {
        switch error {
        case let e as SSHTransportError:
            switch e {
            case .versionExchange(let why): return why
            case .protocolError(let why): return "protocol error: \(why)"
            case .negotiation(.noCommonAlgorithm(let category, let offers)):
                return "no matching \(category) algorithm — the device offers: \(offers.joined(separator: ", "))"
            case .keyExchange(let why): return "key exchange failed: \(why)"
            case .signature(let why): return "the server's host-key signature did not verify (\(why))"
            case .packet(.macMismatch): return "corrupted packet (MAC mismatch)"
            case .packet(let why): return "bad packet: \(why)"
            case .hostKeyRejected: return "host key rejected"
            case .hostKeyChangedDuringRekey:
                return hostKeyRefusedPrefix + "⚠️ the server presented a different host key during rekey"
            case .disconnectedByServer(_, let description):
                return description.isEmpty ? "disconnected by the server" : "disconnected by the server: \(description)"
            case .closed: return "connection closed"
            }
        case let e as SSHLink.Failure:
            switch e {
            case .closedByPeer: return "connection closed by the server"
            case .socket(let why): return why
            }
        case let e as UserAuthError:
            switch e {
            case .transport(let t): return describe(t)
            case .protocolError(let why): return "protocol error: \(why)"
            default: return "\(e)"
            }
        case let e as ConnectionError:
            switch e {
            case .transport(let t): return describe(t)
            case .protocolError(let why): return "protocol error: \(why)"
            case .unknownChannel: return "protocol error: \(e)"
            }
        default:
            return "\(error)"
        }
    }

    /// Resolves and connects (every address getaddrinfo returns, in order)
    /// with a non-blocking connect bounded by `deadline`.
    /// getaddrinfo on its own thread: it blocks with no timeout of its own
    /// (an unreachable DNS server held the tab on "connecting…" for the
    /// resolver's full timeout, past the 15 s budget, and Stop could not
    /// interrupt it). The worker waits for it within the deadline; an
    /// abandoned lookup frees its own result when it finally returns.
    private static func resolve(host: String, port: Int, deadline: ContinuousClock.Instant,
                                isRunning: () -> Bool) -> Result<UnsafeMutablePointer<addrinfo>, HandshakeFailure> {
        let service = String(port)
        // No AI_NUMERICHOST shortcut for address literals: on an IPv6-only
        // network with NAT64, macOS's full getaddrinfo is what synthesizes
        // the IPv6 address for an IPv4 literal.
        let box = ResolutionBox()
        Thread.detachNewThread {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            var list: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, service, &hints, &list)
            let keep = box.outcome.withLock { o -> Bool in
                guard !o.abandoned else { return false }
                o.done = true
                o.rc = rc
                o.list = Int(bitPattern: list)
                return true
            }
            if !keep, let list { freeaddrinfo(list) }
            box.finished.signal()
        }
        let clock = ContinuousClock()
        while true {
            let outcome = box.outcome.withLock { $0 }
            if outcome.done {
                guard outcome.rc == 0, let list = UnsafeMutablePointer<addrinfo>(bitPattern: outcome.list) else {
                    return .failure(.message("Failed to resolve hostname \(host) (\(String(cString: gai_strerror(outcome.rc))))"))
                }
                return .success(list)
            }
            let running = isRunning()
            if !running || clock.now >= deadline {
                // Abandon it — unless it finished this instant, then free it.
                let late = box.outcome.withLock { o -> Int in
                    o.abandoned = true
                    return o.done ? o.list : 0
                }
                if let list = UnsafeMutablePointer<addrinfo>(bitPattern: late) { freeaddrinfo(list) }
                return .failure(running ? .message("Timeout resolving \(host)") : .stopped)
            }
            // Woken the moment the lookup ends; the slices keep Stop and
            // the deadline checked.
            _ = box.finished.wait(timeout: .now() + .milliseconds(200))
        }
    }

    private static func openTCP(host: String, port: Int, deadline: ContinuousClock.Instant,
                                isRunning: () -> Bool) -> Result<Int32, HandshakeFailure> {
        let list: UnsafeMutablePointer<addrinfo>
        switch resolve(host: host, port: port, deadline: deadline, isRunning: isRunning) {
        case .success(let resolved): list = resolved
        case .failure(let failure): return .failure(failure)
        }
        let first = list
        defer { freeaddrinfo(list) }
        let clock = ContinuousClock()
        var lastError = "Connection refused"
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            cursor = info.pointee.ai_next
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            // Close-on-exec: a local shell tab forked later must not hold a
            // copy of this socket, or closing the tab sends no FIN and the
            // device's VTY stays taken ("All lines busy").
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var on: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Disable Nagle: an interactive terminal wants keystrokes on the
            // wire immediately, not after a 40 ms buffering delay.
            _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { return .success(fd) }
            guard errno == EINPROGRESS else {
                lastError = String(cString: strerror(errno))
                close(fd)
                continue
            }
            // With another address still to try, this one gets 5 s, not the
            // whole budget: a black-holed IPv6 (SYNs dropped, no RST) must
            // not use up the time the working IPv4 address needed.
            let isLast = cursor == nil
            let addressDeadline = isLast ? deadline : min(deadline, clock.now.advanced(by: .seconds(5)))
            while true {
                guard isRunning() else { close(fd); return .failure(.stopped) }
                let left = clock.now.duration(to: addressDeadline)
                if left <= .zero {
                    if !isLast, clock.now < deadline { lastError = "timed out"; break }
                    close(fd)
                    return .failure(.message("Timeout connecting to \(host)"))
                }
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ms = Int32(min(200, max(1, left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000)))
                let ready = poll(&p, 1, ms)
                if ready < 0, errno != EINTR { lastError = String(cString: strerror(errno)); break }
                if ready <= 0 { continue }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                if error == 0 { return .success(fd) }
                lastError = String(cString: strerror(error))
                break
            }
            close(fd)
        }
        return .failure(.message("Failed to connect: \(lastError)"))
    }

    // MARK: Host key

    static let hostKeyRefusedPrefix = "host key refused: "
    /// Starts the message of a session that ENDED (the shell exited or the
    /// device closed it) rather than dropped; only `closeSession(…,
    /// endedNormally: true)` may produce it.
    static let sessionEndedPrefix = "Connection to "

    /// ~/.ssh from the passwd entry, like libssh (and OpenSSH) — not $HOME.
    static var sshDirectory: String {
#if SHEEPTERM_TESTING
        if let dir = _testSSHDirectory { return dir }
#endif
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir) + "/.ssh"
        }
        return NSHomeDirectory() + "/.ssh"
    }

    /// The system-wide file libssh (and OpenSSH) also consult. Read-only for
    /// us: a key found there is trusted, never copied to ~/.ssh.
    static let globalKnownHostsPath = "/etc/ssh/ssh_known_hosts"

    /// Both known_hosts files, parsed ONCE per connect: the pinned key types
    /// and the host-key check read the same snapshot.
    nonisolated struct KnownHostsFiles: Sendable {
        /// nil when ~/.ssh/known_hosts exists but cannot be read (fail closed).
        let user: KnownHosts?
        /// nil when missing or unreadable — the system file is not ours to
        /// fix, and OpenSSH ignores it then too.
        let global: KnownHosts?

        func pinnedKeyTypes(host: String, port: Int) -> [String] {
            var types = user?.pinnedKeyTypes(host: host, port: port) ?? []
            for type in global?.pinnedKeyTypes(host: host, port: port) ?? [] where !types.contains(type) {
                types.append(type)
            }
            return types
        }
    }

    static func loadKnownHosts(userPath: String = sshDirectory + "/known_hosts",
                               globalPath: String? = globalKnownHostsPath) -> KnownHostsFiles {
        func parse(_ path: String) -> KnownHosts? {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return KnownHosts(text: String(decoding: data, as: UTF8.self))
        }
        let user = FileManager.default.fileExists(atPath: userPath) ? parse(userPath) : KnownHosts(text: "")
        return KnownHostsFiles(user: user, global: globalPath.flatMap(parse))
    }

    nonisolated enum HostKeyVerdict: Equatable, Sendable {
        case trusted
        /// Not pinned anywhere: ask the user (`hostKeyPrompt`); only on
        /// "trust" is it saved to ~/.ssh (`trustOnFirstUse`).
        case firstSeen
        /// Starts with `hostKeyRefusedPrefix`.
        case refused(String)
    }

    /// The whole trust decision, as OpenSSH makes it over its two files: a
    /// match in EITHER file trusts the key, @revoked in either refuses it,
    /// and a pin found only in the system file is enforced (the user cannot
    /// clear it — an administrator must). Pure, so the rules are tested.
    static func hostKeyVerdict(user: KnownHosts.Result, global: KnownHosts.Result) -> HostKeyVerdict {
        // Every refusal starts with `hostKeyRefusedPrefix`: the controller
        // keys on it to give the tab a status auto-reconnect leaves alone. A
        // refused host key is a decision, not a link drop — retried, it
        // re-raised the MITM warning three times and spent the reconnect
        // budget on a device that would never be trusted that way.
        if case .revoked(let line) = user {
            return .refused(hostKeyRefusedPrefix + "⚠️ this host key is marked @revoked on line \(line) of ~/.ssh/known_hosts — refusing it.")
        }
        if case .revoked(let line) = global {
            return .refused(hostKeyRefusedPrefix + "⚠️ this host key is marked @revoked on line \(line) of \(globalKnownHostsPath) — refusing it.")
        }
        if case .ok = user { return .trusted }
        if case .ok = global { return .trusted }
        // Same type, different key (in either file) outranks a type change:
        // it is the stronger signal, and naming the user's type-change line
        // first would send them to delete a line that cannot clear it.
        switch (user, global) {
        case (.changed(let lines), _):
            return .refused(hostKeyRefusedPrefix + changedWarning + removalHint(lines: lines, reason: "reinstalled"))
        case (_, .changed(let lines)):
            return .refused(hostKeyRefusedPrefix + changedWarning + systemPinHint(lines: lines))
        case (.otherType(_, let lines), _):
            // A key of a type while we had another type recorded. A MITM that
            // offers only a key TYPE the victim has not pinned (the device is
            // pinned as ed25519; the attacker presents its own RSA key and
            // drops the ed25519 offer) lands exactly here. OpenSSH asks; we
            // refuse and say how to proceed (the first-use dialog is for a
            // host with NO pinned key — this host has one) —
            // the same shape as CHANGED, which is the same attack with the
            // same key type.
            return .refused(hostKeyRefusedPrefix + typeChangedWarning("~/.ssh/known_hosts")
                + removalHint(lines: lines, reason: "upgraded or reinstalled"))
        case (_, .otherType(_, let lines)):
            return .refused(hostKeyRefusedPrefix + typeChangedWarning(globalKnownHostsPath) + systemPinHint(lines: lines))
        default:
            return .firstSeen
        }
    }

    private static let changedWarning = "⚠️ HOST KEY CHANGED — possible man-in-the-middle. "

    private static func typeChangedWarning(_ file: String) -> String {
        "⚠️ HOST KEY TYPE CHANGED — the server offers a key of a type that is not the one pinned in \(file) "
            + "(possible man-in-the-middle). "
    }

    /// "line 5" / "lines 3, 9" over `sorted` (deduplicated, ascending).
    private static func lineList(sorted: [Int]) -> String? {
        guard !sorted.isEmpty else { return nil }
        return sorted.count == 1 ? "line \(sorted[0])" : "lines " + sorted.map(String.init).joined(separator: ", ")
    }

    private static func systemPinHint(lines: [Int]) -> String {
        let which = lineList(sorted: Array(Set(lines)).sorted()).map { " (\($0))" } ?? ""
        return "The pinned key is in the system-wide \(globalKnownHostsPath)\(which); if the device was reinstalled, "
            + "an administrator must update that file."
    }

    static let unreadableKnownHostsRefusal = hostKeyRefusedPrefix
        + "cannot read ~/.ssh/known_hosts — refusing to trust any host key. Fix or remove the file, then reconnect."

    /// What the first-connection trust question shows. Everything the user
    /// needs to compare against the device's own `show ssh server host-key`
    /// / `ssh-keygen -lf` output.
    nonisolated struct HostKeyQuestion: Sendable, Equatable {
        let host: String
        let port: Int
        /// "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", …
        let keyType: String
        /// OpenSSH's form: "SHA256:" + unpadded base64 of SHA-256(key blob).
        let fingerprint: String

        /// "host" on port 22, "host:port" otherwise ("[v6]:port" for an
        /// IPv6 literal, so the port cannot read as part of the address).
        var target: String {
            if port == 22 { return host }
            return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        }
    }

    nonisolated enum HostKeyAnswer: Sendable, Equatable {
        /// "Trust & Connect": pin the key, carry on with the handshake.
        case trust
        /// "Cancel": nothing is written, the session ends.
        case cancel
        /// The session was stopped while the question was open.
        case stopped
    }

    /// The fingerprint `ssh-keygen -lf` prints for the same key (SHA-256 is
    /// CryptoKit's, inside SheepSSH's `SSHHash`).
    static func fingerprint(of key: SSHPublicKey) -> String { key.fingerprintSHA256 }

    static func hostKeyQuestion(key: SSHPublicKey, host: String, port: Int) -> HostKeyQuestion {
        HostKeyQuestion(host: host, port: port, keyType: key.keyType, fingerprint: fingerprint(of: key))
    }

    /// How a first-seen key ended up.
    nonisolated enum FirstUseOutcome: Sendable, Equatable {
        /// The file trusts it now (another tab pinned this very key while we
        /// were connecting or while the question was open). Nothing written.
        case alreadyTrusted
        /// The user said yes and the key was appended.
        case saved
        /// The user said yes; the key is trusted for this session only.
        case notSaved(String)
        /// Starts with `hostKeyRefusedPrefix` (a different key for the host
        /// appeared meanwhile, or the file became unreadable).
        case refused(String)
        /// The user said no. Nothing written.
        case declined
        /// The session was stopped while the question was open. Nothing written.
        case stopped
    }

    /// Trust on first use WITH consent — the whole decision, minus the UI, so
    /// the harness drives the real thing. `global` is the system file's
    /// answer; `path` is ~/.ssh/known_hosts.
    ///
    /// 1. Look at the user file as it is NOW (the connect-time snapshot can
    ///    be seconds old): a key another tab pinned since, or a conflicting
    ///    one, is decided without asking.
    /// 2. Ask. Nothing has been written and no credential has been sent.
    /// 3. On "trust", `pinFirstUse` decides AGAIN under the file lock and
    ///    appends in the same breath: the dialog can stay open for minutes,
    ///    and a different key appearing for the host in that time is a
    ///    CHANGED refusal, not a second pin.
    static func trustOnFirstUse(key: SSHPublicKey, host: String, port: Int, global: KnownHosts.Result,
                                path: String, ask: (HostKeyQuestion) -> HostKeyAnswer) -> FirstUseOutcome {
        var now = KnownHosts(text: "")
        if FileManager.default.fileExists(atPath: path) {
            guard let data = FileManager.default.contents(atPath: path) else {
                return .refused(unreadableKnownHostsRefusal)
            }
            now = KnownHosts(text: String(decoding: data, as: UTF8.self))
        }
        switch hostKeyVerdict(user: now.lookup(host: host, port: port, key: key), global: global) {
        case .trusted: return .alreadyTrusted
        case .refused(let why): return .refused(why)
        case .firstSeen: break
        }
        switch ask(hostKeyQuestion(key: key, host: host, port: port)) {
        case .cancel: return .declined
        case .stopped: return .stopped
        case .trust: break
        }
        let (verdict, saveError) = pinFirstUse(key: key, host: host, port: port, global: global, path: path)
        switch verdict {
        case .trusted: return .alreadyTrusted
        case .refused(let why): return .refused(why)
        case .firstSeen: return saveError.map { .notSaved($0) } ?? .saved
        }
    }

    /// The close message for a declined first-seen key. Starts with
    /// "connection cancelled" on purpose: the controller turns that into
    /// "disconnected — cancelled", which auto-reconnect leaves alone (it
    /// would otherwise put the same question straight back up).
    static func declinedHostKeyMessage(_ q: HostKeyQuestion) -> String {
        "connection cancelled — host key not trusted: \(q.target) \(q.keyType) \(q.fingerprint) (nothing was saved)"
    }

#if SHEEPTERM_TESTING
    /// The worker harness points ~/.ssh at a scratch directory, so nothing it
    /// does can reach the real known_hosts.
    nonisolated(unsafe) static var _testSSHDirectory: String?
#endif

    /// nil when the key is trusted (known, or first seen and accepted);
    /// otherwise why not: `.hostKey` (a refusal, starting with
    /// `hostKeyRefusedPrefix`), `.message` (the user declined) or `.stopped`.
    /// `waited` is told how long the user took to answer.
    private func verifyHostKey(_ key: SSHPublicKey, host: String, port: Int, files: KnownHostsFiles,
                               waited: (Duration) -> Void) -> HandshakeFailure? {
        // Fail closed: an unreadable known_hosts must never look like "first
        // connection" — that would silently disable MITM protection and
        // overwrite the stored key.
        guard let user = files.user else { return .hostKey(Self.unreadableKnownHostsRefusal) }
        let global = files.global?.lookup(host: host, port: port, key: key) ?? KnownHosts.Result.notFound
        switch Self.hostKeyVerdict(user: user.lookup(host: host, port: port, key: key), global: global) {
        case .trusted: return nil
        case .refused(let why): return .hostKey(why)
        case .firstSeen: break
        }
        guard isRunning else { return .stopped }
        let question = Self.hostKeyQuestion(key: key, host: host, port: port)
        // No way to ask is no consent: refuse rather than pin silently.
        guard let prompt = hostKeyPrompt else {
            return .hostKey(Self.hostKeyRefusedPrefix + "first connection to \(question.target) — "
                + "\(question.keyType) \(question.fingerprint) is not in known_hosts and there is no way to ask "
                + "whether to trust it. Nothing was saved.")
        }
        let outcome = Self.trustOnFirstUse(key: key, host: host, port: port, global: global,
                                           path: Self.sshDirectory + "/known_hosts") { q in
            let clock = ContinuousClock()
            let asked = clock.now
            defer { waited(asked.duration(to: clock.now)) }
            let answer = prompt(q) { [weak self] in !(self?.isRunning ?? false) }
            // A stop that landed while the question was open wins over the
            // answer: the tab is gone, nothing may be pinned on its behalf.
            return isRunning ? answer : .stopped
        }
        let id = "\(question.keyType) \(question.fingerprint)"
        switch outcome {
        case .alreadyTrusted:
            return nil
        case .saved:
            notice("first connection — host key \(id) trusted and saved to known_hosts")
            return nil
        case .notSaved(let why):
            // A failed save must not be silent — the user would otherwise
            // believe the key is pinned when it isn't.
            notice("first connection — host key \(id) trusted for this session but could NOT be saved to known_hosts: \(why)")
            return nil
        case .refused(let why):
            return .hostKey(why)
        case .declined:
            return .message(Self.declinedHostKeyMessage(question))
        case .stopped:
            return .stopped
        }
    }

    /// Trust on first use, race-free: under an exclusive flock on the file
    /// (which also serializes two tabs — flock is per open, not per
    /// process — and any other flock-ing client), re-read it, decide again
    /// and append only if the key is still unknown. Two tabs meeting a new
    /// device at once can therefore not each pin a different key (the
    /// second, possibly a MITM's, would then be trusted forever).
    /// Creates the directory (0700) and the file (0600) when missing.
    static func pinFirstUse(key: SSHPublicKey, host: String, port: Int, global: KnownHosts.Result,
                            path: String) -> (verdict: HostKeyVerdict, saveError: String?) {
        let directory = (path as NSString).deletingLastPathComponent
        // EEXIST: another tab (or program) made it a moment ago — fine.
        if !FileManager.default.fileExists(atPath: directory), mkdir(directory, 0o700) != 0, errno != EEXIST {
            return (.firstSeen, String(cString: strerror(errno)))
        }
        var writable = true
        var fd = open(path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        let openErrno = errno
        if fd < 0, openErrno == EACCES || openErrno == EROFS || openErrno == EPERM {
            // Read-only on purpose? Still decide on what it says.
            writable = false
            fd = open(path, O_RDONLY | O_CLOEXEC)
        }
        guard fd >= 0 else {
            // The create's error, not the read-only fallback's ENOENT: a
            // non-writable ~/.ssh is "Permission denied".
            let why = String(cString: strerror(openErrno))
            return FileManager.default.fileExists(atPath: path) ? (.refused(unreadableKnownHostsRefusal), nil) : (.firstSeen, why)
        }
        defer { close(fd) }

        // The file lock first, waited on by each tab for itself (in
        // parallel, never queued behind another tab's wait): this runs
        // inside the handshake, where neither Stop nor the connect deadline
        // reaches, so it must not wait forever.
        let clock = ContinuousClock()
        let giveUp = clock.now.advanced(by: knownHostsLockWait)
        var locked = false, lockTimedOut = false
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            let e = errno
            if e == EINTR { continue }
            guard e == EWOULDBLOCK || e == EAGAIN else { break }     // no flock here: the in-app lock stands
            if clock.now >= giveUp { lockTimedOut = true; break }
            usleep(50_000)
        }
        defer { if locked { _ = flock(fd, LOCK_UN) } }
        // Then the in-app lock, held only for read-decide-append: tabs are
        // serialized even where the file system refuses flock.
        return pinLock.withLock { _ -> (verdict: HostKeyVerdict, saveError: String?) in
            var text = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = chunk.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(text.count)) }
                if n > 0 { text.append(contentsOf: chunk[0..<n]); continue }
                if n < 0, errno == EINTR { continue }
                if n < 0 { return (.refused(unreadableKnownHostsRefusal), nil) }
                break
            }
            // Decided on the file as it is now even when its lock could not
            // be had: a key another tab pinned meanwhile still wins.
            let current = KnownHosts(text: String(decoding: text, as: UTF8.self))
            let verdict = hostKeyVerdict(user: current.lookup(host: host, port: port, key: key), global: global)
            guard verdict == .firstSeen else { return (verdict, nil) }
            guard writable else { return (.firstSeen, "the file is read-only") }
            // Nothing is written without the lock.
            guard !lockTimedOut else { return (.firstSeen, "another program holds ~/.ssh/known_hosts locked") }

            var bytes = Array(KnownHosts.line(host: host, port: port, key: key).utf8)
            if let last = text.last, last != 0x0A { bytes.insert(0x0A, at: 0) }
            // A write cut short is NOT rolled back: OpenSSH's ssh does not
            // flock, and no check-then-truncate is atomic against its
            // appends — a truncate could cut its line and silently unpin a
            // host. The torn bytes are harmless: the parser skips a
            // malformed line, and the next append starts on a fresh line.
            var written = 0
            while written < bytes.count {
                let n = bytes[written...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n > 0 { written += n; continue }
                if n < 0, errno == EINTR { continue }
                return (.firstSeen, n < 0 ? String(cString: strerror(errno)) : "the disk took no more bytes")
            }
            return (.firstSeen, nil)
        }
    }

    private static let pinLock = Mutex(())
    /// How long to wait for another program's lock on known_hosts.
    static let knownHostsLockWait: Duration = .seconds(5)

    /// How to clear a stale pin, by LINE NUMBER. Pointing at `ssh-keygen -R`
    /// sent people into a dead end: OpenSSH 10's ssh-keygen calls any
    /// `ssh-dss` line invalid and then refuses to rewrite the file at all —
    /// and a DSA pin is exactly what an old switch leaves behind. Deleting the
    /// numbered line works whatever the file holds (hashed names included).
    static func removalHint(lines: [Int], reason: String) -> String {
        let sorted = Array(Set(lines)).sorted()
        guard let which = lineList(sorted: sorted) else {
            return "If the device was \(reason), remove its entry from ~/.ssh/known_hosts and reconnect."
        }
        let command = "sed -i '' " + sorted.map { "-e '\($0)d'" }.joined(separator: " ") + " ~/.ssh/known_hosts"
        return "The pinned key is on \(which) of ~/.ssh/known_hosts. If the device was \(reason), delete "
            + (sorted.count == 1 ? "that line" : "those lines") + " (\(command)) and reconnect."
    }

    // MARK: Authentication

    /// None, then public keys (ssh-agent, then ~/.ssh/id_ed25519, id_ecdsa,
    /// id_rsa — what libssh's publickey_auto tried), then up to three rounds
    /// of password + keyboard-interactive.
    private func authenticate(_ link: SSHLink, _ config: SSHConfig, legacy: Bool, wake: Int32) -> Bool {
        let auth = SSHUserAuth(transport: link.transport, username: config.username)
        hostKeyRefusedDuringAuth = nil
        // Replies park on the link and are taken one at a time, so whatever
        // follows USERAUTH_SUCCESS in the same read (OpenSSH sends
        // hostkeys-00@openssh.com right after it) stays parked for the
        // connection layer.
        link.parkMessages()
        /// Set once a credential has actually been REFUSED by a live server.
        /// After that, a dropped connection is almost certainly the server
        /// hanging up on too many failures — sshd does exactly that at
        /// MaxAuthTries — and calling that a transport failure would send
        /// auto-reconnect back with the same wrong password.
        var credentialRefused = false

        /// Whether the last drop was the server hanging up (not a timeout).
        var lastDropWasHangUp = false
        /// Runs `start`, then pumps until the userauth layer answers (banners
        /// are skipped — libssh never showed them either). nil = stop
        /// authenticating: tab closed, or the transport died (recorded in
        /// `authTransportError` unless a credential was already refused).
        /// `waitsForPerson`: the answer may wait on a human or a slow
        /// backend — a password or challenge checked against RADIUS/TACACS
        /// with retries, a Duo push approved on a phone — so it gets 90 s,
        /// not the 15 s a plain protocol reply gets.
        func exchange(waitsForPerson: Bool = false, _ start: () throws -> Void) -> [SSHUserAuth.Event]? {
            do {
                try start()
            } catch {
                return transportDied(error)
            }
            var events: [SSHUserAuth.Event] = []
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(waitsForPerson ? 90 : 15))
            while true {
                while events.isEmpty, let payload = link.nextParked() {
                    do {
                        events += try auth.handle(payload).filter { if case .banner = $0 { return false }; return true }
                    } catch {
                        return transportDied(error)
                    }
                }
                if !events.isEmpty { return events }
                guard isRunning else { return nil }
                if clock.now >= deadline { return transportDied(SSHLink.Failure.socket("timed out waiting for the server")) }
                do {
                    try link.step(timeoutMS: 200, wake: wake, extra: [])
                } catch {
                    return transportDied(error)
                }
            }
        }
        func transportDied(_ error: Error) -> [SSHUserAuth.Event]? {
            if let refusal = Self.hostKeyRefusal(in: error), isRunning {
                hostKeyRefusedDuringAuth = refusal
                return nil
            }
            if case SSHLink.Failure.closedByPeer = error { lastDropWasHangUp = true }
            if case .disconnectedByServer? = error as? SSHTransportError { lastDropWasHangUp = true }
            if case .transport(.disconnectedByServer)? = error as? UserAuthError { lastDropWasHangUp = true }
            if isRunning, !credentialRefused {
                authTransportError = "connection lost during authentication: \(Self.describe(error))"
            }
            return nil
        }

        // Stop before each attempt when the tab was closed.
        guard isRunning else { return false }
        guard let service = exchange({ try auth.requestService() }), service.contains(.serviceAccepted) else { return false }
        guard isRunning, let none = exchange({ try auth.tryNone() }) else { return false }
        if none.contains(.success) { return true }
        var methods: [String] = []
        if case .failure(_, let offered, _)? = none.first { methods = offered }

        // One loop, driven by what the server offers NOW (its list after
        // every answer): keys while it takes publickey and some are left,
        // then password and keyboard-interactive — only those it lists (a
        // method it does not list always fails and still counts against
        // MaxAuthTries). An empty list tells us nothing: try all, as libssh
        // did. A partial success (sshd AuthenticationMethods) is not a
        // refusal: the loop simply follows the new list — password,publickey
        // goes back for a key, publickey,keyboard-interactive to the OTP.
        func offers(_ method: String) -> Bool { methods.isEmpty || methods.contains(method) }
        func note(_ events: [SSHUserAuth.Event]) -> (success: Bool, partial: Bool) {
            if events.contains(.success) { return (true, false) }
            if case .failure(_, let next, let partial)? = events.first {
                if !next.isEmpty { methods = next }
                return (false, partial)
            }
            return (false, false)
        }

        // Keys: the agent's, then ~/.ssh/id_*, each asked about first so an
        // agent is not asked to sign for a key the server will refuse. A key
        // is marked tried only when actually offered (the next factor of
        // publickey,publickey needs a different one).
        let preferences: AlgorithmPreferences = legacy ? .legacy : .modern
        var signers: [SSHSigner]?
        var tried = Set<[UInt8]>()
        var keysRefused = 0
        func loadSigners() -> [SSHSigner] {
            if let signers { return signers }
            var loaded: [SSHSigner] = []
            if let socket = SSHAgent.socketPath, let identities = try? SSHAgent.identities(socketPath: socket) {
                // A signature may wait up to a minute for the user's
                // approval; closing the tab must still end it.
                for identity in identities { identity.shouldCancel = { [weak self] in !(self?.isRunning ?? false) } }
                loaded += identities
            }
            for entry in DefaultIdentities.load(directory: Self.sshDirectory) {
                if case .ready(let signer) = entry { loaded.append(signer) }
            }
            signers = loaded
            return loaded
        }
        func keyStage() -> AuthStep {
            for signer in loadSigners() where !tried.contains(signer.publicKey.blob) {
                guard isRunning else { return .stop }
                guard offers("publickey") else { return .exhausted }
                tried.insert(signer.publicKey.blob)
                guard let algorithm = publicKeyAlgorithm(for: signer.publicKey, accepted: preferences.hostKeys,
                                                         serverSignatureAlgorithms: link.transport.serverSignatureAlgorithms)
                else { continue }
                guard let query = exchange({ try auth.queryPublicKey(signer.publicKey, algorithm: algorithm) }) else { return .stop }
                guard query.contains(.publicKeyAcceptable(signer.publicKey)) else {
                    // Not a refused CREDENTIAL (the user typed nothing): a
                    // later drop stays "connection lost"; only a hang-up
                    // right here gets the MaxAuthTries hint below.
                    keysRefused += 1
                    _ = note(query)
                    continue
                }
                var signError: Error?
                guard let result = exchange({
                    do { try auth.tryPublicKey(signer, algorithm: algorithm) } catch UserAuthError.signer(let e) { signError = e; throw e }
                }) else {
                    if signError != nil, isRunning {
                        // The agent (or key) could not sign: not a dead link.
                        authTransportError = nil
                        notice("\(signer.label): could not sign — skipped")
                        continue
                    }
                    return .stop
                }
                let outcome = note(result)
                if outcome.success { notice("authenticated with public key"); return .success }
                if outcome.partial { return .partial }
            }
            return .exhausted
        }

        /// The password, once the server has accepted it (as the login or as
        /// one factor of several): saved once, when the whole login succeeds.
        var passwordToSave: String?
        func succeeded() -> Bool {
            if let passwordToSave { onPasswordWorked?(config.username, passwordToSave) }
            return true
        }
        var password = config.password
        /// Whether an already-accepted password may answer a later password
        /// prompt; off once a round failed that way.
        var reuseAccepted = true
        var acceptedReuseFailures = 0
        /// The server said the password expired (PASSWD_CHANGEREQ).
        var changeRequested = false
        /// Asked for only when something will actually use it.
        func needPassword() -> String? {
            if let password, !password.isEmpty { return password }
            guard let entered = passwordPrompt?("Password for \(config.username)@\(config.host)"), !entered.isEmpty else {
                authCancelled = true
                return nil
            }
            password = entered
            return entered
        }

        /// Ends the attempt after a failed exchange; when the server hung up
        /// after refusing keys, says the likely cause (MaxAuthTries is spent
        /// by every refused key, before any password is typed).
        func hungUp() -> Bool {
            if keysRefused > 0, lastDropWasHangUp, isRunning {
                notice("the server hung up after refusing \(keysRefused) key(s) — too many keys in the agent for its MaxAuthTries?")
            }
            return false
        }

        var failedRounds = 0
        // Bounded however the server answers: one that says "partial
        // success" forever must not spin this loop.
        for _ in 0..<24 {
            guard isRunning else { return false }

            if offers("publickey") {
                switch keyStage() {
                case .success: return succeeded()
                case .partial: continue
                case .stop:
                    return hungUp()
                case .exhausted: break
                }
            }

            let tryPassword = offers("password") && passwordToSave == nil
            let tryInteractive = offers("keyboard-interactive")
            guard tryPassword || tryInteractive else {
                notice("the server accepts only: \(methods.joined(separator: ", ")) — no key it takes was found")
                return false
            }

            if tryPassword {
                guard let currentPassword = needPassword() else { return false }
                guard let result = exchange(waitsForPerson: true, { try auth.tryPassword(currentPassword) }) else { return hungUp() }
                if case .passwordChangeRequested? = result.first {
                    // The password method cannot change it (SheepTerm does not
                    // speak PASSWD_CHANGEREQ). Keyboard-interactive can — PAM
                    // asks "New password:" there — so go on if offered; else
                    // every further try would fail and count toward lockout.
                    credentialRefused = true
                    changeRequested = true
                    guard offers("keyboard-interactive") else {
                        notice("the device says this password has expired — change it on the device, then reconnect")
                        return false
                    }
                } else {
                    let outcome = note(result)
                    if outcome.success { passwordToSave = currentPassword; return succeeded() }
                    if outcome.partial { passwordToSave = currentPassword; continue }
                    // The server ANSWERED: a hang-up after this is
                    // MaxAuthTries, not the network.
                    credentialRefused = true
                }
            }

            var usedPassword = false
            var answeredWithAccepted = false
            /// The user typed something this round (an OTP, a new password).
            var typedAnswer = false
            /// What the user typed at "New password:" — the password from
            /// now on, if the change goes through.
            var newPassword: String?
            // Same round, same password, into keyboard-interactive after the
            // password method refused it — kept on purpose (as libssh did):
            // TACACS gear often lists both and only takes it this way.
            if tryInteractive, offers("keyboard-interactive") {
                // Old network gear + TACACS very often use it. Rounds that
                // asked nothing: a server may send one informational round
                // before the real one; one that sends them forever would pin
                // the tab in an exchange only closing it could end.
                var emptyRounds = 0
                // The first reply may already wait on AAA failover or a push.
                guard var interactive = exchange(waitsForPerson: true, { try auth.startKeyboardInteractive() }) else { return hungUp() }
                while case .infoRequest(let request)? = interactive.first {
                    guard isRunning else { return false }
                    if request.prompts.isEmpty {
                        emptyRounds += 1
                        if emptyRounds > 8 {
                            notice("keyboard-interactive: the server keeps asking nothing — giving up")
                            return false
                        }
                    }
                    var answers: [String] = []
                    for prompt in request.prompts {
                        let normalized = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let kind = Self.classifyPrompt(normalized)
                        let asksAdditionalFactor = kind.additionalFactor
                        // "New password:" / "Retype new password:" (a PAM
                        // expiry flow) must come from the user: answering
                        // them with the old one fails, or quietly "changes"
                        // it to itself.
                        let asksNewPassword = kind.newPassword
                        let isPasswordPrompt = !prompt.echo
                            && (normalized.contains("password") || (request.prompts.count == 1 && normalized.isEmpty))
                            && !asksAdditionalFactor && !asksNewPassword
                        // The password answers a password prompt: the one the
                        // server already accepted as an earlier factor, else
                        // the known one, else asked for here.
                        if isPasswordPrompt {
                            if let accepted = passwordToSave, reuseAccepted {
                                answers.append(accepted)
                                answeredWithAccepted = true
                            } else if passwordToSave != nil {
                                // A round already failed with it: this prompt
                                // wants something else (a second backend).
                                let display = prompt.text.isEmpty ? "Password for \(config.username)@\(config.host)" : prompt.text
                                guard let entered = challengePrompt?(display, true) else {
                                    authCancelled = true
                                    return false
                                }
                                answers.append(entered)
                            } else {
                                guard let currentPassword = needPassword() else { return false }
                                answers.append(currentPassword)
                                usedPassword = true
                            }
                        } else {
                            let display = prompt.text.isEmpty
                                ? "Authentication challenge for \(config.username)@\(config.host)"
                                : prompt.text
                            guard let entered = challengePrompt?(display, !prompt.echo) else {
                                authCancelled = true
                                return false
                            }
                            answers.append(entered)
                            typedAnswer = true
                            if asksNewPassword, !prompt.echo { newPassword = entered }
                        }
                    }
                    guard let next = exchange(waitsForPerson: true, { try auth.respond(answers) }) else { return hungUp() }
                    interactive = next
                }
                let outcome = note(interactive)
                // Only a password that actually answered is saved: a denied
                // password followed by a successful OTP challenge used to
                // cache the DENIED one.
                if outcome.success || outcome.partial, usedPassword { passwordToSave = password }
                if outcome.success || outcome.partial, let newPassword {
                    passwordToSave = newPassword
                    password = newPassword
                    notice("password changed on the device — if this host uses a saved credential, update it there too")
                }
                if outcome.success { return succeeded() }
                if outcome.partial { continue }
                credentialRefused = true
                // The accepted password is suspect at once when it was all
                // that was sent; with a code typed too, the code was likely
                // wrong — but not twice (a second backend may want another).
                if answeredWithAccepted {
                    acceptedReuseFailures += 1
                    if !typedAnswer || acceptedReuseFailures >= 2 { reuseAccepted = false }
                }
            }

            if changeRequested {
                // Keyboard-interactive could not change it either: every
                // further round would fail too and count toward lockout.
                notice("the device says this password has expired — change it on the device, then reconnect")
                return false
            }
            failedRounds += 1
            if failedRounds >= 3 { return false }
            notice("authentication failed — try again")
            // Re-ask the password only if it may be what was wrong: not when
            // only a one-time code was refused.
            if tryPassword || usedPassword { password = nil }
        }
        notice("authentication did not converge — giving up")
        return false
    }

    // MARK: Channel setup helpers

    /// Pumps until `done(events so far)`; connection events are collected
    /// into `collecting` (the caller replays the ones it did not consume).
    private func waitFor(_ link: SSHLink, _ connection: SSHConnection, wake: Int32,
                         collecting: inout [SSHConnection.Event],
                         until done: ([SSHConnection.Event]) -> Bool) -> Result<Void, HandshakeFailure> {
        let clock = ContinuousClock()
        // 90 s, not 15: IOS/NX-OS hold the shell's CHANNEL_SUCCESS until
        // "aaa authorization exec" finishes, and a TACACS+ failover alone can
        // take longer than 15 s (OpenSSH sets no deadline here at all).
        let deadline = clock.now.advanced(by: .seconds(90))
        // What arrives meanwhile is held until setup ends; the window cannot
        // slow a server that floods instead of answering (it is topped up as
        // data arrives), so the hold is capped.
        var heldBytes = 0
        while true {
            let events = connection.takeEvents()
            for case .data(_, let bytes) in events { heldBytes += bytes.count }
            for case .extendedData(_, let bytes) in events { heldBytes += bytes.count }
            collecting += events
            if done(collecting) { return .success(()) }
            if heldBytes > 4 << 20 {
                return .failure(.message("the server sent more than 4 MiB before the session was set up"))
            }
            guard isRunning else { return .failure(.stopped) }
            if clock.now >= deadline { return .failure(.message("timed out waiting for the server")) }
            do {
                try link.step(timeoutMS: 200, wake: wake, extra: [])
            } catch {
                // What the link routed just before failing (the device's last
                // words, EOF, CLOSE) is kept for the caller to show.
                collecting += connection.takeEvents()
                return .failure(Self.handshakeFailure(error))
            }
        }
    }

    /// Sends a want-reply channel request and waits for its answer. nil means
    /// the session is over (already reported).
    private func requestAndWait(_ name: String, _ link: SSHLink, _ connection: SSHConnection, _ channel: UInt32,
                                wake: Int32, collecting: inout [SSHConnection.Event],
                                send: () throws -> Void) -> Bool? {
        /// Shows what the device printed (typically "All lines are busy" on a
        /// VTY-full box — the actual explanation) before a setup close.
        func showOutput() {
            for event in collecting {
                switch event {
                case .data(channel, let bytes), .extendedData(channel, let bytes): onData?(bytes)
                default: break
                }
            }
            collecting.removeAll { if case .data(channel, _) = $0 { return true }
                                   if case .extendedData(channel, _) = $0 { return true }; return false }
        }
        func channelEnded() -> Bool {
            collecting.contains { if case .closed(channel) = $0 { return true }; if case .eof(channel) = $0 { return true }; return false }
                || !connection.isOpen(channel)
        }
        if channelEnded() {
            showOutput()
            closeSession("the server closed the channel before \(name)")
            return nil
        }
        do {
            try send()
        } catch {
            if let refusal = Self.hostKeyRefusal(in: error) { closeSession(refusal, hostKeyRefusal: true); return nil }
            closeSession("\(name) failed: \(Self.describe(error))")
            return nil
        }
        var answer: Bool?
        let outcome = waitFor(link, connection, wake: wake, collecting: &collecting) { events in
            for event in events {
                if case .channelRequestReply(channel, name, let ok) = event { answer = ok; return true }
                if case .closed(channel) = event { return true }
            }
            return false
        }
        collecting.removeAll { if case .channelRequestReply(channel, name, _) = $0 { return true }; return false }
        switch outcome {
        case .failure(let failure):
            showOutput()
            report(failure, prefix: "\(name) failed: ")
            return nil
        case .success:
            // A reply and the close can arrive in one read: the reply alone
            // must not send the next request to a channel that is gone.
            guard let answer, !channelEnded() else {
                showOutput()
                closeSession("the server closed the channel during \(name)")
                return nil
            }
            return answer
        }
    }

    // MARK: Interactive phase

    private func deliver(_ event: SSHConnection.Event, channel: UInt32, forwarder: AgentForwarder?, connection: SSHConnection) {
        switch event {
        case .data(let id, let bytes) where id == channel:
            onData?(bytes)
        case .extendedData(let id, let bytes) where id == channel:
            // stderr goes to the terminal too, as it did.
            onData?(bytes)
        case .data(let id, let bytes):
            forwarder?.received(id, bytes, connection: connection)
        case .agentChannelOpened(let id):
            // No forwarder (the auth-agent-req was refused after the server
            // already opened one): close it, or the far end waits forever.
            if let forwarder {
                do { try forwarder.channelOpened(id, connection: connection) } catch {}
            } else {
                try? connection.close(id)
            }
        case .eof(let id) where id != channel:
            forwarder?.channelEOF(id)
        case .closed(let id) where id != channel:
            forwarder?.channelClosed(id)
        default:
            break
        }
    }

    /// Why the interactive loop ended. A host key refused on rekey must reach
    /// closeSession as a refusal (auto-reconnect stops), not as quoted text.
    nonisolated private struct LoopFailure {
        let message: String
        var hostKeyRefusal = false
    }

    /// Returns an error message when the session died from a local failure,
    /// nil for a normal/remote close.
    ///
    /// Waiting happens in poll() on the socket, the self-pipe and any agent
    /// sockets, so typing has zero added latency while idle wakeups stay at
    /// 1/sec.
    private func ioLoop(link: SSHLink, connection: SSHConnection, channel: UInt32, pipeRead: Int32,
                        forwarder: AgentForwarder?, watcher: SessionPathWatcher) -> LoopFailure? {
        // ContinuousClock, not Date: these are internal deadlines, and a wall
        // clock can jump (NTP, time zone, a laptop lid closed and reopened).
        let clock = ContinuousClock()
        var lastKeepalive = clock.now
        var lastAddressCheck = clock.now
        // Liveness. A link can die without anyone hanging up — a firewall that
        // drops the flow, a middlebox that keeps ACKing an association it has
        // already forgotten, an RST that arrives out of window during a flood
        // and is discarded. A black-holed session was once measured accepting
        // 328 typed lines over five and a half minutes with the status bar
        // still saying "ssh2".
        //
        // The probe is keepalive@openssh.com with want_reply, which RFC 4254
        // requires an answer to (REQUEST_FAILURE, since nobody knows the
        // name). Three of those with no inbound byte in between means the peer
        // is gone. (Under libssh every probe had to be sent twice — its
        // ssh_send_keepalive put nothing on the wire on alternate calls.
        // SheepSSH sends every one.)
        //
        //  - The first two probes go at 1 s and 15 s, so a session that lives
        //    a quarter of a minute is covered. A link that dies before THAT
        //    cannot be caught this way — there is no evidence yet that this
        //    device answers probes, and disconnecting on a guess is worse than
        //    the bug. TCP keepalive covers every peer that stops ACKing.
        //  - Arming on "any inbound after a probe" can be fooled by output
        //    that merely happened to arrive. Two answers inside a one-second
        //    window are asked for before the deadline is armed, so a device
        //    that ignores global requests is never held to it and never
        //    disconnected for being quiet — the one failure a liveness check
        //    must not have.
        var probesSinceInbound = 0
        var probeConfirmations = 0
        var replyWindowEnds: ContinuousClock.Instant?
        var probesSent = 0
        var armed: Bool { probeConfirmations >= 2 }
        func noteInbound() {
            if let window = replyWindowEnds, clock.now <= window {
                probeConfirmations += 1
                replyWindowEnds = nil
            }
            probesSinceInbound = 0
        }
        /// 1 s, then 15 s, then every 60 s.
        func probeDue() -> Bool {
            let waited = lastKeepalive.duration(to: clock.now)
            switch probesSent {
            case 0: return waited > .seconds(1)
            case 1: return waited > .seconds(14)
            default: return waited > .seconds(60)
            }
        }
        /// Channel data waiting for the server's window. Input is moved from
        /// the worker's (bounded) queue into the channel only while this is
        /// small, so a stalled link fills the bounded queue — and the user is
        /// told — instead of an unbounded one.
        let channelHighWater = 256 * 1024
        var lastProgress = clock.now
        /// Bytes the socket has accepted: progress is this moving, not the
        /// channel backlog shrinking (the backlog is refilled to the
        /// high-water mark every pass while input waits, and bytes sealed
        /// onto a wedged socket are not sent).
        var lastSocketBytes = link.socketBytesWritten
        /// The same for input waiting on the device's window: progress is
        /// channel DATA going out — our own keepalives every 60 s must not
        /// count, or they reset the clock just before it runs out.
        var lastWindowProgress = clock.now
        var lastDataSent = connection.dataSent(channel)
        /// Delivers every pending connection event; true when the session
        /// channel reached EOF or CLOSE.
        func drainEvents() -> Bool {
            var ended = false
            for event in connection.takeEvents() {
                deliver(event, channel: channel, forwarder: forwarder, connection: connection)
                switch event {
                case .eof(channel), .closed(channel): ended = true
                default: break
                }
            }
            return ended
        }

        link.route = { try connection.handle($0) }
        while isRunning {
            // The one network death the socket cannot report: this Mac moved
            // off the network the connection was established from, and no
            // interface holds the local address any more. Checked first —
            // the watcher's wake write made poll() return just now, and the
            // keepalive clocks further down own every slower death. The
            // path monitor stays silent when only the address changes (new
            // DHCP lease on the same subnet, a rotated IPv6 temporary
            // address), so look every 5 s as well — getifaddrs is tens of
            // µs; the verdict still waits out the watcher's grace.
            if lastAddressCheck.duration(to: clock.now) > .seconds(5) {
                lastAddressCheck = clock.now
                watcher.check()
            }
            if let lost = watcher.lostConnection() { return .init(message: lost) }
            do {
                if probeDue() {
                    try connection.sendKeepalive()
                    lastKeepalive = clock.now
                    probesSent += 1
                    probesSinceInbound += 1
                    replyWindowEnds = clock.now.advanced(by: .seconds(1))
                    if armed, probesSinceInbound >= 3 {
                        return .init(message: "no answer to three keepalives — connection lost")
                    }
                }

                // Events first: after the server's CLOSE the channel is gone,
                // and a write or resize to it would turn a normal logout
                // into an error.
                if drainEvents() || !connection.isOpen(channel) { return nil }

                // Everything not yet on the socket counts: bytes the
                // transport holds during a rekey the server never finishes,
                // or sealed bytes a black-holed socket will not take, must
                // not grow unseen (or dodge the stall check below). Agent
                // replies may go AgentForwarder.maximumUnsent above this, so
                // a paste never starves a signature request. (Input is one
                // FIFO: a Ctrl-C typed during a paste still follows the rest
                // of the paste — this bounds only what is past the queue.)
                // Refill in packet-sized steps, not whatever the socket just
                // took: a slow link would otherwise seal a stream of tiny
                // packets, each with its own header, padding and MAC.
                let room = channelHighWater - connection.pendingOutput(channel) - link.unsentBytes
                if room >= SSHConnection.maxPacket {
                    let writes = takeWrites(limit: room)
                    if !writes.isEmpty { try connection.write(channel, writes) }
                }
                // Stall deadline, not a batch deadline: a big paste on a slow
                // link needs steady progress, which is fine — only give up
                // when NOTHING reaches the socket for 60 s while bytes are
                // sealed for it (or held by a rekey that never finishes).
                let sealedWaiting = link.unsentBytes > 0
                if !sealedWaiting || link.socketBytesWritten > lastSocketBytes { lastProgress = clock.now }
                lastSocketBytes = link.socketBytesWritten
                // Input waiting only for the device's window is flow control
                // while keepalive replies prove the device alive (a switch in
                // a two-minute `write memory` stops reading). With nothing
                // proving it alive, no channel data out for 60 s is a stall —
                // a device that ignores keepalives and never reopens its
                // window would otherwise hang "connected" forever.
                let windowWaiting = !armed && connection.pendingOutput(channel) > 0
                let dataSent = connection.dataSent(channel)
                if !windowWaiting || dataSent != lastDataSent { lastWindowProgress = clock.now }
                lastDataSent = dataSent
                if (sealedWaiting && lastProgress.duration(to: clock.now) > .seconds(60))
                    || (windowWaiting && lastWindowProgress.duration(to: clock.now) > .seconds(60)) {
                    return .init(message: "write stalled for 60 s — connection wedged?")
                }

                if let resize = takeResize() {
                    try connection.windowChange(channel, columns: resize.cols, rows: resize.rows)
                    state.withLock { $0.appliedResize = resize }
                }

                // Agent traffic rides the same session.
                try forwarder?.pump(connection: connection, unsentBytes: { link.unsentBytes })

                // Liveness counts whole authenticated packets, not bytes: a
                // corrupted stream being discarded must not look alive.
                let before = link.transport.packetsReceived
                // An agent tunnel held back by the unsent budget is not
                // polled, and step's own flush may free it: look again soon.
                try link.step(timeoutMS: forwarder?.isThrottledByUnsent == true ? 50 : 1000, wake: pipeRead,
                              extra: forwarder?.descriptors ?? [])
                if link.transport.packetsReceived > before { noteInbound() }
            } catch SSHLink.Failure.closedByPeer {
                // Output that came with the hang-up is delivered; a hang-up
                // after the shell's own EOF/close is a normal end.
                return drainEvents() ? nil : .init(message: "connection lost: connection closed by the server")
            } catch {
                let ended = drainEvents()
                if case .disconnectedByServer(_, let description)? = error as? SSHTransportError, ended {
                    // `exit` answered with output, EOF, CLOSE and DISCONNECT
                    // in one segment: a normal end — but keep what the server
                    // said (an idle timeout, "cleared by administrator").
                    if !description.isEmpty { notice("the server said: \(description)") }
                    return nil
                }
                if let refusal = Self.hostKeyRefusal(in: error) { return .init(message: refusal, hostKeyRefusal: true) }
                if link.transport.isDiscardingCorruptPacket || isCorruption(error) {
                    return .init(message: "connection lost: corrupted packet from the server")
                }
                return .init(message: "connection lost: \(Self.describe(error))")
            }
        }
        return nil
    }

    private func isCorruption(_ error: Error) -> Bool {
        if case .packet? = error as? SSHTransportError { return true }
        return false
    }

    /// TCP-level keepalive on the socket. This is the half of liveness that
    /// needs no cooperation from the device and cannot false-positive: the
    /// kernel probes, and a peer that has stopped ACKing at all (cable out,
    /// host rebooted, VPN gone, NAT entry expired) makes the socket fail,
    /// which the io loop reports. Without it macOS leaves an idle TCP
    /// connection alone indefinitely, so the app sat on a socket to a machine
    /// that had been off for an hour.
    ///
    /// 60 s idle, then 6 probes 10 s apart — dead in about two minutes, which
    /// is under the SSH-level deadline on purpose: whichever notices first is
    /// right, and this one is the one that works on gear that ignores global
    /// requests.
    private func enableTCPKeepalive(on fd: Int32) {
        guard fd >= 0 else { return }
        var on: Int32 = 1
        var idle: Int32 = 60
        var interval: Int32 = 10
        var count: Int32 = 6
        let size = socklen_t(MemoryLayout<Int32>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, size)
        _ = setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
        _ = setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, size)
        _ = setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, size)
    }
}

/// Reports, while a session is live, the one network death the socket itself
/// cannot see for minutes: the Mac moved to another network (Wi-Fi swapped,
/// cable pulled, the old address's lease gone) and no longer holds the local
/// address the TCP connection was established from. The kernel keeps the old
/// flow "established" — packets leave with a source address no interface owns
/// and are silently dropped — and neither TCP clock ends it quickly: on XNU
/// the keepalive idle timer runs from the last segment RECEIVED, and once the
/// SSH probe (every 60 s) sits un-ACKed the connection is under the
/// retransmit timer, which backs off for many minutes. So it took the third
/// missed SSH probe — 2–3 minutes of frozen screen the user had to press
/// Reconnect on (reported 2026-09-30).
///
/// `NWPathMonitor` is only a signal, and not a complete one: a new DHCP
/// address on the same subnet or a rotated IPv6 temporary address can leave
/// the path looking identical, so no update comes. The I/O loop therefore
/// also asks (`check()`) every few seconds; getifaddrs costs tens of µs.
/// The DECISION (`verdict`) is deliberately narrow — a loss is recorded only
/// when BOTH hold:
///  - the path is `.satisfied` (some network is up) and the local address
///    the connection was established from is on no up interface. No network
///    at all is NOT a loss: lid closed, Wi-Fi toggled, cable re-plugged —
///    the same address usually comes back and TCP rides the gap out. A
///    network that never returns is the keepalive's job (3 missed probes);
///  - and it is still so after a grace (5 s): wake from sleep and DHCP
///    renewals drop the address for a second or three and hand the SAME one
///    back. If it came back, nothing happened.
/// A path update that keeps the address (an AP roam, a VPN stacking a utun
/// on the same en0, a captive portal appearing) is not a proven death — the
/// flow may well still work — and disconnecting on it would be exactly the
/// false positive a liveness check must not have.
///
/// Addresses are compared in binary (`Address`): a dual-stack socket's
/// IPv4-mapped `::ffff:a.b.c.d` is the IPv4 address getifaddrs lists, and a
/// link-local IPv6 address matches only on the same interface — `fe80::x` on
/// awdl0 is not `fe80::x` on en0.
nonisolated final class SessionPathWatcher: @unchecked Sendable {
    /// A local address in comparable form.
    struct Address: Equatable, Sendable, CustomStringConvertible {
        /// 4 bytes (IPv4, including an IPv4-mapped IPv6 address) or 16.
        let bytes: [UInt8]
        /// The interface index of a link-local IPv6 address; 0 otherwise.
        let scope: UInt32

        /// Normalizes: IPv4-mapped IPv6 becomes IPv4; a link-local IPv6
        /// address keeps its scope (taken from the KAME-embedded word in
        /// bytes 2–3 when `scope` is 0 — older BSD getifaddrs output) and
        /// has that word cleared; every other address has scope 0.
        init?(bytes: [UInt8], scope: UInt32 = 0) {
            switch bytes.count {
            case 4:
                self.bytes = bytes
                self.scope = 0
            case 16:
                if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                    self.bytes = Array(bytes[12...])
                    self.scope = 0
                } else if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 {
                    var cleared = bytes
                    let embedded = UInt32(bytes[2]) << 8 | UInt32(bytes[3])
                    cleared[2] = 0
                    cleared[3] = 0
                    self.bytes = cleared
                    self.scope = scope != 0 ? scope : embedded
                } else {
                    self.bytes = bytes
                    self.scope = 0
                }
            default:
                return nil
            }
        }

        /// From an AF_INET/AF_INET6 sockaddr; nil for any other family.
        init?(sockaddr sa: UnsafePointer<sockaddr>) {
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                self.init(bytes: withUnsafeBytes(of: addr) { Array($0) })
            case AF_INET6:
                let s6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                self.init(bytes: withUnsafeBytes(of: s6.sin6_addr) { Array($0) }, scope: s6.sin6_scope_id)
            default:
                return nil
            }
        }

        /// From dotted IPv4 or IPv6 text (tests, mostly).
        init?(_ text: String, scope: UInt32 = 0) {
            var v4 = in_addr()
            var v6 = in6_addr()
            if inet_pton(AF_INET, text, &v4) == 1 {
                self.init(bytes: withUnsafeBytes(of: v4) { Array($0) })
            } else if inet_pton(AF_INET6, text, &v6) == 1 {
                self.init(bytes: withUnsafeBytes(of: v6) { Array($0) }, scope: scope)
            } else {
                return nil
            }
        }

        var isLinkLocalV6: Bool { bytes.count == 16 && bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 }

        /// Whether `candidate` (an interface's address) is this address. A
        /// link-local address with no known scope matches on bytes alone —
        /// less precise, never a false "gone".
        func matches(_ candidate: Address) -> Bool {
            bytes == candidate.bytes && (scope == 0 || candidate.scope == scope)
        }

        var description: String {
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let family = bytes.count == 4 ? AF_INET : AF_INET6
            let converted = bytes.withUnsafeBytes {
                inet_ntop(family, $0.baseAddress, &text, socklen_t(INET6_ADDRSTRLEN))
            }
            guard converted != nil else { return "?" }
            let base = SessionPathWatcher.text(text)
            guard scope != 0 else { return base }
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
            return if_indextoname(scope, &name) != nil
                ? base + "%" + SessionPathWatcher.text(name) : base + "%\(scope)"
        }
    }

    /// What one look at the network says.
    struct Observation: Equatable, Sendable {
        var pathSatisfied: Bool
        var addressPresent: Bool
    }

    enum Verdict: Equatable { case alive, suspect, lost }

    /// The whole decision, pure. `.suspect` = look again after the grace;
    /// `.lost` only when both looks saw a satisfied path without the address.
    static func verdict(_ first: Observation, afterGrace: Observation?) -> Verdict {
        guard first.pathSatisfied, !first.addressPresent else { return .alive }
        guard let afterGrace else { return .suspect }
        guard afterGrace.pathSatisfied, !afterGrace.addressPresent else { return .alive }
        return .lost
    }

    private struct State {
        var local: Address?
        var wake: Int32 = -1
        /// Written once (under the lock, with the wake write), read by the
        /// I/O loop every pass. Never cleared — the loop exits on it.
        var loss: String?
        /// Set by stop(): nothing may write `wake` after it.
        var stopped = false
        var graceArmed = false
        /// The last path the monitor reported; false until the first one.
        var pathSatisfied = false
    }
    private let state = Mutex(State())
    private let grace: DispatchTimeInterval
    private let addressPresent: @Sendable (Address) -> Bool
    private let pathProbe: (@Sendable () -> Bool)?

    /// `inet_ntop`'s output buffer as Swift text (everything before the NUL).
    private static func text(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix(while: { $0 != 0 }).lazy.map { UInt8(bitPattern: $0) },
               as: UTF8.self)
    }
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "sheepterm.pathwatch")

    /// The defaults are the real thing; tests inject a short grace and
    /// scripted probes (`pathSatisfied` overrides the monitor's report).
    init(grace: DispatchTimeInterval = .seconds(5),
         addressPresent: @escaping @Sendable (Address) -> Bool = { SessionPathWatcher.addressIsStillLocal($0) },
         pathSatisfied: (@Sendable () -> Bool)? = nil) {
        self.grace = grace
        self.addressPresent = addressPresent
        self.pathProbe = pathSatisfied
    }

    /// The socket's local IPv4/IPv6 address, or nil when there is nothing
    /// comparable (no address yet, or a family we do not read). A nil start
    /// means watching stays off — never a false disconnect.
    static func localAddress(of fd: Int32) -> Address? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let copied = withUnsafeMutableBytes(of: &storage) { raw -> Int32 in
            raw.withMemoryRebound(to: sockaddr.self) { bound in
                getsockname(fd, bound.baseAddress, &length)
            }
        }
        guard copied == 0 else { return nil }
        return withUnsafeBytes(of: storage) { raw -> Address? in
            raw.withMemoryRebound(to: sockaddr.self) { Address(sockaddr: $0.baseAddress!) }
        }
    }

    /// Whether `address` is still assigned to an interface that is up. When
    /// the interface list itself cannot be read the answer is "yes" — a
    /// check that cannot run must not disconnect.
    static func addressIsStillLocal(_ address: Address) -> Bool {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return true }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let ifa = ptr.pointee
            cursor = ifa.ifa_next
            // An address on an interface that is down is gone for routing
            // purposes — the packets have no way out either way.
            guard let sa = ifa.ifa_addr, (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  var candidate = Address(sockaddr: sa) else { continue }
            // A link-local entry that carries no scope at all belongs to the
            // interface it is listed under.
            if candidate.isLinkLocalV6, candidate.scope == 0,
               let indexed = Address(bytes: candidate.bytes, scope: if_nametoindex(ifa.ifa_name)) {
                candidate = indexed
            }
            if address.matches(candidate) { return true }
        }
        return false
    }

    /// Begins watching. `local` is the snapshot `localAddress(of:)` took at
    /// connect time; `wake` is the worker's self-pipe write end (O_NONBLOCK),
    /// written once when the loss is recorded so the I/O loop's poll returns
    /// immediately.
    func start(local: Address?, wake: Int32) {
        guard let local else { return }
        state.withLock {
            $0.local = local
            $0.wake = wake
        }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.state.withLock { $0.pathSatisfied = path.status == .satisfied }
            self.check()
        }
        monitor.start(queue: monitorQueue)
    }

    /// One look, from any thread: the monitor's handler, and the I/O loop
    /// every few seconds (the path can stay identical while the address
    /// changes). A suspicious look arms ONE grace re-check; the verdict is
    /// made there.
    func check() {
        guard let (local, cached) = state.withLock({ s -> (Address, Bool)? in
            guard let local = s.local, !s.stopped, s.loss == nil, !s.graceArmed else { return nil }
            return (local, s.pathSatisfied)
        }) else { return }
        let first = Observation(pathSatisfied: pathProbe?() ?? cached, addressPresent: addressPresent(local))
        guard Self.verdict(first, afterGrace: nil) == .suspect else { return }
        let armed = state.withLock { s -> Bool in
            guard !s.stopped, s.loss == nil, !s.graceArmed else { return false }
            s.graceArmed = true
            return true
        }
        guard armed else { return }
        monitorQueue.asyncAfter(deadline: .now() + grace) { [weak self] in
            self?.graceExpired(first: first)
        }
    }

    private func graceExpired(first: Observation) {
        guard let (local, cached) = state.withLock({ s -> (Address, Bool)? in
            guard let local = s.local, !s.stopped else { return nil }
            return (local, s.pathSatisfied)
        }) else { return }
        let again = Observation(pathSatisfied: pathProbe?() ?? cached, addressPresent: addressPresent(local))
        state.withLock { s in
            s.graceArmed = false
            // The stopped check and the write share one critical section:
            // once stop() has set the flag, no write can still be on its way
            // to a descriptor the worker is about to close (and the system
            // may hand to someone else).
            guard !s.stopped, s.loss == nil, Self.verdict(first, afterGrace: again) == .lost else { return }
            s.loss = "connection lost: the network changed — this Mac no longer holds \(local)"
            var byte: UInt8 = 0
            _ = Darwin.write(s.wake, &byte, 1)
        }
    }

    /// The recorded loss, if any.
    func lostConnection() -> String? { state.withLock { $0.loss } }

    /// After this returns nothing writes `wake` — the caller closes it right
    /// away. `monitor.cancel()` is asynchronous (a handler may still run) and
    /// a grace timer may still fire, so a queue barrier is not enough; both
    /// check `stopped` under the same lock that guards their write.
    func stop() {
        let wasWatching = state.withLock { s -> Bool in
            defer { s.stopped = true }
            return s.local != nil && !s.stopped
        }
        guard wasWatching else { return }
        monitor.cancel()
    }
}

/// One TCP connection carrying one SSHTransport: non-blocking socket I/O,
/// the outbound byte queue, and routing of transport messages to whichever
/// layer is current (userauth, then connection). Used only on the worker's
/// queue.
nonisolated final class SSHLink {
    enum Failure: Error {
        case closedByPeer
        case socket(String)
    }

    let fd: Int32
    let transport: SSHTransport
    /// Where transport `.message` payloads go; by default they park until
    /// a layer takes them (`nextParked`) or `drainMessages` replays them.
    var route: ([UInt8]) throws -> Void = { _ in }
    private(set) var isReady = false
    private var outbound = ByteQueue()
    /// Bytes the socket has accepted, ever (write-stall accounting).
    private(set) var socketBytesWritten = 0
    /// Everything accepted for sending that the socket has not taken yet:
    /// sealed and queued here or in the transport, or held by it during a
    /// rekey. The worker's back-pressure counts all of it — a large remote
    /// window and a black-holed socket must not buffer a paste unseen.
    var unsentBytes: Int {
        outbound.count + transport.outgoingByteCount + transport.heldPayloadBytes
    }
    private var closed = false
    private var parked: [[UInt8]] = []
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    static let maxReadsPerStep = 4

    init(fd: Int32, transport: SSHTransport) {
        self.fd = fd
        self.transport = transport
        parkMessages()
    }

    func parkMessages() {
        route = { [unowned self] in self.parked.append($0) }
    }

    func nextParked() -> [UInt8]? {
        parked.isEmpty ? nil : parked.removeFirst()
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        _ = Darwin.close(fd)
    }

    /// Best-effort goodbye: channel close/EOF already queued by the caller,
    /// then SSH_MSG_DISCONNECT, one non-blocking flush, close.
    func shutdown() {
        guard !closed else { return }
        transport.disconnect(reason: .byApplication, description: "")
        try? flush()
        close()
    }

    /// Re-delivers messages that arrived before `route` was pointed at the
    /// layer that wants them.
    func drainMessages() throws {
        let pending = parked
        parked.removeAll()
        for payload in pending { try route(payload) }
    }

    private func takeTransportEvents() throws {
        for event in transport.takeEvents() {
            switch event {
            case .ready: isReady = true
            case .keysChanged: break
            case .message(let payload): try route(payload)
            }
        }
    }

    /// Writes as much queued output as the socket takes right now.
    func flush() throws {
        transport.drainOutgoing(into: &outbound)
        while !outbound.isEmpty {
            let n = outbound.unread.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                outbound.consume(n)
                socketBytesWritten += n
            } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                break
            } else {
                throw Failure.socket("write failed: \(String(cString: strerror(errno)))")
            }
        }
    }

    /// One pass: flush, wait up to `timeoutMS` for the socket / wake pipe /
    /// `extra` descriptors, read what arrived, feed the transport, route its
    /// messages, flush again. Returns true when bytes came from the server.
    @discardableResult
    func step(timeoutMS: Int32, wake: Int32, extra: [Int32]) throws -> Bool {
        try flush()
        try takeTransportEvents()
        var fds = [pollfd(fd: fd, events: Int16(POLLIN) | (outbound.isEmpty ? 0 : Int16(POLLOUT)), revents: 0),
                   pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
        fds += extra.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        let ready = poll(&fds, nfds_t(fds.count), timeoutMS)
        if ready < 0 {
            if errno == EINTR { return false }
            throw Failure.socket("poll failed: \(String(cString: strerror(errno)))")
        }
        if Int32(fds[1].revents) & Int32(POLLIN) != 0 {
            // The work it announced is picked up by the caller's next pass.
            var sink = [UInt8](repeating: 0, count: 256)
            _ = sink.withUnsafeMutableBytes { Darwin.read(wake, $0.baseAddress, $0.count) }
        }
        var gotBytes = false
        let revents = Int32(fds[0].revents)
        // HUP/ERR is checked after the read: a hang-up arriving WITH final
        // data must still deliver that data first.
        if revents & Int32(POLLIN | POLLHUP | POLLERR) != 0 {
            // At most `maxReadsPerStep` buffers per pass, so a flood cannot
            // keep the caller from typing, resizing, probing or stopping —
            // and its output reaches the terminal as it comes.
            for _ in 0..<Self.maxReadsPerStep {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    gotBytes = true
                    do {
                        try transport.receive(buffer[0..<n])
                    } catch {
                        // Packets parsed before the failing one (the last
                        // output, EOF, CLOSE before a DISCONNECT) still count.
                        try? takeTransportEvents()
                        throw error
                    }
                    try takeTransportEvents()
                    if n < buffer.count { break }
                } else if n == 0 {
                    try takeTransportEvents()
                    throw Failure.closedByPeer
                } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    break
                } else {
                    throw Failure.socket("read failed: \(String(cString: strerror(errno)))")
                }
            }
        }
        if revents & Int32(POLLNVAL) != 0 { throw Failure.socket("socket closed") }
        try flush()
        return gotBytes
    }
}
