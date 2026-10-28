import Darwin
import Foundation
import Synchronization

/// What `SerialTerminalController` drives: a console line is a console line
/// whether it is a USB cable (`SerialWorker`) or a telnet socket
/// (`TelnetWorker`) — bytes in, bytes out, a break, an end. The serial-only
/// parts (line speed, XMODEM) stay on `SerialWorker` itself.
nonisolated protocol ConsoleWorker: AnyObject, Sendable {
    var onData: (@Sendable ([UInt8]) -> Void)? { get set }
    var onNotice: (@Sendable (String) -> Void)? { get set }
    var onInputDiscarded: (@Sendable () -> Void)? { get set }
    var onStatus: (@Sendable (String) -> Void)? { get set }
    var onClosed: (@Sendable (String) -> Void)? { get set }
    @discardableResult func write(_ bytes: [UInt8]) -> Bool
    @discardableResult func sendBreak() -> Bool
    func stop()
    var isTransferring: Bool { get }
    /// Bytes accepted by `write` and not yet on the line: a transfer is
    /// refused until they are (it would drop them).
    var hasQueuedWrites: Bool { get }
    /// `hasQueuedWrites`, or bytes the loop took that are not out yet (the
    /// serial line's own buffer and the tty's output queue; telnet's socket
    /// outbox). Safe Paste waits for false before it counts a line's delay.
    var hasUnsentWrites: Bool { get }
    /// Send File via XMODEM (the device must already be waiting for it).
    @discardableResult func startTransfer(_ transfer: SerialWorker.Transfer) -> Bool
    func cancelTransfer()
}

extension SerialWorker: ConsoleWorker {}

/// Runs one telnet session (RFC 854) on its own queue — the SerialWorker
/// shape over a TCP socket: poll on the socket + a self-pipe, a bounded
/// input queue, one notice per stall. The protocol itself is
/// `TelnetProtocol` (sans-I/O, harness-tested); the connect is SSHWorker's
/// (`openTCP`: every address, 15 s, Stop interrupts it).
///
/// Nothing is typed into the device on the user's behalf: the only bytes
/// this sends unasked are telnet's own negotiation (window size, terminal
/// type, echo/go-ahead), which a CLI never sees as input.
nonisolated final class TelnetWorker: ConsoleWorker {
    private let queue = DispatchQueue(label: "sheepterm.telnet.session")
    private struct State: Sendable {
        var pendingWrites: [UInt8] = []
        /// The loop's socket outbox, as of its last pass (`hasUnsentWrites`).
        var unsentOutbox = 0
        var writeOverflowNotified = false
        /// True from start() until run() has completed all of its defers.
        var runActive = false
        var running = false
        var pendingBreak = false
        /// The grid size, as the terminal last reported it. Read by the loop
        /// for NAWS; `sizeChanged` marks it new.
        var size = (cols: 80, rows: 24)
        var sizeChanged = false
        var wakeFD: Int32 = -1
        var onData: (@Sendable ([UInt8]) -> Void)?
        var onNotice: (@Sendable (String) -> Void)?
        var onInputDiscarded: (@Sendable () -> Void)?
        var onStatus: (@Sendable (String) -> Void)?
        var onClosed: (@Sendable (String) -> Void)?
        var onLocalEcho: (@Sendable (Bool) -> Void)?
        /// Send File via XMODEM over the socket (5.0 (53)): asked for, not
        /// yet taken by the loop; while active the line is the file's.
        var pendingTransfer: SerialWorker.Transfer?
        var transferActive = false
        var cancelTransfer = false
    }
    private let state = Mutex(State())

    /// Same cap and reason as SerialWorker: above the app's own paste limit.
    private static let maxPendingWrites = SafePastePlan.maxBytes + 1024 * 1024
    /// Typed input is taken from the queue only while less than this sits
    /// unsent at the socket — so a Ctrl-C behind a long paste is not stuck
    /// behind megabytes the kernel has not taken (SSHWorker's 256 KiB rule).
    static let socketHighWater = 256 * 1024
    /// Connect budget: TCP, every address, the lot (SSH's 15 s).
    static let connectTimeout: Duration = .seconds(15)
    /// No progress on queued output for this long = the far end is gone.
    static let stallSeconds: Double = 60

    /// The message of a session the FAR END ended (a `logout`/`exit`, the
    /// device's exec-timeout). It starts with SSH's `sessionEndedPrefix` so
    /// the controller files it the same way: ended, not dropped — no
    /// auto-reconnect.
    static func endedMessage(host: String) -> String {
        SSHWorker.sessionEndedPrefix + "\(host) closed."
    }

    var onData: (@Sendable ([UInt8]) -> Void)? {
        get { state.withLock { $0.onData } }
        set { state.withLock { $0.onData = newValue } }
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

    /// The server stopped (or started) echoing: whether the client must echo
    /// typed text itself (`TelnetProtocol.needsLocalEcho`). Worker queue.
    var onLocalEcho: (@Sendable (Bool) -> Void)? {
        get { state.withLock { $0.onLocalEcho } }
        set { state.withLock { $0.onLocalEcho = newValue } }
    }

    /// XMODEM over telnet (a console server's line to a ROMMON): binary is
    /// asked for both ways first; typing and Break are refused meanwhile.
    var isTransferring: Bool { state.withLock { $0.transferActive } }

    var hasQueuedWrites: Bool { state.withLock { !$0.pendingWrites.isEmpty } }
    var hasUnsentWrites: Bool { state.withLock { !$0.pendingWrites.isEmpty || $0.unsentOutbox > 0 } }

    /// Refused while written bytes still wait for the socket, like
    /// `SerialWorker.startTransfer`.
    @discardableResult
    func startTransfer(_ transfer: SerialWorker.Transfer) -> Bool {
        state.withLock { state in
            guard state.running, !state.transferActive, state.pendingWrites.isEmpty else { return false }
            state.transferActive = true
            state.cancelTransfer = false
            state.pendingTransfer = transfer
            state.pendingBreak = false
            Self.poke(state.wakeFD)
            return true
        }
    }

    func cancelTransfer() {
        state.withLock { state in
            guard state.transferActive else { return }
            state.cancelTransfer = true
            Self.poke(state.wakeFD)
        }
    }

    func start(host: String, port: Int, cols: Int, rows: Int) {
        guard (1...65535).contains(port) else {
            onClosed?("invalid port \(port) — must be between 1 and 65535")
            return
        }
        let accepted = state.withLock { state in
            guard !state.runActive else { return false }
            state.runActive = true
            state.running = true
            state.pendingWrites.removeAll(keepingCapacity: true)
            state.unsentOutbox = 0
            state.pendingBreak = false
            state.writeOverflowNotified = false
            state.size = (cols, rows)
            state.sizeChanged = false
            return true
        }
        guard accepted else {
            onClosed?("the previous telnet session is still closing — try again")
            return
        }
        queue.async { [weak self] in
            self?.run(host: host, port: port)
        }
    }

    func stop() {
        state.withLock { state in
            state.running = false
            Self.poke(state.wakeFD)
        }
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        var notice: (@Sendable (String) -> Void)?
        var message = ""
        var accepted = false
        var discarded: (@Sendable () -> Void)?
        state.withLock { state in
            guard state.running, !state.transferActive else {
                discarded = state.onInputDiscarded
                return
            }
            // All-or-nothing, as on a serial line: never the front of a line.
            guard state.pendingWrites.count + bytes.count <= Self.maxPendingWrites else {
                discarded = state.onInputDiscarded
                if !state.writeOverflowNotified {
                    state.writeOverflowNotified = true
                    notice = state.onNotice
                    message = bytes.count > Self.maxPendingWrites
                        ? "that paste is larger than SheepTerm will send in one go — nothing was sent"
                        : "the connection is not draining — input is being discarded until it catches up"
                }
                return
            }
            state.writeOverflowNotified = false
            state.pendingWrites.append(contentsOf: bytes)
            accepted = true
            Self.poke(state.wakeFD)
        }
        if let notice { notice(message) }
        discarded?()
        return accepted
    }

    /// Telnet BREAK (IAC BRK): a console server turns it into a break on the
    /// serial line behind it. Ahead of queued text, like SerialWorker's.
    @discardableResult
    func sendBreak() -> Bool {
        state.withLock { state in
            guard state.running, !state.transferActive else { return false }
            state.pendingBreak = true
            Self.poke(state.wakeFD)
            return true
        }
    }

    /// The terminal's grid; reported to the server by NAWS when it agreed to it.
    func resize(cols: Int, rows: Int) {
        state.withLock { state in
            guard state.size != (cols, rows) else { return }
            state.size = (cols, rows)
            state.sizeChanged = true
            Self.poke(state.wakeFD)
        }
    }

    private static func poke(_ fd: Int32) {
        guard fd >= 0 else { return }
        var byte: UInt8 = 0
        _ = Darwin.write(fd, &byte, 1)
    }

    private var isRunning: Bool { state.withLock { $0.running } }

    private func run(host: String, port: Int) {
        var transfer: XModemSender?
        var transferJob: SerialWorker.Transfer?
        defer {
            let unclaimed = state.withLock { state -> SerialWorker.Transfer? in
                state.running = false
                state.pendingWrites.removeAll(keepingCapacity: true)
                state.unsentOutbox = 0
                state.pendingBreak = false
                state.runActive = false
                state.transferActive = false
                state.cancelTransfer = false
                defer { state.pendingTransfer = nil }
                return state.pendingTransfer
            }
            // A transfer cut off by the session's end still reports it.
            if let job = transferJob ?? unclaimed {
                switch transfer?.phase {
                case .done?: job.onFinish(.done)
                case .failed(let failure)?: job.onFinish(.failed(failure))
                default: job.onFinish(.failed(.sessionEnded))
                }
            }
        }
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            onClosed?("pipe failed: \(String(cString: strerror(errno)))")
            return
        }
        let pipeRead = pipeFDs[0], pipeWrite = pipeFDs[1]
        _ = fcntl(pipeWrite, F_SETFL, O_NONBLOCK)
        _ = fcntl(pipeRead, F_SETFL, O_NONBLOCK)
        _ = fcntl(pipeWrite, F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipeRead, F_SETFD, FD_CLOEXEC)
        state.withLock { $0.wakeFD = pipeWrite }
        defer {
            state.withLock { $0.wakeFD = -1 }
            close(pipeRead)
            close(pipeWrite)
        }

        let fd: Int32
        let deadline = ContinuousClock.now.advanced(by: Self.connectTimeout)
        switch SSHWorker.openTCP(host: host, port: port, deadline: deadline, isRunning: { [weak self] in self?.isRunning ?? false }) {
        case .success(let socket): fd = socket
        case .failure(.stopped): onClosed?("telnet session closed"); return
        case .failure(.message(let why)), .failure(.negotiation(let why)), .failure(.hostKey(let why)):
            onClosed?(why)
            return
        }
        defer { close(fd) }
        SSHWorker.enableTCPKeepalive(on: fd)
        // Wi-Fi swapped under the session: same watcher as SSH, or the tab
        // sits frozen until TCP keepalive gives up minutes later.
        let watcher = SessionPathWatcher()
        watcher.start(local: SessionPathWatcher.localAddress(of: fd), wake: pipeWrite)
        defer { watcher.stop() }

        let size = state.withLock { $0.size }
        var telnet = TelnetProtocol(cols: size.cols, rows: size.rows)
        var outbox = telnet.opening()
        let display = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        onStatus?("telnet · \(display)")

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var localEcho = false
        var lastReported = (bytes: -1, at: 0.0)
        /// Progress at most a few times a second, and the last step always.
        func reportTransfer(_ sender: XModemSender, _ job: SerialWorker.Transfer) {
            let now = Self.clock()
            let done = sender.bytesAcknowledged
            if done != lastReported.bytes, now - lastReported.at >= 0.2 || done == sender.totalBytes {
                lastReported = (done, now)
                job.onProgress(done, sender.totalBytes)
            }
        }
        var lastProgress = Self.clock()
        var lastAddressCheck = Self.clock()

        while isRunning {
            if Self.clock() - lastAddressCheck > 5 {
                lastAddressCheck = Self.clock()
                watcher.check()
            }
            if let lost = watcher.lostConnection() { onClosed?(lost); return }

            let (resized, cols, rows, wantsBreak) = state.withLock { state -> (Bool, Int, Int, Bool) in
                defer { state.sizeChanged = false; state.pendingBreak = false }
                return (state.sizeChanged, state.size.cols, state.size.rows, state.pendingBreak)
            }
            if resized { outbox += telnet.resize(cols: cols, rows: rows) }
            if wantsBreak {
                outbox += TelnetProtocol.breakCommand
                onNotice?("break sent")
            }
            // The file transfer: taken, cancelled, ticked, finished — once a pass.
            let (job, cancel) = state.withLock { state -> (SerialWorker.Transfer?, Bool) in
                defer { state.pendingTransfer = nil; state.cancelTransfer = false }
                return (state.pendingTransfer, state.cancelTransfer)
            }
            if let job {
                transferJob = job
                outbox += telnet.requestBinary()
                transfer = XModemSender(data: job.data, fileName: job.fileName, mode: job.mode, now: Self.clock())
                lastReported = (-1, 0)
            }
            if var sender = transfer, let job = transferJob {
                outbox += telnet.encode(cancel ? sender.cancel() : sender.tick(now: Self.clock()))
                transfer = sender
                reportTransfer(sender, job)
                if case .done = sender.phase { transfer = nil; transferJob = nil; state.withLock { $0.transferActive = false }; job.onFinish(.done) }
                else if case .failed(let why) = sender.phase { transfer = nil; transferJob = nil; state.withLock { $0.transferActive = false }; job.onFinish(.failed(why)) }
            }
            if outbox.count < Self.socketHighWater {
                let waiting = outbox.count
                let typed = state.withLock { state -> [UInt8] in
                    // Moved to the outbox under the same lock: no moment where
                    // the bytes are in neither count (`hasUnsentWrites`).
                    state.unsentOutbox = waiting + state.pendingWrites.count
                    defer { state.pendingWrites.removeAll(keepingCapacity: true) }
                    return state.pendingWrites
                }
                if !typed.isEmpty {
                    if outbox.isEmpty { lastProgress = Self.clock() }
                    outbox += telnet.encode(typed)
                }
            }

            if !outbox.isEmpty {
                let written = outbox.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress, raw.count) }
                if written > 0 {
                    outbox.removeFirst(written)
                    lastProgress = Self.clock()
                } else if written < 0, errno != EAGAIN, errno != EINTR {
                    onClosed?("connection lost: \(String(cString: strerror(errno)))")
                    return
                } else if Self.clock() - lastProgress > Self.stallSeconds {
                    onClosed?("connection lost: nothing could be sent for \(Int(Self.stallSeconds)) s")
                    return
                }
            } else {
                lastProgress = Self.clock()
            }

            let unsent = outbox.count
            state.withLock { $0.unsentOutbox = unsent }
            var events = Int16(POLLIN)
            if !outbox.isEmpty { events |= Int16(POLLOUT) }
            var pfds = [
                pollfd(fd: fd, events: events, revents: 0),
                pollfd(fd: pipeRead, events: Int16(POLLIN), revents: 0),
            ]
            // A transfer has deadlines (a start settle, 10 s answers).
            var timeout: Int32 = 1000
            if let deadline = transfer?.nextDeadline {
                timeout = Int32(max(5, min(1000, (deadline - Self.clock()) * 1000 + 1)))
            }
            let ready = poll(&pfds, 2, timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                onClosed?("poll failed: \(String(cString: strerror(errno)))")
                return
            }
            guard ready > 0 else { continue }
            if Int32(pfds[1].revents) & Int32(POLLIN) != 0 {
                var sink = [UInt8](repeating: 0, count: 256)
                while (sink.withUnsafeMutableBytes { Darwin.read(pipeRead, $0.baseAddress, $0.count) }) > 0 {}
            }
            let revents = Int32(pfds[0].revents)
            // A hangup arrives with whatever the far end said last: read it
            // (EOF follows) rather than drop it.
            if revents & Int32(POLLIN | POLLHUP) != 0 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    let (data, reply) = telnet.receive(Array(buffer[0..<count]))
                    outbox += reply
                    if var sender = transfer, let job = transferJob, !data.isEmpty {
                        // The device's half of the protocol, not text.
                        outbox += telnet.encode(sender.receive(data, now: Self.clock()))
                        let after = sender.leftover
                        transfer = sender
                        reportTransfer(sender, job)
                        if case .done = sender.phase { transfer = nil; transferJob = nil; state.withLock { $0.transferActive = false }; job.onFinish(.done) }
                        else if case .failed(let why) = sender.phase { transfer = nil; transferJob = nil; state.withLock { $0.transferActive = false }; job.onFinish(.failed(why)) }
                        if !after.isEmpty { onData?(after) }
                    } else if !data.isEmpty {
                        onData?(data)
                    }
                    if telnet.needsLocalEcho != localEcho {
                        localEcho = telnet.needsLocalEcho
                        onLocalEcho?(localEcho)
                    }
                } else if count == 0 {
                    onClosed?(Self.endedMessage(host: host))
                    return
                } else if errno != EAGAIN, errno != EINTR {
                    onClosed?("connection lost: \(String(cString: strerror(errno)))")
                    return
                }
            } else if revents & Int32(POLLERR | POLLNVAL) != 0 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                onClosed?("connection lost: \(String(cString: strerror(error == 0 ? EIO : error)))")
                return
            }
        }
        onClosed?("telnet session closed")
    }

    private static func clock() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

#if SHEEPTERM_TESTING
    func _testLifecycleSnapshot() -> (running: Bool, runActive: Bool, pendingWriteCount: Int) {
        state.withLock { ($0.running, $0.runActive, $0.pendingWrites.count) }
    }
#endif
}
