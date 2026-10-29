import Darwin
import Foundation
import SheepSSH

/// The SSH half of File ▸ File Server: an in-app SFTP + SCP server a switch
/// connects to (`copy sftp://sheepterm@<mac>/file …`, `copy scp://…`).
/// Ported from SheepDrop's server (SFTPServerListener / SFTPRequestHandler /
/// SCPServerHandler, proven against real Aruba gear); what changed is WHAT a
/// path resolves to — `FileServerAccess.readURL` / `writeURL` (one served
/// file, one write folder, never over an existing name) instead of a served
/// root folder — and the login, which is the one `access.username` /
/// `access.password` pair, compared in constant time inside SheepSSH.
///
/// - SSH is SheepSSH's server role (`SSHServerTransport` +
///   `SSHServerConnection`): ed25519 AND ssh-rsa host keys (ArubaOS `copy
///   scp:` fails against ed25519 only), modern algorithms first, the legacy
///   ones old switches need after them.
/// - One thread per connection (blocking pump: socket ↔ transport ↔
///   handler), one accept thread; caps: 16 connections, 4 per address;
///   30 s to log in, 10 min idle.
/// - Uploads land in a hidden temp beside the target and are promoted with
///   `renamex_np(RENAME_EXCL)`, which refuses an existing name — a device can
///   never replace a file on the Mac. 16 GB per upload, and never more than
///   the volume has free.
/// - Port 22 only (6.0 (13)), like TFTP's 69: a fallback port (2222 until
///   6.0 (12)) broke the copy commands of every device that cannot carry a
///   port (ArubaOS, Huawei, H3C, FortiGate …). A restart waits for the
///   listener a stop left closing — any server object's, `Closing` counts
///   them app-wide — and retries 22 for `FileServerPlan.sshBindWindow`;
///   still busy = the start fails with `PortInUse`, "Port 22 is in use by
///   Remote Login" (`FileServerPlan.sshPortHolder`) — the user turns Remote
///   Login off and starts again.
nonisolated final class SSHFileServer: @unchecked Sendable {
    static let maximumConnections = 16
    static let maximumPerPeer = 4
    /// Wrong passwords from one address before it waits out `lockout` —
    /// reconnecting used to be free (security review 6.0; same rule as FTP).
    static let maximumFailuresPerPeer = 9
    static let lockout: TimeInterval = 60
    /// One upload at most this big (a config backup is KBs; firmware goes
    /// the other way).
    static let maximumUpload: Int64 = FileServerPlan.maximumUpload

    struct Failure: Error, CustomStringConvertible {
        let description: String
        /// The errno of a failed bind/listen (0 = not a socket error).
        var code: Int32 = 0
    }

    /// The port stayed taken past `FileServerPlan.sshBindWindow`: the
    /// popover shows `description` as it is ("Port 22 is in use by …").
    struct PortInUse: Error, CustomStringConvertible {
        let description: String
    }

    /// Listening sockets a `stop()` has asked to close that the accept
    /// thread has not closed yet — of ANY server object (the app makes a new
    /// one per start), so the next start waits for them instead of reading
    /// our own closing socket as "in use".
    private enum Closing {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var count = 0
        static var busy: Bool { lock.withLock { count > 0 } }
        static func begin() { lock.withLock { count += 1 } }
        static func end() { lock.withLock { count -= 1 } }
    }

    let access: FileServerAccess
    let hostKeyDirectory: URL
    /// Version + kex + login must finish within this.
    var handshakeTimeout: TimeInterval = 30
    /// Version + key exchange alone: a device does that in well under a
    /// second; a connection that sits silent holds one of the 16 slots, so
    /// it gets this long, not the whole login time (review 6.0 (4)).
    var keyExchangeTimeout: TimeInterval = 10
    /// No byte from the client for this long ends the connection.
    var idleTimeout: TimeInterval = 600

    private let lock = NSLock()
    // Lock-protected.
    private var running = false
    private var listenFD: Int32 = -1
    private var wakePipe: (read: Int32, write: Int32) = (-1, -1)
    private var sessions: [ObjectIdentifier: Session] = [:]
    /// Failed logins per peer and when the last one was (lock).
    private var peerFailures: [String: (count: Int, last: Date)] = [:]

    /// False = this address is now locked out: the session ends at once,
    /// so the connections it already holds cannot keep guessing, and a
    /// login that lands while it is locked is not let in (review 6.0 (4)).
    @discardableResult
    fileprivate func noteLogin(from peer: String, ok: Bool) -> Bool {
        lock.withLock {
            if ok {
                guard !isLockedOut(peer) else { return false }
                peerFailures[peer] = nil
                return true
            }
            let previous = peerFailures[peer]
            peerFailures[peer] = ((previous?.count ?? 0) + 1, Date())
            return !isLockedOut(peer)
        }
    }

    /// Call with the lock held.
    private func isLockedOut(_ peer: String) -> Bool {
        guard let entry = peerFailures[peer] else { return false }
        if Date().timeIntervalSince(entry.last) > Self.lockout { peerFailures[peer] = nil; return false }
        return entry.count >= Self.maximumFailuresPerPeer
    }
    private var abortGeneration = 0
    private var temps: Set<String> = []
    private let threads = DispatchGroup()

    /// Uploads into this server's folder, for an SFTP/SCP handler (the
    /// harness drives an `SFTPServerHandler` with raw packets through it).
    var uploads: UploadFactory { UploadFactory(server: self) }

    init(access: FileServerAccess, hostKeyDirectory: URL) {
        self.access = access
        self.hostKeyDirectory = hostKeyDirectory
    }

    deinit {
        stop()
    }

    // MARK: Start / stop

    /// Loads (or makes) the host keys, binds and starts accepting. Binds
    /// `preferredPort` and nothing else (22 in the app; a free high port in
    /// the tests) and returns it; `preferredPort` 0 = any free port (tests).
    func start(preferredPort: UInt16 = 22) async throws -> UInt16 {
        let directory = hostKeyDirectory
        let task = Task.detached { () throws -> [SSHPrivateKey] in try HostKeyStore.ensureAll(directory: directory) }
        let keys = try await task.value
        let signers: [SSHSigner] = keys.map { PrivateKeySigner($0, label: "file server host key") }

        let bound = try await Self.bindPortOnly(preferredPort)

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            close(bound.fd)
            throw Failure(description: "pipe failed: \(String(cString: strerror(errno)))")
        }
        for fd in pipeFDs { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let started: Bool = lock.withLock {
            guard !running, listenFD < 0 else { return false }
            running = true
            listenFD = bound.fd
            wakePipe = (pipeFDs[0], pipeFDs[1])
            return true
        }
        guard started else {
            close(bound.fd); close(pipeFDs[0]); close(pipeFDs[1])
            throw Failure(description: "the server is already running")
        }
        threads.enter()
        // Constants for the thread (a captured var / non-Sendable array
        // warned); the signers are immutable keys read on that thread only.
        let wake = pipeFDs[0]
        let hostKeys = SignerList(signers)
        let thread = Thread { [self] in
            acceptLoop(listen: bound.fd, wake: wake, signers: hostKeys.signers)
            threads.leave()
        }
        thread.name = "sheepterm.ssh-file-server.accept"
        thread.start()
        return bound.port
    }

    /// Ends every connection, releases the port and removes every temp file
    /// an unfinished upload left. Waits (briefly) for the threads.
    func stop() {
        let (wasRunning, live, wake): (Bool, [Session], Int32) = lock.withLock {
            let was = running
            running = false
            if was { Closing.begin() }   // ended by acceptLoop once the socket is closed
            return (was, Array(sessions.values), wakePipe.write)
        }
        guard wasRunning else { return }
        if wake >= 0 { var byte: UInt8 = 1; _ = write(wake, &byte, 1) }
        for session in live { session.kill() }
        _ = threads.wait(timeout: .now() + 3)
        let leftovers: Set<String> = lock.withLock {
            defer { temps.removeAll() }
            return temps
        }
        for path in leftovers { unlink(path) }
    }

    /// Ends every upload in flight at once (their temps are dropped, their
    /// bars fail); reads and logins carry on.
    func abortWrites() {
        // Each session re-reads the generation on its next pump (≤ 100 ms).
        lock.withLock { abortGeneration += 1 }
    }

    fileprivate var currentAbortGeneration: Int { lock.withLock { abortGeneration } }
    fileprivate func registerTemp(_ path: String) { _ = lock.withLock { temps.insert(path) } }
    fileprivate func unregisterTemp(_ path: String) { _ = lock.withLock { temps.remove(path) } }

    // MARK: Socket

    /// `port`, retried while it is our own closing listener or still
    /// address-in-use, up to `FileServerPlan.sshBindWindow`; then
    /// `PortInUse` naming the holder. Never another port.
    private static func bindPortOnly(_ port: UInt16) async throws -> (fd: Int32, port: UInt16) {
        if port == 0 { return try bindAndListen(port: 0) }
        let deadline = Date().addingTimeInterval(FileServerPlan.sshBindWindow)
        while Closing.busy, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        var lastError: Failure?
        repeat {
            do { return try bindAndListen(port: port) } catch let error as Failure {
                lastError = error
                guard error.code == EADDRINUSE else { throw error }
                try? await Task.sleep(for: .milliseconds(150))
            }
        } while Date() < deadline
        if let lastError, lastError.code == EADDRINUSE {
            let process = TCPPortOwner.listener(port: port)
            // launchctl only when it can change the name, and never on the
            // cooperative pool (it blocks up to 2 s).
            let remoteLogin = FileServerPlan.needsRemoteLoginCheck(port: port, process: process)
                ? await TCPPortOwner.remoteLoginOnAsync() : false
            let holder = FileServerPlan.sshPortHolder(process: process, remoteLoginOn: remoteLogin)
            throw PortInUse(description: FileServerPlan.portBusyMessage(port: port, owner: holder))
        }
        throw lastError ?? Failure(description: "cannot listen on port \(port)")
    }

    private static func bindAndListen(port: UInt16) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket failed: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw Failure(description: "cannot listen on port \(port): \(String(cString: strerror(code)))", code: code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return (fd, UInt16(bigEndian: actual.sin_port))
    }

    private func acceptLoop(listen fd: Int32, wake: Int32, signers: [SSHSigner]) {
        defer {
            close(fd)
            Closing.end()   // only stop() ends the loop, and it began this
            lock.withLock {
                close(wakePipe.read); close(wakePipe.write)
                wakePipe = (-1, -1)
                listenFD = -1
            }
        }
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
        while lock.withLock({ running }) {
            let ready = poll(&fds, 2, 1000)
            if ready < 0, errno != EINTR { usleep(100_000); continue }
            guard lock.withLock({ running }) else { break }
            guard ready > 0, fds[0].revents & Int16(POLLIN) != 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if errno != EAGAIN && errno != EINTR { usleep(100_000) }   // EMFILE: do not spin
                continue
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            let peer = Self.peerHost(fd: client)
            let session = Session(server: self, fd: client, peer: peer, signers: signers)
            let admitted: Bool = lock.withLock {
                guard running, !isLockedOut(peer), sessions.count < Self.maximumConnections,
                      sessions.values.filter({ $0.peer == peer }).count < Self.maximumPerPeer else { return false }
                sessions[ObjectIdentifier(session)] = session
                return true
            }
            guard admitted else { close(client); continue }
            threads.enter()
            let thread = Thread { [self] in
                session.run()
                lock.withLock { sessions[ObjectIdentifier(session)] = nil }
                threads.leave()
            }
            thread.name = "sheepterm.ssh-file-server.session"
            thread.start()
        }
    }

    static func peerHost(fd: Int32) -> String {
        var addr = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) == 0 }
        }
        guard ok else { return "?" }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        let text = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        return text.hasPrefix("::ffff:") ? String(text.dropFirst(7)) : text
    }

    // MARK: - One connection

    /// Everything below runs on the session's own thread, except `kill` and
    /// `wake` (they only touch the socket / an atomic flag).
    fileprivate final class Session: @unchecked Sendable {
        unowned let server: SSHFileServer
        let fd: Int32
        let peer: String
        private let transport: SSHServerTransport
        private let connection: SSHServerConnection
        private var dead = false
        private var deadline: Date
        private let keyExchangeDeadline: Date
        private var seenAbort: Int
        private var sftp: (channel: UInt32, handler: SFTPServerHandler)?
        private var sftpInbox: [UInt8] = []
        /// The client sent EOF on the sftp channel; exit + CLOSE go out once
        /// the inbox is answered — still under the 2 MB back-pressure, so a
        /// client that queues 16 MB of READs and stops reading cannot make
        /// us buffer the gigabytes they ask for (security review 6.0 (4)).
        private var sftpEOF = false
        private var sftpExited = false
        private var scp: (channel: UInt32, io: ChannelIO)?
        private var serviceChosen = false
        private var channelClosed = false

        init(server: SSHFileServer, fd: Int32, peer: String, signers: [SSHSigner]) {
            self.server = server
            self.fd = fd
            self.peer = peer
            transport = SSHServerTransport(configuration: .init(softwareVersion: "SheepTerm_FileServer", hostKeys: signers))
            connection = SSHServerConnection(transport: transport, configuration: .init(
                username: server.access.username, password: server.access.password))
            deadline = Date().addingTimeInterval(server.handshakeTimeout)
            keyExchangeDeadline = Date().addingTimeInterval(min(server.keyExchangeTimeout, server.handshakeTimeout))
            seenAbort = server.currentAbortGeneration
        }

        func kill() { shutdown(fd, SHUT_RDWR) }

        func run() {
            defer {
                sftp?.handler.closeAll(reason: "connection ended")
                scp?.io.markDead()
                transport.disconnect()
                flush()
                close(fd)
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
            transport.start()
            // Handshake, login, the one channel the client opens.
            while !dead, !serviceChosen { pumpOnce() }
            if let scp, !dead {
                let handler = SCPServerHandler(io: scp.io, command: scp.io.command, access: server.access,
                                               peer: peer, uploads: uploadFactory())
                handler.run()
                return
            }
            while !dead, sftp != nil, !channelClosed { pumpOnce() }
        }

        func uploadFactory() -> UploadFactory {
            UploadFactory(server: server)
        }

        var abortRequested: Bool { server.currentAbortGeneration != seenAbort }

        // MARK: Pump

        /// Send what is queued, wait ≤100 ms for the client, route what came.
        func pumpOnce() {
            guard !dead else { return }
            flush()
            if abortRequested {
                seenAbort = server.currentAbortGeneration
                sftp?.handler.abortWrites()
                scp?.io.abortWrites = true
            }
            if Date() >= deadline || (transport.sessionID == nil && Date() >= keyExchangeDeadline) {
                transport.disconnect(reason: .byApplication, description: "timed out")
                flush()
                dead = true
                return
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 100)
            guard ready > 0 else {
                if ready < 0, errno != EINTR { dead = true }
                return
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            guard n > 0 else { dead = true; return }
            if connection.isAuthenticated { deadline = Date().addingTimeInterval(server.idleTimeout) }
            do {
                try transport.receive(buffer[0..<n])
                for event in transport.takeEvents() {
                    guard case .message(let payload) = event else { continue }
                    try connection.handle(payload)
                    route(connection.takeEvents())
                    if dead { return }
                }
            } catch {
                dead = true
            }
            serviceSFTPInbox()
        }

        /// Writes everything the transport has sealed; a client that stops
        /// reading for 30 s is dropped.
        func flush() {
            var out = transport.takeOutgoing()
            var offset = 0
            let limit = Date().addingTimeInterval(30)
            while offset < out.count {
                let n = out[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n > 0 { offset += n; continue }
                if n < 0, errno == EAGAIN || errno == EINTR {
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if Date() >= limit || poll(&p, 1, 1000) < 0 { dead = true; return }
                    continue
                }
                dead = true
                return
            }
            out.removeAll()
        }

        private func route(_ events: [SSHServerConnection.Event]) {
            for event in events {
                switch event {
                case .authenticated:
                    guard server.noteLogin(from: peer, ok: true) else { lockedOut(); return }
                    deadline = Date().addingTimeInterval(server.idleTimeout)
                case .passwordRejected:
                    guard server.noteLogin(from: peer, ok: false) else { lockedOut(); return }
                case .channelOpened:
                    break
                case .channelRequest(let id, let request):
                    choose(id, request)
                case .data(let id, let bytes):
                    if id == sftp?.channel, !sftpEOF {
                        sftpInbox += bytes
                        // A real client keeps a few MB in flight at most.
                        if sftpInbox.count > 16 * 1024 * 1024 { dead = true; return }
                    } else if id == scp?.channel {
                        scp?.io.feed(bytes)
                    }
                case .eof(let id):
                    if id == scp?.channel { scp?.io.markEOF() }
                    if id == sftp?.channel {
                        // Like sftp-server on stdin EOF: status 0, then EOF +
                        // CLOSE once the last replies are out (OpenSSH `sftp`
                        // waits for our CLOSE).
                        sftpEOF = true
                        serviceSFTPInbox()
                    }
                case .closed(let id):
                    if id == sftp?.channel || id == scp?.channel {
                        channelClosed = true
                        scp?.io.markDead()
                    }
                }
            }
        }

        private func lockedOut() {
            transport.disconnect(reason: .byApplication, description: "too many failed logins")
            flush()
            dead = true
        }

        /// One service per connection: the sftp subsystem or an scp exec.
        private func choose(_ id: UInt32, _ request: SSHServerConnection.ChannelRequest) {
            guard connection.isAuthenticated, !serviceChosen else {
                if case .refused = request { return }
                connection.replyRequest(id, success: false)
                return
            }
            switch request {
            case .subsystem("sftp"):
                connection.replyRequest(id, success: true)
                sftp = (id, SFTPServerHandler(access: server.access, peer: peer, uploads: uploadFactory()))
                serviceChosen = true
            case .exec(let command) where SCPServerHandler.parse(command) != nil:
                connection.replyRequest(id, success: true)
                scp = (id, ChannelIO(session: self, channel: id, command: command))
                serviceChosen = true
            case .subsystem, .exec:
                connection.replyRequest(id, success: false)
            case .refused:
                break
            }
        }

        /// Answers every complete SFTP packet, while the replies already
        /// queued for the client stay under 2 MB (READs are cheap to ask for).
        private func serviceSFTPInbox() {
            guard let (channel, handler) = sftp, !sftpExited else { return }
            var consumed = 0
            var waiting = false
            while sftpInbox.count - consumed >= 4 {
                if connection.pendingOutput(channel) > 2 * 1024 * 1024 { waiting = true; break }
                let b = sftpInbox[consumed..<(consumed + 4)].map(UInt32.init)
                let length = Int(b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3])
                guard length >= 1, length <= 256 * 1024 else { dead = true; return }
                guard sftpInbox.count - consumed >= 4 + length else { break }
                let packet = Array(sftpInbox[(consumed + 4)..<(consumed + 4 + length)])
                consumed += 4 + length
                let reply = handler.respond(to: packet)
                if !reply.isEmpty {
                    do { try connection.write(channel, reply) } catch { dead = true; return }
                }
            }
            if consumed > 0 { sftpInbox.removeFirst(consumed) }
            if sftpEOF, !waiting {
                sftpExited = true
                sftpInbox.removeAll()
                connection.sendExitStatus(channel: channel, code: 0)
                try? connection.finish(channel)
            }
        }

        // MARK: SCP channel plumbing

        fileprivate var isDead: Bool { dead }
        /// Ends the whole session (a client flooding a channel that is not
        /// being read — the same answer the SFTP inbox cap gives).
        fileprivate func abandon() { dead = true; shutdown(fd, SHUT_RDWR) }
        fileprivate var isChannelClosed: Bool { channelClosed }
        fileprivate func channelWrite(_ channel: UInt32, _ bytes: [UInt8]) -> Bool {
            guard !dead, connection.isWritable(channel) else { return false }
            do { try connection.write(channel, bytes) } catch { dead = true; return false }
            // Back-pressure: never more than 1 MB waiting for the window.
            while !dead, !channelClosed, connection.pendingOutput(channel) > 1024 * 1024 { pumpOnce() }
            flush()
            return !dead
        }
        fileprivate func channelExit(_ channel: UInt32, _ code: Int32) {
            connection.sendExitStatus(channel: channel, code: code)
            try? connection.finish(channel)
            // Let the tail, EOF and CLOSE out, and wait (briefly) for the
            // client's CLOSE.
            let until = Date().addingTimeInterval(5)
            while !dead, !channelClosed, Date() < until { pumpOnce() }
            flush()
        }
    }

    /// Blocking channel I/O for SCPServerHandler, driven by the session's
    /// pump on the same thread.
    fileprivate final class ChannelIO: SCPChannelIO {
        unowned let session: Session
        let channel: UInt32
        let command: String
        private var inbox: [UInt8] = []
        private var inboxStart = 0
        private var eof = false
        private var dead = false
        var abortWrites = false

        init(session: Session, channel: UInt32, command: String) {
            self.session = session
            self.channel = channel
            self.command = command
        }

        /// Bytes waiting for the handler. The window is topped up as data
        /// arrives, so a client that floods during `scp -f` (when nothing is
        /// read) must be cut off, not buffered without bound.
        static let maximumInbox = 16 * 1024 * 1024

        func feed(_ bytes: [UInt8]) {
            guard inbox.count - inboxStart + bytes.count <= Self.maximumInbox else { markDead(); session.abandon(); return }
            inbox += bytes
        }
        func markEOF() { eof = true }
        func markDead() { dead = true }

        var uploadAborted: Bool { abortWrites }

        func write(_ bytes: [UInt8]) -> Bool {
            guard !dead else { return false }
            return session.channelWrite(channel, bytes)
        }

        func read(max: Int) -> [UInt8]? {
            while inbox.count - inboxStart == 0 {
                if eof || dead || session.isDead || session.isChannelClosed { return nil }
                session.pumpOnce()
            }
            let end = min(inbox.count, inboxStart + max)
            let out = Array(inbox[inboxStart..<end])
            inboxStart = end
            if inboxStart == inbox.count { inbox.removeAll(keepingCapacity: true); inboxStart = 0 }
            return out
        }

        func exit(_ code: Int32) {
            guard !dead else { return }
            session.channelExit(channel, code)
        }
    }
}

// MARK: - Paths

/// How a device path maps onto the File Server's one-folder view. `/`, `.`
/// and `` are the (virtual) root, the only directory; any other path is a
/// NAME handed to `FileServerAccess` raw (FileServerPlan uses its last
/// component). A `..` component anywhere is refused outright.
nonisolated enum SSHServerPath {
    static func components(_ raw: String) -> [Substring] {
        raw.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "/" || $0 == "\\" })
    }

    static func isRoot(_ raw: String) -> Bool {
        components(raw).allSatisfy { $0 == "." }
    }

    static func climbs(_ raw: String) -> Bool {
        components(raw).contains("..")
    }

    /// REALPATH's answer: absolute, `.` dropped, `..` resolved lexically and
    /// never above `/`.
    static func canonical(_ raw: String) -> String {
        var out: [Substring] = []
        for part in components(raw) {
            if part == "." { continue }
            if part == ".." { _ = out.popLast(); continue }
            out.append(part)
        }
        return "/" + out.joined(separator: "/")
    }

    /// The served file for a device read, or nil.
    static func read(_ raw: String, _ access: FileServerAccess) -> URL? {
        guard !isRoot(raw), !climbs(raw) else { return nil }
        return access.readURL(raw)
    }

    /// Where a device write lands, or nil (writes off, bad name, name taken).
    static func write(_ raw: String, _ access: FileServerAccess) -> URL? {
        guard !isRoot(raw), !climbs(raw), let url = access.writeURL(raw) else { return nil }
        // Anything at all at that name — a file, a (dangling) symlink, a
        // directory — refuses the write; FileServerPlan's `exists` may follow
        // symlinks, lstat does not.
        var st = stat()
        guard lstat(url.path, &st) != 0, errno == ENOENT else { return nil }
        return url
    }
}

// MARK: - Uploads

/// Why an upload was refused.
nonisolated enum UploadRefusal: Error, CustomStringConvertible {
    case exists, tooBig, noSpace, cannotCreate(String)
    var description: String {
        switch self {
        case .exists: return "a file of that name already exists"
        case .tooBig: return "larger than \(SSHFileServer.maximumUpload / 1024 / 1024 / 1024) GB"
        case .noSpace: return "not enough free space on the Mac"
        case .cannotCreate(let why): return "cannot create the file: \(why)"
        }
    }
}

/// Makes `ServerUpload`s and keeps the server's list of temps, so `stop()`
/// can sweep what an interrupted session left.
nonisolated struct UploadFactory {
    fileprivate let server: SSHFileServer

    func begin(final: URL, announced: Int64?) -> Result<ServerUpload, UploadRefusal> {
        ServerUpload.begin(final: final, announced: announced, factory: self)
    }

    func registered(_ path: String) { server.registerTemp(path) }
    /// Writes still on and still into this folder (re-asked at commit).
    func stillWritable(_ final: URL) -> Bool { server.access.writeURL(final.lastPathComponent) == final }
    func released(_ path: String) { server.unregisterTemp(path) }
}

/// One upload: a hidden temp beside the target, written at offsets, promoted
/// to the final name only if that name is still free.
nonisolated final class ServerUpload {
    let final: URL
    let temp: URL
    private var fd: Int32
    /// Bytes this upload may grow to: 16 GB, or less if the volume has less.
    let limit: Int64
    private(set) var size: Int64 = 0
    private let factory: UploadFactory

    private init(final: URL, temp: URL, fd: Int32, limit: Int64, factory: UploadFactory) {
        self.final = final
        self.temp = temp
        self.fd = fd
        self.limit = limit
        self.factory = factory
    }

    static func freeSpace(at folder: URL) -> Int64? {
        var fs = statfs()
        guard statfs(folder.path, &fs) == 0 else { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    fileprivate static func begin(final: URL, announced: Int64?, factory: UploadFactory) -> Result<ServerUpload, UploadRefusal> {
        let folder = final.deletingLastPathComponent()
        // Less a reserve: concurrent uploads must not take the disk to zero.
        let free = max(0, (freeSpace(at: folder) ?? 0) - DownloadCap.reserve)
        if let announced {
            if announced > SSHFileServer.maximumUpload { return .failure(.tooBig) }
            if announced > free { return .failure(.noSpace) }
        }
        let limit = min(SSHFileServer.maximumUpload, free)
        guard limit > 0 else { return .failure(.noSpace) }
        let temp = folder.appendingPathComponent(".sheepterm-ssh-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .failure(.cannotCreate(String(cString: strerror(errno)))) }
        factory.registered(temp.path)
        return .success(ServerUpload(final: final, temp: temp, fd: fd, limit: limit, factory: factory))
    }

    /// How far past what is written a WRITE may start. Clients write in
    /// order with a few MB in flight; one byte at the 16 GB mark would make
    /// a disk (NTFS, FAT, exFAT, SMB) fill the gap with zeros before any
    /// budget sees it (review 6.0 (4)).
    static let maximumGap: Int64 = 64 * 1024 * 1024

    /// False: past the limit, too far ahead, or the disk refused.
    func write(_ bytes: ArraySlice<UInt8>, at offset: Int64) -> Bool {
        // `offset <= limit - count`, not `offset + count <= limit`: an SFTP
        // WRITE at Int64.max must be refused, not trap (review 6.0 (2)).
        guard fd >= 0, offset >= 0, offset <= limit - Int64(bytes.count),
              offset - size <= Self.maximumGap else { return false }
        var done = 0
        while done < bytes.count {
            let n = bytes[(bytes.startIndex + done)...].withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(offset) + off_t(done)) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            done += n
        }
        size = max(size, offset + Int64(bytes.count))
        return true
    }

    /// Closes and promotes the temp. `renamex_np(RENAME_EXCL)` refuses an
    /// existing final name — never a replace (works on APFS, HFS+, exFAT,
    /// SMB, where link(2) does not).
    func commit() -> Result<Void, UploadRefusal> {
        guard fd >= 0 else { return .failure(.cannotCreate("closed")) }
        let synced = fsync(fd) == 0
        close(fd)
        fd = -1
        guard synced else { discard(); return .failure(.cannotCreate("write failed")) }
        // Writes turned off (or the folder changed) while the bytes came in:
        // nothing lands.
        guard factory.stillWritable(final) else { discard(); return .failure(.cannotCreate("writes were turned off")) }
        guard renamex_np(temp.path, final.path, UInt32(RENAME_EXCL)) == 0 else {
            let err = errno          // read before discard() can change it
            discard()
            return .failure(err == EEXIST ? .exists : .cannotCreate(String(cString: strerror(err))))
        }
        factory.released(temp.path)
        Quarantine.mark(final)      // it came from the network, like a download
        return .success(())
    }

    func discard() {
        if fd >= 0 { close(fd); fd = -1 }
        unlink(temp.path)
        factory.released(temp.path)
    }

    deinit {
        if fd >= 0 { discard() }
    }
}

// MARK: - Progress

/// One transfer's bar, throttled to ~128 KB like TFTPServer.
nonisolated final class TransferReport {
    private let report: @Sendable (ServerTransfer) -> Void
    private var transfer: ServerTransfer
    private var lastReported: Int64 = 0
    private(set) var finished = false

    init(peer: String, name: String, isUpload: Bool, total: Int64, report: @escaping @Sendable (ServerTransfer) -> Void) {
        self.report = report
        transfer = ServerTransfer(token: UUID().uuidString, peer: peer, name: name, isUpload: isUpload,
                                  done: 0, total: total)
        report(transfer)
    }

    func progress(_ done: Int64) {
        guard !finished else { return }
        transfer.done = done
        if done - lastReported >= 128 * 1024 || (transfer.total > 0 && done >= transfer.total) {
            lastReported = done
            report(transfer)
        }
    }

    func done(_ total: Int64) {
        guard !finished else { return }
        finished = true
        transfer.done = total
        transfer.total = total
        transfer.state = .done
        report(transfer)
    }

    func failed(_ detail: String) {
        guard !finished else { return }
        finished = true
        transfer.state = .failed
        transfer.detail = detail
        report(transfer)
    }

    /// A request refused before any byte moved still shows as a failed bar,
    /// so a typo in the device command is visible in the popover.
    static func refused(peer: String, name: String, isUpload: Bool, detail: String,
                        report: @escaping @Sendable (ServerTransfer) -> Void) {
        var t = ServerTransfer(token: UUID().uuidString, peer: peer, name: name.isEmpty ? "?" : name,
                               isUpload: isUpload, done: 0, total: 0)
        t.state = .failed
        t.detail = detail
        report(t)
    }
}

/// The host keys handed to the accept thread once, never mutated.
nonisolated private struct SignerList: @unchecked Sendable {
    let signers: [any SSHSigner]
    init(_ signers: [any SSHSigner]) { self.signers = signers }
}

