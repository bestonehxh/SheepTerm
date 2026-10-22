import Darwin
import Foundation
import Synchronization

/// Runs one serial-port session (POSIX termios) on its own queue,
/// mirroring SSHWorker's thread-safe surface.
nonisolated final class SerialWorker: Sendable {
    private let queue = DispatchQueue(label: "sheepterm.serial.session")
    private struct State: Sendable {
        var pendingWrites: [UInt8] = []
        /// Set when input was discarded because the buffer is full; cleared
        /// by the next accepted write, so one stall produces one notice.
        var writeOverflowNotified = false
        /// True from start() until run() has completed all of its defers.
        /// Kept separate from `running`, which stop() clears immediately.
        var runActive = false
        var running = false
        /// A break condition the user asked for (⌃⌥B). Taken by the loop
        /// ahead of `pendingWrites`: a break is for a device that is booting,
        /// and the moment matters more than the order against queued text.
        var pendingBreak = false
        /// A line speed the user picked in the tab (5.0 (39)), not yet taken
        /// by the loop. Applied on the open port — no close, no reopen.
        var pendingBaud: Int?
        var onBaudChanged: (@Sendable (Int) -> Void)?
        /// Write end of the self-pipe; -1 when the loop isn't up.
        var wakeFD: Int32 = -1
        var onData: (@Sendable ([UInt8]) -> Void)?
        var onNotice: (@Sendable (String) -> Void)?
        /// Fired when a write was refused. A paced paste has to stop: the
        /// pacer counts lines it HANDED OVER, so without this the HUD
        /// reports a full send while the device got a config with holes.
        var onInputDiscarded: (@Sendable () -> Void)?
        var onStatus: (@Sendable (String) -> Void)?
        var onClosed: (@Sendable (String) -> Void)?
        /// Send File via XMODEM (5.0 (22)): asked for, not yet taken by the
        /// loop. From the moment it is asked until it ends the port is the
        /// transfer's — `write` refuses everything else.
        var pendingTransfer: Transfer?
        var transferActive = false
        var cancelTransfer = false
    }

    /// One XMODEM/YMODEM send, as handed to the loop. The callbacks run on
    /// the worker queue; the caller hops to main.
    struct Transfer: Sendable {
        let data: [UInt8]
        let fileName: String
        let mode: XModemSender.Mode
        /// (bytes acknowledged, total) — at most a few times a second.
        let onProgress: @Sendable (Int, Int) -> Void
        /// The sender's last phase: `.done` or `.failed(…)`. Exactly once.
        let onFinish: @Sendable (XModemSender.Phase) -> Void
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
    /// The port runs at a new speed (`setBaud` went through). Worker queue.
    var onBaudChanged: (@Sendable (Int) -> Void)? {
        get { state.withLock { $0.onBaudChanged } }
        set { state.withLock { $0.onBaudChanged = newValue } }
    }

    /// `cfsetspeed` takes a `speed_t`, which is UNSIGNED: `speed_t(-1)` is a
    /// Swift trap and not a failed guard, so a `Host.port` of −1 restored from
    /// a backup used to kill the whole process — every other open session with
    /// it. Refuse the value the way `SSHWorker.connect` refuses a port outside
    /// 1…65535: with a sentence the user can read, on the session that asked
    /// for it, leaving the rest of the app alone.
    private static func rejection(forBaud baudRate: Int) -> String? {
        guard !Host.serialBaudRange.contains(baudRate) else { return nil }
        return "invalid baud rate \(baudRate) — must be between "
            + "\(Host.serialBaudRange.lowerBound) and \(Host.serialBaudRange.upperBound). "
            + "Edit the host and pick a baud rate."
    }

    func start(devicePath: String, baudRate: Int) {
        // Before the run is claimed, so a refused baud leaves the worker free
        // for the corrected host instead of parked in `runActive`.
        if let rejection = Self.rejection(forBaud: baudRate) {
            onClosed?(rejection)
            return
        }
        let accepted = state.withLock { state in
            // One file descriptor owns this worker queue at a time. Do not let
            // a new run overtake teardown after stop().
            guard !state.runActive else { return false }
            state.runActive = true
            state.running = true
            state.pendingWrites.removeAll(keepingCapacity: true)
            state.pendingBreak = false
            state.pendingBaud = nil
            state.writeOverflowNotified = false
            return true
        }
        // A refusal must SAY so — see the matching note in SSHWorker.start.
        guard accepted else {
            onClosed?("the previous serial session is still closing — try again")
            return
        }
        queue.async { [weak self] in
            self?.run(devicePath: devicePath, baudRate: baudRate)
        }
    }

    func stop() {
        state.withLock { state in
            state.running = false
            // Wake the poll loop now. Holding the Mutex prevents a race with
            // teardown closing and invalidating (or reusing) the descriptor.
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
            // A dead or wedged session must not buffer input forever — and
            // a paced paste has to hear about the refusal, exactly as it
            // does for a full buffer, or it keeps counting lines the port
            // never got.
            guard state.running else {
                discarded = state.onInputDiscarded
                return
            }
            // A file is going out: a key on the line would corrupt a block,
            // and a paste has to hear that it was not sent.
            guard !state.transferActive else {
                discarded = state.onInputDiscarded
                return
            }
            // All-or-nothing, and on a console cable this is the case that
            // matters most: the old code appended `bytes.prefix(room)`, so a
            // paced paste into a 9600-baud port — which drains ~960 B/s while
            // the pacer feeds ~8 KB/s — would eventually send the FRONT of a
            // config line to a live switch and drop the rest.
            guard state.pendingWrites.count + bytes.count <= Self.maxPendingWrites else {
                discarded = state.onInputDiscarded
                if !state.writeOverflowNotified {
                    state.writeOverflowNotified = true
                    notice = state.onNotice
                    message = bytes.count > Self.maxPendingWrites
                        ? "that paste is larger than SheepTerm will send in one go — nothing was sent"
                        : "serial port is not draining — input is being discarded until it catches up"
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

    /// Queue a break condition (a ~0.4 s space on the line — `tcsendbreak`
    /// ignores its duration on macOS). Returns false when there is no live
    /// session to send it on, so the caller can say so instead of pretending.
    ///
    /// It jumps the write queue on purpose: the one time a console user
    /// reaches for Break is to stop a switch's boot loader, and that window
    /// is a second or two wide. Text queued behind a slow port can wait.
    @discardableResult
    func sendBreak() -> Bool {
        state.withLock { state in
            // A break in the middle of a block corrupts it: not while a
            // file transfer owns the line.
            guard state.running, !state.transferActive else { return false }
            state.pendingBreak = true
            if state.wakeFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.write(state.wakeFD, &byte, 1)
            }
            return true
        }
    }

    /// Change the line speed of the open port (5.0 (39)): the status bar's
    /// baud menu, for a console that came up at the wrong speed. Taken by the
    /// loop at the top of its next pass; success is `onStatus` with the new
    /// line + `onBaudChanged`, a driver refusal an `onNotice`. false = no live
    /// session, a file transfer owns the line, or not a baud rate.
    @discardableResult
    func setBaud(_ baudRate: Int) -> Bool {
        guard Self.rejection(forBaud: baudRate) == nil else { return false }
        return state.withLock { state in
            guard state.running, !state.transferActive else { return false }
            state.pendingBaud = baudRate
            if state.wakeFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.write(state.wakeFD, &byte, 1)
            }
            return true
        }
    }

    private func takeBaud() -> Int? {
        state.withLock { state in
            defer { state.pendingBaud = nil }
            return state.pendingBaud
        }
    }

    private var isRunning: Bool {
        state.withLock { $0.running }
    }

    /// Starts sending a file over the line (the device must already be
    /// waiting: ROMMON `xmodem -c …`, a BootROM's "download via XMODEM").
    /// false = no live session, or a transfer is already running.
    @discardableResult
    func startTransfer(_ transfer: Transfer) -> Bool {
        state.withLock { state in
            guard state.running, !state.transferActive else { return false }
            state.transferActive = true
            state.cancelTransfer = false
            state.pendingTransfer = transfer
            // What was typed before it is the device's no more — and a
            // Break asked for a moment earlier must not land mid-handshake.
            state.pendingWrites.removeAll(keepingCapacity: true)
            state.pendingBreak = false
            if state.wakeFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.write(state.wakeFD, &byte, 1)
            }
            return true
        }
    }

    /// Stops the transfer with the protocol's abort (CAN × 8); the device
    /// drops back to its prompt. A no-op when none is running.
    func cancelTransfer() {
        state.withLock { state in
            guard state.transferActive else { return }
            state.cancelTransfer = true
            if state.wakeFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.write(state.wakeFD, &byte, 1)
            }
        }
    }

    var isTransferring: Bool {
        state.withLock { $0.transferActive }
    }

    /// Clears and returns the pending break flag.
    private func takeBreak() -> Bool {
        state.withLock { state in
            let pending = state.pendingBreak
            state.pendingBreak = false
            return pending
        }
    }

    private func takeWrites() -> [UInt8] {
        state.withLock { state in
            let writes = state.pendingWrites
            state.pendingWrites.removeAll()
            return writes
        }
    }

    private func run(devicePath: String, baudRate: Int) {
        // Reset the public lifecycle on every exit path and drop input that
        // belongs to the dead device. Resource defers registered below run
        // first, then runActive is released for a possible later start().
        // A transfer cut off by the session ending still reports its end
        // (registered first, so it runs LAST — after the port is closed).
        var transfer: XModemSender?
        var transferJob: Transfer?
        defer {
            let unclaimed = state.withLock { state -> Transfer? in
                state.running = false
                state.pendingWrites.removeAll(keepingCapacity: true)
                state.pendingBreak = false
                state.pendingBaud = nil
                state.runActive = false
                state.transferActive = false
                state.cancelTransfer = false
                defer { state.pendingTransfer = nil }
                return state.pendingTransfer
            }
            // Still running when the session ended. A sender that had in
            // fact finished (its last ACK read just before the loop ended)
            // reports how it finished; anything else did not finish.
            if let job = transferJob ?? unclaimed {
                switch transfer?.phase {
                case .done?: job.onFinish(.done)
                case .failed(let failure)?: job.onFinish(.failed(failure))
                default: job.onFinish(.failed(.sessionEnded))
                }
            }
        }
        // `start` already refused an unusable baud, but the trap is one line
        // below `cfsetspeed` and the promise is that NO path reaches it with a
        // value `speed_t` cannot hold — so the check is repeated here, where
        // it is next to the thing it protects, rather than trusted from afar.
        if let rejection = Self.rejection(forBaud: baudRate) {
            onClosed?(rejection)
            return
        }
        var fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        // A reconnect reaches open() before the PREVIOUS session's defers
        // have run: stop() only pokes the self-pipe, so for a few
        // milliseconds the old descriptor still holds TIOCEXCL and the port
        // answers EBUSY. Retry briefly instead of failing the reconnect
        // outright (this also rides out another app letting go of the cable).
        if fd < 0, errno == EBUSY {
            let deadline = Date().addingTimeInterval(1.0)
            while fd < 0, isRunning, Date() < deadline {
                usleep(20_000)
                fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
                if fd < 0, errno != EBUSY { break }
            }
        }
        guard fd >= 0 else {
            onClosed?("cannot open \(devicePath): \(String(cString: strerror(errno)))")
            return
        }
        defer { close(fd) }

        // Self-pipe so write() can wake the poll loop immediately; lets the
        // idle timeout be a full second with zero added input latency.
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            onClosed?("pipe failed: \(String(cString: strerror(errno)))")
            return
        }
        let pipeRead = pipeFDs[0]
        let pipeWrite = pipeFDs[1]
        // Non-blocking so a full pipe can never stall the caller of write().
        _ = fcntl(pipeWrite, F_SETFL, O_NONBLOCK)
        // Never inherited across exec (a local shell tab's child).
        _ = fcntl(pipeWrite, F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipeRead, F_SETFD, FD_CLOEXEC)
        state.withLock { $0.wakeFD = pipeWrite }
        defer {
            state.withLock { $0.wakeFD = -1 }
            close(pipeRead)
            close(pipeWrite)
        }

        // Exclusive access so two apps don't fight over the console cable.
        // Not fatal — some drivers reject it — so warn and carry on.
        if ioctl(fd, TIOCEXCL) != 0 {
            onNotice?("could not lock port exclusively — another app may have it open")
        }

        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else {
            onClosed?("tcgetattr failed: \(String(cString: strerror(errno)))")
            return
        }
        // Hand the port back the way we found it.
        var original = tty
        defer { tcsetattr(fd, TCSANOW, &original) }
        cfmakeraw(&tty)
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        // 8N1
        tty.c_cflag &= ~tcflag_t(PARENB)
        tty.c_cflag &= ~tcflag_t(CSTOPB)
        tty.c_cflag &= ~tcflag_t(CSIZE)
        tty.c_cflag |= tcflag_t(CS8)
        // No flow control
        tty.c_cflag &= ~tcflag_t(CRTSCTS)
        tty.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        guard cfsetspeed(&tty, speed_t(baudRate)) == 0,
              tcsetattr(fd, TCSANOW, &tty) == 0 else {
            onClosed?("cannot configure \(baudRate) baud: \(String(cString: strerror(errno)))")
            return
        }

        func reportStatus(_ baud: Int) {
            onStatus?("serial · \((devicePath as NSString).lastPathComponent) · \(baud) 8N1")
        }
        reportStatus(baudRate)

        /// A speed picked in the tab: same termios, new speed, on the open
        /// port. TCSANOW, not TCSADRAIN — the port is at the wrong speed, and
        /// waiting for its output to drain is waiting on the very thing that
        /// is wrong (a wedged line would hang the change forever).
        func applyBaudIfPending() {
            guard let baud = takeBaud() else { return }
            var current = termios()
            guard tcgetattr(fd, &current) == 0,
                  cfsetspeed(&current, speed_t(baud)) == 0,
                  tcsetattr(fd, TCSANOW, &current) == 0 else {
                onNotice?("cannot set \(baud) baud: \(String(cString: strerror(errno)))")
                return
            }
            // The new speed first, then the status line: both hop to main in
            // order, and the status handler reads the host's port.
            onBaudChanged?(baud)
            reportStatus(baud)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)

        /// Puts the line in break for the driver's fixed duration when one is
        /// pending. Blocking: `tcsendbreak` returns after the condition ends
        /// (~0.4 s), which is also how long the far end needs to notice it —
        /// nothing else on this queue is more urgent during that time.
        func sendBreakIfPending() {
            guard takeBreak() else { return }
            if tcsendbreak(fd, 0) == 0 {
                onNotice?("break sent")
            } else {
                onNotice?("break failed: \(String(cString: strerror(errno)))")
            }
        }

        /// One non-blocking read, handed straight to the session. Returns
        /// false when the session is over — the caller must return, and
        /// `onClosed` has already been fired.
        ///
        /// A nested function and not two copies: the write loop and the idle
        /// poll below both read, and the last time they each had their own
        /// copy only one of them ran while the send side was blocked. See the
        /// note in the write loop.
        func readOnce() -> Bool {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                if transfer != nil {
                    // The device's half of the protocol, not text.
                    let reply = transfer!.receive(Array(buffer[0..<count]), now: Self.clock())
                    let after = transfer!.leftover
                    guard writeTransfer(reply) else { return false }
                    if !after.isEmpty { onData?(after) }
                } else {
                    onData?(Array(buffer[0..<count]))
                }
            } else if count == 0 {
                // EOF — device gone (cable unplugged).
                onClosed?("serial device disconnected")
                return false
            } else if errno != EAGAIN, errno != EINTR {
                onClosed?("read failed: \(String(cString: strerror(errno)))")
                return false
            }
            return true
        }

        /// Writes a frame of the transfer whole (a 1K block at 9600 baud is
        /// ~1 s of line). Returns false when the session is over (`onClosed`
        /// already fired).
        func writeTransfer(_ bytes: [UInt8]) -> Bool {
            var offset = 0
            var lastProgress = Self.clock()
            while offset < bytes.count {
                guard isRunning else { return false }
                if Self.clock() - lastProgress > 60 {
                    onClosed?("write stalled for 60 s — is flow control stuck?")
                    return false
                }
                let written = bytes[offset...].withUnsafeBytes { raw in
                    Darwin.write(fd, raw.baseAddress, raw.count)
                }
                if written > 0 {
                    offset += written
                    lastProgress = Self.clock()
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno != EAGAIN {
                    onClosed?("write failed: \(String(cString: strerror(errno)))")
                    return false
                } else {
                    var wfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&wfd, 1, 100)
                    if Int32(wfd.revents) & Int32(POLLHUP | POLLERR | POLLNVAL) != 0 {
                        onClosed?("serial device disconnected")
                        return false
                    }
                }
            }
            return true
        }

        var lastReported = (bytes: -1, at: 0.0)
        /// Takes a new transfer, a cancel, a timeout, progress and the end —
        /// once per pass. false = the session is over.
        func serviceTransfer() -> Bool {
            let (job, cancel) = state.withLock { state -> (Transfer?, Bool) in
                defer { state.pendingTransfer = nil; state.cancelTransfer = false }
                return (state.pendingTransfer, state.cancelTransfer)
            }
            if let job {
                transferJob = job
                transfer = XModemSender(data: job.data, fileName: job.fileName, mode: job.mode, now: Self.clock())
                lastReported = (-1, 0)
            }
            guard var sender = transfer, let job = transferJob else { return true }
            let out = cancel ? sender.cancel() : sender.tick(now: Self.clock())
            transfer = sender
            guard writeTransfer(out) else { return false }
            let now = Self.clock()
            let acknowledged = sender.bytesAcknowledged
            if acknowledged != lastReported.bytes, now - lastReported.at >= 0.2 || acknowledged == sender.totalBytes {
                lastReported = (acknowledged, now)
                job.onProgress(acknowledged, sender.totalBytes)
            }
            switch sender.phase {
            case .done, .failed:
                transfer = nil
                transferJob = nil
                state.withLock { $0.transferActive = false }
                job.onFinish(sender.phase)
            default:
                break
            }
            return true
        }

        while isRunning {
            // Ahead of a transfer taken this pass: its first byte goes out
            // at the speed the user picked before starting it.
            applyBaudIfPending()
            guard serviceTransfer() else { return }
            // Before the queued text, every pass — see `sendBreak`.
            sendBreakIfPending()
            let writes = takeWrites()
            if !writes.isEmpty {
                var offset = 0
                // Stall deadline, not a batch deadline: a 100 KB paste at
                // 9600 baud needs ~107 s of steady progress, which is fine
                // — only abort when the port makes NO progress for 60 s
                // (flow control wedged).
                var lastProgress = Date()
                while offset < writes.count {
                    // Bail out when the tab is closed instead of spinning
                    // forever on a stalled port.
                    guard isRunning else { return }
                    // A break asked for in the middle of a long paste (or a
                    // stalled one) must not wait for the paste to finish.
                    sendBreakIfPending()
                    if Date().timeIntervalSince(lastProgress) > 60 {
                        onClosed?("write stalled for 60 s — is flow control stuck?")
                        return
                    }
                    let written = writes[offset...].withUnsafeBytes { raw in
                        Darwin.write(fd, raw.baseAddress, raw.count)
                    }
                    if written > 0 {
                        offset += written
                        lastProgress = Date()
                    } else if written < 0, errno == EINTR {
                        continue
                    } else if written < 0, errno != EAGAIN {
                        onClosed?("write failed: \(String(cString: strerror(errno)))")
                        return
                    }
                    // Inbound, WHATEVER the write did. This read used to sit
                    // inside the `written > 0` branch, so a port whose output
                    // buffer was full stopped reading altogether — the two
                    // directions of a serial line are independent, and the
                    // send side being wedged is exactly when the far end is
                    // most likely to be saying why. Measured against a pty
                    // with 1 MB queued and the master not draining: 0 bytes
                    // of 14 injected inbound arrived in 2 s, and all 14 landed
                    // the instant the send side drained — up to the 60 s
                    // stall deadline below, that is how long a console can go
                    // unread (and unlogged).
                    guard readOnce() else { return }
                    if written <= 0 {
                        // EAGAIN or a 0-byte write: output buffer full —
                        // sleep in the kernel until the port is writable
                        // instead of usleep-spinning. POLLIN as well as
                        // POLLOUT: waiting on writability alone would leave
                        // arriving bytes sitting in the driver for the whole
                        // 100 ms even though we could take them at once.
                        var wfd = pollfd(fd: fd, events: Int16(POLLIN | POLLOUT), revents: 0)
                        _ = poll(&wfd, 1, 100)
                        let revents = Int32(wfd.revents)
                        if revents & Int32(POLLIN) != 0 {
                            guard readOnce() else { return }
                        }
                        // Same rule as the idle poll below: checked after the
                        // read and not as an else of POLLIN, so a hangup that
                        // arrives WITH data is honored without losing what
                        // came with it. Without it, a device that hangs up
                        // while our send side is wedged is noticed only when
                        // the write itself fails or the 60 s stall deadline
                        // runs out — and a hangup does not always fail a
                        // write that is already parked on EAGAIN.
                        if revents & Int32(POLLHUP | POLLERR | POLLNVAL) != 0 {
                            onClosed?("serial device disconnected")
                            return
                        }
                    }
                }
            }

            // Sleep in the kernel until bytes arrive or write() pokes the
            // self-pipe. The pipe wake covers pending writes, so the idle
            // timeout only needs to notice unplug (POLLHUP) and stop() —
            // 1 wakeup/sec, zero added input latency.
            var pfds = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: pipeRead, events: Int16(POLLIN), revents: 0),
            ]
            // A transfer has deadlines (a 0.1 s start settle, 10 s answers):
            // wake for the next one instead of the idle second.
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
            if ready > 0 {
                // Drain the wake pipe; the queued bytes it announced are
                // picked up by takeWrites() at the top of the next pass.
                if Int32(pfds[1].revents) & Int32(POLLIN) != 0 {
                    var sink = [UInt8](repeating: 0, count: 256)
                    _ = sink.withUnsafeMutableBytes { raw in
                        Darwin.read(pipeRead, raw.baseAddress, raw.count)
                    }
                }
                let revents = Int32(pfds[0].revents)
                if revents & Int32(POLLIN) != 0 {
                    guard readOnce() else { return }
                }
                // Checked independently, NOT as an else of POLLIN: a hangup
                // arriving WITH pending data (POLLIN|POLLHUP) must still be
                // honored after the read — as an else-if, a read that hit
                // EAGAIN would leave the HUP unnoticed and the loop would
                // keep polling a dead port.
                if revents & Int32(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    onClosed?("serial device disconnected")
                    return
                }
            }
        }
        onClosed?("serial session closed")
    }

    /// Monotonic seconds for the transfer's deadlines (a wall-clock jump
    /// must not fire or starve a 10 s timeout).
    private static func clock() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

#if SHEEPTERM_TESTING
    /// Compiled only by the standalone worker regression harness.
    func _testLifecycleSnapshot() -> (
        running: Bool,
        runActive: Bool,
        pendingWriteCount: Int,
        pendingBreak: Bool,
        pendingBaud: Int?
    ) {
        state.withLock { ($0.running, $0.runActive, $0.pendingWrites.count, $0.pendingBreak, $0.pendingBaud) }
    }
#endif
}
