import Foundation
import Network

/// TFTP server (RFC 1350 + blksize/tsize/timeout options, RFC 2347–2349) for
/// File ▸ File Server: a switch runs `copy tftp://<mac>/file …` and pulls the
/// one file the user picked, or (with writes allowed) pushes a backup into
/// the chosen folder. Ported from SheepDrop's server, which was hardened
/// against real devices and an audit (2026-10-02); what changed here is
/// WHAT a name resolves to — `FileServerPlan.readTarget` / `writeTarget`
/// instead of a served root folder — and that a write never replaces a file.
///
/// - Network.framework UDP: the listener hands us one NWConnection per remote
///   endpoint; each accepted transfer moves to its own ephemeral port (RFC
///   1350's server TID), so ACKs cannot be forged blind on port 69.
/// - Port 69 only (6.0 (12)): a fallback port broke the devices' copy
///   commands (most forms cannot carry one). A restart waits for the
///   listener the last stop left closing — any server object's, they are
///   tracked app-wide in `Retired` — and retries 69 for
///   `FileServerPlan.tftpBindWindow`; still busy = the start fails with
///   "Port 69 is in use by <process>" (`PortOwner.udp`).
/// - Everything runs on one serial queue; the app hears about transfers only
///   through the @Sendable callbacks.
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
    /// The listener died after it was ready (interface gone, port taken
    /// away): the app must show the server as off.
    var onListenerFailed: (@Sendable (String) -> Void)?

    // Queue-confined.
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]

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

    /// Binds `preferredPort` and nothing else (69 in the app; a free high
    /// port in the tests) and returns it.
    func start(preferredPort: UInt16 = 69) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(FileServerPlan.tftpBindWindow)
        // A stop → start: the listener the stop cancelled (this object's or
        // an earlier server's — the app makes a new one per start) may still
        // hold the port. Wait for it first, then retry the port itself.
        while Retired.busy, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        var lastError: Error?
        repeat {
            do {
                return try await listen(on: preferredPort)
            } catch {
                lastError = error
                guard Self.isAddressInUse(error) else { throw error }
                try? await Task.sleep(for: .milliseconds(150))
            }
        } while Date() < deadline
        if let lastError, Self.isAddressInUse(lastError) {
            throw PortInUse(description: FileServerPlan.portBusyMessage(port: preferredPort,
                                                                     owner: PortOwner.udp(port: preferredPort)))
        }
        throw lastError ?? Failure(description: "cannot listen on port \(preferredPort)")
    }

    private static func isAddressInUse(_ error: Error) -> Bool {
        if case .posix(let code) = error as? NWError { return code == .EADDRINUSE }
        return false
    }

    /// What a listener's state means to `listen` before it has answered.
    enum ListenerOutcome: Equatable {
        case ready
        /// Never bound: cancel it and hand `start` the error (an
        /// address-in-use is retried there until `tftpBindWindow`, then
        /// `PortInUse`).
        case failed(NWError)
        case cancelled
        case keepWaiting
    }

    /// `.waiting` with EADDRINUSE is the port taken, not a passing network
    /// change: left alone (`default: break`) the listener waited there and
    /// `start` never returned (6.0 (12) review) — it is a failure like
    /// `.failed`. Any other `.waiting` (no network yet) keeps waiting.
    static func listenerOutcome(_ state: NWListener.State) -> ListenerOutcome {
        switch state {
        case .ready: return .ready
        case .failed(let error): return .failed(error)
        case .waiting(let error) where isAddressInUse(error): return .failed(error)
        case .cancelled: return .cancelled
        default: return .keepWaiting
        }
    }

    /// Listeners a stop cancelled that have not reported `.cancelled` yet,
    /// across every TFTPServer object.
    enum Retired {
        private static let lock = NSLock()
        /// Held strongly: a listener nobody holds never reports `.cancelled`
        /// (the server object, and with it the listener, is dropped on stop).
        nonisolated(unsafe) private static var closing: [ObjectIdentifier: (listener: NWListener, since: Date)] = [:]

        static func add(_ listener: NWListener) {
            // Only one that may still hold the port: a failed or cancelled
            // listener reports nothing more and would hold up every start.
            switch listener.state {
            case .cancelled, .failed: return
            default: break
            }
            lock.withLock { closing[ObjectIdentifier(listener)] = (listener, Date()) }
        }
        /// By identifier: the listener's own state handler calls this, and
        /// capturing the listener there would keep it alive.
        static func remove(_ id: ObjectIdentifier) {
            _ = lock.withLock { closing.removeValue(forKey: id) }
        }
        /// A listener that never reports back is forgotten after 5 s.
        static var busy: Bool {
            lock.withLock {
                closing = closing.filter { $0.value.since.timeIntervalSinceNow > -5 }
                return !closing.isEmpty
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if let listener { Retired.add(listener); listener.cancel() }
            listener = nil
            for session in sessions.values { session.cancel() }
            sessions.removeAll()
        }
    }

    private func listen(on port: UInt16) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    continuation.resume(throwing: Failure(description: "bad port \(port)"))
                    return
                }
                let candidate: NWListener
                do {
                    candidate = try NWListener(using: .udp, on: nwPort)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Resume exactly once across ready/failed/cancelled.
                let resumed = Box(false)
                let candidateID = ObjectIdentifier(candidate)
                candidate.stateUpdateHandler = { [weak self] state in
                    if case .cancelled = state { Retired.remove(candidateID) }
                    guard let self else { return }
                    self.queue.async {
                        switch Self.listenerOutcome(state) {
                        case .ready:
                            if !resumed.value {
                                resumed.value = true
                                continuation.resume(returning: port)
                            }
                        case .failed(let error):
                            if !resumed.value {
                                resumed.value = true
                                // Never bound: not a listener to wait for
                                // (the retry must not "retire" it).
                                if self.listener === candidate { self.listener = nil }
                                candidate.cancel()
                                continuation.resume(throwing: error)
                            } else if self.listener === candidate {
                                self.listener = nil
                                self.onListenerFailed?(String(describing: error))
                            }
                        case .cancelled:
                            if !resumed.value {
                                resumed.value = true
                                continuation.resume(throwing: Failure(description: "server stopped before it began listening"))
                            }
                        case .keepWaiting:
                            break
                        }
                    }
                }
                candidate.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    self.queue.async { self.accept(connection) }
                }
                if let old = listener { Retired.add(old); old.cancel() }
                listener = candidate
                candidate.start(queue: queue)
            }
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Transfers at once, overall and per device address. TFTP has no login,
    /// so these caps keep one host (or spoofed RRQs) from opening unbounded
    /// sessions and file handles.
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

    private func accept(_ connection: NWConnection) {
        let session = Session(server: self, connection: connection)
        let host = session.peerHost
        guard sessions.count < Self.maximumSessions,
              sessions.values.filter({ $0.peerHost == host }).count < Self.maximumPerPeer else {
            // Say so instead of dropping it: a device retrying (or a second
            // copy) gets a reason, not a timeout (review 5.0 (58)).
            var busy = Data([0, 5, 0, 0])
            busy.append(contentsOf: Array("server busy, try again".utf8)); busy.append(0)
            connection.start(queue: queue)
            connection.send(content: busy, completion: .contentProcessed { _ in connection.cancel() })
            // A flow that never gets ready never completes the send: cancel
            // it anyway, so a flood cannot pile up connections (review 6.0).
            queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
            return
        }
        sessions[ObjectIdentifier(session)] = session
        session.begin()
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

    // Queue-confined like its owner — every callback hops onto serverQueue.
    fileprivate final class Session: @unchecked Sendable {
        private unowned let server: TFTPServer
        /// The listener-side flow the request arrived on (server port).
        private let connection: NWConnection
        /// The transfer's own socket on a fresh ephemeral port. Nil until the
        /// request is accepted.
        private var transfer: NWConnection?
        private var io: NWConnection { transfer ?? connection }
        private let peer: String

        private var isWrite = false
        private var filename = ""
        private var blockSize = 512
        // Reads stream from disk block by block — a 700 MB image must not be
        // resident in RAM for the whole transfer.
        private var readHandle: FileHandle?
        private var fileSize: Int = 0
        private var writeHandle: FileHandle?
        private var writeTemp: URL?
        private var writeFinal: URL?
        private var writtenBytes: Int = 0
        /// This upload's ceiling: 16 GB, or less when the disk is short.
        private var writeLimit = TFTPServer.maximumWriteBytes
        private var expectedTotal: Int?
        private var currentBlock: UInt16 = 0   // last block sent (read) / acked (write)
        private var lastPacket = Data()
        private var retries = 0
        /// Set once the peer acknowledges a DATA block (or sends data). Until
        /// then the "peer" may be a spoofed address: answer once, retransmit
        /// at most once, so this server is a poor reflector.
        private var peerProven = false
        private var generation = 0
        private var finished = false
        private var sentFinal = false
        private let token = UUID().uuidString
        /// The bar this session reported last, and whether it completed.
        private var lastActive: ServerTransfer?
        private var transferDone = false
        private var lastReported = 0

        var isWriting: Bool { isWrite && !finished }

        func abort(_ why: String) {
            guard !finished else { return }
            sendError(0, why)
        }

        /// The device's address without the (per-transfer) UDP port.
        var peerHost: String {
            if case let .hostPort(host, _) = connection.endpoint { return "\(host)" }
            return peer
        }

        init(server: TFTPServer, connection: NWConnection) {
            self.server = server
            self.connection = connection
            if case let .hostPort(host, port) = connection.endpoint {
                self.peer = "\(host):\(port)"
            } else {
                self.peer = "?"
            }
        }

        func begin() {
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.finish(nil) }
            }
            connection.start(queue: server.serverQueue)
            receiveNext(first: true)
        }

        func cancel() {
            finished = true
            if var t = lastActive, !transferDone { t.state = .failed; t.detail = "stopped"; server.onProgress(t) }
            discardTemp()
            connection.cancel()
            transfer?.cancel()
        }

        /// Moves the session onto its own ephemeral UDP port, connected to the
        /// device; the listener-side flow is released.
        private func openTransferPort() {
            // An explicit wildcard local endpoint is required: with none,
            // Network.framework tries the listener's own port and the flow
            // sits in .waiting(EADDRINUSE).
            let params = NWParameters.udp
            var anyHost: NWEndpoint.Host = .ipv4(.any)
            if case let .hostPort(host, _) = connection.endpoint, case .ipv6 = host {
                anyHost = .ipv6(.any)
            }
            params.requiredLocalEndpoint = .hostPort(host: anyHost, port: .any)
            let next = NWConnection(to: connection.endpoint, using: params)
            next.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .waiting: self?.finish("could not open a transfer port", failed: true)
                default: break
                }
            }
            next.start(queue: server.serverQueue)
            transfer = next
            connection.stateUpdateHandler = nil
            connection.cancel()
        }

        private func receiveNext(first: Bool = false) {
            io.receiveMessage { [weak self] data, _, _, error in
                guard let self, !self.finished else { return }
                if error != nil { self.finish(nil); return }
                guard let data, data.count >= 2 else {
                    if first { self.finish(nil) } else { self.receiveNext() }
                    return
                }
                self.handle(packet: data, first: first)
            }
        }

        private func handle(packet: Data, first: Bool) {
            let opcode = UInt16(packet[packet.startIndex]) << 8 | UInt16(packet[packet.startIndex + 1])
            // A new peer's first datagram must be a request.
            if first && opcode != 1 && opcode != 2 { finish(nil); return }
            switch opcode {
            case 1, 2: // RRQ / WRQ
                guard first else { receiveNext(); return }
                startRequest(packet: packet, write: opcode == 2)
            case 3: handleData(packet)
            case 4: handleAck(packet)
            case 5:
                let message = String(data: packet.dropFirst(4).prefix(while: { $0 != 0 }), encoding: .utf8) ?? "error"
                finish("device error: \(message)", failed: true)
            default:
                receiveNext()
            }
        }

        // MARK: Request

        private func startRequest(packet: Data, write: Bool) {
            var fields: [String] = []
            var current = Data()
            for byte in packet.dropFirst(2) {
                if byte == 0 {
                    fields.append(String(decoding: current, as: UTF8.self))
                    current.removeAll()
                } else {
                    current.append(byte)
                }
            }
            guard fields.count >= 2 else { sendError(4, "malformed request"); return }
            filename = String(fields[0].prefix(255))
            isWrite = write
            let mode = fields[1].lowercased()
            guard mode == "octet" || mode == "netascii" else {
                sendError(4, "mode \(mode) not supported")
                return
            }

            var options: [(String, String)] = []
            var index = 2
            while index + 1 < fields.count {
                options.append((fields[index].lowercased(), fields[index + 1]))
                index += 2
            }

            if isWrite {
                // Never past the free space less a reserve: an upload (TFTP
                // has no login) must not take the Mac's disk to zero.
                writeLimit = min(TFTPServer.maximumWriteBytes,
                                 max(0, Self.freeSpace(near: server.resolveWriteFolderHint()) - Int(DownloadCap.reserve)))
                if let size = options.first(where: { $0.0 == "tsize" }).flatMap({ Int($0.1) }), size > writeLimit {
                    sendError(3, "file too large")
                    return
                }
                var url = server.resolveWrite(filename)
                if url == nil {
                    guard let folder = server.resolveWriteFolderHint() else {
                        sendError(2, "receiving files is off")
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
                        sendError(2, "file name not accepted")
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
                    sendError(1, "file not found")
                    return
                }
                readHandle = handle
                fileSize = size
            }

            var acked: [(String, String)] = []
            for (name, value) in options {
                switch name {
                case "blksize":
                    blockSize = min(max(Int(value) ?? 512, 8), 8192)
                    acked.append((name, "\(blockSize)"))
                case "tsize":
                    if isWrite {
                        // Echo only a number (RFC 2349); anything else is
                        // left out of the OACK, never reflected back.
                        guard let size = Int(value), size >= 0 else { break }
                        expectedTotal = size
                        acked.append((name, "\(size)"))
                    } else {
                        acked.append((name, "\(fileSize)"))
                    }
                case "timeout":
                    // RFC 2349: 1–255 seconds.
                    guard let seconds = Int(value), (1...255).contains(seconds) else { break }
                    acked.append((name, "\(seconds)"))
                default:
                    break
                }
            }

            openTransferPort()
            reportProgress(done: 0, total: isWrite ? (expectedTotal ?? 0) : fileSize, force: true)

            if !acked.isEmpty {
                var oack = Data([0, 6])
                for (name, value) in acked {
                    oack.append(contentsOf: name.utf8); oack.append(0)
                    oack.append(contentsOf: value.utf8); oack.append(0)
                }
                lastPacket = oack
                send(oack)
                scheduleRetransmit()
            } else if isWrite {
                sendAck(0)
            } else {
                sendDataBlock(1)
            }
            receiveNext()
        }

        // MARK: Read path (device pulls)

        private func handleAck(_ packet: Data) {
            guard !isWrite else { receiveNext(); return }
            guard packet.count >= 4 else { receiveNext(); return }
            let block = UInt16(packet[packet.startIndex + 2]) << 8 | UInt16(packet[packet.startIndex + 3])
            // Only the ACK for the block in flight advances (no Sorcerer's
            // Apprentice); lost packets are resent by the timer.
            guard block == currentBlock else { receiveNext(); return }
            retries = 0
            // Any ACK on our transfer port proves the peer, ACK 0 too (after
            // an OACK): a spoofer never saw that port. Without it a lost
            // DATA 1 was never resent and the read failed (review 6.0 (2)).
            peerProven = true
            if sentFinal {
                reportDone(done: fileSize)
                finish(nil)
                return
            }
            sendDataBlock(block &+ 1)
            receiveNext()
        }

        private func sendDataBlock(_ block: UInt16) {
            guard let handle = readHandle else { return }
            let offset = sendOffset(for: block)
            guard offset <= fileSize,
                  let chunk = try? { () -> Data in
                      try handle.seek(toOffset: UInt64(offset))
                      return try handle.read(upToCount: blockSize) ?? Data()
                  }() else {
                sendError(0, "read failed")
                return
            }
            var packet = Data([0, 3, UInt8(block >> 8), UInt8(block & 0xFF)])
            packet.append(chunk)
            currentBlock = block
            if chunk.count < blockSize { sentFinal = true }
            lastPacket = packet
            send(packet)
            reportProgress(done: min(offset + chunk.count, fileSize), total: fileSize)
            scheduleRetransmit()
        }

        /// Absolute file offset for a (possibly wrapped) block number.
        private var wrapCount = 0
        private var lastRawBlock: UInt16 = 0
        private func sendOffset(for block: UInt16) -> Int {
            if block < lastRawBlock && lastRawBlock &- block > 0x8000 {
                wrapCount += 1
            }
            lastRawBlock = block
            return (wrapCount * 65536 + Int(block) - 1) * blockSize
        }

        // MARK: Write path (device sends a backup)

        private func handleData(_ packet: Data) {
            // Receive into a hidden temp beside the target; it becomes the
            // real file only once the last block arrives, and only if the
            // name is still free (link(2) refuses to replace).
            // Only for a real block 1: a stray or short first packet must not
            // end "waiting for the first block" (`writeTemp == nil` is that
            // wait — ACK 0 is never repeated before block 1; review 6.0 (2)).
            if isWrite, currentBlock == 0, writeHandle == nil, writeTemp == nil, let url = writeFinal,
               packet.count >= 4, packet[packet.startIndex + 2] == 0, packet[packet.startIndex + 3] == 1 {
                let temp = url.deletingLastPathComponent()
                    .appendingPathComponent(".sheepterm-tftp-\(UUID().uuidString)")
                guard FileManager.default.createFile(atPath: temp.path, contents: nil),
                      let handle = try? FileHandle(forWritingTo: temp) else {
                    try? FileManager.default.removeItem(at: temp)
                    sendError(2, "cannot create file")
                    return
                }
                writeHandle = handle
                writeTemp = temp
            }
            guard isWrite, let handle = writeHandle else { receiveNext(); return }
            guard packet.count >= 4 else { receiveNext(); return }
            let block = UInt16(packet[packet.startIndex + 2]) << 8 | UInt16(packet[packet.startIndex + 3])
            let payload = packet.dropFirst(4)
            peerProven = true
            retries = 0
            if block == currentBlock &+ 1 {
                guard writtenBytes + payload.count <= writeLimit else {
                    sendError(3, "file too large")
                    return
                }
                do {
                    try handle.write(contentsOf: payload)
                } catch {
                    finish("write failed", failed: true)
                    return
                }
                writtenBytes += payload.count
                currentBlock = block
                reportProgress(done: writtenBytes, total: expectedTotal ?? 0)
            }
            // Last block = a short payload on the block just written.
            if block == currentBlock && payload.count < blockSize {
                try? handle.close()
                writeHandle = nil
                // The device announced the size (tsize): a file that did not
                // arrive whole is refused, never saved as a silently short
                // backup (a live Aruba CX run once lost its first block).
                if let expected = expectedTotal, expected > 0, writtenBytes != expected {
                    sendError(3, "size mismatch: got \(writtenBytes) of \(expected) bytes")
                    return
                }
                // Promote BEFORE the final ACK: the device hears success only
                // once the file is really in place.
                let saved = promoteWrite()
                guard saved == 0 else {
                    sendError(saved == EEXIST ? 6 : 3, saved == EEXIST ? "file already exists" : "could not save file")
                    return
                }
                sendAck(block)
                reportDone(done: writtenBytes)
                dallyForFinalAck(block)
                return
            }
            // A stale or out-of-order block re-ACKs what was really written,
            // never a block that was not.
            sendAck(currentBlock)
            receiveNext()
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

        /// RFC 1350 §6: after the last ACK, stay a few seconds and answer a
        /// repeat of the last block — if that ACK was lost the device would
        /// otherwise report a failure for a backup that is saved.
        private func dallyForFinalAck(_ block: UInt16) {
            generation += 1      // no retransmit timer now
            dallyReceive(block, until: Date().addingTimeInterval(3))
            server.serverQueue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish(nil) }
        }

        private func dallyReceive(_ block: UInt16, until deadline: Date) {
            io.receiveMessage { [weak self] data, _, _, error in
                guard let self, !self.finished else { return }
                guard error == nil, let data, data.count >= 4, Date() < deadline else { return }
                let isLastBlock = data[data.startIndex + 1] == 3
                    && UInt16(data[data.startIndex + 2]) << 8 | UInt16(data[data.startIndex + 3]) == block
                if isLastBlock { self.send(self.lastPacket) }
                self.dallyReceive(block, until: deadline)
            }
        }

        private func sendAck(_ block: UInt16) {
            let packet = Data([0, 4, UInt8(block >> 8), UInt8(block & 0xFF)])
            lastPacket = packet
            send(packet)
            scheduleRetransmit()
        }

        // MARK: Progress

        /// Throttled to ~128 KB so a big image doesn't flood main. Nothing
        /// shows until the peer is proven (its first DATA block, or an ACK on
        /// the transfer port): a bare or spoofed request repeated every few
        /// minutes kept an "active" bar up, so the server never turned itself
        /// off and the Transfer Log filled with timeouts (review 6.0 (4)).
        private var shown = false
        private func reportProgress(done: Int, total: Int, force: Bool = false) {
            guard peerProven else { return }
            let t = ServerTransfer(token: token, peer: peerHost, name: filename, isUpload: isWrite,
                                 done: Int64(done), total: Int64(total))
            lastActive = t
            if !shown || force || done - lastReported >= 128 * 1024 || (total > 0 && done >= total) {
                shown = true
                lastReported = done
                server.onProgress(t)
            }
        }

        private func reportDone(done: Int) {
            transferDone = true
            // A write saved beside a taken name shows (and logs) the name it got.
            let name = isWrite ? (writeFinal?.lastPathComponent ?? filename) : filename
            server.onProgress(ServerTransfer(token: token, peer: peerHost, name: name, isUpload: isWrite,
                                           done: Int64(done), total: Int64(done), state: .done))
        }

        // MARK: Plumbing

        private func send(_ packet: Data) {
            io.send(content: packet, completion: .contentProcessed { _ in })
        }

        /// Before a device's FIRST data block (a write) the OACK / ACK 0 is
        /// NOT repeated: a switch can take over 5 s to render its
        /// running-config, and an Aruba CX that receives the OACK twice
        /// restarts its numbering one chunk late — its first 1468 bytes never
        /// arrive (seen live 2026-10-25). If the OACK was really lost, the
        /// device repeats its WRQ (RFC 1350: the requester retransmits) and a
        /// new session answers it. This is how long we wait for block 1.
        static let firstDataWait: TimeInterval = 30

        private func scheduleRetransmit() {
            generation += 1
            let expected = generation
            // Waiting for the FIRST block (no temp yet) — not a block number
            // that wrapped back to 0 on a file past 32 MB × blksize.
            if isWrite && writeTemp == nil {
                server.serverQueue.asyncAfter(deadline: .now() + Self.firstDataWait) { [weak self] in
                    guard let self, !self.finished, self.generation == expected else { return }
                    self.finish("timed out", failed: true)
                }
                return
            }
            server.serverQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.finished, self.generation == expected else { return }
                self.retries += 1
                // No retransmit to a peer that never answered: a spoofed
                // request must not get a second block toward its "victim"
                // (security review 6.0). A real device asks again itself.
                if self.retries > (self.peerProven ? 5 : 0) {
                    self.finish("timed out", failed: true)
                } else {
                    self.send(self.lastPacket)
                    self.scheduleRetransmit()
                }
            }
        }

        private static func freeSpace(near folder: URL?) -> Int {
            guard let folder,
                  let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
                  let free = values.volumeAvailableCapacityForImportantUsage else { return Int.max }
            return Int(clamping: free)
        }

        private func sendError(_ code: UInt16, _ message: String) {
            var packet = Data([0, 5, UInt8(code >> 8), UInt8(code & 0xFF)])
            packet.append(contentsOf: message.utf8)
            packet.append(0)
            send(packet)
            // A refused request shows as a failed bar, so "file not found"
            // (a typo in the device command) is visible in the popover.
            if lastActive == nil {
                lastActive = ServerTransfer(token: token, peer: peerHost, name: filename.isEmpty ? "?" : filename,
                                          isUpload: isWrite, done: 0, total: 0)
            }
            finish(message, failed: true)
        }

        private func finish(_ detail: String?, failed: Bool = false) {
            guard !finished else { return }
            finished = true
            generation += 1
            try? readHandle?.close()
            readHandle = nil
            // Still holding a temp ⇒ the upload never completed; discard it.
            discardTemp()
            if var t = lastActive, !transferDone {
                t.state = .failed
                t.detail = detail ?? "interrupted"
                server.onProgress(t)
            }
            connection.cancel()
            // Not at once: an ERROR sent just before (mid-transfer) was
            // dropped with the flow and never reached the device.
            if let flow = transfer {
                server.serverQueue.asyncAfter(deadline: .now() + 0.3) { flow.cancel() }
            }
            server.sessionEnded(self)
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
