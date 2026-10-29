import Darwin
import Foundation

/// TFTP server (RFC 1350 + blksize/tsize/timeout options, RFC 2347–2349) for
/// File ▸ File Server: a switch runs `copy tftp://<mac>/file …` and pulls the
/// one file the user picked, or (with writes allowed) pushes a backup into
/// the chosen folder. What a name resolves to is `FileServerPlan.readTarget` /
/// `writeTarget`; a write never replaces a file.
///
/// 6.0 (13) restructure — the protocol is `TFTPTransfer` (TFTPProtocol.swift,
/// sans-I/O, harness-tested); this file is only its I/O:
/// - BSD UDP sockets (`UDPSocket`) on ONE serial queue, read through dispatch
///   sources. The old Network.framework server lost replies: a refusal's ERROR
///   was queued on the listener's per-peer flow and that flow was cancelled on
///   the next line, which drops the queued datagram (42 % of "file not found"
///   and 8 % of "file too large" answers never left the Mac in a 300-request
///   loop); sendto(2) here has handed the datagram to the kernel when it returns.
/// - Each accepted transfer gets its own socket on a fresh ephemeral port (RFC
///   1350's server TID), so ACKs cannot be forged blind on port 69; a datagram
///   to it from another port of the device gets ERROR 5 and the transfer goes
///   on. Refusals are answered from port 69.
/// - A device repeating its request while its transfer is open (same address
///   and port) is answered by THAT transfer — one reply per request — instead
///   of starting a second transfer from another port.
/// - Port 69 only (6.0 (12)): a fallback port broke the devices' copy commands.
///   close(2) frees the port at once; a restart waits only for listener sockets
///   a stop has not closed yet (`Closing`, app-wide — the model makes a new
///   server per start) and retries 69 for `FileServerPlan.tftpBindWindow`;
///   still busy = "Port 69 is in use by <process>" (`PortOwner.udp`).
/// - The app hears about transfers only through the @Sendable callbacks, which
///   run on the server's queue.
nonisolated final class TFTPServer: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Port still held after `FileServerPlan.tftpBindWindow`: the popover
    /// shows `description` as it is ("Port 69 is in use by …").
    struct PortInUse: Error, CustomStringConvertible {
        let description: String
    }

    private let queue = DispatchQueue(label: "sheepterm.tftp.server")
    private let readURL: @Sendable (String) -> URL?
    private let writeURL: @Sendable (String) -> URL?
    fileprivate let onProgress: @Sendable (ServerTransfer) -> Void

    private let callbackLock = NSLock()
    nonisolated(unsafe) private var listenerFailed: (@Sendable (String) -> Void)?
    /// The listener socket failed after it was ready: the app must show the
    /// server as off. Set from any thread.
    var onListenerFailed: (@Sendable (String) -> Void)? {
        get { callbackLock.withLock { listenerFailed } }
        set { callbackLock.withLock { listenerFailed = newValue } }
    }

    // Queue-confined.
    /// Port 69 over IPv4 and over IPv6 (one socket each, see `UDPSocket.listeners`).
    private var listeners: [Listener] = []
    /// One bound socket. `token` keys it in `Closing` — never the fd number,
    /// which the kernel hands out again the moment it is closed.
    private typealias Listener = (fd: Int32, family: Int32, source: DispatchSourceRead, token: UUID)
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var stopped = false
    private var buffer = [UInt8](repeating: 0, count: 65536)

    /// `readURL` / `writeURL` map the name a device asked for to a file, or
    /// nil to refuse; `writeURL` is consulted only for a write request, so
    /// "writes off" is a `writeURL` that always answers nil.
    init(readURL: @escaping @Sendable (String) -> URL?,
         writeURL: @escaping @Sendable (String) -> URL?,
         onProgress: @escaping @Sendable (ServerTransfer) -> Void) {
        self.readURL = readURL
        self.writeURL = writeURL
        self.onProgress = onProgress
    }

    /// Binds `preferredPort` and nothing else (69 in the app; 0 = any free
    /// port, for the tests) and returns the port bound.
    func start(preferredPort: UInt16 = 69) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(FileServerPlan.tftpBindWindow)
        // A stop → start: a listener the stop cancelled (this object's or an
        // earlier server's) is closed on its queue's next turn. Wait for it,
        // then retry the port itself (another program may be letting go).
        while Closing.busy, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        var lastError: UDPSocket.Failure?
        repeat {
            switch UDPSocket.listeners(port: preferredPort) {
            case .success(let bound):
                return try await install(bound)
            case .failure(let failure):
                lastError = failure
                guard failure.code == EADDRINUSE else {
                    throw Failure(description: "cannot listen on port \(preferredPort): \(failure)")
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        } while Date() < deadline
        if lastError?.code == EADDRINUSE {
            throw PortInUse(description: FileServerPlan.portBusyMessage(port: preferredPort,
                                                                     owner: PortOwner.udp(port: preferredPort)))
        }
        throw Failure(description: "cannot listen on port \(preferredPort)")
    }

    private func install(_ bound: [(fd: Int32, family: Int32, port: UInt16)]) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async { [self] in
                guard !stopped else {
                    for b in bound { close(b.fd) }
                    continuation.resume(throwing: Failure(description: "server stopped before it began listening"))
                    return
                }
                for old in listeners { closeListener(old) }
                listeners = bound.map { b in
                    let source = DispatchSource.makeReadSource(fileDescriptor: b.fd, queue: queue)
                    let fd = b.fd
                    let token = UUID()
                    source.setEventHandler { [weak self] in self?.drainListener(fd) }
                    source.setCancelHandler { close(fd); Closing.remove(token) }
                    source.activate()
                    return (b.fd, b.family, source, token)
                }
                continuation.resume(returning: bound[0].port)
            }
        }
    }

    /// Listener sockets a stop cancelled whose dispatch source has not
    /// closed them yet (GCD runs the cancel handler, which closes the fd, on
    /// the queue's next turn). App-wide: the model makes a new server per start.
    /// Keyed per LISTENER (a token made with it), not by fd: the cancel
    /// handler closes the fd before it removes its entry, and in that gap
    /// the kernel may give the same number to a new listener whose own
    /// close is then pending — an fd key would let the old handler erase it.
    enum Closing {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var open: [UUID: Date] = [:]
        static func add(_ token: UUID) { lock.withLock { open[token] = Date() } }
        static func remove(_ token: UUID) { _ = lock.withLock { open.removeValue(forKey: token) } }
        static func isPending(_ token: UUID) -> Bool { lock.withLock { open[token] != nil } }
        /// One that never closes (cannot happen with GCD, but never wait on
        /// it forever) is forgotten after 5 s.
        static var busy: Bool {
            lock.withLock {
                open = open.filter { $0.value.timeIntervalSinceNow > -5 }
                return !open.isEmpty
            }
        }
    }

    private func closeListener(_ l: Listener) {
        Closing.add(l.token)
        l.source.cancel()
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            for l in listeners { closeListener(l) }
            listeners = []
            for session in sessions.values { session.stop() }
            sessions.removeAll()
        }
    }

    /// Transfers at once, overall and per device address. TFTP has no login,
    /// so these caps keep one host (or spoofed RRQs) from opening unbounded
    /// sessions and file handles. A transfer that has finished and only
    /// dallies for a lost final ACK does not count.
    static let maximumSessions = 32
    static let maximumPerPeer = 4
    /// Largest file a device may push. Configs and tech-support bundles are
    /// far smaller; without a cap one peer could stream until the disk is
    /// full (block numbers wrap, so a write never has to end).
    static let maximumWriteBytes = Int(FileServerPlan.maximumUpload)

    /// Writes were switched off (or the folder changed): end every upload in
    /// flight now — the switch must mean "no more bytes land".
    func abortWrites() {
        queue.async { [self] in
            for session in sessions.values where session.isWriting { session.abort("writes were turned off") }
        }
    }

    // MARK: Listener (port 69)

    private func drainListener(_ fd: Int32) {
        // Bounded per wake-up so one flood cannot starve the transfers.
        for _ in 0..<64 {
            switch UDPSocket.receive(fd, into: &buffer) {
            case .datagram(let bytes, let from):
                handleRequest(bytes, from: from, listenerFD: fd)
            case .empty:
                return
            case .failed(let code):
                guard listeners.contains(where: { $0.fd == fd }) else { return }
                for l in listeners { closeListener(l) }
                listeners = []
                onListenerFailed?(String(cString: strerror(code)))
                return
            }
        }
    }

    private func handleRequest(_ bytes: Data, from peer: UDPAddress, listenerFD: Int32) {
        // Only a request opens anything; a stray ACK/DATA on port 69 gets no
        // answer (this server must not be a reflector).
        guard let op = TFTPPacket.opcode(of: bytes), op == TFTPOpcode.rrq.rawValue || op == TFTPOpcode.wrq.rawValue else { return }
        let open = sessions.values.filter { !$0.isFinished }
        if let same = open.first(where: { $0.peer.sameHost(peer) && $0.peer.port == peer.port }) {
            same.repeatedRequest()
            return
        }
        guard open.count < Self.maximumSessions,
              open.filter({ $0.peer.sameHost(peer) }).count < Self.maximumPerPeer else {
            // Say so instead of dropping it: a device retrying (or a second
            // copy) gets a reason, not a timeout (review 5.0 (58)).
            UDPSocket.send(listenerFD, TFTPPacket.error(code: TFTPErrorCode.notDefined, message: "server busy, try again").encoded, to: peer)
            return
        }
        let session = Session(server: self, peer: peer, family: peer.family, listenerFD: listenerFD)
        sessions[ObjectIdentifier(session)] = session
        session.begin(bytes)
    }

    fileprivate func sessionEnded(_ session: Session) {
        sessions[ObjectIdentifier(session)] = nil
    }

    fileprivate func resolveRead(_ name: String) -> URL? { readURL(name) }
    fileprivate func resolveWrite(_ name: String) -> URL? { writeURL(name) }
    /// Where writes would land (for the free-space check): the folder of
    /// any name the write rule accepts.
    fileprivate func resolveWriteFolderHint() -> URL? {
        writeURL("sheepterm-probe-\(UUID().uuidString)")?.deletingLastPathComponent()
    }
    fileprivate var serverQueue: DispatchQueue { queue }

    // MARK: - One transfer

    // Queue-confined like its owner: every source and timer runs on serverQueue.
    fileprivate final class Session: @unchecked Sendable {
        private unowned let server: TFTPServer
        let peer: UDPAddress
        private let family: Int32
        /// Port 69's socket: refusals are answered from there.
        private let listenerFD: Int32
        /// The transfer's own socket (its TID), once the request is accepted.
        private var fd: Int32 = -1
        private var readSource: DispatchSourceRead?
        private var timer: DispatchSourceTimer?
        private var machine: TFTPTransfer?

        private var isWrite = false
        private var filename = ""
        // Reads stream from disk block by block — a 700 MB image must not be
        // resident in RAM for the whole transfer.
        private var readHandle: FileHandle?
        private var fileSize: Int64 = 0
        private var writeHandle: FileHandle?
        private var writeTemp: URL?
        private var writeFinal: URL?
        private let token = UUID().uuidString
        private var torn = false
        /// The bar this session reported last, and whether it completed.
        private var lastActive: ServerTransfer?
        private var transferDone = false
        private var lastReported: Int64 = 0
        private var shown = false
        private var buffer = [UInt8](repeating: 0, count: 65536)

        var isFinished: Bool { torn || (machine?.isFinished ?? false) }
        var isWriting: Bool { isWrite && !isFinished }
        private var peerHost: String { peer.host }

        init(server: TFTPServer, peer: UDPAddress, family: Int32, listenerFD: Int32) {
            self.server = server
            self.peer = peer
            self.family = family
            self.listenerFD = listenerFD
        }

        // MARK: Request

        func begin(_ bytes: Data) {
            guard case .request(let request)? = TFTPPacket.parse(bytes) else {
                refuse(TFTPErrorCode.illegalOperation, "malformed request")
                return
            }
            filename = String(request.name.prefix(255))
            isWrite = request.isWrite
            guard request.mode == "octet" || request.mode == "netascii" else {
                refuse(TFTPErrorCode.illegalOperation, "mode \(request.mode) not supported")
                return
            }

            var limit = Int64.max
            if isWrite {
                // Never past the free space less a reserve: an upload (TFTP
                // has no login) must not take the Mac's disk to zero.
                limit = Int64(min(TFTPServer.maximumWriteBytes,
                                  max(0, Self.freeSpace(near: server.resolveWriteFolderHint()) - Int(DownloadCap.reserve))))
                if let refusal = TFTPNegotiation.writeRefusal(request, limit: limit) {
                    refuse(refusal.code, refusal.message)
                    return
                }
                var url = server.resolveWrite(filename)
                if url == nil {
                    guard let folder = server.resolveWriteFolderHint() else {
                        refuse(TFTPErrorCode.accessViolation, "receiving files is off")
                        return
                    }
                    // A name already there (re-running yesterday's backup
                    // command) lands beside it as name-2.ext: the same answer
                    // as a free name, so asking lists nothing (TFTP has no
                    // login), and nothing is replaced. Any other refusal is a
                    // bad name — the same for every folder.
                    let name = FileServerPlan.lastComponent(of: filename)
                    let taken = folder.appendingPathComponent(name, isDirectory: false)
                    guard FileServerPlan.isPlainName(name), Self.occupied(taken),
                          let variant = FileServerPlan.freeVariant(of: taken, exists: Self.occupied) else {
                        refuse(TFTPErrorCode.accessViolation, "file name not accepted")
                        return
                    }
                    url = variant
                }
                // The temp is made at the first DATA block, not here: a bare
                // request (a scanner, a probe) leaves nothing on disk.
                writeFinal = url
            } else {
                guard let url = server.resolveRead(filename),
                      let handle = try? FileHandle(forReadingFrom: url),
                      let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
                    refuse(TFTPErrorCode.fileNotFound, "file not found")
                    return
                }
                readHandle = handle
                fileSize = Int64(size)
            }

            let agreed = TFTPNegotiation.server(request, fileSize: isWrite ? nil : fileSize)
            guard openTransferSocket() else {
                refuse(TFTPErrorCode.notDefined, "could not open a transfer port")
                return
            }
            var transfer = TFTPTransfer(role: isWrite ? .receiver : .sender,
                                        opening: agreed.acknowledged.isEmpty ? .plain : .oack(agreed.acknowledged),
                                        peerPort: peer.port, blockSize: agreed.blockSize, limit: limit,
                                        expectedSize: isWrite ? agreed.expectedSize : nil,
                                        policy: .server(timeout: agreed.timeout))
            let actions = transfer.start(now: UDPSocket.now, source: read)
            machine = transfer
            perform(actions)
        }

        /// The request is refused before a transfer exists: ERROR from port
        /// 69, and a failed bar so "file not found" (a typo in the device
        /// command) shows in the popover.
        private func refuse(_ code: UInt16, _ message: String) {
            UDPSocket.send(listenerFD, TFTPPacket.error(code: code, message: message).encoded, to: peer)
            lastActive = ServerTransfer(token: token, peer: peerHost, name: filename.isEmpty ? "?" : filename,
                                        isUpload: isWrite, done: 0, total: 0)
            reportFailure(message)
            teardown()
        }

        /// A socket on a fresh ephemeral port, of the device's family.
        private func openTransferSocket() -> Bool {
            guard case .success(let bound) = UDPSocket.bound(port: 0, family: family) else { return false }
            fd = bound.fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: server.serverQueue)
            let socket = fd
            source.setEventHandler { [weak self] in self?.drain() }
            source.setCancelHandler { close(socket) }
            readSource = source
            source.activate()
            return true
        }

        // MARK: Machine I/O

        private func drain() {
            for _ in 0..<64 {
                guard !torn else { return }
                switch UDPSocket.receive(fd, into: &buffer) {
                case .datagram(let bytes, let from):
                    // Another host is not part of this transfer at all; another
                    // port of the device's host is a wrong TID (the machine
                    // answers it with ERROR 5).
                    guard from.sameHost(peer), var m = machine else { continue }
                    let actions = m.receive(bytes, from: from.port, now: UDPSocket.now, source: read)
                    machine = m
                    perform(actions)
                case .empty:
                    return
                case .failed:
                    fail("transfer socket failed")
                    return
                }
            }
        }

        func repeatedRequest() {
            guard var m = machine else { return }
            let actions = m.repeatedRequest()
            machine = m
            perform(actions)
        }

        func abort(_ why: String) {
            guard var m = machine else { return }
            let actions = m.abort(code: TFTPErrorCode.notDefined, message: why)
            machine = m
            perform(actions)
        }

        private func fail(_ why: String) {
            reportFailure(why)
            teardown()
        }

        private func perform(_ actions: [TFTPTransfer.Action]) {
            for action in actions {
                guard !torn else { return }
                switch action {
                case .send(let bytes, let port):
                    UDPSocket.send(fd, bytes, to: peer.withPort(port))
                case .deliver(let payload):
                    guard deliver(payload) else { return }
                case .progress(let done):
                    reportProgress(done: done)
                case .lastBlock:
                    finishWrite()
                    return   // finishWrite fed the machine; its actions ran
                case .finished(let outcome):
                    switch outcome {
                    case .done(let bytes):
                        reportDone(done: bytes)
                    case .failed(let failure):
                        reportFailure(Self.detail(failure), aborted: { if case .aborted = failure { return true } else { return false } }())
                    }
                }
            }
            afterStep()
        }

        /// Re-arms the timer to the machine's next deadline, or lets go once
        /// it is closed.
        private func afterStep() {
            guard !torn, let m = machine else { return }
            if m.isClosed { teardown(); return }
            guard let deadline = m.nextDeadline else { timer?.cancel(); timer = nil; return }
            if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: server.serverQueue)
                t.setEventHandler { [weak self] in self?.tick() }
                timer = t
                t.schedule(deadline: .now() + max(0, deadline - UDPSocket.now), leeway: .milliseconds(10))
                t.activate()
            } else {
                timer?.schedule(deadline: .now() + max(0, deadline - UDPSocket.now), leeway: .milliseconds(10))
            }
        }

        private func tick() {
            guard !torn, var m = machine else { return }
            let actions = m.tick(now: UDPSocket.now)
            machine = m
            perform(actions)
        }

        /// The sender's block reader.
        private func read(_ offset: Int64, _ count: Int) throws -> Data {
            guard let handle = readHandle, offset <= fileSize else { throw Failure(description: "read failed") }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }

        /// Receive into a hidden temp beside the target; it becomes the real
        /// file only once the last block arrives, and only if the name is
        /// still free.
        private func deliver(_ payload: Data) -> Bool {
            if writeHandle == nil {
                guard writeTemp == nil, let url = writeFinal else { return false }
                let temp = url.deletingLastPathComponent().appendingPathComponent(".sheepterm-tftp-\(UUID().uuidString)")
                guard FileManager.default.createFile(atPath: temp.path, contents: nil),
                      let handle = try? FileHandle(forWritingTo: temp) else {
                    try? FileManager.default.removeItem(at: temp)
                    abort(code: TFTPErrorCode.accessViolation, "cannot create file")
                    return false
                }
                writeHandle = handle
                writeTemp = temp
            }
            do {
                try writeHandle?.write(contentsOf: payload)
                return true
            } catch {
                abort(code: TFTPErrorCode.diskFull, "write failed")
                return false
            }
        }

        private func abort(code: UInt16, _ why: String) {
            guard var m = machine else { return }
            let actions = m.abort(code: code, message: why)
            machine = m
            perform(actions)
        }

        /// The last block is in: promote BEFORE the final ACK — the device
        /// hears success only once the file is really in place.
        private func finishWrite() {
            try? writeHandle?.close()
            writeHandle = nil
            guard var m = machine else { return }
            let saved = promoteWrite()
            let actions = saved == 0
                ? m.commit(now: UDPSocket.now)
                : m.abort(code: saved == EEXIST ? TFTPErrorCode.fileExists : TFTPErrorCode.diskFull,
                          message: saved == EEXIST ? "file already exists" : "could not save file")
            machine = m
            perform(actions)
        }

        /// The temp becomes the final name with renamex_np(RENAME_EXCL):
        /// atomic, and it fails when the name was taken meanwhile — never a
        /// replace (link(2) was refused by exFAT/SMB). The saved file is
        /// quarantined like a download: it came from the network.
        private func promoteWrite() -> Int32 {
            guard let temp = writeTemp, var final = writeFinal else { return EINVAL }
            // Writes still on, same folder? Off or moved meanwhile: nothing lands.
            guard let folder = server.resolveWriteFolderHint(),
                  folder.standardizedFileURL.path == final.deletingLastPathComponent().standardizedFileURL.path else { return EACCES }
            // Taken while it arrived: the next free name-N, never a replace.
            let asked = folder.appendingPathComponent(FileServerPlan.lastComponent(of: filename), isDirectory: false)
            var attempts = 0
            while renamex_np(temp.path, final.path, UInt32(RENAME_EXCL)) != 0 {
                let failure = errno
                guard failure == EEXIST else { return failure }
                // Bounded, and never the same name twice (a folder whose
                // lookups lag its renames — network, file provider).
                attempts += 1
                guard attempts < 16, let next = FileServerPlan.freeVariant(of: asked, exists: Self.occupied),
                      next != final else { return EEXIST }
                final = next
            }
            writeFinal = final
            writeTemp = nil
            Quarantine.mark(final, from: peerHost)
            return 0
        }

        /// Anything at that name — a file, a directory, a dangling symlink.
        static func occupied(_ url: URL) -> Bool {
            var st = stat()
            return lstat(url.path, &st) == 0 || errno != ENOENT
        }

        private func discardTemp() {
            try? writeHandle?.close()
            writeHandle = nil
            if let temp = writeTemp { try? FileManager.default.removeItem(at: temp) }
            writeTemp = nil
        }

        /// The server stopped: the bar says so, nothing is left behind.
        func stop() {
            guard !torn else { return }
            if var t = lastActive, !transferDone { t.state = .failed; t.detail = "stopped"; server.onProgress(t) }
            transferDone = true
            teardown()
        }

        private func teardown() {
            guard !torn else { return }
            torn = true
            timer?.cancel()
            timer = nil
            // Every reply already went out with a synchronous sendto: the
            // socket can close now without losing an ERROR.
            readSource?.cancel()
            readSource = nil
            try? readHandle?.close()
            readHandle = nil
            // Still holding a temp ⇒ the upload never completed; discard it.
            discardTemp()
            server.sessionEnded(self)
        }

        // MARK: Progress

        static func detail(_ failure: TFTPTransfer.Failure) -> String {
            switch failure {
            case .timedOut: return "timed out"
            case .peer(_, let message): return "device error: \(message.isEmpty ? "error" : message)"
            case .tooLarge: return "file too large"
            case .sizeMismatch(let got, let expected): return "size mismatch: got \(got) of \(expected) bytes"
            case .badOption(let why): return why
            case .aborted(_, let message): return message
            }
        }

        /// Throttled to ~128 KB so a big image doesn't flood main. Nothing
        /// shows until the peer is proven (its first DATA block, or an ACK on
        /// the transfer port): a bare or spoofed request repeated every few
        /// minutes kept an "active" bar up, so the server never turned itself
        /// off and the Transfer Log filled with timeouts (review 6.0 (4)).
        private func reportProgress(done: Int64) {
            guard machine?.proven == true else { return }
            let total = isWrite ? (machine?.expectedSize ?? 0) : fileSize
            let t = ServerTransfer(token: token, peer: peerHost, name: filename, isUpload: isWrite, done: done, total: total)
            lastActive = t
            if !shown || done - lastReported >= 128 * 1024 || (total > 0 && done >= total) {
                shown = true
                lastReported = done
                server.onProgress(t)
            }
        }

        private func reportDone(done: Int64) {
            transferDone = true
            // A write saved beside a taken name shows (and logs) the name it got.
            let name = isWrite ? (writeFinal?.lastPathComponent ?? filename) : filename
            server.onProgress(ServerTransfer(token: token, peer: peerHost, name: name, isUpload: isWrite,
                                             done: done, total: done, state: .done))
        }

        /// A failed bar — for a transfer that showed one, or one THIS end
        /// refused or aborted (writes turned off, a read error). An unproven
        /// request that timed out or was ended by its sender shows nothing.
        private func reportFailure(_ detail: String, aborted: Bool = false) {
            guard !transferDone else { return }
            if lastActive == nil, aborted {
                lastActive = ServerTransfer(token: token, peer: peerHost, name: filename.isEmpty ? "?" : filename,
                                            isUpload: isWrite, done: 0, total: 0)
            }
            guard var t = lastActive else { return }
            transferDone = true
            t.state = .failed
            t.detail = detail
            server.onProgress(t)
        }

        private static func freeSpace(near folder: URL?) -> Int {
            guard let folder,
                  let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
                  let free = values.volumeAvailableCapacityForImportantUsage else { return Int.max }
            return Int(clamping: free)
        }
    }
}

/// Who holds a local UDP port, for "Port 69 is in use by …": every process
/// this user may inspect (libproc, in-process, ~5 ms). A root-owned holder
/// (launchd's tftpd socket) is not visible → nil, and the message says only
/// "in use".
nonisolated enum PortOwner {
    static func udp(port: UInt16) -> String? {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let got = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return nil }
        for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.size) where pid > 0 {
            if holds(pid: pid, udpPort: port) {
                var name = [CChar](repeating: 0, count: 256)
                guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
                let text = String(decoding: name.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }

    private static func holds(pid: pid_t, udpPort port: UInt16) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 8)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let length = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, length) == length else { continue }
            let socket = info.psi
            guard socket.soi_protocol == IPPROTO_UDP,
                  socket.soi_family == AF_INET || socket.soi_family == AF_INET6 else { continue }
            if UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.soi_proto.pri_in.insi_lport)) == port { return true }
        }
        return false
    }
}
