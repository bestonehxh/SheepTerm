import Foundation
import SheepSSH
import Synchronization

// The Files tab's SFTP / SCP client (`RemoteFileClient`). One SSH session per
// client on its own serial queue, driven exactly the way SSHWorker drives a
// terminal session: SheepTerm's `SSHLink` (self-pipe poll), SheepTerm's
// known_hosts files and trust rules (`SSHWorker.hostKeyVerdict` /
// `pinFirstUse`), the same algorithm sets and TCP connect. The SFTP v3 codec
// (`SFTPWire`) and the blind SCP fallback (`SCPTransfer`) are ported from
// SheepDrop, where they were proven against real switches.
//
// - Host key: trusted only when known_hosts says so, or when the caller's
//   `HostKeyDecision` names this key's exact fingerprint. Anything else ends
//   the connect with `.hostKeyUnknown` / `.hostKeyChanged` inside the key
//   exchange — before userauth starts, so no credential has left the Mac.
// - Every operation runs on the queue, one at a time (a listing waits for a
//   transfer in flight). Task cancellation pokes the self-pipe, so a
//   cancelled transfer stops within one poll.
// - Progress callbacks run on the client's queue (at most ~10/s): hop to
//   the main actor before touching UI.
// - Downloads land in a hidden part file beside the destination and are
//   renamed over it only when complete: a failure or a cancel leaves no
//   partial file under the destination's name.

nonisolated final class SFTPClient: RemoteFileClient {
    let canBrowse: Bool
    private let engine: SFTPEngine

    private init(engine: SFTPEngine, canBrowse: Bool) {
        self.engine = engine
        self.canBrowse = canBrowse
    }

    deinit { engine.shutdown() }

    /// SFTP subsystem; for `.scp`, tries SFTP first and falls back to blind
    /// SCP (canBrowse = false) when the device refuses the subsystem.
    /// `sharing`: ride that terminal tab's own SSH connection (no second
    /// login, no host-key question) instead of opening one. Any failure —
    /// the device refusing a second channel, the tab dropping — is thrown;
    /// the caller then connects on its own.
    static func connect(_ endpoint: RemoteEndpoint, sharing bridge: SSHChannelBridge? = nil) async throws -> SFTPClient {
        let engine = SFTPEngine(endpoint, sharing: bridge)
        do {
            let browsable = try await engine.perform { e, op in try e.connect(op) }
            if bridge == nil { engine.startKeepalive() }
            return SFTPClient(engine: engine, canBrowse: browsable)
        } catch {
            engine.shutdown()
            throw error
        }
    }

    /// The Files tab's connect for an SSH host: on the lending tab's
    /// connection first (true = riding it), on its own when that fails —
    /// except where its own could not do better (the device has no SFTP)
    /// or must not be tried (`jumpOnly`: a jump-host device is never
    /// dialled directly).
    static func connect(_ endpoint: RemoteEndpoint, preferring bridge: SSHChannelBridge?,
                        jumpOnly: Bool) async throws -> (SFTPClient, Bool) {
        if let bridge {
            do {
                return (try await connect(endpoint, sharing: bridge), true)
            } catch let error as RemoteFileError {
                if jumpOnly || error == .cancelled { throw error }
                if case .unsupported = error { throw error }
            }
        } else if jumpOnly {
            throw RemoteFileError.connection(String(localized:
                "Open the SSH tab first — Open Files reaches a jump-host device only through its open tab."))
        }
        return (try await connect(endpoint), false)
    }

    private static let blind = RemoteFileError.unsupported(
        "This device does not serve SFTP — only get/put by path (SCP) is possible")

    func home() async throws -> String {
        guard canBrowse else { return "/" }
        return try await engine.perform { e, op in try e.home(op) }
    }

    func list(_ path: String) async throws -> [RemoteEntry] {
        guard canBrowse else { throw Self.blind }
        return try await engine.perform { e, op in try e.list(path, op) }
    }

    func download(_ remotePath: String, to local: URL, replacing: Bool, progress: @escaping TransferProgress) async throws {
        let browse = canBrowse
        try await engine.perform { e, op in
            if browse { try e.download(remotePath, to: local, replacing: replacing, progress: progress, op) }
            else { try e.scp(push: false, local: local, remote: remotePath, replacing: replacing, progress: progress, op) }
        }
    }

    func upload(_ local: URL, to remotePath: String, progress: @escaping TransferProgress) async throws {
        let browse = canBrowse
        try await engine.perform { e, op in
            if browse { try e.upload(local, to: remotePath, progress: progress, op) }
            else { try e.scp(push: true, local: local, remote: remotePath, progress: progress, op) }
        }
    }

    func makeDirectory(_ path: String) async throws {
        guard canBrowse else { throw Self.blind }
        try await engine.perform { e, op in try e.makeDirectory(path, op) }
    }

    func remove(_ path: String, isDirectory: Bool) async throws {
        guard canBrowse else { throw Self.blind }
        try await engine.perform { e, op in try e.remove(path, isDirectory: isDirectory, op) }
    }

    func rename(_ from: String, to: String) async throws {
        guard canBrowse else { throw Self.blind }
        try await engine.perform { e, op in try e.rename(from, to: to, op) }
    }

    func close() { engine.shutdown() }

#if SHEEPTERM_TESTING
    struct TestState: Sendable {
        var lost: String?
        var sftpReady: Bool
        var keepalivesSent: Int
        var unansweredKeepalives: Int
    }
    /// The harness: keepalive counters, whether the link is lost.
    func _testState() async throws -> TestState {
        try await engine.perform { e, _ in e.testState }
    }
#endif
}

// MARK: - Host key

/// The host-key decision for the Files tab, over SheepTerm's own files and
/// rules (the same ones a terminal session uses). Pure apart from the append
/// `.trustAndSave` makes, so the harness drives the real thing.
nonisolated enum SFTPHostKeyCheck {
    enum Outcome: Equatable, Sendable {
        case accept
        case refuse(RemoteFileError)
    }

    static func decide(key: SSHPublicKey, host: String, port: Int, decision: HostKeyDecision,
                       files: SSHWorker.KnownHostsFiles, path: String) -> Outcome {
        let fingerprint = key.fingerprintSHA256, type = key.keyType
        // Fail closed: an unreadable known_hosts is never "first connection".
        guard let user = files.user else { return .refuse(.connection(SSHWorker.unreadableKnownHostsRefusal)) }
        let global = files.global?.lookup(host: host, port: port, key: key) ?? KnownHosts.Result.notFound
        let userResult = user.lookup(host: host, port: port, key: key)
        switch SSHWorker.hostKeyVerdict(user: userResult, global: global) {
        case .trusted:
            return .accept
        case .refused(let why):
            if case .revoked = userResult { return .refuse(.connection(why)) }
            if case .revoked = global { return .refuse(.connection(why)) }
            // "Trust This Key Too": only a conflict in the user's OWN file,
            // only for the exact key the user was shown, appended beside the
            // old pin under the file lock (SSHWorker's rules). Trust-once is
            // never enough for a key that contradicts a pin.
            if case .trustAndSave(let wanted) = decision, wanted == fingerprint,
               let conflict = SSHWorker.addableConflict(user: userResult, global: global) {
                let (verdict, _) = SSHWorker.pinFirstUse(key: key, host: host, port: port, global: global,
                                                          path: path, besidePin: conflict)
                if case .refused = verdict { return .refuse(.hostKeyChanged(fingerprint: fingerprint, keyType: type)) }
                return .accept
            }
            return .refuse(.hostKeyChanged(fingerprint: fingerprint, keyType: type))
        case .firstSeen:
            switch decision {
            case .trustOnce(let wanted) where wanted == fingerprint:
                return .accept
            case .trustAndSave(let wanted) where wanted == fingerprint:
                // Decided again under the lock, appended in the same breath.
                // A save that fails (read-only file) still trusts this one
                // connection, as Trust & Connect does.
                let (verdict, _) = SSHWorker.pinFirstUse(key: key, host: host, port: port, global: global, path: path)
                switch verdict {
                case .trusted, .firstSeen: return .accept
                case .refused(let why):
                    return why == SSHWorker.unreadableKnownHostsRefusal
                        ? .refuse(.connection(why))
                        : .refuse(.hostKeyChanged(fingerprint: fingerprint, keyType: type))
                }
            default:
                return .refuse(.hostKeyUnknown(fingerprint: fingerprint, keyType: type))
            }
        }
    }
}

// MARK: - Engine

/// A self-pipe that wakes the engine's poll from any thread (cancel, close).
nonisolated final class SFTPWakePipe: Sendable {
    private let fds: Mutex<(read: Int32, write: Int32)>

    init() {
        var p: [Int32] = [-1, -1]
        if pipe(&p) == 0 {
            for fd in p {
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            }
        }
        fds = Mutex((p[0], p[1]))
    }

    var readFD: Int32 { fds.withLock { $0.read } }

    func poke() {
        fds.withLock { f in
            guard f.write >= 0 else { return }
            var byte: UInt8 = 1
            _ = Darwin.write(f.write, &byte, 1)
        }
    }

    /// Waits up to `timeoutMS` for a poke, then empties the pipe. (The
    /// shared-connection engine's poll: the bridge pokes it.)
    func wait(timeoutMS: Int32) {
        let fd = readFD
        guard fd >= 0 else { return }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&p, 1, timeoutMS)
        var sink = [UInt8](repeating: 0, count: 64)
        while Darwin.read(fd, &sink, sink.count) > 0 {}
    }

    func close() {
        fds.withLock { f in
            if f.read >= 0 { Darwin.close(f.read) }
            if f.write >= 0 { Darwin.close(f.write) }
            f = (-1, -1)
        }
    }
}

/// One operation's cancellation flag (set from the Task's cancel handler).
nonisolated final class SFTPOp: Sendable {
    let cancelled = Atomic<Bool>(false)
}

/// At most one progress report per 100 ms, plus the final one.
nonisolated struct ProgressThrottle {
    let report: TransferProgress
    private var last: ContinuousClock.Instant?

    init(_ report: @escaping TransferProgress) { self.report = report }

    mutating func tick(_ done: Int64, _ total: Int64?) {
        let now = ContinuousClock.now
        if let last, last.duration(to: now) < .milliseconds(100) { return }
        last = now
        report(done, total)
    }

    func finish(_ done: Int64, _ total: Int64?) { report(done, total) }
}

/// Everything below `perform` runs on `queue`; the stored state is
/// queue-confined (the @unchecked Sendable contract), apart from the
/// atomics and the wake pipe.
nonisolated final class SFTPEngine: @unchecked Sendable {
    let queue = DispatchQueue(label: "sheepterm.sftp.client")
    let endpoint: RemoteEndpoint
    private let wake = SFTPWakePipe()
    private let closing = Atomic<Bool>(false)

    // Queue-confined.
    private var link: SSHLink?
    private var connection: SSHConnection?
    /// Set when the engine rides a terminal tab's connection: then there is
    /// no link or connection of its own, and every channel goes through it.
    private let shared: SSHChannelBridge?
    private var channels: (any SFTPChannels)? { shared ?? connection }
    private var wire: SFTPWire?
    private var sftpChannel: UInt32?
    private var sftpReady = false
    /// Why the session died (the link failed, the SFTP channel closed).
    private var lost: String?
    private var lastFailureWasHangUp = false
    /// What the link last threw (the legacy retry reads it).
    private var lastLinkError: Error?
    private var opened = Set<UInt32>()
    private var openFailed: [UInt32: String] = [:]
    private var requestReplies: [UInt32: Bool] = [:]
    private var ended = Set<UInt32>()
    private var scpTransfer: SCPTransfer?
    private var scpChannel: UInt32?
    private var scpFailure: String?
    private var scpStderr = ""
    private var keepaliveTimer: DispatchSourceTimer?
    private var lastInbound = ContinuousClock.now
    private var unansweredKeepalives = 0
    private var keepalivesSent = 0
    private var tornDown = false

    /// Data-phase window: requests in flight × bytes each.
    static let chunk = 32 * 1024
    static let window = 64
    /// A listing longer than this is cut off with an error: a server that
    /// answers READDIR forever must not grow memory without bound.
    static let maximumListing = 100_000
    /// And at most this many bytes of names: 100,000 names of 4 MB each fit
    /// the count (review 6.0 (4)). FTP caps its listing at 16 MB too.
    #if SHEEPTERM_TESTING
    nonisolated(unsafe) static var maximumListingBytes = 32 * 1024 * 1024
    #else
    static let maximumListingBytes = 32 * 1024 * 1024
    #endif
    /// No byte from the server for this long during an operation = dead.
    static let idleLimit: Duration = .seconds(30)
#if SHEEPTERM_TESTING
    /// Shortened by the harness so a keepalive round is seen in seconds.
    nonisolated(unsafe) static var keepaliveSeconds = 20
#else
    static let keepaliveSeconds = 20
#endif

    init(_ endpoint: RemoteEndpoint, sharing bridge: SSHChannelBridge? = nil) {
        self.endpoint = endpoint
        self.shared = bridge
        let wake = self.wake
        bridge?.setEngineWake { wake.poke() }
    }

    // MARK: Thread-safe surface

    /// Runs `body` on the queue. Task cancellation sets the op's flag and
    /// wakes the poll; anything that is not a RemoteFileError is reported as
    /// a connection error.
    func perform<T: Sendable>(_ body: @escaping @Sendable (SFTPEngine, SFTPOp) throws -> T) async throws -> T {
        let op = SFTPOp()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                queue.async {
                    continuation.resume(with: Result {
                        do {
                            if op.cancelled.load(ordering: .relaxed) { throw RemoteFileError.cancelled }
                            return try body(self, op)
                        } catch let error as RemoteFileError {
                            throw error
                        } catch {
                            throw RemoteFileError.connection(SSHWorker.describe(error))
                        }
                    })
                }
            }
        } onCancel: {
            op.cancelled.store(true, ordering: .relaxed)
            wake.poke()
        }
    }

    /// Ends the session: an operation in flight stops at its next poll.
    func shutdown() {
        guard !closing.exchange(true, ordering: .relaxed) else { return }
        wake.poke()
        queue.async { [self] in teardown() }
    }

    func startKeepalive() {
        queue.async { [self] in
            guard !tornDown else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let interval = DispatchTimeInterval.seconds(Self.keepaliveSeconds)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.idleTick() }
            timer.resume()
            keepaliveTimer = timer
        }
    }

#if SHEEPTERM_TESTING
    var testState: SFTPClient.TestState {
        SFTPClient.TestState(lost: lost, sftpReady: sftpReady, keepalivesSent: keepalivesSent,
                             unansweredKeepalives: unansweredKeepalives)
    }
#endif

    // MARK: Lifecycle (queue)

    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        if let connection, let id = sftpChannel, connection.isOpen(id) { try? connection.close(id) }
        shared?.detach()
        link?.shutdown()
        link = nil
        connection = nil
        wire = nil
        sftpReady = false
        scpTransfer = nil
        wake.close()
    }

    private func markLost(_ why: String) {
        if lost == nil { lost = why }
        sftpReady = false
    }

    /// Between operations: read what the server sent (window adjusts,
    /// keepalive replies, a close) and probe a quiet server.
    private func idleTick() {
        guard !tornDown, lost == nil, let link, let connection else { return }
        do {
            _ = try step(nil, timeoutMS: 0)
        } catch {
            return
        }
        if lastInbound.duration(to: .now) >= .seconds(Self.keepaliveSeconds) {
            if unansweredKeepalives >= 3 {
                markLost("the server stopped answering keepalives")
                return
            }
            do {
                try connection.sendKeepalive()
                try link.flush()
                unansweredKeepalives += 1
                keepalivesSent += 1
            } catch {
                markLost("connection lost: \(SSHWorker.describe(error))")
            }
        }
    }

    // MARK: Pump (queue)

    /// One pass of the link. True when bytes came from the server.
    @discardableResult
    private func step(_ op: SFTPOp?, timeoutMS: Int32 = 200) throws -> Bool {
        if let op, op.cancelled.load(ordering: .relaxed) { throw RemoteFileError.cancelled }
        if closing.load(ordering: .relaxed) { throw RemoteFileError.connection("closed") }
        if let lost { throw RemoteFileError.connection(lost) }
        if let shared {
            if !shared.hasEvents, shared.lost == nil { wake.wait(timeoutMS: timeoutMS) }
            let got = shared.hasEvents
            if got { lastInbound = .now }
            try drainConnectionEvents()
            if let why = shared.lost, !shared.hasEvents {
                lastFailureWasHangUp = true
                markLost(why)
            }
            if let lost { throw RemoteFileError.connection(lost) }
            return got
        }
        guard let link else { throw RemoteFileError.connection("not connected") }
        let got: Bool
        do {
            got = try link.step(timeoutMS: timeoutMS, wake: wake.readFD, extra: [])
        } catch {
            lastLinkError = error
            if case SSHLink.Failure.closedByPeer = error { lastFailureWasHangUp = true }
            if case .disconnectedByServer? = error as? SSHTransportError { lastFailureWasHangUp = true }
            if case .transport(.disconnectedByServer)? = error as? ConnectionError { lastFailureWasHangUp = true }
            let why = SSHWorker.describe(error)
            markLost(why)
            throw RemoteFileError.connection(why)
        }
        if got {
            lastInbound = .now
            unansweredKeepalives = 0
        }
        try drainConnectionEvents()
        if let lost { throw RemoteFileError.connection(lost) }
        return got
    }

    /// Pumps until `done()`. `service` runs before every pass (SCP feeds
    /// its outgoing bytes there). Times out only on a SILENT server.
    private func pump(_ op: SFTPOp, idle: Duration = idleLimit, pollMS: Int32 = 200, service: () throws -> Void = {},
                      until done: () throws -> Bool) throws {
        var quietSince = ContinuousClock.now
        while true {
            try service()
            if try done() { return }
            if try step(op, timeoutMS: pollMS) {
                quietSince = .now
            } else if quietSince.duration(to: .now) > idle {
                throw RemoteFileError.connection("timed out waiting for the server")
            }
        }
    }

    private func drainConnectionEvents() throws {
        guard let events = shared?.takeEvents() ?? connection?.takeEvents() else { return }
        for event in events {
            switch event {
            case .channelOpened(let id):
                opened.insert(id)
            case .channelOpenFailed(let id, _, let description):
                openFailed[id] = description.isEmpty ? "refused" : description
            case .channelRequestReply(let id, _, let success):
                requestReplies[id] = success
            case .data(let id, let bytes):
                if id == sftpChannel, let wire {
                    do {
                        try wire.consume(bytes)
                    } catch {
                        if let text = error.shellText {
                            // Check Point: a clish user. Gaia wants bash
                            // (or scponly) for file transfer.
                            markLost(String(localized: "The device's shell answered instead of SFTP: “\(text)”. Give this user a bash shell (Check Point: set user <name> shell /bin/bash), or use SCP."))
                        } else {
                            markLost("the SFTP stream is out of sync (\(error.message))")
                        }
                    }
                } else if id == scpChannel, let scpTransfer {
                    do {
                        try scpTransfer.feed(bytes)
                    } catch {
                        scpFailure = error.message
                    }
                }
            case .extendedData(let id, let bytes):
                if id == scpChannel, scpStderr.utf8.count < 4096 {
                    scpStderr += String(decoding: bytes, as: UTF8.self)
                }
            case .eof(let id), .closed(let id):
                ended.insert(id)
                if id == sftpChannel, sftpReady { markLost("the server closed the SFTP session") }
            case .globalReply:
                unansweredKeepalives = 0
            case .exitStatus, .exitSignal, .agentChannelOpened:
                break
            case .remoteForwardReply, .forwardedChannelOpened:
                break       // never asked for: this client requests no forwards
            }
        }
    }

    // MARK: Connect (queue)

    private enum HandshakeError: Error {
        case negotiation(String)
        case fatal(RemoteFileError)
    }

    /// Host-key outcome, handed out of the @Sendable validator.
    private final class Verdict: Sendable {
        let refusal = Mutex<RemoteFileError?>(nil)
    }

    func connect(_ op: SFTPOp) throws -> Bool {
        guard (1...65535).contains(endpoint.port) else {
            throw RemoteFileError.connection("invalid port \(endpoint.port) — must be between 1 and 65535")
        }
        if shared != nil {
            // The tab already logged in and checked the host key.
            if try openSFTP(op) { return true }
            guard endpoint.proto == .scp else {
                throw RemoteFileError.unsupported("The device refused the SFTP subsystem — connect with SCP instead")
            }
            return false
        }
        var legacy = false
        var established: SSHLink
        switch handshake(legacy: false, op) {
        case .success(let made): established = made
        case .failure(.fatal(let error)): throw error
        case .failure(.negotiation(let why)):
            // Old switches: the legacy set only when the host allows it.
            guard endpoint.legacyAlgorithms else { throw RemoteFileError.connection(why) }
            legacy = true
            switch handshake(legacy: true, op) {
            case .success(let made): established = made
            case .failure(.fatal(let error)): throw error
            case .failure(.negotiation(let why)): throw RemoteFileError.connection(why)
            }
        }
        link = established

        // No username yet (Open File's field left empty): the host key is
        // settled, so the card asks for one now — like an SSH tab, after
        // KEX — instead of failing (the user, 6.0 (11)).
        guard !endpoint.username.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RemoteFileError.passwordRequired
        }
        try authenticate(established, legacy: legacy, op)

        let connection = SSHConnection(transport: established.transport)
        self.connection = connection
        // Messages that arrived with USERAUTH_SUCCESS belong to the connection now.
        established.route = { try connection.handle($0) }
        do {
            try established.drainMessages()
        } catch {
            throw RemoteFileError.connection("connection lost: \(SSHWorker.describe(error))")
        }

        if try openSFTP(op) { return true }
        guard endpoint.proto == .scp else {
            throw RemoteFileError.unsupported("The device refused the SFTP subsystem — connect with SCP instead")
        }
        return false
    }

    /// TCP + version exchange + key exchange + the host-key decision, within
    /// SSHWorker's 15 s budget.
    private func handshake(legacy: Bool, _ op: SFTPOp) -> Result<SSHLink, HandshakeError> {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        let host = endpoint.host, port = endpoint.port, decision = endpoint.hostKey
        let fd: Int32
        switch SSHWorker.openTCPSocket(host: host, port: port, deadline: deadline,
                                       isRunning: { !op.cancelled.load(ordering: .relaxed) && !self.closing.load(ordering: .relaxed) }) {
        case .success(let socket): fd = socket
        case .failure(let failure):
            return .failure(.fatal(failure.message.map { RemoteFileError.connection($0) } ?? .cancelled))
        }
        SSHWorker.enableTCPKeepalive(on: fd)

        let verdict = Verdict()
        let base: AlgorithmPreferences = legacy ? .legacy : .modern
        let pinned = SSHWorker.loadKnownHosts().pinnedKeyTypes(host: host, port: port)
        let configuration = SSHTransport.Configuration(
            preferences: base.preferringHostKeyTypes(pinned),
            softwareVersion: "SheepTerm",
            groupExchangeBits: legacy ? 1024...8192 : 2048...8192,
            hostKeyValidator: { key in
                let outcome = SFTPHostKeyCheck.decide(key: key, host: host, port: port, decision: decision,
                                                      files: SSHWorker.loadKnownHosts(),
                                                      path: SSHWorker.sshDirectory + "/known_hosts")
                switch outcome {
                case .accept: return true
                case .refuse(let error):
                    verdict.refusal.withLock { $0 = error }
                    return false
                }
            })
        let candidate = SSHLink(fd: fd, transport: SSHTransport(configuration: configuration))
        candidate.transport.start()
        link = candidate
        lost = nil
        lastFailureWasHangUp = false
        lastLinkError = nil
        defer { link = nil }
        do {
            while !candidate.isReady {
                if clock.now >= deadline {
                    throw RemoteFileError.connection("timed out waiting for the server")
                }
                try step(op)
            }
        } catch {
            candidate.close()
            let underlying = lost
            lost = nil
            if let refusal = verdict.refusal.withLock({ $0 }) { return .failure(.fatal(refusal)) }
            if let remote = error as? RemoteFileError, remote == .cancelled { return .failure(.fatal(.cancelled)) }
            if let why = underlying, Self.isNegotiation(lastLinkError) { return .failure(.negotiation(why)) }
            return .failure(.fatal((error as? RemoteFileError) ?? .connection(SSHWorker.describe(error))))
        }
        return .success(candidate)
    }

    /// SSHWorker's rule for "retry with the legacy set": no common
    /// algorithm, a group-exchange prime under modern's 2048 bits, or an old
    /// device that hangs up on our KEXINIT naming the algorithms.
    private static func isNegotiation(_ error: Error?) -> Bool {
        guard let transport = error as? SSHTransportError else { return false }
        switch transport {
        case .negotiation, .keyExchange(.groupTooSmall): return true
        case .disconnectedByServer(let reason, let description):
            let text = description.lowercased()
            return reason == 3 || ["no match", "key exchange", "kex", "algorithm", "cipher"].contains(where: text.contains)
        default: return false
        }
    }

    // MARK: Authentication (queue)

    /// none, the host's own key, password, keyboard-interactive (non-echo
    /// password prompts get the password, user/login prompts the username —
    /// Aruba CX / TACACS gear that only offers it), then — when no password
    /// was given — the ssh-agent and ~/.ssh keys a terminal session would
    /// also try. Keys from the agent are NOT offered before a given password:
    /// each refused key spends a network device's MaxAuthTries.
    private func authenticate(_ link: SSHLink, legacy: Bool, _ op: SFTPOp) throws {
        let username = endpoint.username
        let auth = SSHUserAuth(transport: link.transport, username: username)
        link.parkMessages()
        var credentialInFlight = false

        func exchange(_ start: () throws -> Void) throws -> [SSHUserAuth.Event] {
            do {
                try start()
            } catch {
                throw RemoteFileError.connection("authentication could not start: \(SSHWorker.describe(error))")
            }
            var events: [SSHUserAuth.Event] = []
            var quietSince = ContinuousClock.now
            while true {
                while events.isEmpty, let payload = link.nextParked() {
                    do {
                        events += try auth.handle(payload).filter { if case .banner = $0 { return false }; return true }
                    } catch {
                        throw RemoteFileError.connection(SSHWorker.describe(error))
                    }
                }
                if !events.isEmpty { return events }
                do {
                    if try step(op) { quietSince = .now }
                } catch {
                    // A server that hangs up IN REPLY to a password refused it
                    // (sshd at MaxAuthTries, some gear on the first wrong one).
                    if credentialInFlight, lastFailureWasHangUp { throw RemoteFileError.authenticationFailed }
                    throw error
                }
                if quietSince.duration(to: .now) > Self.idleLimit {
                    throw RemoteFileError.connection("timed out waiting for the server")
                }
            }
        }

        guard try exchange({ try auth.requestService() }).contains(.serviceAccepted) else {
            throw RemoteFileError.connection("the server refused authentication")
        }
        let none = try exchange { try auth.tryNone() }
        if none.contains(.success) { return }
        var methods: [String] = []
        if case .failure(_, let offered, _)? = none.first { methods = offered }
        func offers(_ method: String) -> Bool { methods.isEmpty || methods.contains(method) }
        func note(_ events: [SSHUserAuth.Event]) -> (success: Bool, partial: Bool) {
            if events.contains(.success) { return (true, false) }
            if case .failure(_, let next, let partial)? = events.first {
                if !next.isEmpty { methods = next }
                return (false, partial)
            }
            return (false, false)
        }
        let preferences: AlgorithmPreferences = legacy ? .legacy : .modern

        // 1. The host's own key.
        if let text = endpoint.privateKey, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let passphrase = endpoint.keyPassphrase.flatMap { $0.isEmpty ? nil : Array($0.utf8) }
            let key: SSHPrivateKey
            do {
                key = try PEMPrivateKey.load(text, passphrase: passphrase)
            } catch {
                switch error {
                case .passphraseRequired: throw RemoteFileError.connection("The private key is encrypted — its passphrase is needed")
                case .wrongPassphrase: throw RemoteFileError.connection("Wrong passphrase for the private key")
                default: throw RemoteFileError.connection("Cannot read the private key (\(error))")
                }
            }
            let signer = PrivateKeySigner(key, label: "host key file")
            if offers("publickey"),
               let algorithm = publicKeyAlgorithm(for: signer.publicKey, accepted: preferences.hostKeys,
                                                  serverSignatureAlgorithms: link.transport.serverSignatureAlgorithms) {
                credentialInFlight = true
                let result = try exchange { try auth.tryPublicKey(signer, algorithm: algorithm) }
                credentialInFlight = false
                let outcome = note(result)
                if outcome.success { return }
            }
        }

        // 2. Password, then keyboard-interactive with the same password.
        let password = endpoint.password ?? ""
        if !password.isEmpty {
            if offers("password") {
                credentialInFlight = true
                let result = try exchange { try auth.tryPassword(password) }
                credentialInFlight = false
                if case .passwordChangeRequested? = result.first {
                    throw RemoteFileError.remote("The device says this password has expired — change it in a terminal session")
                }
                let outcome = note(result)
                if outcome.success { return }
            }
            if offers("keyboard-interactive") {
                if try keyboardInteractive(auth, password: password, exchange: exchange,
                                           inFlight: { credentialInFlight = $0 }, note: note) { return }
            }
        }

        // 3. The agent's and ~/.ssh's keys, as a terminal session tries them —
        //    only when no password was given, or the server takes nothing else.
        if offers("publickey"), password.isEmpty || !(offers("password") || offers("keyboard-interactive")) {
            var signers: [SSHSigner] = []
            if let socket = SSHAgent.socketPath, let identities = try? SSHAgent.identities(socketPath: socket) {
                for identity in identities {
                    identity.shouldCancel = { [weak self] in op.cancelled.load(ordering: .relaxed) || (self?.closing.load(ordering: .relaxed) ?? true) }
                }
                signers += identities
            }
            for entry in DefaultIdentities.load(directory: SSHWorker.sshDirectory) {
                if case .ready(let signer) = entry { signers.append(signer) }
            }
            for signer in signers {
                guard offers("publickey") else { break }
                guard let algorithm = publicKeyAlgorithm(for: signer.publicKey, accepted: preferences.hostKeys,
                                                         serverSignatureAlgorithms: link.transport.serverSignatureAlgorithms)
                else { continue }
                let query = try exchange { try auth.queryPublicKey(signer.publicKey, algorithm: algorithm) }
                guard query.contains(.publicKeyAcceptable(signer.publicKey)) else { _ = note(query); continue }
                let result: [SSHUserAuth.Event]
                do {
                    result = try exchange { try auth.tryPublicKey(signer, algorithm: algorithm) }
                } catch RemoteFileError.connection(let why) where why.hasPrefix("authentication could not start") {
                    continue        // the agent could not sign: next key
                }
                if note(result).success { return }
            }
        }

        if password.isEmpty, offers("password") || offers("keyboard-interactive") {
            throw RemoteFileError.passwordRequired
        }
        throw RemoteFileError.authenticationFailed
    }

    /// One keyboard-interactive exchange. True = authenticated.
    private func keyboardInteractive(_ auth: SSHUserAuth, password: String,
                                     exchange: (() throws -> Void) throws -> [SSHUserAuth.Event],
                                     inFlight: (Bool) -> Void,
                                     note: ([SSHUserAuth.Event]) -> (success: Bool, partial: Bool)) throws -> Bool {
        var interactive = try exchange { try auth.startKeyboardInteractive() }
        var rounds = 0
        while case .infoRequest(let request)? = interactive.first {
            rounds += 1
            if rounds > 8 { throw RemoteFileError.connection("keyboard-interactive did not finish") }
            var answers: [String] = []
            for prompt in request.prompts {
                let normalized = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let kind = SSHWorker.classifyPrompt(normalized)
                if !prompt.echo, !kind.additionalFactor, !kind.newPassword {
                    answers.append(password)
                } else if prompt.echo, ["user", "login", "name"].contains(where: normalized.contains) {
                    answers.append(endpoint.username)
                } else {
                    throw RemoteFileError.unsupported(
                        "The device asks “\(prompt.text)” — log in once from a terminal tab to answer it")
                }
            }
            inFlight(!answers.isEmpty)
            defer { inFlight(false) }
            interactive = try exchange { try auth.respond(answers) }
        }
        return note(interactive).success
    }

    // MARK: Channels (queue)

    private func openChannel(_ op: SFTPOp) throws -> UInt32 {
        guard let channels else { throw RemoteFileError.connection(lost ?? "not connected") }
        let id: UInt32
        do {
            id = try channels.openSessionChannel()
        } catch {
            markLost(SSHWorker.describe(error))
            throw RemoteFileError.connection(SSHWorker.describe(error))
        }
        try pump(op) { opened.contains(id) || openFailed[id] != nil || ended.contains(id) }
        if let why = openFailed.removeValue(forKey: id) {
            throw RemoteFileError.remote("The device refused a new channel: \(why)")
        }
        guard opened.contains(id), !ended.contains(id) else {
            throw RemoteFileError.remote("The device closed the channel")
        }
        return id
    }

    private func closeChannel(_ id: UInt32) {
        if let channels, channels.isOpen(id) { try? channels.close(id) }
        opened.remove(id)
        requestReplies.removeValue(forKey: id)
    }

    private func channelWrite(_ id: UInt32, _ bytes: [UInt8]) throws {
        guard let channels else { throw RemoteFileError.connection(lost ?? "not connected") }
        do {
            try channels.write(id, bytes)
        } catch {
            markLost(SSHWorker.describe(error))
            throw RemoteFileError.connection(SSHWorker.describe(error))
        }
    }

    /// Opens the "sftp" subsystem. False = the device refused it.
    private func openSFTP(_ op: SFTPOp) throws -> Bool {
        guard let channels else { throw RemoteFileError.connection("not connected") }
        let id = try openChannel(op)
        do {
            try channels.requestSubsystem(id, "sftp")
        } catch {
            throw RemoteFileError.connection(SSHWorker.describe(error))
        }
        try pump(op) { requestReplies[id] != nil || ended.contains(id) }
        guard requestReplies[id] == true, !ended.contains(id) else {
            closeChannel(id)
            return false
        }
        let wire = SFTPWire()
        self.wire = wire
        sftpChannel = id
        try channelWrite(id, wire.initPacket())
        try pump(op) { wire.serverVersion != 0 || ended.contains(id) }
        guard wire.serverVersion >= 3, !ended.contains(id) else {
            self.wire = nil
            sftpChannel = nil
            closeChannel(id)
            return false
        }
        sftpReady = true
        return true
    }

    // MARK: SFTP requests (queue)

    private func liveWire() throws -> SFTPWire {
        if let lost { throw RemoteFileError.connection(lost) }
        guard let wire, sftpReady else { throw RemoteFileError.connection("not connected") }
        return wire
    }

    /// Sends a request; returns its id.
    private func send(_ packet: [UInt8]) throws -> UInt32 {
        let wire = try liveWire()
        guard let id = sftpChannel else { throw RemoteFileError.connection("not connected") }
        try channelWrite(id, packet)
        return wire.latestRequestID
    }

    private func roundTrip(_ packet: [UInt8], _ op: SFTPOp) throws -> SFTPWire.Reply {
        let wire = try liveWire()
        let id = try send(packet)
        var reply: SFTPWire.Reply?
        do {
            try pump(op) {
                reply = wire.takeReply(for: id)
                return reply != nil
            }
        } catch {
            wire.forget(id)
            throw error
        }
        return reply!
    }

    /// Several requests in flight at once; replies in request order.
    private func roundTrips(_ packets: [[UInt8]], _ op: SFTPOp) throws -> [SFTPWire.Reply] {
        let wire = try liveWire()
        var ids: [UInt32] = []
        var got: [UInt32: SFTPWire.Reply] = [:]
        do {
            for packet in packets { ids.append(try send(packet)) }
            try pump(op) {
                for id in ids where got[id] == nil {
                    if let reply = wire.takeReply(for: id) { got[id] = reply }
                }
                return got.count == ids.count
            }
        } catch {
            for id in ids where got[id] == nil { wire.forget(id) }
            throw error
        }
        return ids.map { got[$0]! }
    }

    /// Closes a handle without waiting (an abandoned transfer).
    private func abandon(_ ids: some Sequence<UInt32>, handle: [UInt8]) {
        guard let wire else { return }
        for id in ids { wire.forget(id) }
        if lost == nil, let id = try? send(wire.close(handle)) { wire.forget(id) }
    }

    private func failure(_ reply: SFTPWire.Reply, path: String, what: String) -> RemoteFileError {
        guard case .status(let code, let message) = reply else {
            return .remote("\(what) \(path): unexpected reply from the server")
        }
        switch code {
        case SFTPWire.Status.noSuchFile: return .notFound(path)
        case SFTPWire.Status.permissionDenied: return .permissionDenied(path)
        case SFTPWire.Status.fileAlreadyExists: return .alreadyExists(path)
        case SFTPWire.Status.opUnsupported:
            return .unsupported(message.isEmpty ? "The server does not support \(what)" : message)
        default:
            return .remote(message.isEmpty ? "Cannot \(what) \(path)" : "Cannot \(what) \(path): \(message)")
        }
    }

    private func requireOK(_ reply: SFTPWire.Reply, path: String, what: String) throws {
        if case .status(SFTPWire.Status.ok, _) = reply { return }
        throw failure(reply, path: path, what: what)
    }

    /// True when `path` exists (for v3 servers, which answer FAILURE where
    /// v5 says FILE_ALREADY_EXISTS).
    private func exists(_ path: String, _ op: SFTPOp) throws -> Bool {
        let wire = try liveWire()
        if case .attrs = try roundTrip(wire.lstat(path), op) { return true }
        return false
    }

    static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    // MARK: Operations (queue)

    func home(_ op: SFTPOp) throws -> String {
        let wire = try liveWire()
        let reply = try roundTrip(wire.realpath("."), op)
        if case .names(let names) = reply, let first = names.first, !first.name.isEmpty { return first.name }
        if case .status = reply { throw failure(reply, path: ".", what: "find the home directory of") }
        return "/"
    }

    func list(_ path: String, _ op: SFTPOp) throws -> [RemoteEntry] {
        let wire = try liveWire()
        let open = try roundTrip(wire.openDir(path), op)
        guard case .handle(let handle) = open else { throw failure(open, path: path, what: "list") }
        var entries: [RemoteEntry] = []
        var links: [Int] = []
        var nameBytes = 0
        do {
            reading: while true {
                let reply = try roundTrip(wire.readDir(handle), op)
                switch reply {
                case .names(let names):
                    guard entries.count + names.count <= Self.maximumListing else {
                        throw RemoteFileError.remote("\(path) lists more than \(Self.maximumListing) entries")
                    }
                    nameBytes += names.reduce(0) { $0 + $1.name.utf8.count }
                    guard nameBytes <= Self.maximumListingBytes else {
                        throw RemoteFileError.remote("\(path) lists more than \(Self.maximumListingBytes / 1024 / 1024) MB of names")
                    }
                    for item in names where item.name != "." && item.name != ".." {
                        let attrs = item.attrs
                        if attrs.isSymlink { links.append(entries.count) }
                        entries.append(RemoteEntry(
                            name: item.name,
                            isDirectory: attrs.isDirectory,
                            isSymlink: attrs.isSymlink,
                            size: attrs.isDirectory ? nil : attrs.size.map { Int64(clamping: $0) },
                            modified: attrs.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                            permissions: SFTPWire.permissionString(attrs.permissions)))
                    }
                case .status(SFTPWire.Status.eof, _):
                    break reading
                default:
                    throw failure(reply, path: path, what: "list")
                }
            }
        } catch {
            abandon([], handle: handle)
            throw error
        }
        _ = try? roundTrip(wire.close(handle), op)
        // A symlink is a folder when its target is one (STAT follows it).
        if !links.isEmpty {
            let targets = try roundTrips(links.map { wire.stat(Self.join(path, entries[$0].name)) }, op)
            for (index, reply) in zip(links, targets) {
                if case .attrs(let target) = reply {
                    entries[index].isDirectory = target.isDirectory
                    entries[index].size = target.isDirectory ? nil : target.size.map { Int64(clamping: $0) }
                }
            }
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func makeDirectory(_ path: String, _ op: SFTPOp) throws {
        let wire = try liveWire()
        let reply = try roundTrip(wire.mkdir(path), op)
        if case .status(SFTPWire.Status.ok, _) = reply { return }
        if case .status(SFTPWire.Status.failure, _) = reply, try exists(path, op) { throw RemoteFileError.alreadyExists(path) }
        throw failure(reply, path: path, what: "create")
    }

    func remove(_ path: String, isDirectory: Bool, _ op: SFTPOp) throws {
        let wire = try liveWire()
        try requireOK(try roundTrip(isDirectory ? wire.rmdir(path) : wire.remove(path), op), path: path, what: "delete")
    }

    func rename(_ from: String, to: String, _ op: SFTPOp) throws {
        let wire = try liveWire()
        let reply = try roundTrip(wire.rename(from, to), op)
        if case .status(SFTPWire.Status.ok, _) = reply { return }
        if case .status(SFTPWire.Status.failure, _) = reply, try exists(to, op) { throw RemoteFileError.alreadyExists(to) }
        throw failure(reply, path: from, what: "rename")
    }

    /// ".name.sheepterm-<random>.part" beside the destination (≤ 255 bytes).
    static func partURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(DownloadCommit.partName(for: destination, tag: String(UUID().uuidString.prefix(8))))
    }

    private static func makePart(for destination: URL) throws -> (URL, FileHandle) {
        let part = partURL(for: destination)
        guard FileManager.default.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o644]),
              let handle = try? FileHandle(forWritingTo: part) else {
            throw RemoteFileError.permissionDenied(destination.deletingLastPathComponent().lastPathComponent)
        }
        return (part, handle)
    }

    func download(_ remotePath: String, to local: URL, replacing: Bool, progress: @escaping TransferProgress, _ op: SFTPOp) throws {
        let wire = try liveWire()
        let statReply = try roundTrip(wire.stat(remotePath), op)
        guard case .attrs(let attrs) = statReply else { throw failure(statReply, path: remotePath, what: "read") }
        if attrs.isDirectory { throw RemoteFileError.unsupported("\(remotePath) is a folder") }
        // Size 0 is "unknown" too: a virtual file (running-config) reports 0.
        let total: Int64? = attrs.size.flatMap { $0 > 0 ? Int64(clamping: $0) : nil }
        let cap = DownloadCap.bytes(for: local)
        if let total, total > cap {
            throw RemoteFileError.remote("Not enough free space for \(remotePath)")
        }

        let open = try roundTrip(wire.openRead(remotePath), op)
        guard case .handle(let handle) = open else { throw failure(open, path: remotePath, what: "read") }
        let (part, out): (URL, FileHandle)
        do {
            (part, out) = try Self.makePart(for: local)
        } catch {
            abandon([], handle: handle)
            throw error
        }
        var committed = false
        defer {
            try? out.close()
            if !committed { unlink(part.path) }
        }

        // Pipelined like OpenSSH's sftp: 64 READs of 32 KB in flight; replies
        // may come out of order — each lands at its own offset. A short read
        // (the server's own cap) asks again for the rest.
        var inFlight: [UInt32: (offset: UInt64, length: Int)] = [:]
        var nextOffset: UInt64 = 0
        var done: Int64 = 0
        var reachedEOF = false
        var throttle = ProgressThrottle(progress)
        do {
            func issue(_ offset: UInt64, _ length: Int) throws {
                inFlight[try send(wire.read(handle: handle, offset: offset, length: length))] = (offset, length)
            }
            while true {
                while !reachedEOF, inFlight.count < Self.window, total.map({ nextOffset < UInt64($0) }) ?? true {
                    try issue(nextOffset, Self.chunk)
                    nextOffset += UInt64(Self.chunk)
                }
                if inFlight.isEmpty { break }
                var got: (id: UInt32, reply: SFTPWire.Reply)?
                try pump(op) {
                    got = wire.takeAnyReply()
                    return got != nil
                }
                guard let (id, reply) = got, let request = inFlight.removeValue(forKey: id) else { continue }
                switch reply {
                case .data(let bytes):
                    guard !bytes.isEmpty, bytes.count <= request.length else {
                        throw RemoteFileError.remote("Read failed at \(done) bytes")
                    }
                    do {
                        try out.seek(toOffset: request.offset)
                        try out.write(contentsOf: bytes)
                    } catch {
                        throw RemoteFileError.remote("Cannot write \(local.lastPathComponent): \(error.localizedDescription)")
                    }
                    done += Int64(bytes.count)
                    guard done <= cap else { throw RemoteFileError.remote("\(remotePath) is larger than the free space") }
                    if bytes.count < request.length {
                        try issue(request.offset + UInt64(bytes.count), request.length - bytes.count)
                    }
                    throttle.tick(done, total)
                case .status(SFTPWire.Status.eof, _):
                    reachedEOF = true
                default:
                    throw failure(reply, path: remotePath, what: "read")
                }
            }
        } catch {
            abandon(inFlight.keys, handle: handle)
            throw error
        }
        _ = try? roundTrip(wire.close(handle), op)
        if let total, done != total {
            throw RemoteFileError.remote("\(remotePath) ended early: \(done) of \(total) bytes")
        }
        do {
            try out.synchronize()
            try out.close()
        } catch {
            throw RemoteFileError.remote("Cannot write \(local.lastPathComponent): \(error.localizedDescription)")
        }
        try DownloadCommit.commit(part, to: local, replacing: replacing)
        committed = true
        throttle.finish(done, total ?? done)
    }

    func upload(_ local: URL, to remotePath: String, progress: @escaping TransferProgress, _ op: SFTPOp) throws {
        let wire = try liveWire()
        guard let input = try? FileHandle(forReadingFrom: local) else { throw RemoteFileError.notFound(local.lastPathComponent) }
        defer { try? input.close() }
        let total = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        let open = try roundTrip(wire.openWrite(remotePath), op)
        guard case .handle(let handle) = open else { throw failure(open, path: remotePath, what: "write") }

        var inFlight: [UInt32: Int] = [:]
        var offset: UInt64 = 0
        var done: Int64 = 0
        var readAll = false
        var throttle = ProgressThrottle(progress)
        do {
            while true {
                while !readAll, inFlight.count < Self.window {
                    let data: Data?
                    do {
                        data = try input.read(upToCount: Self.chunk)
                    } catch {
                        throw RemoteFileError.remote("Cannot read \(local.lastPathComponent): \(error.localizedDescription)")
                    }
                    guard let data, !data.isEmpty else { readAll = true; break }
                    let bytes = [UInt8](data)
                    inFlight[try send(wire.write(handle: handle, offset: offset, bytes[...]))] = bytes.count
                    offset += UInt64(bytes.count)
                }
                if inFlight.isEmpty { break }
                var got: (id: UInt32, reply: SFTPWire.Reply)?
                try pump(op) {
                    got = wire.takeAnyReply()
                    return got != nil
                }
                guard let (id, reply) = got, let count = inFlight.removeValue(forKey: id) else { continue }
                try requireOK(reply, path: remotePath, what: "write")
                done += Int64(count)
                throttle.tick(done, total)
            }
        } catch {
            abandon(inFlight.keys, handle: handle)
            throw error
        }
        // The server may report a failed flush at CLOSE (disk full).
        try requireOK(try roundTrip(wire.close(handle), op), path: remotePath, what: "write")
        throttle.finish(done, total)
    }

    // MARK: SCP (queue) — blind get/put on an exec channel

    /// "flash:/img.swi" → ("flash:", "img.swi"); "backups/run.cfg" →
    /// ("backups", "run.cfg"); "primary" (no slash, CX) → ("primary", the
    /// local name).
    static func splitRemotePath(_ remotePath: String, fallbackName: String) -> (location: String, name: String) {
        guard let slash = remotePath.lastIndex(of: "/") else { return (remotePath, fallbackName) }
        let name = String(remotePath[remotePath.index(after: slash)...])
        let location = String(remotePath[..<slash])
        return (location.isEmpty ? "/" : location, name.isEmpty ? fallbackName : name)
    }

    private static func scpError(_ message: String, path: String) -> RemoteFileError {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("no such file") || lower.contains("not found") { return .notFound(path) }
        if lower.contains("permission denied") { return .permissionDenied(path) }
        return .remote(text.isEmpty ? "SCP failed" : text)
    }

    func scp(push: Bool, local: URL, remote: String, replacing: Bool = false, progress: @escaping TransferProgress, _ op: SFTPOp) throws {
        if let lost { throw RemoteFileError.connection(lost) }
        guard let channels else { throw RemoteFileError.connection("not connected") }
        var part: URL?
        var committed = false
        defer { if !committed, let part { unlink(part.path) } }
        let transfer: SCPTransfer
        if push {
            let (location, name) = Self.splitRemotePath(remote, fallbackName: local.lastPathComponent)
            guard let made = try? SCPTransfer(push: location, name: name, localURL: local) else {
                throw RemoteFileError.notFound(local.lastPathComponent)
            }
            transfer = made
        } else {
            let (url, handle) = try Self.makePart(for: local)
            try? handle.close()
            part = url
            guard let made = try? SCPTransfer(pull: remote, localURL: url, maximumBytes: DownloadCap.bytes(for: url)) else {
                throw RemoteFileError.permissionDenied(local.deletingLastPathComponent().lastPathComponent)
            }
            transfer = made
        }

        let channel = try openChannel(op)
        scpTransfer = transfer
        scpChannel = channel
        scpFailure = nil
        scpStderr = ""
        defer {
            scpTransfer = nil
            scpChannel = nil
            closeChannel(channel)
        }
        do {
            try channels.requestExec(channel, command: transfer.command)
        } catch {
            throw RemoteFileError.connection(SSHWorker.describe(error))
        }
        try pump(op) { requestReplies[channel] != nil || ended.contains(channel) }
        guard requestReplies[channel] == true else {
            throw RemoteFileError.unsupported("The device refused scp for “\(remote)”")
        }
        do {
            try transfer.beginExecApproved()
        } catch {
            throw Self.scpError(error.message, path: remote)
        }

        var throttle = ProgressThrottle(progress)
        // A push has nothing to read while it sends: poll briefly, or every
        // pass waits out the poll with the socket idle (5.7 MB/s measured).
        try pump(op, pollMS: push ? 2 : 200, service: {
            var chunk = transfer.outgoing
            if !chunk.isEmpty { try channelWrite(channel, chunk) }
            // Backpressure: read more of the file only while the channel
            // holds < 1 MB (a push used to read the whole file at disk speed).
            while !transfer.isFinished, scpFailure == nil, channels.pendingOutput(channel) < 1024 * 1024 {
                do { try transfer.feed([]) } catch let error as SCPError { scpFailure = error.message }
                chunk = transfer.outgoing
                if chunk.isEmpty { break }
                try channelWrite(channel, chunk)
            }
            if transfer.done > 0 { throttle.tick(transfer.done, transfer.total > 0 ? transfer.total : nil) }
        }) {
            transfer.isFinished || scpFailure != nil || ended.contains(channel)
        }
        // The final ack (pull) goes out before the channel closes.
        let tail = transfer.outgoing
        if !tail.isEmpty { try? channelWrite(channel, tail) }
        if let message = scpFailure ?? transfer.failureMessage { throw Self.scpError(message, path: remote) }
        guard transfer.isFinished else {
            throw Self.scpError(scpStderr.isEmpty ? "The device closed the SCP channel early" : scpStderr, path: remote)
        }
        if !scpStderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Self.scpError(scpStderr, path: remote)
        }
        if let part {
            try DownloadCommit.commit(part, to: local, replacing: replacing)
            committed = true
        }
        throttle.finish(transfer.done, transfer.total)
    }
}

/// The channel half of a connection, as the engine uses it: its own
/// `SSHConnection`, or a terminal tab's through `SSHChannelBridge`.
nonisolated protocol SFTPChannels: AnyObject {
    func openSessionChannel() throws -> UInt32
    func requestSubsystem(_ id: UInt32, _ name: String) throws
    func requestExec(_ id: UInt32, command: String) throws
    func write(_ id: UInt32, _ bytes: [UInt8]) throws
    func close(_ id: UInt32) throws
    func isOpen(_ id: UInt32) -> Bool
    func pendingOutput(_ id: UInt32) -> Int
}

nonisolated extension SSHConnection: SFTPChannels {
    func openSessionChannel() throws -> UInt32 { try openSession() }
}
nonisolated extension SSHChannelBridge: SFTPChannels {}
